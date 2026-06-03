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
