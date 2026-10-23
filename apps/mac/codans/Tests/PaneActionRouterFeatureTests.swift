import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

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

  /// Minimal one-of-each catalog with a ready `TabAddress` the reducer
  /// resolves the source `contentID` to. Using stable IDs keeps the
  /// recorded-call assertions decoupled from `UUID()` randomness.
  private struct Fixture {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let paneID = PaneID()
    let tabID = TabID()
    let contentID = ContentID()
    let secondTabID = TabID()
    let secondContentID = ContentID()

    var address: TabAddress {
      TabAddress(
        projectID: projectID, worktreeID: worktreeID,
        paneID: paneID, tabID: tabID, contentID: contentID
      )
    }

    /// Catalog shape used by `newTab` / `newSplit` / `gotoTab` which read
    /// `snapshot()` to find the source session's directory and its Pane.
    /// The second Tab sits in the same Pane so `gotoTab(.next)` has a
    /// non-trivial target.
    func catalog(zoomed: Bool = false) -> Catalog {
      let tab = Tab(id: tabID, content: .terminal(id: contentID, workingDirectory: "/cwd"))
      let secondTab = Tab(
        id: secondTabID, content: .terminal(id: secondContentID, workingDirectory: "/cwd2"))
      let pane = Pane(id: paneID, tabs: [tab, secondTab], selectedTabID: tabID)
      var splitTree = SplitTree(leaf: paneID)
      if zoomed { splitTree = splitTree.settingZoomed(paneID) }
      let worktree = Worktree(
        id: worktreeID, name: "w", path: "/w",
        splitTree: splitTree, panes: [pane], focusedPaneID: paneID
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
  func newTabOpensATabInTheSourcePaneWithItsDirectory() async {
    let f = Fixture()
    let recorded = LockIsolated<(PaneID?, WorktreeID, ProjectID, String?)?>(nil)
    let ensured = LockIsolated<ContentID?>(nil)
    let focused = LockIsolated<ContentID?>(nil)
    let createdContent = ContentID()
    let store = TestStore(initialState: PaneActionRouterFeature.State()) {
      PaneActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.snapshot = { f.catalog() }
      $0.hierarchyClient.newTab = { paneID, wid, pid, content, _, _, _ in
        recorded.setValue((paneID, wid, pid, content.terminal?.workingDirectory))
        return TabAddress(
          projectID: pid, worktreeID: wid, paneID: paneID ?? PaneID(),
          tabID: TabID(), contentID: createdContent)
      }
      $0.hierarchyClient.ensureSurface = { id in ensured.setValue(id) }
      $0.hierarchyClient.focusSurfaceView = { id in focused.setValue(id) }
    }

    await store.send(.requested(f.contentID, .newTab))
    await store.finish()
    #expect(recorded.value?.0 == f.paneID)
    #expect(recorded.value?.1 == f.worktreeID)
    #expect(recorded.value?.2 == f.projectID)
    #expect(recorded.value?.3 == "/cwd")
    #expect(ensured.value == createdContent)
    #expect(focused.value == createdContent)
  }

  // MARK: - closeTab(.this)

  @Test
  func closeTabThisCallsCloseTab() async {
    let f = Fixture()
    let recorded = LockIsolated<TabID?>(nil)
    let store = TestStore(initialState: PaneActionRouterFeature.State()) {
      PaneActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.closeTab = { tid in recorded.setValue(tid) }
    }

    await store.send(.requested(f.contentID, .closeTab(mode: .this)))
    #expect(recorded.value == f.tabID)
  }

  // MARK: - moveTab

  @Test
  func moveTabCallsMoveTabWithOffset() async {
    let f = Fixture()
    let recorded = LockIsolated<(TabID, Int)?>(nil)
    let store = TestStore(initialState: PaneActionRouterFeature.State()) {
      PaneActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.moveTab = { tid, offset in recorded.setValue((tid, offset)) }
    }

    await store.send(.requested(f.contentID, .moveTab(offset: 2)))
    #expect(recorded.value?.0 == f.tabID)
    #expect(recorded.value?.1 == 2)
  }

  // MARK: - gotoTab(.next)

  @Test
  func gotoTabNextCallsSelectTabWithNextTabID() async {
    let f = Fixture()
    let recorded = LockIsolated<TabID?>(nil)
    let catalog = f.catalog()
    let store = TestStore(initialState: PaneActionRouterFeature.State()) {
      PaneActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.selectTab = { tid in recorded.setValue(tid) }
    }

    await store.send(.requested(f.contentID, .gotoTab(target: .next)))
    // With two tabs (`tabID`, `secondTabID`) and current index 0, .next → secondTabID.
    #expect(recorded.value == f.secondTabID)
  }

  // MARK: - newSplit

  @Test
  func newSplitHorizontalCallsSplitPaneWithRightDirection() async {
    let f = Fixture()
    let recorded = LockIsolated<(PaneID, SplitTree<PaneID>.NewDirection, String?)?>(nil)
    let ensured = LockIsolated<ContentID?>(nil)
    let createdContent = ContentID()
    let catalog = f.catalog()
    let store = TestStore(initialState: PaneActionRouterFeature.State()) {
      PaneActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.splitPane = { paneID, dir, content, _, _ in
        recorded.setValue((paneID, dir, content.terminal?.workingDirectory))
        return TabAddress(
          projectID: f.projectID, worktreeID: f.worktreeID, paneID: PaneID(),
          tabID: TabID(), contentID: createdContent)
      }
      $0.hierarchyClient.ensureSurface = { id in ensured.setValue(id) }
      $0.hierarchyClient.focusSurfaceView = { _ in }
    }

    await store.send(.requested(f.contentID, .newSplit(direction: .right)))
    await store.finish()
    #expect(recorded.value?.0 == f.paneID)
    #expect(recorded.value?.1 == .right)
    #expect(recorded.value?.2 == "/cwd")
    #expect(ensured.value == createdContent)
  }

  // MARK: - closePane

  /// ghostty's `close_surface` closes the session the keybind fired in:
  /// the router retires that Tab and leaves the "last Tab closes the
  /// Pane" rule to the manager. `closePane` must NOT fire.
  @Test
  func closePaneClosesTheSourceTab() async {
    let f = Fixture()
    let closedTab = LockIsolated<TabID?>(nil)
    let closePaneCalled = LockIsolated(false)
    let store = TestStore(initialState: PaneActionRouterFeature.State()) {
      PaneActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.closeTab = { tid in closedTab.setValue(tid) }
      $0.hierarchyClient.closePane = { _ in closePaneCalled.setValue(true) }
    }

    await store.send(.requested(f.contentID, .closePane))
    #expect(closedTab.value == f.tabID)
    #expect(closePaneCalled.value == false)
  }

  // MARK: - gotoSplit

  /// The spatial walk lives in the manager; the router forwards the
  /// source Pane and the direction untouched.
  @Test
  func gotoSplitForwardsDirectionToFocusNeighbour() async {
    let f = Fixture()
    let recorded = LockIsolated<[(PaneID, FocusDirection)]>([])
    let store = TestStore(initialState: PaneActionRouterFeature.State()) {
      PaneActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.focusNeighbour = { pid, direction in
        recorded.withValue { $0.append((pid, direction)) }
        return nil
      }
    }

    await store.send(.requested(f.contentID, .gotoSplit(direction: .right)))
    await store.send(.requested(f.contentID, .gotoSplit(direction: .down)))
    #expect(recorded.value.map(\.0) == [f.paneID, f.paneID])
    #expect(recorded.value.map(\.1) == [.right, .down])
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
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.resizePane = { paneID, direction, amount in
        recorded.setValue((paneID, direction, amount))
      }
    }

    await store.send(.requested(f.contentID, .resizeSplit(direction: .up, amount: 0.1)))
    #expect(recorded.value?.0 == f.paneID)
    #expect(recorded.value?.1 == .up)
    #expect(recorded.value?.2 == 0.1)
  }

  // MARK: - equalizeSplits

  @Test
  func equalizeSplitsCallsEqualizeSplitsForTheWorktree() async {
    let f = Fixture()
    let recorded = LockIsolated<(WorktreeID, ProjectID)?>(nil)
    let store = TestStore(initialState: PaneActionRouterFeature.State()) {
      PaneActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.equalizeSplits = { wid, pid in recorded.setValue((wid, pid)) }
    }

    await store.send(.requested(f.contentID, .equalizeSplits))
    #expect(recorded.value?.0 == f.worktreeID)
    #expect(recorded.value?.1 == f.projectID)
  }

  // MARK: - toggleSplitZoom

  /// Zoom state is owned by the Worktree's split tree; the router asks the
  /// manager to flip it for the source Pane whether or not it is zoomed.
  @Test
  func toggleSplitZoomCallsToggleZoomOnTheSourcePane() async {
    let f = Fixture()
    let recorded = LockIsolated<[PaneID]>([])
    let store = TestStore(initialState: PaneActionRouterFeature.State()) {
      PaneActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.snapshot = { f.catalog(zoomed: true) }
      $0.hierarchyClient.toggleZoom = { pid in
        recorded.withValue { $0.append(pid) }
        return false
      }
    }

    await store.send(.requested(f.contentID, .toggleSplitZoom))
    #expect(recorded.value == [f.paneID])
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

    await store.send(.requested(f.contentID, .presentTerminal))
    await store.receive(.delegate(.presentTerminalRequested(f.contentID)))
  }

  @Test
  func toggleCommandPaletteEmitsDelegate() async {
    let f = Fixture()
    let store = TestStore(initialState: PaneActionRouterFeature.State()) {
      PaneActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
    }

    await store.send(.requested(f.contentID, .toggleCommandPalette))
    await store.receive(.delegate(.commandPaletteToggleRequested(f.contentID)))
  }

  @Test
  func openLinkEmitsDelegate() async {
    let f = Fixture()
    let store = TestStore(initialState: PaneActionRouterFeature.State()) {
      PaneActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
    }

    await store.send(.requested(f.contentID, .openLink(raw: "src/a.swift:3", workingDirectory: "/repo")))
    await store.receive(
      .delegate(.openLinkRequested(f.contentID, raw: "src/a.swift:3", workingDirectory: "/repo")))
  }

  // MARK: - addressOf nil (teardown race)

  /// Reducer must never crash when `addressOf` returns `nil` — the router
  /// is called on the ghostty action callback thread, so a Content that
  /// raced teardown is expected. No mutation closure should fire.
  @Test
  func missingAddressIsSilentNoOp() async {
    let f = Fixture()
    let newTabCalled = LockIsolated(false)
    let closeTabCalled = LockIsolated(false)
    let moveTabCalled = LockIsolated(false)
    let store = TestStore(initialState: PaneActionRouterFeature.State()) {
      PaneActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in nil }
      $0.hierarchyClient.newTab = { paneID, wid, pid, _, _, _, _ in
        newTabCalled.setValue(true)
        return TabAddress(
          projectID: pid, worktreeID: wid, paneID: paneID ?? PaneID(),
          tabID: TabID(), contentID: ContentID())
      }
      $0.hierarchyClient.closeTab = { _ in closeTabCalled.setValue(true) }
      $0.hierarchyClient.moveTab = { _, _ in moveTabCalled.setValue(true) }
    }

    await store.send(.requested(f.contentID, .newTab))
    await store.send(.requested(f.contentID, .closeTab(mode: .this)))
    await store.send(.requested(f.contentID, .moveTab(offset: 1)))
    #expect(newTabCalled.value == false)
    #expect(closeTabCalled.value == false)
    #expect(moveTabCalled.value == false)
  }
}
