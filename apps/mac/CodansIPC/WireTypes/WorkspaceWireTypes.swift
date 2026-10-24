import CodansCore
import Foundation

extension IPC {
  /// One source project of a workspace. Exactly one of `projectID` (a
  /// registered local Project), `path` (a folder inside any local
  /// repository that is not bare), or `remoteURL` (cloned first) names it;
  /// the server resolves each to the repository's main checkout. A source
  /// creates no branch and checks nothing out.
  public struct WorkspaceSourceRequest: Codable, Equatable, Sendable {
    /// Link name inside the `default` group; defaults to the repository's
    /// folder name.
    public let name: String?
    public let projectID: ProjectID?
    public let path: String?
    /// A remote to clone. The clone lands in `cloneDestination`, or under
    /// the request's clone base directory (default
    /// `~/.codans/sources/<name>`); an existing clone of the same remote
    /// there is reused.
    public let remoteURL: String?
    public let cloneDestination: String?

    public init(
      name: String? = nil,
      projectID: ProjectID? = nil,
      path: String? = nil,
      remoteURL: String? = nil,
      cloneDestination: String? = nil,
    ) {
      self.name = name
      self.projectID = projectID
      self.path = path
      self.remoteURL = remoteURL
      self.cloneDestination = cloneDestination
    }

    private enum CodingKeys: String, CodingKey {
      case name, projectID, path, remoteURL, cloneDestination
    }

    public init(from decoder: Decoder) throws {
      try RetiredWireKeys.reject(
        ["branch", "baseRef", "useExistingBranch", "remoteRef", "resetLocalBranch", "role"],
        in: decoder, reason: RetiredWireKeys.branchesBelongToGroups)
      let container = try decoder.container(keyedBy: CodingKeys.self)
      name = try container.decodeIfPresent(String.self, forKey: .name)
      projectID = try container.decodeIfPresent(ProjectID.self, forKey: .projectID)
      path = try container.decodeIfPresent(String.self, forKey: .path)
      remoteURL = try container.decodeIfPresent(String.self, forKey: .remoteURL)
      cloneDestination = try container.decodeIfPresent(String.self, forKey: .cloneDestination)
    }
  }

  /// Params for `workspace.create`: a root and its source projects only.
  /// Branches belong to `workspace.createGroup`.
  public struct WorkspaceCreateRequest: Codable, Equatable, Sendable {
    public let title: String
    /// Defaults to `~/.codans/workspaces/<slug>`, suffixed when taken.
    public let rootPath: String?
    public let description: String?
    public let taskLinks: [String]?
    /// Where remote sources are cloned when they name no destination.
    public let cloneBaseDirectory: String?
    public let projects: [WorkspaceSourceRequest]

    public init(
      title: String,
      rootPath: String? = nil,
      description: String? = nil,
      taskLinks: [String]? = nil,
      cloneBaseDirectory: String? = nil,
      projects: [WorkspaceSourceRequest]
    ) {
      self.title = title
      self.rootPath = rootPath
      self.description = description
      self.taskLinks = taskLinks
      self.cloneBaseDirectory = cloneBaseDirectory
      self.projects = projects
    }

    private enum CodingKeys: String, CodingKey {
      case title, rootPath, description, taskLinks, cloneBaseDirectory, projects
    }

    public init(from decoder: Decoder) throws {
      try RetiredWireKeys.reject(
        ["members", "branch", "baseRef", "useExistingBranch", "trackRemote"],
        in: decoder, reason: RetiredWireKeys.branchesBelongToGroups)
      let container = try decoder.container(keyedBy: CodingKeys.self)
      title = try container.decode(String.self, forKey: .title)
      rootPath = try container.decodeIfPresent(String.self, forKey: .rootPath)
      description = try container.decodeIfPresent(String.self, forKey: .description)
      taskLinks = try container.decodeIfPresent([String].self, forKey: .taskLinks)
      cloneBaseDirectory = try container.decodeIfPresent(String.self, forKey: .cloneBaseDirectory)
      projects = try container.decode([WorkspaceSourceRequest].self, forKey: .projects)
    }
  }

  /// Params for `workspace.add`: one more source project, listed in the
  /// `default` group. Named groups are unchanged.
  public struct WorkspaceAddRequest: Codable, Equatable, Sendable {
    public let projectID: ProjectID
    public let project: WorkspaceSourceRequest
    /// Where a remote source is cloned when it names no destination.
    public let cloneBaseDirectory: String?

    public init(projectID: ProjectID, project: WorkspaceSourceRequest, cloneBaseDirectory: String? = nil) {
      self.projectID = projectID
      self.project = project
      self.cloneBaseDirectory = cloneBaseDirectory
    }

    private enum CodingKeys: String, CodingKey {
      case projectID, project, cloneBaseDirectory
    }

    public init(from decoder: Decoder) throws {
      try RetiredWireKeys.reject(["member"], in: decoder, reason: RetiredWireKeys.branchesBelongToGroups)
      let container = try decoder.container(keyedBy: CodingKeys.self)
      projectID = try container.decode(ProjectID.self, forKey: .projectID)
      project = try container.decode(WorkspaceSourceRequest.self, forKey: .project)
      cloneBaseDirectory = try container.decodeIfPresent(String.self, forKey: .cloneBaseDirectory)
    }
  }

  /// Where a source repository came from.
  public enum WorkspaceMemberSourceKind: String, Codable, Equatable, Sendable {
    /// A local repository with a working tree.
    case local
    /// Cloned from `remoteURL`.
    case remote
  }

  /// Params for `workspace.drop`: remove one source project. The source
  /// directory and every checkout stay on disk.
  public struct WorkspaceDropRequest: Codable, Equatable, Sendable {
    public let projectID: ProjectID
    /// The source's name (as `workspace show` lists it) or its path.
    public let project: String

    public init(projectID: ProjectID, project: String) {
      self.projectID = projectID
      self.project = project
    }

    private enum CodingKeys: String, CodingKey {
      case projectID, project
    }

    public init(from decoder: Decoder) throws {
      try RetiredWireKeys.reject(
        ["member", "keepBranch"], in: decoder,
        reason: "drop removes a source project and never deletes a checkout or branch; "
          + "pass `project`, and delete a group with `workspace.deleteGroup`")
      let container = try decoder.container(keyedBy: CodingKeys.self)
      projectID = try container.decode(ProjectID.self, forKey: .projectID)
      project = try container.decode(String.self, forKey: .project)
    }
  }

  /// Response for `workspace.drop`.
  public struct WorkspaceDropResponse: Codable, Equatable, Sendable {
    public let name: String
    /// The source main checkout, which stays on disk.
    public let path: String

    public init(name: String, path: String) {
      self.name = name
      self.path = path
    }
  }

  /// Params for `workspace.remove`.
  public struct WorkspaceRemoveRequest: Codable, Equatable, Sendable {
    public let projectID: ProjectID
    /// `deleteFiles` deletes the files the Workspace owns (named groups,
    /// the default links, the root when owned). Source checkouts are kept.
    public let cleanup: WorkspaceCleanup
    /// With `deleteFiles`: the caller accepts losing uncommitted changes,
    /// unpushed commits, running terminals, and extra files.
    public let acknowledgeRisks: Bool

    public init(projectID: ProjectID, cleanup: WorkspaceCleanup = .entryOnly, acknowledgeRisks: Bool = false) {
      self.projectID = projectID
      self.cleanup = cleanup
      self.acknowledgeRisks = acknowledgeRisks
    }

    private enum CodingKeys: String, CodingKey {
      case projectID, cleanup, acknowledgeRisks
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      projectID = try container.decode(ProjectID.self, forKey: .projectID)
      cleanup = try container.decodeIfPresent(WorkspaceCleanup.self, forKey: .cleanup) ?? .entryOnly
      acknowledgeRisks = try container.decodeIfPresent(Bool.self, forKey: .acknowledgeRisks) ?? false
    }
  }

  /// Response for `workspace.remove`.
  public struct WorkspaceRemoveResponse: Codable, Equatable, Sendable {
    public let projectID: ProjectID
    public let rootPath: String
    public let outcome: WorkspaceRemovalOutcome

    public init(projectID: ProjectID, rootPath: String, outcome: WorkspaceRemovalOutcome) {
      self.projectID = projectID
      self.rootPath = rootPath
      self.outcome = outcome
    }
  }

  /// Params for `workspace.describe`.
  public struct WorkspaceDescribeRequest: Codable, Equatable, Sendable {
    public let projectID: ProjectID

    public init(projectID: ProjectID) {
      self.projectID = projectID
    }
  }

  /// One source project with its reference row in the `default` group.
  public struct WorkspaceProjectSummary: Codable, Equatable, Sendable {
    public let name: String
    /// The source main checkout (canonical).
    public let sourceGitRoot: String
    public let sourceKind: WorkspaceMemberSourceKind
    public let remoteURL: String?
    /// Live branch of the reference row.
    public let branch: String?
    public let worktreeID: WorktreeID?

    public init(
      name: String,
      sourceGitRoot: String,
      sourceKind: WorkspaceMemberSourceKind = .local,
      remoteURL: String? = nil,
      branch: String? = nil,
      worktreeID: WorktreeID? = nil
    ) {
      self.name = name
      self.sourceGitRoot = sourceGitRoot
      self.sourceKind = sourceKind
      self.remoteURL = remoteURL
      self.branch = branch
      self.worktreeID = worktreeID
    }
  }

  /// One row of a group: a reference (`default` group) or a member
  /// checkout (named group).
  public struct WorkspaceGroupMemberSummary: Codable, Equatable, Sendable {
    public let name: String
    /// Absolute, canonical path.
    public let path: String
    public let branch: String?
    public let sourceGitRoot: String?
    public let role: WorkspaceSlot.Role
    public let worktreeID: WorktreeID?

    public init(
      name: String,
      path: String,
      branch: String? = nil,
      sourceGitRoot: String? = nil,
      role: WorkspaceSlot.Role,
      worktreeID: WorktreeID? = nil
    ) {
      self.name = name
      self.path = path
      self.branch = branch
      self.sourceGitRoot = sourceGitRoot
      self.role = role
      self.worktreeID = worktreeID
    }
  }

  /// One group of a workspace as the manifest records it, with its rows.
  public struct WorkspaceGroupSummary: Codable, Equatable, Sendable {
    public let id: WorkspaceGroupID
    public let name: String
    public let isDefault: Bool
    /// Absolute, canonical group directory.
    public let path: String
    /// The group's own terminal row.
    public let worktreeID: WorktreeID?
    /// Set while a delete is incomplete.
    public let deletion: GroupDeletionState?
    public let members: [WorkspaceGroupMemberSummary]

    public init(
      id: WorkspaceGroupID,
      name: String,
      isDefault: Bool,
      path: String,
      worktreeID: WorktreeID? = nil,
      deletion: GroupDeletionState? = nil,
      members: [WorkspaceGroupMemberSummary]
    ) {
      self.id = id
      self.name = name
      self.isDefault = isDefault
      self.path = path
      self.worktreeID = worktreeID
      self.deletion = deletion
      self.members = members
    }
  }

  /// Response for `workspace.create` and `workspace.describe`.
  public struct WorkspaceSummary: Codable, Equatable, Sendable {
    public let projectID: ProjectID
    public let title: String
    public let rootPath: String
    public let description: String?
    public let taskLinks: [String]
    public let projects: [WorkspaceProjectSummary]
    /// `default` first, then the named groups in manifest order.
    public let groups: [WorkspaceGroupSummary]

    public init(
      projectID: ProjectID,
      title: String,
      rootPath: String,
      description: String? = nil,
      taskLinks: [String] = [],
      projects: [WorkspaceProjectSummary],
      groups: [WorkspaceGroupSummary]
    ) {
      self.projectID = projectID
      self.title = title
      self.rootPath = rootPath
      self.description = description
      self.taskLinks = taskLinks
      self.projects = projects
      self.groups = groups
    }
  }

  // MARK: - Groups

  /// Params for `workspace.createGroup`: one branch for every source
  /// project. Every option not given falls back to the source Project's
  /// settings, the same defaults the New Group sheet shows.
  public struct WorkspaceGroupCreateRequest: Codable, Equatable, Sendable {
    public let projectID: ProjectID
    public let name: String
    public let branch: String
    /// Base ref per source project, keyed by the source's name.
    public let baseRefs: [String: String]?
    /// Fetch the base ref's remote first. Applies to every source.
    public let fetch: Bool?
    public let copyIgnored: Bool?
    public let copyUntracked: Bool?

    public init(
      projectID: ProjectID,
      name: String,
      branch: String,
      baseRefs: [String: String]? = nil,
      fetch: Bool? = nil,
      copyIgnored: Bool? = nil,
      copyUntracked: Bool? = nil
    ) {
      self.projectID = projectID
      self.name = name
      self.branch = branch
      self.baseRefs = baseRefs
      self.fetch = fetch
      self.copyIgnored = copyIgnored
      self.copyUntracked = copyUntracked
    }
  }

  /// Response for `workspace.createGroup`. The group exists even when a
  /// setup command failed.
  public struct WorkspaceGroupCreateResponse: Codable, Equatable, Sendable {
    public let projectID: ProjectID
    public let group: WorkspaceGroupSummary
    public let setupFailures: [GroupCreationResult.SetupFailure]

    public init(
      projectID: ProjectID, group: WorkspaceGroupSummary, setupFailures: [GroupCreationResult.SetupFailure] = []
    ) {
      self.projectID = projectID
      self.group = group
      self.setupFailures = setupFailures
    }
  }

  /// Params for `workspace.checkGroupDeletion`.
  public struct WorkspaceGroupRequest: Codable, Equatable, Sendable {
    public let projectID: ProjectID
    /// Group name or id.
    public let group: String

    public init(projectID: ProjectID, group: String) {
      self.projectID = projectID
      self.group = group
    }
  }

  /// Params for `workspace.deleteGroup`. The server re-runs the check: a
  /// failed probe or an unacknowledged risk is a `conflict` that lists it.
  public struct WorkspaceGroupDeleteRequest: Codable, Equatable, Sendable {
    public let projectID: ProjectID
    /// Group name or id.
    public let group: String
    /// Also delete each member branch the check lists as deletable.
    public let deleteBranches: Bool
    /// The caller accepts losing the risks the check reports.
    public let acknowledgeRisks: Bool

    public init(projectID: ProjectID, group: String, deleteBranches: Bool = false, acknowledgeRisks: Bool = false) {
      self.projectID = projectID
      self.group = group
      self.deleteBranches = deleteBranches
      self.acknowledgeRisks = acknowledgeRisks
    }

    private enum CodingKeys: String, CodingKey {
      case projectID, group, deleteBranches, acknowledgeRisks
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      projectID = try container.decode(ProjectID.self, forKey: .projectID)
      group = try container.decode(String.self, forKey: .group)
      deleteBranches = try container.decodeIfPresent(Bool.self, forKey: .deleteBranches) ?? false
      acknowledgeRisks = try container.decodeIfPresent(Bool.self, forKey: .acknowledgeRisks) ?? false
    }
  }

  /// Response for `workspace.deleteGroup`. With any failure the group stays,
  /// marked as an incomplete deletion; the same request retries it.
  public struct WorkspaceGroupDeleteResponse: Codable, Equatable, Sendable {
    public let projectID: ProjectID
    public let groupID: WorkspaceGroupID
    public let groupName: String
    public let outcome: GroupDeletionOutcome

    public init(projectID: ProjectID, groupID: WorkspaceGroupID, groupName: String, outcome: GroupDeletionOutcome) {
      self.projectID = projectID
      self.groupID = groupID
      self.groupName = groupName
      self.outcome = outcome
    }
  }

  // MARK: - Hierarchy

  /// Where a workspace row sits, for `codans tree --json` and
  /// `hierarchy.describeWorktree`. Nil for rows outside a workspace.
  public struct WorkspaceGroupRef: Codable, Equatable, Sendable {
    public let id: WorkspaceGroupID
    public let name: String
    public let role: WorkspaceSlot.Role

    public init(id: WorkspaceGroupID, name: String, role: WorkspaceSlot.Role) {
      self.id = id
      self.name = name
      self.role = role
    }

    /// The row's group, read from the catalog. Nil when the row has no slot
    /// or its group is not recorded.
    public init?(worktree: Worktree, in project: Project) {
      guard project.isWorkspace, let slot = worktree.workspaceSlot,
        let group = project.workspaceGroups.first(where: { $0.id == slot.groupID })
      else { return nil }
      self.init(id: group.id, name: group.name, role: slot.role)
    }
  }
}

/// Request keys an older wire shape used. They fail with a clear message
/// instead of being dropped, so a caller never believes a branch was made.
enum RetiredWireKeys {
  static let branchesBelongToGroups =
    "a workspace now takes source projects only; branches belong to `workspace group create` (workspace.createGroup)"

  private struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }

  static func reject(_ keys: [String], in decoder: Decoder, reason: String) throws {
    guard let container = try? decoder.container(keyedBy: AnyKey.self) else { return }
    if let key = keys.first(where: { container.contains(AnyKey(stringValue: $0)) }) {
      throw IPCError.invalidParams(message: "`\(key)` is no longer accepted: \(reason)", path: [key])
    }
  }
}
