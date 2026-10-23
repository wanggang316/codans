import ComposableArchitecture
import Foundation
import Testing
import CodansCore

@testable import Codans

@MainActor
struct SplitViewportFeatureTests {
  private static func address(
    worktreeID: WorktreeID = WorktreeID(), projectID: ProjectID = ProjectID(),
    paneID: PaneID = PaneID(), contentID: ContentID = ContentID()
  ) -> TabAddress {
    TabAddress(
      projectID: projectID, worktreeID: worktreeID, paneID: paneID,
      tabID: TabID(), contentID: contentID)
  }

  @Test
  func worktreeChangedUpdatesState() async {
    let store = TestStore(initialState: SplitViewportFeature.State()) {
      SplitViewportFeature()
    }
    let worktreeID = WorktreeID()
    await store.send(.worktreeChanged(worktreeID)) {
      $0.worktreeID = worktreeID
    }
    await store.send(.worktreeChanged(nil)) {
      $0.worktreeID = nil
    }
  }

  @Test
  func hostsChangedCarriesExistingHostsOverByContent() async {
    let kept = PaneHostFeature.State(
      contentID: ContentID(), paneID: PaneID(), tabID: TabID(),
      worktreeID: WorktreeID(), projectID: ProjectID())
    var ready = kept
    ready.slotGeometry = ContentGeometry(size: CGSize(width: 10, height: 10))
    let fresh = PaneHostFeature.State(
      contentID: ContentID(), paneID: PaneID(), tabID: TabID(),
      worktreeID: kept.worktreeID, projectID: kept.projectID)
    var initial = SplitViewportFeature.State()
    initial.paneHosts = [ready]

    let store = TestStore(initialState: initial) {
      SplitViewportFeature()
    } withDependencies: {
      $0.terminalClient.surface = { _ in nil }
    }

    // The stale seed for `kept` must not knock the carried host back to
    // its seed; the new Content is added as seeded.
    await store.send(.hostsChanged([kept, fresh])) {
      $0.paneHosts = [ready, fresh]
    }
  }

  @Test
  func newTabForwardsToNewTab() async {
    let received = LockIsolated<(PaneID?, WorktreeID, ProjectID, String?)?>(nil)
    let ensured = LockIsolated<ContentID?>(nil)
    let paneID = PaneID()
    let worktreeID = WorktreeID()
    let projectID = ProjectID()
    let createdContent = ContentID()

    let store = TestStore(initialState: SplitViewportFeature.State()) {
      SplitViewportFeature()
    } withDependencies: {
      $0.hierarchyClient.newTab = { pane, wid, pid, content, _, _, _ in
        received.withValue { $0 = (pane, wid, pid, content.terminal?.workingDirectory) }
        return Self.address(
          worktreeID: wid, projectID: pid, paneID: pane ?? PaneID(), contentID: createdContent)
      }
      $0.hierarchyClient.ensureSurface = { id in ensured.withValue { $0 = id } }
      $0.hierarchyClient.focusSurfaceView = { _ in }
    }

    await store.send(
      .newTabButtonTapped(
        inPane: paneID, inWorktree: worktreeID,
        inProject: projectID,
        workingDirectory: "/tmp/x"
      ))
    await store.finish()
    let captured = received.value
    #expect(captured?.0 == paneID)
    #expect(captured?.1 == worktreeID)
    #expect(captured?.2 == projectID)
    #expect(captured?.3 == "/tmp/x")
    #expect(ensured.value == createdContent)
  }

  @Test
  func splitForwardsToSplitPane() async {
    let received = LockIsolated<(PaneID, SplitTree<PaneID>.NewDirection, String?)?>(nil)
    let paneID = PaneID()

    let store = TestStore(initialState: SplitViewportFeature.State()) {
      SplitViewportFeature()
    } withDependencies: {
      $0.hierarchyClient.splitPane = { pid, dir, content, _, _ in
        received.withValue { $0 = (pid, dir, content.terminal?.workingDirectory) }
        return Self.address()
      }
      $0.hierarchyClient.ensureSurface = { _ in }
      $0.hierarchyClient.focusSurfaceView = { _ in }
    }

    await store.send(.splitButtonTapped(paneID, direction: .right, workingDirectory: "/"))
    await store.finish()
    #expect(received.value?.0 == paneID)
    #expect(received.value?.1 == .right)
    #expect(received.value?.2 == "/")
  }

  @Test
  func closePaneForwardsToClosePane() async {
    let received = LockIsolated<PaneID?>(nil)
    let paneID = PaneID()

    let store = TestStore(initialState: SplitViewportFeature.State()) {
      SplitViewportFeature()
    } withDependencies: {
      $0.hierarchyClient.closePane = { pid in
        received.withValue { $0 = pid }
      }
    }

    await store.send(.closePaneButtonTapped(paneID))
    #expect(received.value == paneID)
  }

  @Test
  func focusPaneForwardsToFocusPane() async {
    let received = LockIsolated<PaneID?>(nil)
    let paneID = PaneID()

    let store = TestStore(initialState: SplitViewportFeature.State()) {
      SplitViewportFeature()
    } withDependencies: {
      $0.hierarchyClient.focusPane = { pid in
        received.withValue { $0 = pid }
      }
    }

    await store.send(.focusPaneRequested(paneID))
    #expect(received.value == paneID)
  }

  @Test
  func moveTabRequestMovesItAndRefocusesItsSession() async {
    let paneID = PaneID()
    let targetID = PaneID()
    let tab = Tab(content: .terminal(workingDirectory: "/"))
    let other = Tab(content: .terminal(workingDirectory: "/"))
    let moved = LockIsolated<(TabID, PaneID, Int)?>(nil)
    let focused = LockIsolated<ContentID?>(nil)
    let catalog = Self.catalog(panes: [Pane(id: paneID, tabs: [tab]), Pane(id: targetID, tabs: [other])])

    let store = TestStore(initialState: SplitViewportFeature.State()) {
      SplitViewportFeature()
    } withDependencies: {
      $0.hierarchyClient.moveTabToPane = { id, pane, index in moved.withValue { $0 = (id, pane, index) } }
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.focusSurfaceView = { id in focused.withValue { $0 = id } }
    }

    await store.send(.moveTabRequested(tab.id, toPane: targetID, at: 1))
    await store.finish()
    #expect(moved.value?.0 == tab.id)
    #expect(moved.value?.1 == targetID)
    #expect(moved.value?.2 == 1)
    #expect(focused.value == tab.contentID)
  }

  @Test
  func splitTabRequestSplitsItOutAndRefocusesItsSession() async {
    let paneID = PaneID()
    let tab = Tab(content: .terminal(workingDirectory: "/"))
    let other = Tab(content: .terminal(workingDirectory: "/"))
    let split = LockIsolated<(TabID, PaneID, SplitTree<PaneID>.NewDirection)?>(nil)
    let focused = LockIsolated<ContentID?>(nil)
    let catalog = Self.catalog(panes: [Pane(id: paneID, tabs: [tab, other])])

    let store = TestStore(initialState: SplitViewportFeature.State()) {
      SplitViewportFeature()
    } withDependencies: {
      $0.hierarchyClient.splitTab = { id, anchor, direction in
        split.withValue { $0 = (id, anchor, direction) }
        return PaneID()
      }
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.focusSurfaceView = { id in focused.withValue { $0 = id } }
    }

    await store.send(.splitTabRequested(tab.id, anchor: paneID, direction: .down))
    await store.finish()
    #expect(split.value?.0 == tab.id)
    #expect(split.value?.1 == paneID)
    #expect(split.value?.2 == .down)
    #expect(focused.value == tab.contentID)
  }

  @Test
  func failedTabMoveLeavesFocusAlone() async {
    let focused = LockIsolated<ContentID?>(nil)
    let store = TestStore(initialState: SplitViewportFeature.State()) {
      SplitViewportFeature()
    } withDependencies: {
      $0.hierarchyClient.moveTabToPane = { _, _, _ in throw HierarchyError.notFound("Pane") }
      $0.hierarchyClient.focusSurfaceView = { id in focused.withValue { $0 = id } }
    }

    await store.send(.moveTabRequested(TabID(), toPane: PaneID(), at: 0))
    #expect(focused.value == nil)
  }

  private static func catalog(panes: [Pane]) -> Catalog {
    var tree = SplitTree(leaf: panes[0].id)
    for pane in panes.dropFirst() {
      tree = (try? tree.inserting(pane.id, at: panes[0].id, direction: .right)) ?? tree
    }
    let worktree = Worktree(
      id: WorktreeID(), name: "w", path: "/", splitTree: tree, panes: panes, focusedPaneID: panes[0].id)
    return Catalog(projects: [Project(name: "p", rootPath: "/", worktrees: [worktree])])
  }
}
