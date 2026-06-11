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
}
