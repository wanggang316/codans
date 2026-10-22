import AppKit
import CodansCore

/// What a close would take with it, for the confirmation prompt.
struct CloseConfirmationPrompt: Equatable {
  enum Subject: Equatable {
    case pane
    case tab
    /// Several tabs at once (close others / to the right / all).
    case tabs(Int)
  }

  var subject: Subject
  /// Queued commands across the affected Tabs; discarded by the close.
  var queuedCount: Int
  /// Whether an affected Tab runs a foreground command or a working agent.
  var isRunning: Bool

  /// "3 queued commands will be discarded." — shared with the sidebar's
  /// Remove Worktree / Remove Project prompts so the wording matches.
  static func discardNotice(_ count: Int) -> String {
    count == 1
      ? "1 queued command will be discarded."
      : "\(count) queued commands will be discarded."
  }
}

/// Sheet asking whether to close a pane or tab, per the "Confirm before
/// closing a tab" setting.
///
/// Presented as a sheet on the key window and answered through a completion
/// rather than `runModal()`: the close requests that reach it are sent from
/// inside reducers, and a nested modal run loop there would re-enter the
/// store. Cancel is the default — the prompt exists to protect work that
/// cannot be recovered, so Return keeps it and Close takes a click.
@MainActor
enum CloseConfirmationDialog {
  static func present(
    _ prompt: CloseConfirmationPrompt,
    completion: @escaping @MainActor (Bool) -> Void
  ) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = Self.title(for: prompt.subject)
    alert.informativeText = Self.detail(for: prompt)
    // First button takes Return; a button titled "Cancel" takes Escape too.
    alert.addButton(withTitle: "Cancel")
    let close = alert.addButton(withTitle: "Close")
    close.hasDestructiveAction = true

    if let window = NSApp.keyWindow ?? NSApp.mainWindow {
      alert.beginSheetModal(for: window) { response in
        completion(response == .alertSecondButtonReturn)
      }
    } else {
      completion(alert.runModal() == .alertSecondButtonReturn)
    }
  }

  private static func title(for subject: CloseConfirmationPrompt.Subject) -> String {
    switch subject {
    case .pane: return "Close this pane?"
    case .tab: return "Close this tab?"
    case .tabs(let count): return "Close \(count) tabs?"
    }
  }

  private static func detail(for prompt: CloseConfirmationPrompt) -> String {
    var lines: [String] = []
    if prompt.isRunning {
      lines.append("A command or agent is still running and will be stopped.")
    }
    if prompt.queuedCount > 0 {
      lines.append(CloseConfirmationPrompt.discardNotice(prompt.queuedCount))
    }
    return lines.joined(separator: " ")
  }
}
