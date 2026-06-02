import Foundation

/// A single changed file in a worktree, built by
/// `GitOutputParser.joinDiffNumstatNameStatus` from `git diff --numstat -z`
/// + `git diff --name-status -z` and returned by `GitService.diffNumstat`.
/// `addedLines` / `removedLines` are `-1` sentinels for binary files
/// (see `isBinary`).
///
/// `public` because the `GitService` protocol (also `public`) takes this as a
/// return type — Swift won't let a public method's result be internal even
/// when both live in the same module.
public nonisolated struct ChangedFile: Equatable, Identifiable, Sendable {
  public var id: String { newPath ?? oldPath ?? "" }
  public let oldPath: String?
  public let newPath: String?
  public let status: ChangeStatus
  public let addedLines: Int
  public let removedLines: Int
  public let isBinary: Bool

  public init(
    oldPath: String?,
    newPath: String?,
    status: ChangeStatus,
    addedLines: Int,
    removedLines: Int,
    isBinary: Bool
  ) {
    self.oldPath = oldPath
    self.newPath = newPath
    self.status = status
    self.addedLines = addedLines
    self.removedLines = removedLines
    self.isBinary = isBinary
  }
}

public nonisolated enum ChangeStatus: String, Equatable, Sendable {
  case modified
  case added
  case deleted
  case renamed
}
