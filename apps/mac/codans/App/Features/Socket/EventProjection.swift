import CodansCore
import CodansIPC
import Foundation

/// Projects the live catalog into the wire `HierarchySummary` that
/// `events.subscribe` carries. Pure over its inputs so the shape is
/// testable without a running app.
enum EventProjection {
  /// Archived worktrees are left out: a remote client lists what the
  /// sidebar shows, and archived rows are hidden there by default.
  ///
  /// `liveDirectory` is the shell's reported working directory, when the
  /// pane has a surface; a pane without one reports the directory it was
  /// opened in. `paneIsLive` is nil when there is no terminal runtime, and
  /// then `isLive` is left out rather than claimed false.
  static func hierarchySummary(
    catalog: Catalog,
    handles: IPC.TargetHandles,
    focusedPane: (TabID) -> PaneID?,
    paneTitle: (PaneID) -> String?,
    activePaneID: PaneID? = nil,
    liveDirectory: (PaneID) -> String? = { _ in nil },
    paneIsLive: ((PaneID) -> Bool)? = nil
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
                      labels: pane.labels.sorted(),
                      cwd: liveDirectory(pane.id) ?? pane.workingDirectory,
                      isLive: paneIsLive?(pane.id)
                    )
                  },
                  layout: tab.splitTree.root.map(layoutNode),
                  zoomedPaneID: tab.splitTree.zoomed?.description
                )
              }
            )
          }
        )
      },
      selectedProjectID: catalog.selectedProjectID?.description,
      activePaneID: activePaneID?.description
    )
  }

  static func layoutNode(_ node: SplitTree<PaneID>.Node) -> IPC.SplitLayoutNode {
    switch node {
    case .leaf(let paneID):
      return .leaf(paneID: paneID.description)
    case .split(let split):
      return .split(
        direction: split.direction == .horizontal ? .horizontal : .vertical,
        ratio: split.ratio,
        left: layoutNode(split.left),
        right: layoutNode(split.right))
    }
  }
}
