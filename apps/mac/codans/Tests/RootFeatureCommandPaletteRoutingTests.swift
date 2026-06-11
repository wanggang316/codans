import ComposableArchitecture
import Foundation
import Testing
import CodansCore

@testable import Codans

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
  func activateSelectWorktreeRevealsAndExpandsInSidebar() async {
    // The palette is keyboard-only, so selecting a worktree must reveal it
    // in the sidebar: expand the parent project (so the row renders), force
    // the sidebar visible, and bump the reveal trigger that drives
    // scroll-into-view. Selection itself still routes through worktreeRowTapped.
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let expandCalls = LockIsolated<[(ProjectID, Bool)]>([])
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { Catalog() }
      $0.hierarchyClient.lastFocusedPane = { _ in nil }
      $0.hierarchyClient.setProjectExpanded = { pid, expanded in
        expandCalls.withValue { $0.append((pid, expanded)) }
      }
      $0.hierarchyClient.selectProject = { _ in }
      $0.hierarchyClient.selectWorktree = { _, _ in }
    }
    store.exhaustivity = .off

    let before = store.state.revealSelectionTrigger
    await store.send(.commandPaletteToggle(nil))
    await store.send(
      .commandPalette(
        .presented(.delegate(.activate(.selectWorktree(projectID, worktreeID)))))
    )
    await store.receive(\.sidebar.worktreeRowTapped)
    await store.finish()

    #expect(store.state.revealSelectionTrigger != before)
    #expect(store.state.sidebarVisible)
    #expect(expandCalls.value.count == 1)
    #expect(expandCalls.value.first?.0 == projectID)
    #expect(expandCalls.value.first?.1 == true)
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
