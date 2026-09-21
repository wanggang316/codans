import Foundation

/// What removing a workspace may touch beyond the catalog entry. The
/// default touches nothing on disk: the checkouts and their branches stay
/// exactly where they are.
public nonisolated struct WorkspaceCleanup: Codable, Equatable, Sendable {
  /// Unregister every member checkout from its source repository and delete
  /// the workspace folder.
  public var deleteFiles: Bool
  /// After a member's checkout is gone, also delete the branch it was on.
  /// Ignored unless `deleteFiles` is set.
  public var deleteBranches: Bool

  public init(deleteFiles: Bool = false, deleteBranches: Bool = false) {
    self.deleteFiles = deleteFiles
    self.deleteBranches = deleteBranches
  }

  public static let entryOnly = WorkspaceCleanup()
}

/// What a workspace removal actually did. `failures` names members whose
/// checkout could not be unregistered; when any exist the folder is left in
/// place, since deleting it would strand a worktree registration in the
/// source repository.
public nonisolated struct WorkspaceRemovalOutcome: Codable, Equatable, Sendable {
  public let deletedFolder: Bool
  public let failures: [String]
  /// Branches kept because git refused to delete them (checked out
  /// elsewhere), by member name.
  public let keptBranches: [String]

  public init(deletedFolder: Bool, failures: [String] = [], keptBranches: [String] = []) {
    self.deletedFolder = deletedFolder
    self.failures = failures
    self.keptBranches = keptBranches
  }
}
