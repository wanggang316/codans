import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// Every `CommandPaletteItem.Kind` must land in `RootFeature.route(_:)`
/// and fan out to an existing feature action. The switch is exhaustive
/// by compiler enforcement (no `default` case); this suite provides
/// runtime coverage for a representative set of branches so future
/// refactors of the destination action shapes trip a test rather than
/// silently producing a no-op at the palette edge.
@MainActor
struct RootFeatureCommandPaletteRoutingTests {
  private static func stubbedStore(
    state: RootFeature.State = RootFeature.State()
  ) -> TestStore<RootFeature.State, RootFeature.Action> {
    let store = TestStore(initialState: state) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { Catalog() }
      $0.editorClient = EditorClient.testValue
      $0.gitService = GitServiceClient.testValue
      $0.updatesClient.checkNow = {}
    }
    store.exhaustivity = .off
    return store
  }

  @Test
  func activateToggleDiffInspectorRoutesToRoot() async {
    let store = Self.stubbedStore()
    // Prime the palette so the delegate has a parent to bubble through.
    await store.send(.commandPaletteToggle(nil))
    await store.send(.commandPalette(.presented(.delegate(.activate(.toggleDiffInspector)))))
    await store.receive(\.diffInspectorToggledForCurrentWorktree)
  }

  @Test
  func activateWindowActionRoutesToWindowRouter() async {
    let store = Self.stubbedStore()
    await store.send(.commandPaletteToggle(nil))
    await store.send(
      .commandPalette(.presented(.delegate(.activate(.windowAction(.checkForUpdates)))))
    )
    await store.receive(\.windowActionRouter.requested)
  }

  @Test
  func activateOpenCurrentWorktreeInDefaultEditorRoutes() async {
    let store = Self.stubbedStore()
    await store.send(.commandPaletteToggle(nil))
    await store.send(
      .commandPalette(.presented(.delegate(.activate(.openCurrentWorktreeInDefaultEditor))))
    )
    await store.receive(\.openDefaultForCurrentWorktreeRequested)
  }

  @Test
  func activateSelectWorktreeDrivesFocusCascade() async {
    // Selecting a worktree from the palette is keyboard-only — unlike a
    // sidebar mouse click there's no follow-up pane click to set first
    // responder. The route must drive the full `focusHierarchyPath`
    // cascade and land focus on the worktree's pane, not merely flip
    // sidebar selection.
    let pane = Pane(workingDirectory: "/repo")
    let tab = Tab(splitTree: SplitTree(leaf: pane.id), panes: [pane])
    let worktree = Worktree(
      name: "main", path: "/repo", tabs: [tab], selectedTabID: tab.id
    )
    let project = Project(
      name: "p", rootPath: "/repo", gitRoot: "/repo",
      worktrees: [worktree], selectedWorktreeID: worktree.id
    )
    let catalog = Catalog(projects: [project])

    let focusSurfaceCalls = LockIsolated<[PaneID]>([])
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.lastFocusedPane = { _ in nil }
      $0.hierarchyClient.selectProject = { _ in }
      $0.hierarchyClient.selectWorktree = { _, _ in }
      $0.hierarchyClient.selectTab = { _, _, _ in }
      $0.hierarchyClient.focusPane = { _, _, _, _ in }
      $0.hierarchyClient.focusSurfaceView = { paneID in
        focusSurfaceCalls.withValue { $0.append(paneID) }
      }
    }
    store.exhaustivity = .off

    await store.send(.commandPaletteToggle(nil))
    await store.send(
      .commandPalette(
        .presented(.delegate(.activate(.selectWorktree(project.id, worktree.id)))))
    )
    await store.receive(\.focusHierarchyPath)
    await store.finish()

    // The cascade made the worktree's only pane first responder.
    #expect(focusSurfaceCalls.value == [pane.id])
  }

  @Test
  func activateSelectWorktreeWithoutPaneFallsBackToSidebarSelection() async {
    // A worktree with no seeded tab/pane has nothing to focus; the palette
    // degrades to a bare selection rather than dropping the activation.
    let worktree = Worktree(name: "main", path: "/repo", tabs: [], selectedTabID: nil)
    let project = Project(
      name: "p", rootPath: "/repo", gitRoot: "/repo",
      worktrees: [worktree], selectedWorktreeID: worktree.id
    )
    let catalog = Catalog(projects: [project])

    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.lastFocusedPane = { _ in nil }
      $0.hierarchyClient.selectProject = { _ in }
      $0.hierarchyClient.selectWorktree = { _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.commandPaletteToggle(nil))
    await store.send(
      .commandPalette(
        .presented(.delegate(.activate(.selectWorktree(project.id, worktree.id)))))
    )
    await store.receive(\.sidebar.worktreeRowTapped)
    await store.finish()
  }

  @Test
  func paneActionIsDroppedWhenNoFocusedPane() async {
    // Empty selection → no focused pane → palette silently discards
    // Pane-scoped activations rather than sending with a bogus ID.
    let store = Self.stubbedStore()
    await store.send(.commandPaletteToggle(nil))
    await store.send(
      .commandPalette(.presented(.delegate(.activate(.paneAction(.newTab)))))
    )
    // No downstream action expected — the reducer returns .none.
    // The assertion here is simply that the test does not hang waiting
    // on a receive. `exhaustivity = .off` tolerates no receive.
  }
}
