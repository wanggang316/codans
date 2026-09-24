import CodansIPC
import ComposableArchitecture
import Foundation

/// The Mac's Project → Worktree → Tab → Pane tree as last streamed. The
/// selection itself is per scene (`@SceneStorage` in `BrowserView`), so
/// two windows can browse different places over the same model.
@Reducer
struct BrowserFeature {
  @ObservableState
  struct State: Equatable {
    var hierarchy: IPC.HierarchySummary?

    var projects: [IPC.ProjectSummary] { hierarchy?.projects ?? [] }

    func project(id: String?) -> IPC.ProjectSummary? {
      guard let id else { return nil }
      return projects.first { $0.id == id }
    }

    /// Where a pane sits, for titles and breadcrumbs.
    func location(ofPane paneID: String) -> PaneLocation? {
      for project in projects {
        for worktree in project.worktrees {
          for tab in worktree.tabs {
            if let pane = tab.panes.first(where: { $0.id == paneID }) {
              return PaneLocation(project: project, worktree: worktree, tab: tab, pane: pane)
            }
          }
        }
      }
      return nil
    }
  }

  enum Action: Equatable {
    case eventReceived(IPC.EventFrame)
    case reset
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .eventReceived(let frame):
        switch frame.payload {
        case .snapshot(let snapshot):
          if let hierarchy = snapshot.hierarchy { state.hierarchy = hierarchy }
        case .hierarchyChanged(let hierarchy):
          state.hierarchy = hierarchy
        case .agentStatesChanged, .heartbeat, .unknown:
          break
        }
        return .none

      case .reset:
        state = State()
        return .none
      }
    }
  }
}

struct PaneLocation: Equatable {
  let project: IPC.ProjectSummary
  let worktree: IPC.WorktreeSummary
  let tab: IPC.TabSummary
  let pane: IPC.PaneSummary

  /// A pane's own title, else its tab's, else its short handle.
  var paneTitle: String {
    pane.title ?? tab.title ?? pane.handle ?? "Pane"
  }

  var breadcrumb: String {
    "\(project.name) › \(worktree.name)"
  }
}
