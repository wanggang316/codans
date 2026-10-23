import Foundation

/// What deleting a named group would destroy, collected without side
/// effects. Risks need explicit acknowledgment; a failed probe blocks the
/// delete until a retry succeeds.
public nonisolated struct GroupDeletionCheck: Equatable, Sendable {
  /// Findings for one member checkout of the group.
  public struct Member: Equatable, Sendable {
    public var name: String
    public var worktreeID: WorktreeID
    /// Absolute checkout path.
    public var path: String
    /// Live branch, `nil` when detached.
    public var branch: String?
    /// Files `git status` reports as changed or untracked.
    public var uncommittedCount: Int
    /// Commits that no upstream or other ref holds.
    public var unpushedCount: Int
    /// Branches the delete-branch option would delete for this member.
    public var deletableBranches: [String]
    /// Why a probe of this member failed; any value blocks the delete.
    public var checkFailure: String?

    public init(
      name: String,
      worktreeID: WorktreeID,
      path: String,
      branch: String? = nil,
      uncommittedCount: Int = 0,
      unpushedCount: Int = 0,
      deletableBranches: [String] = [],
      checkFailure: String? = nil
    ) {
      self.name = name
      self.worktreeID = worktreeID
      self.path = path
      self.branch = branch
      self.uncommittedCount = uncommittedCount
      self.unpushedCount = unpushedCount
      self.deletableBranches = deletableBranches
      self.checkFailure = checkFailure
    }

    public var hasRisks: Bool { uncommittedCount > 0 || unpushedCount > 0 }
  }

  public var projectID: ProjectID
  public var groupID: WorkspaceGroupID
  public var groupName: String
  public var members: [Member]
  /// Panes of the group row and its member rows that are running something.
  public var busyPaneIDs: [PaneID]
  /// Entries of the group directory that are not member checkouts (named
  /// groups only; never for a group at the Workspace root).
  public var extraEntries: [String]
  /// Failures that belong to no member (group directory unreadable, …).
  public var groupCheckFailures: [String]

  public init(
    projectID: ProjectID,
    groupID: WorkspaceGroupID,
    groupName: String,
    members: [Member] = [],
    busyPaneIDs: [PaneID] = [],
    extraEntries: [String] = [],
    groupCheckFailures: [String] = []
  ) {
    self.projectID = projectID
    self.groupID = groupID
    self.groupName = groupName
    self.members = members
    self.busyPaneIDs = busyPaneIDs
    self.extraEntries = extraEntries
    self.groupCheckFailures = groupCheckFailures
  }

  /// Something would be lost; the request must acknowledge it.
  public var hasRisks: Bool {
    members.contains(where: \.hasRisks) || !busyPaneIDs.isEmpty || !extraEntries.isEmpty
  }

  /// A probe failed; the delete cannot run until a retry succeeds.
  public var isBlocked: Bool {
    !groupCheckFailures.isEmpty || members.contains { $0.checkFailure != nil }
  }
}

/// A destructive group delete request.
public nonisolated struct GroupDeletionRequest: Equatable, Sendable {
  /// Also delete each member branch the check lists as deletable.
  public var deleteBranches: Bool
  /// The caller saw the check's risks and accepts losing them.
  public var acknowledgeRisks: Bool

  public init(deleteBranches: Bool = false, acknowledgeRisks: Bool = false) {
    self.deleteBranches = deleteBranches
    self.acknowledgeRisks = acknowledgeRisks
  }
}

/// What a group delete did. With any failure the group stays, with its
/// `deletion` state set, so a retry can finish the job.
public nonisolated struct GroupDeletionOutcome: Equatable, Sendable {
  public struct Failure: Equatable, Sendable {
    public var name: String
    public var path: String
    public var reason: String

    public init(name: String, path: String, reason: String) {
      self.name = name
      self.path = path
      self.reason = reason
    }
  }

  /// The group, its directory (when owned), and its rows are gone.
  public var deletedGroup: Bool
  public var removedMembers: [String]
  public var deletedBranches: [String]
  /// Branches git refused to delete, with the reason.
  public var keptBranches: [String]
  public var failures: [Failure]

  public init(
    deletedGroup: Bool,
    removedMembers: [String] = [],
    deletedBranches: [String] = [],
    keptBranches: [String] = [],
    failures: [Failure] = []
  ) {
    self.deletedGroup = deletedGroup
    self.removedMembers = removedMembers
    self.deletedBranches = deletedBranches
    self.keptBranches = keptBranches
    self.failures = failures
  }
}

/// How to remove a Workspace. Both modes keep every source main checkout.
public nonisolated enum WorkspaceRemovalRequest: Equatable, Sendable {
  /// Remove the catalog entry only. Disk unchanged.
  case sidebarOnly
  /// Delete every named group, the default links and directory, then the
  /// root when every group is gone and the root is owned. The catalog entry
  /// goes only on full success.
  case deleteOwnedFiles(GroupDeletionRequest)
}
