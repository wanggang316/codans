import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// TestStore coverage for every `PaneActionRequest` arm of
/// `PaneActionRouterFeature`. The reducer is a fan-out table, so each
/// assertion only checks that the matching `HierarchyClient` closure is
/// called with the resolved address / decoded parameters; catalog-level
/// semantics live in `HierarchyManager` tests.
///
/// Pattern: override only the closures the arm under test touches, record
/// calls into `LockIsolated` boxes, assert after `store.send(...)` settles.
/// `addressOf` is always stubbed because every non-delegate arm probes it
/// first (missing address → silent no-op).
@MainActor
struct PaneActionRouterFeatureTests {
  // MARK: - Fixture

  /// Minimal one-of-each catalog with a ready `PaneAddress` the reducer
  /// resolves `paneID` to. Using stable IDs keeps the recorded-call
  /// assertions decoupled from `UUID()` randomness.
  private struct Fixture {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let tabID = TabID()
    let paneID = PaneID()
    let secondTabID = TabID()
    let secondPaneID = PaneID()

    var address: PaneAddress {
      PaneAddress(
        projectID: projectID,
        worktreeID: worktreeID, tabID: tabID, paneID: paneID
      )
    }

    /// Catalog shape used by `newSplit` / `gotoSplit` / `toggleSplitZoom`
    /// which read `snapshot()` to find the source pane and its tab. The
    /// second tab exists so `gotoTab(.next)` has a non-trivial target.
    func catalog(zoomed: Bool = false) -> Catalog {
      let pane = Pane(id: paneID, workingDirectory: "/cwd")
      let tab = Tab(
        id: tabID,
        splitTree: SplitTree(root: .leaf(paneID), zoomed: zoomed ? paneID : nil),
        panes: [pane]
      )
      let secondPane = Pane(id: secondPaneID, workingDirectory: "/cwd2")
      let secondTab = Tab(
        id: secondTabID,
        splitTree: SplitTree(leaf: secondPaneID),
        panes: [secondPane]
      )
      let worktree = Worktree(
        id: worktreeID, name: "w", path: "/w", tabs: [tab, secondTab]
      )
      let project = Project(
        id: projectID, name: "p", rootPath: "/p", gitRoot: "/p",
        worktrees: [worktree]
      )
      return Catalog(projects: [project])
    }
  }

  // MARK: - newTab

  @Test
  func newTabCallsCreateTabWithResolvedAddress() async {
    let f = Fixture()
    let recorded = LockIsolated<(WorktreeID, ProjectID, String?)?>(nil)
    let store = TestStore(initialState: PaneActionRouterFeature.State()) {
      PaneActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.snapshot = { f.catalog() }
      $0.hierarchyClient.createTab = { wid, pid, name in
        recorded.setValue((wid, pid, name))
        return TabID()
      }
      $0.hierarchyClient.openPane = { _, _, _, _, _ in PaneID() }
    }

    await store.send(.requested(f.paneID, .newTab))
    #expect(recorded.value?.0 == f.worktreeID)
    #expect(recorded.value?.1 == f.projectID)
    #expect(recorded.value?.2 == nil)
  }

  // MARK: - closeTab(.this)

  @Test
  func closeTabThisCallsCloseTab() async {
    let f = Fixture()
    let recorded = LockIsolated<(TabID, WorktreeID, ProjectID)?>(nil)
    let store = TestStore(initialState: PaneActionRouterFeature.State()) {
      PaneActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.closeTab = { tid, wid, pid in
        recorded.setValue((tid, wid, pid))
      }
    }

    await store.send(.requested(f.paneID, .closeTab(mode: .this)))
    #expect(recorded.value?.0 == f.tabID)
    #expect(recorded.value?.1 == f.worktreeID)
    #expect(recorded.value?.2 == f.projectID)
  }

  // MARK: - moveTab

  @Test
  func moveTabCallsMoveTabWithOffset() async {
    let f = Fixture()
    let recorded = LockIsolated<(TabID, WorktreeID, ProjectID, Int)?>(nil)
    let store = TestStore(initialState: PaneActionRouterFeature.State()) {
      PaneActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.moveTab = { tid, wid, pid, offset in
        recorded.setValue((tid, wid, pid, offset))
      }
    }

    await store.send(.requested(f.paneID, .moveTab(offset: 2)))
    #expect(recorded.value?.0 == f.tabID)
    #expect(recorded.value?.3 == 2)
  }

  // MARK: - gotoTab(.next)

  @Test
  func gotoTabNextCallsSelectTabWithNextTabID() async {
    let f = Fixture()
    let recorded = LockIsolated<(TabID?, WorktreeID, ProjectID)?>(nil)
    let catalog = f.catalog()
    let store = TestStore(initialState: PaneActionRouterFeature.State()) {
      PaneActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.selectTab = { tid, wid, pid in
        recorded.setValue((tid, wid, pid))
      }
    }

    await store.send(.requested(f.paneID, .gotoTab(target: .next)))
    // With two tabs (`tabID`, `secondTabID`) and current index 0, .next → secondTabID.
    #expect(recorded.value?.0 == f.secondTabID)
    #expect(recorded.value?.1 == f.worktreeID)
  }

  // MARK: - newSplit

  @Test
  func newSplitHorizontalCallsSplitPaneWithRightDirection() async {
    let f = Fixture()
    let recorded = LockIsolated<
      (PaneID, SplitTree<PaneID>.NewDirection, TabID, WorktreeID, ProjectID, String)?
    >(nil)
    let catalog = f.catalog()
    let store = TestStore(initialState: PaneActionRouterFeature.State()) {
      PaneActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.splitPane = { paneID, dir, tid, wid, pid, cwd, _ in
        recorded.setValue((paneID, dir, tid, wid, pid, cwd))
        return PaneID()
      }
    }

    await store.send(.requested(f.paneID, .newSplit(direction: .right)))
    #expect(recorded.value?.0 == f.paneID)
    #expect(recorded.value?.1 == .right)
    #expect(recorded.value?.2 == f.tabID)
    #expect(recorded.value?.5 == "/cwd")
  }

  // MARK: - gotoSplit

  /// Two-pane horizontal layout (sourcePane | rightPane). Spatial `.right`
  /// lands on `rightPane`; `.left` from sourcePane has no neighbor and
  /// must no-op (no `focusPane` call).
  @Test
  func gotoSplitRoutesSpatialDirectionsThroughGeometry() async throws {
    let f = Fixture()
    let rightPane = PaneID()
    let twoPaneTab = Tab(
      id: f.tabID,
      splitTree: try SplitTree(leaf: f.paneID).inserting(
        rightPane, at: f.paneID, direction: .right),
      panes: [
        Pane(id: f.paneID, workingDirectory: "/cwd"),
        Pane(id: rightPane, workingDirectory: "/cwd"),
      ]
    )
    let worktree = Worktree(
      id: f.worktreeID, name: "w", path: "/w", tabs: [twoPaneTab])
    let catalog = Catalog(projects: [
      Project(
        id: f.projectID, name: "p", rootPath: "/p", gitRoot: "/p",
        worktrees: [worktree])
    ])

    // .right → rightPane (focusPane called with neighbor)
    let recorded = LockIsolated<PaneID?>(nil)
    let store = TestStore(initialState: PaneActionRouterFeature.State()) {
      PaneActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.focusPane = { pid, _, _, _ in recorded.setValue(pid) }
    }
    await store.send(.requested(f.paneID, .gotoSplit(direction: .right)))
    #expect(recorded.value == rightPane)

    // .left from the leftmost pane has no spatial neighbor → no focusPane call.
    let edgeRecorded = LockIsolated<PaneID?>(nil)
    let edgeStore = TestStore(initialState: PaneActionRouterFeature.State()) {
      PaneActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.focusPane = { pid, _, _, _ in edgeRecorded.setValue(pid) }
    }
    await edgeStore.send(.requested(f.paneID, .gotoSplit(direction: .left)))
    #expect(edgeRecorded.value == nil)
  }

  /// 2×2 grid regression: ensures the spatial walk picks the
  /// geometrically correct neighbor (overlap-then-distance), not the
  /// pre-fix tree-order linearization which would land on `bottomLeft`
  /// for `.right` from `topLeft`.
  @Test
  func gotoSplitInGridResolvesByGeometryNotTreeOrder() async throws {
    let f = Fixture()
    let topRight = PaneID()
    let bottomLeft = PaneID()
    let bottomRight = PaneID()
    let splitTree = try SplitTree(leaf: f.paneID)
      .inserting(topRight, at: f.paneID, direction: .right)
      .inserting(bottomLeft, at: f.paneID, direction: .down)
      .inserting(bottomRight, at: topRight, direction: .down)
    let tab = Tab(
      id: f.tabID, splitTree: splitTree,
      panes: [
        Pane(id: f.paneID, workingDirectory: "/cwd"),
        Pane(id: topRight, workingDirectory: "/cwd"),
        Pane(id: bottomLeft, workingDirectory: "/cwd"),
        Pane(id: bottomRight, workingDirectory: "/cwd"),
      ]
    )
    let catalog = Catalog(projects: [
      Project(
        id: f.projectID, name: "p", rootPath: "/p", gitRoot: "/p",
        worktrees: [
          Worktree(id: f.worktreeID, name: "w", path: "/w", tabs: [tab])
        ])
    ])

    let recorded = LockIsolated<PaneID?>(nil)
    let store = TestStore(initialState: PaneActionRouterFeature.State()) {
      PaneActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.focusPane = { pid, _, _, _ in recorded.setValue(pid) }
    }

    // From topLeft: → must be topRight (was bottomLeft pre-fix).
    await store.send(.requested(f.paneID, .gotoSplit(direction: .right)))
    #expect(recorded.value == topRight)

    // ↓ from topLeft: bottomLeft (X-overlap) over bottomRight.
    recorded.setValue(nil)
    await store.send(.requested(f.paneID, .gotoSplit(direction: .down)))
    #expect(recorded.value == bottomLeft)
  }

  // MARK: - resizeSplit

  @Test
  func resizeSplitCallsResizePaneWithDirectionAndAmount() async {
    let f = Fixture()
    let recorded = LockIsolated<(PaneID, ResizeDirection, Double)?>(nil)
    let store = TestStore(initialState: PaneActionRouterFeature.State()) {
      PaneActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      // resizeSplit does not consult addressOf in the reducer, but the
      // override is cheap insurance against future refactors.
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.resizePane = { paneID, direction, amount in
        recorded.setValue((paneID, direction, amount))
      }
    }

    await store.send(.requested(f.paneID, .resizeSplit(direction: .up, amount: 0.1)))
    #expect(recorded.value?.0 == f.paneID)
    #expect(recorded.value?.1 == .up)
    #expect(recorded.value?.2 == 0.1)
  }

  // MARK: - equalizeSplits

  @Test
  func equalizeSplitsCallsEqualizeTabSplits() async {
    let f = Fixture()
    let recorded = LockIsolated<(TabID, WorktreeID, ProjectID)?>(nil)
    let store = TestStore(initialState: PaneActionRouterFeature.State()) {
      PaneActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.equalizeTabSplits = { tid, wid, pid in
        recorded.setValue((tid, wid, pid))
      }
    }

    await store.send(.requested(f.paneID, .equalizeSplits))
    #expect(recorded.value?.0 == f.tabID)
    #expect(recorded.value?.1 == f.worktreeID)
  }

  // MARK: - toggleSplitZoom (two branches)

  @Test
  func toggleSplitZoomWhenNotZoomedCallsFocusPane() async {
    let f = Fixture()
    let focusCalled = LockIsolated<(PaneID, TabID)?>(nil)
    let unzoomCalled = LockIsolated(false)
    let catalog = f.catalog(zoomed: false)
    let store = TestStore(initialState: PaneActionRouterFeature.State()) {
      PaneActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.focusPane = { paneID, tid, _, _ in
        focusCalled.setValue((paneID, tid))
      }
      $0.hierarchyClient.unzoomTab = { _, _, _ in unzoomCalled.setValue(true) }
    }

    await store.send(.requested(f.paneID, .toggleSplitZoom))
    #expect(focusCalled.value?.0 == f.paneID)
    #expect(focusCalled.value?.1 == f.tabID)
    #expect(unzoomCalled.value == false)
  }

  @Test
  func toggleSplitZoomWhenZoomedCallsUnzoomTab() async {
    let f = Fixture()
    let focusCalled = LockIsolated(false)
    let unzoomCalled = LockIsolated<(TabID, WorktreeID, ProjectID)?>(nil)
    let catalog = f.catalog(zoomed: true)
    let store = TestStore(initialState: PaneActionRouterFeature.State()) {
      PaneActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.focusPane = { _, _, _, _ in focusCalled.setValue(true) }
      $0.hierarchyClient.unzoomTab = { tid, wid, pid in
        unzoomCalled.setValue((tid, wid, pid))
      }
    }

    await store.send(.requested(f.paneID, .toggleSplitZoom))
    #expect(focusCalled.value == false)
    #expect(unzoomCalled.value?.0 == f.tabID)
    #expect(unzoomCalled.value?.1 == f.worktreeID)
  }

  // MARK: - presentTerminal / toggleCommandPalette (delegates)

  @Test
  func presentTerminalEmitsDelegate() async {
    let f = Fixture()
    let store = TestStore(initialState: PaneActionRouterFeature.State()) {
      PaneActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
    }

    await store.send(.requested(f.paneID, .presentTerminal))
    await store.receive(.delegate(.presentTerminalRequested(f.paneID)))
  }

  @Test
  func toggleCommandPaletteEmitsDelegate() async {
    let f = Fixture()
    let store = TestStore(initialState: PaneActionRouterFeature.State()) {
      PaneActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
    }

    await store.send(.requested(f.paneID, .toggleCommandPalette))
    await store.receive(.delegate(.commandPaletteToggleRequested(f.paneID)))
  }

  // MARK: - addressOf nil (teardown race)

  /// Reducer must never crash when `addressOf` returns `nil` — the router
  /// is called on the ghostty action callback thread, so a `paneID` that
  /// raced teardown is expected. No mutation closure should fire.
  @Test
  func missingAddressIsSilentNoOp() async {
    let f = Fixture()
    let createTabCalled = LockIsolated(false)
    let closeTabCalled = LockIsolated(false)
    let moveTabCalled = LockIsolated(false)
    let store = TestStore(initialState: PaneActionRouterFeature.State()) {
      PaneActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in nil }
      $0.hierarchyClient.createTab = { _, _, _ in
        createTabCalled.setValue(true)
        return TabID()
      }
      $0.hierarchyClient.closeTab = { _, _, _ in closeTabCalled.setValue(true) }
      $0.hierarchyClient.moveTab = { _, _, _, _ in moveTabCalled.setValue(true) }
    }

    await store.send(.requested(f.paneID, .newTab))
    await store.send(.requested(f.paneID, .closeTab(mode: .this)))
    await store.send(.requested(f.paneID, .moveTab(offset: 1)))
    #expect(createTabCalled.value == false)
    #expect(closeTabCalled.value == false)
    #expect(moveTabCalled.value == false)
  }
}
