import Foundation

extension IPC {
  /// Params for every `hierarchy.describe*` method: the entity's id, located
  /// anywhere in the catalog. Ids are globally unique, so the caller never
  /// has to spell the containers.
  public struct DescribeRequest: Codable, Equatable, Sendable {
    public let id: UUID

    public init(id: UUID) {
      self.id = id
    }
  }

  /// `hierarchy.describeProject`. Ids are plain UUID strings so the CLI's
  /// `--json` prints the same shape every other verb does.
  public struct ProjectDescription: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let canonicalName: String
    public let rootPath: String
    public let gitRoot: String?
    public let remoteHost: String?
    public let isSelected: Bool
    public let selectedWorktreeID: String?
    public let worktreeCount: Int
    public let archivedWorktreeCount: Int
    public let tagIDs: [String]

    public init(
      id: String,
      name: String,
      canonicalName: String,
      rootPath: String,
      gitRoot: String?,
      remoteHost: String?,
      isSelected: Bool,
      selectedWorktreeID: String?,
      worktreeCount: Int,
      archivedWorktreeCount: Int,
      tagIDs: [String]
    ) {
      self.id = id
      self.name = name
      self.canonicalName = canonicalName
      self.rootPath = rootPath
      self.gitRoot = gitRoot
      self.remoteHost = remoteHost
      self.isSelected = isSelected
      self.selectedWorktreeID = selectedWorktreeID
      self.worktreeCount = worktreeCount
      self.archivedWorktreeCount = archivedWorktreeCount
      self.tagIDs = tagIDs
    }
  }

  /// `hierarchy.describeWorktree`.
  public struct WorktreeDescription: Codable, Equatable, Sendable {
    public let id: String
    public let projectID: String
    public let projectName: String
    public let name: String
    public let path: String
    public let branch: String?
    public let isArchived: Bool
    public let isPinned: Bool
    public let isSelected: Bool
    public let selectedTabID: String?
    public let tabCount: Int

    public init(
      id: String,
      projectID: String,
      projectName: String,
      name: String,
      path: String,
      branch: String?,
      isArchived: Bool,
      isPinned: Bool,
      isSelected: Bool,
      selectedTabID: String?,
      tabCount: Int
    ) {
      self.id = id
      self.projectID = projectID
      self.projectName = projectName
      self.name = name
      self.path = path
      self.branch = branch
      self.isArchived = isArchived
      self.isPinned = isPinned
      self.isSelected = isSelected
      self.selectedTabID = selectedTabID
      self.tabCount = tabCount
    }
  }

  /// `hierarchy.describeTab`. `title` is what the sidebar shows (the user's
  /// name, else the last live title); `name` is only the user-set part.
  public struct TabDescription: Codable, Equatable, Sendable {
    public let id: String
    public let handle: String?
    public let projectID: String
    public let worktreeID: String
    public let title: String?
    public let name: String?
    public let icon: String?
    public let isSelected: Bool
    public let focusedPaneID: String?
    public let paneIDs: [String]

    public init(
      id: String,
      handle: String?,
      projectID: String,
      worktreeID: String,
      title: String?,
      name: String?,
      icon: String?,
      isSelected: Bool,
      focusedPaneID: String?,
      paneIDs: [String]
    ) {
      self.id = id
      self.handle = handle
      self.projectID = projectID
      self.worktreeID = worktreeID
      self.title = title
      self.name = name
      self.icon = icon
      self.isSelected = isSelected
      self.focusedPaneID = focusedPaneID
      self.paneIDs = paneIDs
    }
  }

  /// `hierarchy.describePane`. `workingDirectory` is the live shell
  /// directory when the surface has reported one, else the creation-time
  /// one; `isLive` says whether a terminal surface is bound this session.
  public struct PaneDescription: Codable, Equatable, Sendable {
    public let id: String
    public let handle: String?
    public let projectID: String
    public let worktreeID: String
    public let tabID: String
    public let workingDirectory: String
    public let initialCommand: String?
    public let labels: [String]
    public let agent: String?
    public let agentSessionID: String?
    public let isLive: Bool
    public let isFocused: Bool

    public init(
      id: String,
      handle: String?,
      projectID: String,
      worktreeID: String,
      tabID: String,
      workingDirectory: String,
      initialCommand: String?,
      labels: [String],
      agent: String?,
      agentSessionID: String?,
      isLive: Bool,
      isFocused: Bool
    ) {
      self.id = id
      self.handle = handle
      self.projectID = projectID
      self.worktreeID = worktreeID
      self.tabID = tabID
      self.workingDirectory = workingDirectory
      self.initialCommand = initialCommand
      self.labels = labels
      self.agent = agent
      self.agentSessionID = agentSessionID
      self.isLive = isLive
      self.isFocused = isFocused
    }
  }
}
