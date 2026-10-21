import CodansCore
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
    /// The focused Pane's selected Tab.
    public let selectedTabID: String?
    public let tabCount: Int
    public let focusedPaneID: String?
    public let paneCount: Int
    /// The row's group and role inside a workspace; nil elsewhere.
    public let workspaceGroup: WorkspaceGroupRef?

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
      tabCount: Int,
      focusedPaneID: String?,
      paneCount: Int,
      workspaceGroup: WorkspaceGroupRef? = nil
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
      self.focusedPaneID = focusedPaneID
      self.paneCount = paneCount
      self.workspaceGroup = workspaceGroup
    }
  }

  /// `hierarchy.describeTab`. `title` is what the sidebar shows (the user's
  /// name, else the last live title); `name` is only the user-set part.
  /// `paneID` is the Pane holding the Tab and `contentID` its session;
  /// `focusedPaneID` is the Worktree's focused Pane and `paneIDs` is
  /// `[paneID]`, both kept so older readers keep decoding.
  public struct TabDescription: Codable, Equatable, Sendable {
    public let id: String
    public let handle: String?
    public let projectID: String
    public let worktreeID: String
    public let paneID: String
    public let contentID: String
    public let title: String?
    public let name: String?
    public let icon: String?
    public let color: TabColor?
    public let isSelected: Bool
    public let focusedPaneID: String?
    public let paneIDs: [String]

    public init(
      id: String,
      handle: String?,
      projectID: String,
      worktreeID: String,
      paneID: String,
      contentID: String,
      title: String?,
      name: String?,
      icon: String?,
      color: TabColor?,
      isSelected: Bool,
      focusedPaneID: String?,
      paneIDs: [String]
    ) {
      self.id = id
      self.handle = handle
      self.projectID = projectID
      self.worktreeID = worktreeID
      self.paneID = paneID
      self.contentID = contentID
      self.title = title
      self.name = name
      self.icon = icon
      self.color = color
      self.isSelected = isSelected
      self.focusedPaneID = focusedPaneID
      self.paneIDs = paneIDs
    }
  }

  /// `hierarchy.describePane`. Describes one session: `tabID` is the Tab
  /// holding it and `contentID` its session id. `workingDirectory` is the
  /// live shell directory when the surface has reported one, else the
  /// creation-time one; `isLive` says whether a terminal surface is bound
  /// this session.
  public struct PaneDescription: Codable, Equatable, Sendable {
    public let id: String
    public let handle: String?
    public let projectID: String
    public let worktreeID: String
    public let tabID: String
    public let contentID: String
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
      contentID: String,
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
      self.contentID = contentID
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
