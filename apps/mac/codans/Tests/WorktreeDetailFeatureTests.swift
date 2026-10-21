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
    let received = LockIsolated<WorktreeID?>(nil)
    let worktreeID = WorktreeID()
    let projectID = ProjectID()
    let worktree = Worktree(id: worktreeID, name: "w", path: "/tmp/w")
    let catalog = Catalog(projects: [
      Project(id: projectID, name: "p", rootPath: "/tmp/w", worktrees: [worktree])
    ])

    let store = TestStore(initialState: WorktreeDetailFeature.State()) {
      WorktreeDetailFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.newTab = { pane, wid, pid, _, _, _, _ in
        received.withValue { $0 = wid }
        return TabAddress(
          projectID: pid, worktreeID: wid, paneID: pane ?? PaneID(),
          tabID: TabID(), contentID: ContentID())
      }
      $0.hierarchyClient.ensureSurface = { _ in }
      $0.hierarchyClient.focusSurfaceView = { _ in }
    }

    await store.send(
      .tabBar(
        .newTabButtonTapped(
          inPane: nil, inWorktree: worktreeID, inProject: projectID
        )))
    await store.finish()
    #expect(received.value == worktreeID)
  }

  @Test
  func splitViewportActionRoutesViaScope() async {
    let worktreeID = WorktreeID()
    let store = TestStore(initialState: WorktreeDetailFeature.State()) {
      WorktreeDetailFeature()
    }
    await store.send(.splitViewport(.worktreeChanged(worktreeID))) { state in
      state.splitViewport.worktreeID = worktreeID
    }
  }
}
