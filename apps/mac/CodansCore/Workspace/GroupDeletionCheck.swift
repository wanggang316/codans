import Foundation

/// What deleting a named group would destroy, collected without side
/// effects. Risks need explicit acknowledgment; a failed probe blocks the
/// delete until a retry succeeds.
public nonisolated struct GroupDeletionCheck: Codable, Equatable, Sendable {
  /// Findings for one member checkout of the group.
  public struct Member: Codable, Equatable, Sendable {
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
    /// The folder is still on disk, but its source no longer lists it as a
    /// worktree (an earlier removal stopped part way). Its files cannot be
    /// probed; the delete removes the folder itself, so it is a risk.
    public var residualFolder: Bool
    /// The group created this member's branch. A migrated member records no
    /// created branch, so its branch is never deleted.
    public var createdBranch: Bool

    public init(
      name: String,
      worktreeID: WorktreeID,
      path: String,
      branch: String? = nil,
      uncommittedCount: Int = 0,
      unpushedCount: Int = 0,
      deletableBranches: [String] = [],
      checkFailure: String? = nil,
      residualFolder: Bool = false,
      createdBranch: Bool = true
    ) {
      self.createdBranch = createdBranch
      self.name = name
      self.worktreeID = worktreeID
      self.path = path
      self.branch = branch
      self.uncommittedCount = uncommittedCount
      self.unpushedCount = unpushedCount
      self.deletableBranches = deletableBranches
      self.checkFailure = checkFailure
      self.residualFolder = residualFolder
    }

    private enum CodingKeys: String, CodingKey {
      case name, worktreeID, path, branch, uncommittedCount, unpushedCount, deletableBranches, checkFailure
      case residualFolder, createdBranch
    }

    // The two flags are optional on the wire, so a payload without them
    // still decodes.
    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.init(
        name: try container.decode(String.self, forKey: .name),
        worktreeID: try container.decode(WorktreeID.self, forKey: .worktreeID),
        path: try container.decode(String.self, forKey: .path),
        branch: try container.decodeIfPresent(String.self, forKey: .branch),
        uncommittedCount: try container.decode(Int.self, forKey: .uncommittedCount),
        unpushedCount: try container.decode(Int.self, forKey: .unpushedCount),
        deletableBranches: try container.decode([String].self, forKey: .deletableBranches),
        checkFailure: try container.decodeIfPresent(String.self, forKey: .checkFailure),
        residualFolder: try container.decodeIfPresent(Bool.self, forKey: .residualFolder) ?? false,
        createdBranch: try container.decodeIfPresent(Bool.self, forKey: .createdBranch) ?? true)
    }

    public var hasRisks: Bool { uncommittedCount > 0 || unpushedCount > 0 || residualFolder }
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
