import ComposableArchitecture
import Foundation
import CodansCore

/// Composes the tab bar + split viewport for the selected Worktree. The
/// feature itself is state-light: `WorktreeDetailFeature.State` holds the
/// two sub-feature states via `Scope`. Routing of the active worktree
/// address comes from `RootFeature.State.selection` (passed into the view
/// via the host `ContentView`).
@Reducer
struct WorktreeDetailFeature {
  @ObservableState
  struct State: Equatable {
    var tabBar: TabBarFeature.State = .init()
    var splitViewport: SplitViewportFeature.State = .init()
  }

  enum Action: Equatable {
    case tabBar(TabBarFeature.Action)
    case splitViewport(SplitViewportFeature.Action)
  }

  var body: some Reducer<State, Action> {
    Scope(state: \.tabBar, action: \.tabBar) {
      TabBarFeature()
    }
    Scope(state: \.splitViewport, action: \.splitViewport) {
      SplitViewportFeature()
    }
    Reduce { _, _ in .none }
  }
}
