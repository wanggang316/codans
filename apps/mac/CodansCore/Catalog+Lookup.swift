import Foundation

/// Where a Tab lives: its Project, Worktree, and Pane, plus the Tab and
/// Content ids. The answer to "which level hosts this id" for any of the
/// three ids (ADR-0001).
public nonisolated struct TabAddress: Hashable, Sendable {
  public let projectID: ProjectID
  public let worktreeID: WorktreeID
  public let paneID: PaneID
  public let tabID: TabID
  public let contentID: ContentID

  public init(projectID: ProjectID, worktreeID: WorktreeID, paneID: PaneID, tabID: TabID, contentID: ContentID) {
    self.projectID = projectID
    self.worktreeID = worktreeID
    self.paneID = paneID
    self.tabID = tabID
    self.contentID = contentID
  }
}

/// Where a Pane lives.
public nonisolated struct PaneAddress: Hashable, Sendable {
  public let projectID: ProjectID
  public let worktreeID: WorktreeID
  public let paneID: PaneID

  public init(projectID: ProjectID, worktreeID: WorktreeID, paneID: PaneID) {
    self.projectID = projectID
    self.worktreeID = worktreeID
    self.paneID = paneID
  }
}

extension Catalog {
  // MARK: - Walks

  /// Walks projects → worktrees → panes → tabs and returns the first Tab
  /// that satisfies `predicate`, with its address. Linear in the total Tab
  /// count; called from lookups whose cadence is bounded by user actions
  /// and runtime events.
  private func firstTab(where predicate: (Tab) -> Bool) -> (Tab, TabAddress)? {
    for project in projects {
      for worktree in project.worktrees {
        for pane in worktree.panes {
          if let tab = pane.tabs.first(where: predicate) {
            let address = TabAddress(
              projectID: project.id, worktreeID: worktree.id, paneID: pane.id, tabID: tab.id,
              contentID: tab.content.id)
            return (tab, address)
          }
        }
      }
    }
    return nil
  }

  private func firstPane(where predicate: (Pane) -> Bool) -> (Pane, PaneAddress)? {
    for project in projects {
      for worktree in project.worktrees {
        if let pane = worktree.panes.first(where: predicate) {
          return (pane, PaneAddress(projectID: project.id, worktreeID: worktree.id, paneID: pane.id))
        }
      }
    }
    return nil
  }

  // MARK: - Addresses

  public func address(forContent contentID: ContentID) -> TabAddress? {
    firstTab { $0.content.id == contentID }?.1
  }

  public func address(forTab tabID: TabID) -> TabAddress? {
    firstTab { $0.id == tabID }?.1
  }

  public func address(forPane paneID: PaneID) -> PaneAddress? {
    firstPane { $0.id == paneID }?.1
  }

  // MARK: - Nodes

  public func project(_ id: ProjectID) -> Project? {
    projects.first { $0.id == id }
  }

  /// The Worktree with `id` and the Project holding it.
  public func worktree(_ id: WorktreeID) -> (project: Project, worktree: Worktree)? {
    for project in projects {
      if let worktree = project.worktrees.first(where: { $0.id == id }) {
        return (project, worktree)
      }
    }
    return nil
  }

  /// The Worktree with `id`, only when `projectID` holds it.
  public func worktree(_ id: WorktreeID, in projectID: ProjectID) -> Worktree? {
    project(projectID)?.worktrees.first { $0.id == id }
  }

  public func tab(_ id: TabID) -> Tab? {
    firstTab { $0.id == id }?.0
  }

  public func tab(forContent contentID: ContentID) -> Tab? {
    firstTab { $0.content.id == contentID }?.0
  }

  public func pane(_ id: PaneID) -> Pane? {
    firstPane { $0.id == id }?.0
  }

  public func content(_ id: ContentID) -> ContentSnapshot? {
    tab(forContent: id)?.content
  }

  // MARK: - Ancestors by Content id

  public func projectID(forContent contentID: ContentID) -> ProjectID? {
    address(forContent: contentID)?.projectID
  }

  public func worktreeID(forContent contentID: ContentID) -> WorktreeID? {
    address(forContent: contentID)?.worktreeID
  }

  public func paneID(forContent contentID: ContentID) -> PaneID? {
    address(forContent: contentID)?.paneID
  }

  public func tabID(forContent contentID: ContentID) -> TabID? {
    address(forContent: contentID)?.tabID
  }

  // MARK: - Ancestors by Tab id

  public func projectID(forTab tabID: TabID) -> ProjectID? {
    address(forTab: tabID)?.projectID
  }

  public func worktreeID(forTab tabID: TabID) -> WorktreeID? {
    address(forTab: tabID)?.worktreeID
  }

  public func paneID(forTab tabID: TabID) -> PaneID? {
    address(forTab: tabID)?.paneID
  }

  public func contentID(forTab tabID: TabID) -> ContentID? {
    address(forTab: tabID)?.contentID
  }

  // MARK: - Ancestors by Pane id

  public func projectID(forPane paneID: PaneID) -> ProjectID? {
    address(forPane: paneID)?.projectID
  }

  public func worktreeID(forPane paneID: PaneID) -> WorktreeID? {
    address(forPane: paneID)?.worktreeID
  }

  // MARK: - Content id sets

  /// Every `ContentID` under the given Worktree, flat across its Panes.
  /// Empty when the Worktree is not in the catalog.
  public func contentIDs(inWorktree worktreeID: WorktreeID) -> Set<ContentID> {
    worktree(worktreeID).map { Set($0.worktree.contentIDs) } ?? []
  }

  /// Every `ContentID` in the catalog. Membership reconciles (agent
  /// registry, session reaper) use it to detect entries whose Content has
  /// left the hierarchy.
  public func allContentIDs() -> Set<ContentID> {
    var ids: Set<ContentID> = []
    for project in projects {
      for worktree in project.worktrees {
        ids.formUnion(worktree.contentIDs)
      }
    }
    return ids
  }

  /// Every `ContentID` in a non-archived (visible) Worktree. Archive
  /// kills the Worktree's daemons, so its Contents count as gone for live
  /// state — while the records stay in the catalog for restore.
  public func visibleContentIDs() -> Set<ContentID> {
    var ids: Set<ContentID> = []
    for project in projects {
      for worktree in project.worktrees where !worktree.archived {
        ids.formUnion(worktree.contentIDs)
      }
    }
    return ids
  }

  /// The project the sidebar shows as selected: `selectedProjectID` once
  /// the user has picked a row, otherwise (right after launch) the first
  /// project that remembers a selected worktree.
  public var displayedSelectedProjectID: ProjectID? {
    if let id = selectedProjectID, projects.contains(where: { $0.id == id }) {
      return id
    }
    return projects.first { $0.selectedWorktreeID != nil }?.id
  }
}
