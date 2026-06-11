import AppKit
import CodansCore

/// Outcome of the quit confirmation dialog. Maps onto the runtime branches dispatched by
/// `applicationShouldTerminate`: `keepRunning` / `snapshot` route through
/// `SessionLifecycle.detachAllForQuit(action:)`, and `cancel` aborts the quit.
@MainActor
enum QuitChoice {
  /// Detach the daemons; long-running commands keep running and reattach next launch.
  case keepRunning
  /// Snapshot each pane's visible buffer; the daemons exit cleanly.
  case snapshot
  /// User changed their mind; abort the quit.
  case cancel
}

/// Modal NSAlert presented from `applicationShouldTerminate` whenever the user's
/// `QuitConfirmation` setting calls for a prompt.
///
/// `NSAlert.runModal()` is synchronous and runs on the main thread; that is the right tool
/// here because `applicationShouldTerminate` already blocks AppKit's terminate sequence
/// until we return a `TerminateReply`. The dialog therefore exposes a synchronous
/// `present(...)` entry point — no async hop required.
@MainActor
enum QuitConfirmationDialog {
  /// Present the dialog. Returns the user's chosen `QuitChoice`.
  ///
  /// `paneCount` is the number of live panes shown in the alert body. The dialog itself
  /// does not gate on that count — the caller decides via `QuitConfirmation` whether to
  /// present at all — but the message text reflects it so the user sees what's at stake.
  ///
  /// `defaultAction` selects which non-cancel button is wired to Return (Enter) and is
  /// the focused choice on open. The setting's "On quit" action picker therefore steers
  /// the dialog's default-button bias.
  static func present(
    paneCount: Int,
    defaultAction: QuitAction
  ) -> QuitChoice {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "\(paneCount) panes are running. How should they be handled?"
    alert.informativeText =
      "Keep session running lets long-running commands continue. "
      + "Snapshot and exit preserves the visible buffer for next launch."

    // NSAlert wires the FIRST button to Return by default; we lay the buttons out with the
    // user's preferred action first so the focused-button bias matches the setting. The
    // button titled "Cancel" is automatically wired to Escape by AppKit regardless of
    // position.
    switch defaultAction {
    case .keepRunning:
      let keep = alert.addButton(withTitle: "Keep session running")
      keep.keyEquivalent = "\r"
      alert.addButton(withTitle: "Snapshot and exit")
    case .snapshot:
      let snapshot = alert.addButton(withTitle: "Snapshot and exit")
      snapshot.keyEquivalent = "\r"
      alert.addButton(withTitle: "Keep session running")
    }
    alert.addButton(withTitle: "Cancel")

    let response = alert.runModal()
    // First button = `defaultAction`, second button = the other option, third = Cancel.
    // Resolve `response` against `defaultAction` so the user's preferred button keeps
    // returning the choice it advertises regardless of layout order.
    switch response {
    case .alertFirstButtonReturn:
      switch defaultAction {
      case .keepRunning: return .keepRunning
      case .snapshot: return .snapshot
      }
    case .alertSecondButtonReturn:
      switch defaultAction {
      case .keepRunning: return .snapshot
      case .snapshot: return .keepRunning
      }
    default:
      // Third (or Cmd-.) → Cancel.
      return .cancel
    }
  }
}
