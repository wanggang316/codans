import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

@MainActor
struct SplitViewportFeatureTests {
  @Test
  func activeTabChangedUpdatesState() async {
    let store = TestStore(initialState: SplitViewportFeature.State()) {
      SplitViewportFeature()
    }
    let tabID = TabID()
    await store.send(.activeTabChanged(tabID)) {
      $0.activeTabID = tabID
    }
    await store.send(.activeTabChanged(nil)) {
      $0.activeTabID = nil
    }
  }

  @Test
  func newPaneForwardsToOpenPane() async {
    let received = LockIsolated<(TabID, WorktreeID, ProjectID, String)?>(nil)
    let tabID = TabID()
    let worktreeID = WorktreeID()
    let projectID = ProjectID()

    let store = TestStore(initialState: SplitViewportFeature.State()) {
      SplitViewportFeature()
    } withDependencies: {
      $0.hierarchyClient.openPane = { tid, wid, pid, cwd, _ in
        received.withValue { $0 = (tid, wid, pid, cwd) }
        return PaneID()
      }
    }

    await store.send(
      .newPaneButtonTapped(
        inTab: tabID, inWorktree: worktreeID,
        inProject: projectID,
        workingDirectory: "/tmp/x"
      ))
    let captured = received.value
    #expect(captured?.0 == tabID)
    #expect(captured?.1 == worktreeID)
    #expect(captured?.3 == "/tmp/x")
  }

  @Test
  func splitForwardsToSplitPane() async {
    let received = LockIsolated<(PaneID, SplitTree<PaneID>.NewDirection)?>(nil)
    let paneID = PaneID()

    let store = TestStore(initialState: SplitViewportFeature.State()) {
      SplitViewportFeature()
    } withDependencies: {
      $0.hierarchyClient.splitPane = { pid, dir, _, _, _, _, _ in
        received.withValue { $0 = (pid, dir) }
        return PaneID()
      }
    }

    await store.send(
      .splitButtonTapped(
        paneID, direction: .right,
        inTab: TabID(), inWorktree: WorktreeID(),
        inProject: ProjectID(),
        workingDirectory: "/"
      ))
    #expect(received.value?.0 == paneID)
    #expect(received.value?.1 == .right)
  }

  @Test
  func closePaneForwardsToClosePane() async {
    let received = LockIsolated<PaneID?>(nil)
    let paneID = PaneID()

    let store = TestStore(initialState: SplitViewportFeature.State()) {
      SplitViewportFeature()
    } withDependencies: {
      $0.hierarchyClient.closePane = { pid, _, _, _ in
        received.withValue { $0 = pid }
      }
    }

    await store.send(
      .closePaneButtonTapped(
        paneID, inTab: TabID(), inWorktree: WorktreeID(),
        inProject: ProjectID()
      ))
    #expect(received.value == paneID)
  }
}
