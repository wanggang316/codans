import ComposableArchitecture
import Foundation
import Testing
import CodansCore

@testable import Codans

/// Coverage for `WorktreeDetailFeature`'s composition: actions dispatched
/// against the child scopes must route via `tabBar` / `splitViewport`
/// without any additional behaviour on the parent reducer itself.
@MainActor
struct WorktreeDetailFeatureTests {
  @Test
  func tabBarActionRoutesViaScope() async {
    let received = LockIsolated<TabID?>(nil)
    let worktreeID = WorktreeID()
    let projectID = ProjectID()
    let newTabID = TabID()

    let store = TestStore(initialState: WorktreeDetailFeature.State()) {
      WorktreeDetailFeature()
    } withDependencies: {
      $0.hierarchyClient.createTab = { _, _, _ in
        received.withValue { $0 = newTabID }
        return newTabID
      }
      // newTabButtonTapped follows up createTab with a snapshot lookup to
      // resolve the worktree path. The worktree won't be in the catalog so
      // the reducer short-circuits before openPane — we just need a quiet
      // snapshot so the unimplemented testValue doesn't fire an issue.
      $0.hierarchyClient.snapshot = { Catalog() }
    }

    await store.send(
      .tabBar(
        .newTabButtonTapped(
          inWorktree: worktreeID, inProject: projectID
        )))
    #expect(received.value == newTabID)
  }

  @Test
  func splitViewportActionRoutesViaScope() async {
    let tabID = TabID()
    let store = TestStore(initialState: WorktreeDetailFeature.State()) {
      WorktreeDetailFeature()
    }
    await store.send(.splitViewport(.activeTabChanged(tabID))) { state in
      state.splitViewport.activeTabID = tabID
    }
  }
}
