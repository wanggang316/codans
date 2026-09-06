import AppKit

/// What a close would take with it, for the confirmation prompt.
struct QueuedCommandDiscard: Equatable {
  enum Subject: Equatable {
    case pane
    case tab
    /// Several tabs at once (close others / to the right / all).
    case tabs(Int)
  }

  var subject: Subject
  var queuedCount: Int

  /// "3 queued commands will be discarded." — shared with the sidebar's
  /// Remove Worktree / Remove Project prompts so the wording matches.
  static func discardNotice(_ count: Int) -> String {
    count == 1
      ? "1 queued command will be discarded."
      : "\(count) queued commands will be discarded."
  }
}

/// Sheet asking whether to close a pane or tab that still holds queued
/// commands. The queue lives on the pane, so closing the pane discards it
/// silently; this is the one place the user learns that before it happens.
///
/// Presented as a sheet on the key window and answered through a completion
/// rather than `runModal()`: the close requests that reach it are sent from
/// inside reducers, and a nested modal run loop there would re-enter the
/// store. Cancel is the default — the prompt exists to protect work that
/// cannot be recovered, so Return keeps it and Close Anyway takes a click.
@MainActor
enum QueuedCommandsCloseDialog {
  static func present(
    _ discard: QueuedCommandDiscard,
    completion: @escaping @MainActor (Bool) -> Void
  ) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = Self.title(for: discard.subject)
    alert.informativeText = QueuedCommandDiscard.discardNotice(discard.queuedCount)
    // First button takes Return; a button titled "Cancel" takes Escape too.
    alert.addButton(withTitle: "Cancel")
    let close = alert.addButton(withTitle: "Close Anyway")
    close.hasDestructiveAction = true

    if let window = NSApp.keyWindow ?? NSApp.mainWindow {
      alert.beginSheetModal(for: window) { response in
        completion(response == .alertSecondButtonReturn)
      }
    } else {
      completion(alert.runModal() == .alertSecondButtonReturn)
    }
  }

  private static func title(for subject: QueuedCommandDiscard.Subject) -> String {
    switch subject {
    case .pane: return "Close this pane?"
    case .tab: return "Close this tab?"
    case .tabs(let count): return "Close \(count) tabs?"
    }
  }
}
