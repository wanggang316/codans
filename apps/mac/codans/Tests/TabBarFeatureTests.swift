import ComposableArchitecture
import Foundation
import Testing
import CodansCore

@testable import Codans

@MainActor
struct TabBarFeatureTests {
  @Test
  func newTabButtonCallsCreateTab() async {
    let worktreeID = WorktreeID()
    let projectID = ProjectID()
    let received = LockIsolated<(WorktreeID, ProjectID, String?)?>(nil)

    // Reducer now calls snapshot() + openPane() after createTab so the
    // auto-spawned pane lands in the worktree's cwd (see 1f475ff).
    // Stub the chain so the unimplemented closure does not record an
    // issue when this test runs alongside its siblings.
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.createTab = { w, p, name in
        received.withValue { $0 = (w, p, name) }
        return TabID()
      }
      $0.hierarchyClient.snapshot = {
        Catalog()
      }
    }

    await store.send(
      .newTabButtonTapped(inWorktree: worktreeID, inProject: projectID))
    let captured = received.value
    #expect(captured?.0 == worktreeID)
    #expect(captured?.1 == projectID)
    #expect(captured?.2 == nil)
  }

  @Test
  func tabButtonCallsSelectTab() async {
    let tabID = TabID()
    let worktreeID = WorktreeID()
    let projectID = ProjectID()
    let received = LockIsolated<TabID?>(nil)

    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.selectTab = { id, _, _ in
        received.withValue { $0 = id }
      }
    }

    await store.send(
      .tabButtonTapped(tabID, inWorktree: worktreeID, inProject: projectID))
    #expect(received.value == tabID)
  }

  @Test
  func closeButtonCallsCloseTab() async {
    let tabID = TabID()
    let worktreeID = WorktreeID()
    let projectID = ProjectID()
    let received = LockIsolated<TabID?>(nil)

    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.closeTab = { id, _, _ in
        received.withValue { $0 = id }
      }
    }

    await store.send(
      .closeButtonTapped(tabID, inWorktree: worktreeID, inProject: projectID))
    #expect(received.value == tabID)
  }

  // MARK: - Tab-bar uplift (M2-T2.10)

  @Test
  func renameSubmittedCallsRenameTab() async {
    let tabID = TabID()
    let received = LockIsolated<(TabID, String?)?>(nil)
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.renameTab = { id, _, _, name in
        received.withValue { $0 = (id, name) }
      }
    }
    await store.send(
      .renameSubmitted(
        tabID, name: "new-title",
        inWorktree: WorktreeID(), inProject: ProjectID()
      ))
    #expect(received.value?.0 == tabID)
    #expect(received.value?.1 == "new-title")
  }

  @Test
  func contextMenuCloseOthersCallsClient() async {
    let tabID = TabID()
    let received = LockIsolated<TabID?>(nil)
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.closeOtherTabs = { keep, _, _ in
        received.withValue { $0 = keep }
      }
    }
    await store.send(
      .contextMenuCloseOthers(
        tabID, inWorktree: WorktreeID(), inProject: ProjectID()
      ))
    #expect(received.value == tabID)
  }

  @Test
  func contextMenuCloseToRightCallsClient() async {
    let tabID = TabID()
    let received = LockIsolated<TabID?>(nil)
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.closeTabsToRight = { pivot, _, _ in
        received.withValue { $0 = pivot }
      }
    }
    await store.send(
      .contextMenuCloseToRight(
        tabID, inWorktree: WorktreeID(), inProject: ProjectID()
      ))
    #expect(received.value == tabID)
  }

  @Test
  func contextMenuCloseAllCallsClient() async {
    let received = LockIsolated<Bool>(false)
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.closeAllTabs = { _, _ in
        received.withValue { $0 = true }
      }
    }
    await store.send(
      .contextMenuCloseAll(
        inWorktree: WorktreeID(), inProject: ProjectID()
      ))
    #expect(received.value)
  }

  @Test
  func dragReorderEndedCallsReorderTabs() async {
    let ids = [TabID(), TabID(), TabID()]
    let received = LockIsolated<[TabID]?>(nil)
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.reorderTabs = { _, _, ordered in
        received.withValue { $0 = ordered }
      }
    }
    await store.send(
      .dragReorderEnded(
        orderedIDs: ids,
        inWorktree: WorktreeID(), inProject: ProjectID()
      ))
    #expect(received.value == ids)
  }

  @Test
  func middleClickedCallsCloseTab() async {
    let tabID = TabID()
    let received = LockIsolated<TabID?>(nil)
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.closeTab = { id, _, _ in
        received.withValue { $0 = id }
      }
    }
    await store.send(
      .middleClicked(
        tabID, inWorktree: WorktreeID(), inProject: ProjectID()
      ))
    #expect(received.value == tabID)
  }

  @Test
  func trailingSplitRequestedResolvesAnchorAndSplits() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let tabID = TabID()
    let paneID = PaneID()

    // Build a minimal catalog with a single tab carrying one pane.
    let pane = Pane(id: paneID, workingDirectory: "/tmp/repo", initialCommand: nil)
    let tab = Tab(
      id: tabID, name: "one",
      splitTree: SplitTree(leaf: paneID),
      panes: [pane]
    )
    let worktree = Worktree(
      id: worktreeID, name: "main", path: "/tmp/repo", branch: "main",
      tabs: [tab], selectedTabID: tabID
    )
    let project = Project(
      id: projectID, name: "p", rootPath: "/tmp/repo",
      worktrees: [worktree], selectedWorktreeID: worktreeID
    )
    let catalog = Catalog(projects: [project])

    let received = LockIsolated<(PaneID, SplitTree<PaneID>.NewDirection, String)?>(nil)
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.lastFocusedPane = { _ in nil }
      $0.hierarchyClient.splitPane = { pid, dir, _, _, _, cwd, _ in
        received.withValue { $0 = (pid, dir, cwd) }
        return PaneID()
      }
    }

    await store.send(
      .trailingSplitRequested(
        direction: .right,
        inWorktree: worktreeID, inProject: projectID
      ))
    #expect(received.value?.0 == paneID)
    #expect(received.value?.1 == .right)
    #expect(received.value?.2 == "/tmp/repo")
  }

  @Test
  func trailingSplitRequestedAnchorsOnLastFocusedPane() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let tabID = TabID()
    let firstPaneID = PaneID()
    let focusedPaneID = PaneID()

    // Two-pane tab: leaves().first is `firstPaneID`, but focus rests on
    // `focusedPaneID`. The split must anchor on the focused pane.
    let firstPane = Pane(id: firstPaneID, workingDirectory: "/tmp/a", initialCommand: nil)
    let focusedPane = Pane(id: focusedPaneID, workingDirectory: "/tmp/b", initialCommand: nil)
    let splitTree = try! SplitTree(leaf: firstPaneID)
      .inserting(focusedPaneID, at: firstPaneID, direction: .right)
    let tab = Tab(
      id: tabID, name: "two",
      splitTree: splitTree,
      panes: [firstPane, focusedPane]
    )
    let worktree = Worktree(
      id: worktreeID, name: "main", path: "/tmp/repo", branch: "main",
      tabs: [tab], selectedTabID: tabID
    )
    let project = Project(
      id: projectID, name: "p", rootPath: "/tmp/repo",
      worktrees: [worktree], selectedWorktreeID: worktreeID
    )
    let catalog = Catalog(projects: [project])

    let received = LockIsolated<(PaneID, String)?>(nil)
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.lastFocusedPane = { tid in tid == tabID ? focusedPaneID : nil }
      $0.hierarchyClient.splitPane = { pid, _, _, _, _, cwd, _ in
        received.withValue { $0 = (pid, cwd) }
        return PaneID()
      }
    }

    await store.send(
      .trailingSplitRequested(
        direction: .down,
        inWorktree: worktreeID, inProject: projectID
      ))
    #expect(received.value?.0 == focusedPaneID)
    #expect(received.value?.1 == "/tmp/b")
  }

  @Test
  func trailingSplitRequestedNoOpWhenNoActiveTab() async {
    // Empty catalog — no worktree / tab / pane to anchor off.
    let catalog = Catalog()
    let splitCalled = LockIsolated<Bool>(false)
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.lastFocusedPane = { _ in nil }
      $0.hierarchyClient.splitPane = { _, _, _, _, _, _, _ in
        splitCalled.withValue { $0 = true }
        return PaneID()
      }
    }
    await store.send(
      .trailingSplitRequested(
        direction: .right,
        inWorktree: WorktreeID(), inProject: ProjectID()
      ))
    #expect(!splitCalled.value)
  }
}
