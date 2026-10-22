import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

/// Keyboard commands act on the focused Pane, never on another Pane of the
/// Worktree. The fixture has two Panes side by side; the right one is
/// focused, so every command must address it (or its selected Tab).
@MainActor
struct RootFeatureFocusedPaneRoutingTests {
  @MainActor
  private struct Fixture {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let left: Pane
    let right: Pane
    let catalog: Catalog

    init() throws {
      let leftTabs = (0..<3).map { Tab(name: "l\($0)", content: .terminal(workingDirectory: "/tmp")) }
      let rightTabs = (0..<2).map { Tab(name: "r\($0)", content: .terminal(workingDirectory: "/tmp/r")) }
      left = Pane(tabs: leftTabs, selectedTabID: leftTabs[2].id)
      right = Pane(tabs: rightTabs, selectedTabID: rightTabs[1].id)
      let worktree = Worktree(
        id: worktreeID, name: "main", path: "/tmp", branch: "main",
        splitTree: try SplitTree(leaf: left.id).inserting(right.id, at: left.id, direction: .right),
        panes: [left, right], focusedPaneID: right.id
      )
      catalog = Catalog(projects: [
        Project(
          id: projectID, name: "p", rootPath: "/tmp",
          worktrees: [worktree], selectedWorktreeID: worktreeID)
      ])
    }

    var focused: TabAddress {
      let tab = right.selectedTab!
      return TabAddress(
        projectID: projectID, worktreeID: worktreeID, paneID: right.id,
        tabID: tab.id, contentID: tab.contentID)
    }

    var state: RootFeature.State {
      var state = RootFeature.State()
      state.selection = HierarchySelection(projectID: projectID, worktreeID: worktreeID)
      return state
    }
  }

  private func makeStore(
    _ fixture: Fixture, _ configure: (inout DependencyValues) -> Void
  ) -> TestStoreOf<RootFeature> {
    let store = TestStore(initialState: fixture.state) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { fixture.catalog }
      $0.hierarchyClient.focusedContent = { _ in fixture.focused }
      $0.hierarchyClient.addressOf = { contentID in fixture.catalog.address(forContent: contentID) }
      $0.hierarchyClient.ensureSurface = { _ in }
      $0.hierarchyClient.focusSurfaceView = { _ in }
      $0.continuousClock = ImmediateClock()
      configure(&$0)
    }
    store.exhaustivity = .off
    return store
  }

  @Test
  func newTabLandsInTheFocusedPane() async throws {
    let fixture = try Fixture()
    let pane = LockIsolated<PaneID??>(nil)
    let store = makeStore(fixture) {
      $0.hierarchyClient.newTab = { paneID, _, _, _, _, _, _ in
        pane.withValue { $0 = paneID }
        return fixture.focused
      }
    }

    await store.send(.newTabForCurrentWorktree)
    await store.finish()
    // `nil` asks the manager for the Worktree's focused Pane.
    #expect(pane.value == .some(nil))
  }

  @Test
  func closeTabClosesTheFocusedPanesSelectedTab() async throws {
    let fixture = try Fixture()
    let closed = LockIsolated<TabID?>(nil)
    let store = makeStore(fixture) {
      $0.hierarchyClient.closeTab = { id in closed.withValue { $0 = id } }
    }

    await store.send(.closeActiveTabForCurrentWorktree)
    await store.finish()
    #expect(closed.value == fixture.right.selectedTabID)
  }

  @Test
  func selectByPositionCountsInTheFocusedPane() async throws {
    let fixture = try Fixture()
    let call = LockIsolated<(Int, PaneID)?>(nil)
    let store = makeStore(fixture) {
      $0.hierarchyClient.selectTabAtIndex = { index, paneID in
        call.withValue { $0 = (index, paneID) }
        return nil
      }
    }

    await store.send(.selectTabAtIndexForCurrentWorktree(1))
    await store.finish()
    #expect(call.value?.0 == 0)
    #expect(call.value?.1 == fixture.right.id)
  }

  @Test
  func adjacentTabCyclesInTheFocusedPane() async throws {
    let fixture = try Fixture()
    let call = LockIsolated<(TabAdjacency, PaneID)?>(nil)
    let store = makeStore(fixture) {
      $0.hierarchyClient.selectAdjacentTab = { direction, paneID in
        call.withValue { $0 = (direction, paneID) }
        return nil
      }
    }

    await store.send(.selectAdjacentTabForCurrentWorktree(.previous))
    await store.finish()
    #expect(call.value?.0 == .previous)
    #expect(call.value?.1 == fixture.right.id)
  }

  @Test(arguments: [SplitTree<PaneID>.NewDirection.right, .down])
  func splitCreatesAPaneBesideTheFocusedOne(direction: SplitTree<PaneID>.NewDirection) async throws {
    let fixture = try Fixture()
    let call = LockIsolated<(PaneID, SplitTree<PaneID>.NewDirection, String?)?>(nil)
    let store = makeStore(fixture) {
      $0.hierarchyClient.splitPane = { paneID, direction, content, _, _ in
        call.withValue { $0 = (paneID, direction, content.terminal?.workingDirectory) }
        return fixture.focused
      }
    }

    await store.send(.splitCurrentPaneRequested(direction: direction))
    await store.finish()
    #expect(call.value?.0 == fixture.right.id)
    #expect(call.value?.1 == direction)
    // The fresh Tab starts where the focused Tab's session is.
    #expect(call.value?.2 == "/tmp/r")
  }

  @Test
  func directionalFocusMovesFromTheFocusedPane() async throws {
    let fixture = try Fixture()
    let call = LockIsolated<(PaneID, FocusDirection)?>(nil)
    let store = makeStore(fixture) {
      $0.hierarchyClient.focusNeighbour = { paneID, direction in
        call.withValue { $0 = (paneID, direction) }
        return fixture.left.id
      }
    }

    await store.send(.focusAdjacentPaneInCurrentTabRequested(direction: .left))
    await store.finish()
    #expect(call.value?.0 == fixture.right.id)
    #expect(call.value?.1 == .left)
  }

  @Test
  func paletteZoomTogglesTheFocusedPane() async throws {
    let fixture = try Fixture()
    let zoomed = LockIsolated<PaneID?>(nil)
    let store = makeStore(fixture) {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.editorClient = EditorClient.testValue
      $0.gitService = GitServiceClient.testValue
      // The palette reads settings to build its items.
      $0[SettingsWriter.self].readSnapshotSync = { Settings() }
      $0.hierarchyClient.toggleZoom = { paneID in
        zoomed.withValue { $0 = paneID }
        return true
      }
    }

    await store.send(.commandPaletteToggle(nil))
    await store.send(.commandPalette(.presented(.delegate(.activate(.paneAction(.toggleSplitZoom))))))
    await store.finish()
    #expect(zoomed.value == fixture.right.id)
  }
}
