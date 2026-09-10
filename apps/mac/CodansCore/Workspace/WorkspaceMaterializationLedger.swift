import Foundation

/// Records what workspace creation has produced so far, so a failure or a
/// cancellation midway can undo exactly that and nothing else.
///
/// The ledger is pure bookkeeping — the app tier runs the git and
/// filesystem commands for each step. Steps are recorded in the order they
/// happened and undone in reverse: a worktree is unregistered before the
/// branch it was created on is deleted (git refuses to delete a branch that
/// is still checked out), and the root folder goes last.
public nonisolated struct WorkspaceMaterializationLedger: Equatable, Sendable {
  public enum Step: Equatable, Sendable {
    /// A folder this creation made; removed on rollback. Never recorded for
    /// a folder that already existed.
    case createdDirectory(path: String)
    /// A branch `git worktree add -b` created in the source repository.
    /// Recorded before `addedWorktree` so the reverse order deletes the
    /// branch after the worktree is gone.
    case createdBranch(repoRoot: String, branch: String)
    /// A worktree registered in the source repository at `path`.
    case addedWorktree(repoRoot: String, path: String)
  }

  public private(set) var steps: [Step] = []

  public init() {}

  public mutating func record(_ step: Step) {
    steps.append(step)
  }

  /// Steps in undo order.
  public var rollbackSteps: [Step] {
    steps.reversed()
  }

  public var isEmpty: Bool { steps.isEmpty }
}
