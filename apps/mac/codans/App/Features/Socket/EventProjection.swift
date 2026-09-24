import CodansCore
import CodansIPC
import Foundation

/// Projects the live catalog into the wire `HierarchySummary` that
/// `events.subscribe` carries. Pure over its inputs so the shape is
/// testable without a running app.
enum EventProjection {
  /// Archived worktrees are left out: a remote client lists what the
  /// sidebar shows, and archived rows are hidden there by default.
  static func hierarchySummary(
    catalog: Catalog,
    handles: IPC.TargetHandles,
    focusedPane: (TabID) -> PaneID?,
    paneTitle: (PaneID) -> String?
  ) -> IPC.HierarchySummary {
    IPC.HierarchySummary(
      projects: catalog.projects.map { project in
        IPC.ProjectSummary(
          id: project.id.description,
          name: project.name,
          isRemote: project.isRemote,
          selectedWorktreeID: project.selectedWorktreeID?.description,
          worktrees: project.worktrees.filter { !$0.archived }.map { worktree in
            IPC.WorktreeSummary(
              id: worktree.id.description,
              name: worktree.name,
              branch: worktree.branch,
              isPinned: worktree.isPinned,
              selectedTabID: worktree.selectedTabID?.description,
              tabs: worktree.tabs.map { tab in
                IPC.TabSummary(
                  id: tab.id.description,
                  handle: handles.tabs[tab.id.description].map { "t\($0)" },
                  title: tab.name ?? tab.cachedDisplayTitle,
                  focusedPaneID: focusedPane(tab.id)?.description,
                  panes: tab.panes.map { pane in
                    IPC.PaneSummary(
                      id: pane.id.description,
                      handle: handles.panes[pane.id.description].map { "p\($0)" },
                      title: paneTitle(pane.id),
                      agent: pane.agentKind?.rawValue,
                      labels: pane.labels.sorted()
                    )
                  }
                )
              }
            )
          }
        )
      },
      selectedProjectID: catalog.selectedProjectID?.description
    )
  }
}
