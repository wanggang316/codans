import Foundation

/// The on-disk shape of the handoff artifact, spelled once.
///
/// Two consumers need the same names in two different forms: `HandoffStore`
/// builds `URL`s to read and write the files, and `HandoffKickoff` writes
/// worktree-relative strings into the prompt the receiving agent starts
/// with. Every path handed to an agent or a CLI caller is worktree-relative
/// (`.codans/handoff/…`): agents read from the worktree root. Before this type each spelled the layout itself, so a rename in the
/// store would have left the prompt pointing at files that no longer existed
/// — and nothing would have failed until an agent went looking.
public nonisolated enum HandoffLayout {
  /// Per-worktree state directory codans owns; `handoff/` lives inside it.
  public static let stateDirectoryName = ".codans"
  public static let directoryName = "handoff"

  /// Agent-authored briefing. Absent when the last transition had none.
  public static let briefingFileName = "current.md"
  /// codans-generated repository and session state; rewritten every save.
  public static let contextFileName = "context.md"
  /// Append-only history of transitions and checkpoints.
  public static let logFileName = "log.md"
  /// Makes `.codans/` ignore itself. Lives at the state directory's root,
  /// not inside `handoff/`: anything that lands one level up must stay out
  /// of `git status` too, or it shows up in the next `context.md`.
  public static let ignoreFileName = ".gitignore"
  /// Outgoing snapshot of each transition.
  public static let archiveDirectoryName = "archive"
  /// Screen excerpt captured per save.
  public static let sessionsDirectoryName = "sessions"

  /// `.codans/handoff` — the directory as the receiver sees it from the
  /// worktree root.
  public static var worktreeRelativeDirectory: String {
    "\(stateDirectoryName)/\(directoryName)"
  }

  /// `.codans/handoff/<name>`. Pass a directory name with a trailing slash
  /// preserved by the caller if it wants one; this only joins.
  public static func worktreeRelativePath(_ name: String) -> String {
    "\(worktreeRelativeDirectory)/\(name)"
  }
}
