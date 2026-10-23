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

  /// `hierarchy.describeWorktree`. `focusedPaneID` is the Pane that takes
  /// keyboard input; `paneCount` counts the leaves of the split tree.
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
    public let focusedPaneID: String?
    public let paneCount: Int

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
      focusedPaneID: String?,
      paneCount: Int
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
      self.focusedPaneID = focusedPaneID
      self.paneCount = paneCount
    }
  }

  /// `hierarchy.describePane` and the rows of `hierarchy.listPanes`. A Pane
  /// is a split-tree leaf holding a strip of Tabs; `handle` is its `p<n>`
  /// selector, `tabIDs` the strip in order, and `isFocused` whether it is
  /// the Worktree's focused Pane.
  public struct PaneDescription: Codable, Equatable, Sendable {
    public let id: String
    public let handle: String?
    public let projectID: String
    public let worktreeID: String
    public let selectedTabID: String?
    public let tabIDs: [String]
    public let isFocused: Bool

    public init(
      id: String,
      handle: String?,
      projectID: String,
      worktreeID: String,
      selectedTabID: String?,
      tabIDs: [String],
      isFocused: Bool
    ) {
      self.id = id
      self.handle = handle
      self.projectID = projectID
      self.worktreeID = worktreeID
      self.selectedTabID = selectedTabID
      self.tabIDs = tabIDs
      self.isFocused = isFocused
    }
  }

  /// `hierarchy.describeTab` and the rows of `hierarchy.listTabs`. A Tab
  /// is a strip slot with its chip attributes and one Content: `handle` is
  /// its `t<n>` selector, `paneID` the Pane holding it, `contentID` its
  /// session. `title` is what the chip shows (the user's name, else the
  /// last live title); `name` is only the user-set part.
  /// `workingDirectory` is the live shell directory when the session has
  /// reported one, else the creation-time one; `isLive` says whether a
  /// terminal surface is bound this app session.
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
    public let workingDirectory: String?
    public let labels: [String]
    public let agent: String?
    public let agentSessionID: String?
    public let isLive: Bool

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
      workingDirectory: String?,
      labels: [String],
      agent: String?,
      agentSessionID: String?,
      isLive: Bool
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
      self.workingDirectory = workingDirectory
      self.labels = labels
      self.agent = agent
      self.agentSessionID = agentSessionID
      self.isLive = isLive
    }
  }
}
