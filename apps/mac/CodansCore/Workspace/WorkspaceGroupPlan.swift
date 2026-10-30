import Foundation

/// A source project to add to a Workspace: a local repository, or a remote
/// the Workspace clones first. Resolved to the repository's main checkout.
public nonisolated struct WorkspaceSource: Equatable, Sendable {
  public enum Location: Equatable, Sendable {
    /// A local path inside a repository. Normalized to the repository root.
    case local(path: String)
    /// A remote to clone into `cloneDestination`, or reuse when that folder
    /// is already a clone of it.
    case remote(url: String, cloneDestination: String)
  }

  public var location: Location
  /// Link name inside the `default` directory. `nil` derives it from the
  /// repository folder, suffixed on a clash.
  public var name: String?

  public init(location: Location, name: String? = nil) {
    self.location = location
    self.name = name
  }
}

/// Input of `WorkspaceClient.createWorkspace`: a root and its sources. It
/// creates no branch and checks nothing out; groups come later.
public nonisolated struct WorkspaceSourcePlan: Equatable, Sendable {
  public var title: String
  /// Absolute Workspace root. Created when missing.
  public var rootPath: String
  public var description: String?
  public var taskLinks: [String]
  public var sources: [WorkspaceSource]

  public init(
    title: String,
    rootPath: String,
    description: String? = nil,
    taskLinks: [String] = [],
    sources: [WorkspaceSource]
  ) {
    self.title = title
    self.rootPath = rootPath
    self.description = description
    self.taskLinks = taskLinks
    self.sources = sources
  }
}

/// How one source project is checked out in a new named group. Defaults
/// come from `WorkspaceClient.groupCreationDefaults`, which reads the same
/// project and global settings as ordinary worktree creation.
public nonisolated struct MemberCreationOptions: Equatable, Sendable, Identifiable {
  /// Source main checkout (canonical), as listed in the manifest.
  public var sourceGitRoot: String
  /// Member folder name inside the group directory; the source's link name.
  public var name: String
  /// Ref the new branch starts from. `nil` lets git use the repository's
  /// default.
  public var baseRef: String?
  /// `git fetch` the base ref's remote before the checkout.
  public var fetch: Bool
  public var copyIgnored: Bool
  public var copyUntracked: Bool
  /// Agent profile to launch in the member after the group exists.
  public var agentProfileID: UUID?
  /// Command run in the member directory after every checkout exists.
  public var setupCommand: String?

  public var id: String { sourceGitRoot }

  public init(
    sourceGitRoot: String,
    name: String,
    baseRef: String? = nil,
    fetch: Bool = true,
    copyIgnored: Bool = false,
    copyUntracked: Bool = false,
    agentProfileID: UUID? = nil,
    setupCommand: String? = nil
  ) {
    self.sourceGitRoot = sourceGitRoot
    self.name = name
    self.baseRef = baseRef
    self.fetch = fetch
    self.copyIgnored = copyIgnored
    self.copyUntracked = copyUntracked
    self.agentProfileID = agentProfileID
    self.setupCommand = setupCommand
  }
}

/// Input of a new named group: one branch for every member, each member
/// with its own options. Members are in source order.
public nonisolated struct WorkspaceGroupPlan: Equatable, Sendable {
  public var projectID: ProjectID
  /// Display name, independent of the directory name.
  public var name: String
  public var branch: String
  public var members: [MemberCreationOptions]

  /// A single safe path component, using the Workspace title convention.
  public var directoryName: String { WorkspaceLayout.folderName(forTitle: name) }

  public init(projectID: ProjectID, name: String, branch: String, members: [MemberCreationOptions]) {
    self.projectID = projectID
    self.name = name
    self.branch = branch
    self.members = members
  }
}

/// What a finished group creation produced. The caller launches agents from
/// it after the stream ends, so no agent starts before every checkout exists.
public nonisolated struct GroupCreationResult: Equatable, Sendable {
  public struct Member: Equatable, Sendable {
    public var name: String
    public var worktreeID: WorktreeID
    public var agentProfileID: UUID?

    public init(name: String, worktreeID: WorktreeID, agentProfileID: UUID? = nil) {
      self.name = name
      self.worktreeID = worktreeID
      self.agentProfileID = agentProfileID
    }
  }

  public struct SetupFailure: Codable, Equatable, Sendable {
    public var name: String
    public var reason: String

    public init(name: String, reason: String) {
      self.name = name
      self.reason = reason
    }
  }

  public var projectID: ProjectID
  public var groupID: WorkspaceGroupID
  /// The group's own terminal row.
  public var groupWorktreeID: WorktreeID
  public var members: [Member]
  public var setupFailures: [SetupFailure]

  public init(
    projectID: ProjectID,
    groupID: WorkspaceGroupID,
    groupWorktreeID: WorktreeID,
    members: [Member],
    setupFailures: [SetupFailure] = []
  ) {
    self.projectID = projectID
    self.groupID = groupID
    self.groupWorktreeID = groupWorktreeID
    self.members = members
    self.setupFailures = setupFailures
  }
}
