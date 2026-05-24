import AppKit
import TouchCodeCore

/// Outcome of the quit confirmation dialog. Maps onto the runtime branches dispatched by
/// `applicationShouldTerminate`: `keepRunning` / `snapshot` route through
/// `SessionLifecycle.detachAllForQuit(action:)`, `discard` routes through
/// `SessionLifecycle.killAllForQuit()`, and `cancel` aborts the quit.
@MainActor
enum QuitChoice {
  /// Detach the daemons; long-running commands keep running and reattach next launch.
  case keepRunning
  /// Snapshot each pane's visible buffer; the daemons exit cleanly.
  case snapshot
  /// Kill every daemon immediately. No resume on next launch.
  case discard
  /// User changed their mind; abort the quit.
  case cancel
}

/// Modal NSAlert presented from `applicationShouldTerminate` when the user's
/// `QuitStrategy` is `.ask` and at least one pane is live.
///
/// `NSAlert.runModal()` is synchronous and runs on the main thread; that is the right tool
/// here because `applicationShouldTerminate` already blocks AppKit's terminate sequence
/// until we return a `TerminateReply`. The dialog therefore exposes a synchronous
/// `present(...)` entry point — no async hop required.
@MainActor
enum QuitConfirmationDialog {
  /// Present the dialog. Returns the user's chosen `QuitChoice`. When the user ticks
  /// "Don't ask again" and picks Keep Running or Snapshot, `rememberClosure` is invoked
  /// with the corresponding `QuitStrategy` so the caller can persist the choice.
  /// Cancel / Discard ignore the checkbox state — discard is a one-off and cancel does
  /// not represent a strategy.
  ///
  /// `paneCount` is the number of live panes shown in the alert body. Callers should
  /// short-circuit and skip the dialog entirely when this is zero.
  static func present(
    paneCount: Int,
    rememberClosure: @MainActor (QuitStrategy) -> Void
  ) -> QuitChoice {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "\(paneCount) panes are running. How should they be handled?"
    alert.informativeText =
      "Keep Running lets long-running commands continue. "
      + "Snapshot preserves the visible buffer for next launch. "
      + "Discard kills the panes immediately."

    // Order matters: the first button added is the default (Enter), the button titled
    // "Cancel" is automatically wired to Escape by AppKit.
    let keepButton = alert.addButton(withTitle: "Keep Running")
    keepButton.keyEquivalent = "\r"
    alert.addButton(withTitle: "Snapshot")
    alert.addButton(withTitle: "Discard")
    alert.addButton(withTitle: "Cancel")

    let rememberCheckbox = NSButton(
      checkboxWithTitle: "Don't ask again for the chosen option",
      target: nil,
      action: nil
    )
    rememberCheckbox.state = .off
    // Size the checkbox to its intrinsic content so the alert lays it out cleanly.
    rememberCheckbox.sizeToFit()
    alert.accessoryView = rememberCheckbox

    let response = alert.runModal()
    let remember = rememberCheckbox.state == .on

    switch response {
    case .alertFirstButtonReturn:
      if remember { rememberClosure(.keepRunning) }
      return .keepRunning
    case .alertSecondButtonReturn:
      if remember { rememberClosure(.snapshot) }
      return .snapshot
    case .alertThirdButtonReturn:
      // Discard is a one-off; ignore the "don't ask again" checkbox so the user does
      // not accidentally pin the destructive option as their default strategy.
      return .discard
    default:
      // Fourth (or Cmd-.) → Cancel.
      return .cancel
    }
  }
}
