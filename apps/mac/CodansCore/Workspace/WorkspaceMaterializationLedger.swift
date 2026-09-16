import Foundation

/// Records what workspace creation has produced so far, so a failure or a
/// cancellation midway can undo exactly that and nothing else.
///
/// The ledger is pure bookkeeping — the app tier runs the git and
/// filesystem commands for each step. Steps are recorded in the order they
/// happened and undone in reverse: a worktree is unregistered before the
/// branch it was created on is deleted or moved back (git refuses to touch a
/// branch that is still checked out), a clone is deleted after the worktree
/// it served is gone, and the root folder goes last.
public nonisolated struct WorkspaceMaterializationLedger: Equatable, Sendable {
  public enum Step: Equatable, Sendable {
    /// A folder this creation made; removed on rollback. Never recorded for
    /// a folder that already existed.
    case createdDirectory(path: String)
    /// A repository this creation cloned to serve as a member's source;
    /// deleted on rollback. Never recorded for a clone that already existed
    /// and was reused.
    case clonedRepository(path: String)
    /// A branch `git worktree add -b` created in the source repository.
    /// Recorded before `addedWorktree` so the reverse order deletes the
    /// branch after the worktree is gone.
    case createdBranch(repoRoot: String, branch: String)
    /// A branch `git worktree add -B` pointed at a new tip. Rollback moves it
    /// back to `previousTip` rather than deleting it: the branch predates
    /// this creation and its commits are the user's.
    case resetBranch(repoRoot: String, branch: String, previousTip: String)
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
