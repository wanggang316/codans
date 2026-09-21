import Foundation

extension Catalog {
  /// Walks projects → worktrees → tabs → panes to find a pane by id.
  /// O(N) over the catalog tree; called only from UI render paths
  /// (e.g. the pane right-click "Mute notifications" menu reads on
  /// every menu open), so the cost is bounded by user click cadence.
  public func pane(_ id: PaneID) -> Pane? {
    for project in projects {
      for worktree in project.worktrees {
        for tab in worktree.tabs {
          if let pane = tab.panes.first(where: { $0.id == id }) {
            return pane
          }
        }
      }
    }
    return nil
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
