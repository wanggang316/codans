import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// Reducer-level coverage for `CommandPaletteFeature`: item rebuild on
/// open, filtering on each keystroke, selection arithmetic, and the
/// recency write path that RootFeature persists after activation.
@MainActor
struct CommandPaletteFeatureTests {
  private static let sampleCatalog = Catalog()
  private static let sampleSelection = HierarchySelection.empty

  private static func testItem(
    id: String,
    title: String,
    kind: CommandPaletteItem.Kind = .openSettings
  ) -> CommandPaletteItem {
    CommandPaletteItem(id: id, title: title, icon: "circle", kind: kind)
  }

  // MARK: - Appeared

  @Test
  func appearedPopulatesItemsAndSelectsFirst() async {
    let store = TestStore(initialState: CommandPaletteFeature.State()) {
      CommandPaletteFeature()
    }
    store.exhaustivity = .off
    await store.send(.appeared(Self.sampleSelection, Self.sampleCatalog, [], [:], nil, false))
    // `.appeared` defers the build to a follow-up `.indexed` action so the
    // search field can paint immediately on Cmd-K.
    await store.receive(\.indexed)
    #expect(!store.state.items.isEmpty)
    #expect(store.state.filtered.first?.id == store.state.selectionID)
  }

  @Test
  func appearedPrunesStaleDynamicRecency() async {
    let stale: [String: TimeInterval] = [
      "worktree.select.00000000-0000-0000-0000-000000000000": 1_700_000_000,
      "app.open-settings": 1_700_000_100,
    ]
    let store = TestStore(initialState: CommandPaletteFeature.State()) {
      CommandPaletteFeature()
    }
    store.exhaustivity = .off
    await store.send(.appeared(Self.sampleSelection, Self.sampleCatalog, [], stale, nil, false))
    await store.receive(\.indexed)
    // Static ID survives; dynamic ID pointing to a missing worktree is dropped.
    #expect(store.state.recency["app.open-settings"] == 1_700_000_100)
    #expect(store.state.recency["worktree.select.00000000-0000-0000-0000-000000000000"] == nil)
  }

  // MARK: - Query

  @Test
  func queryChangedFiltersItems() async {
    var state = CommandPaletteFeature.State()
    state.items = [
      Self.testItem(id: "a", title: "Git Viewer"),
      Self.testItem(id: "b", title: "New Tab"),
      Self.testItem(id: "c", title: "Quit"),
    ]
    state.filtered = state.items
    state.selectionID = "a"
    let store = TestStore(initialState: state) { CommandPaletteFeature() }
    store.exhaustivity = .off
    await store.send(.queryChanged("git"))
    #expect(store.state.filtered.count == 1)
    #expect(store.state.filtered.first?.id == "a")
    #expect(store.state.selectionID == "a")
  }

  // MARK: - Activation + recency write

  @Test
  func selectionCommittedWritesRecencyAndEmitsActivate() async {
    var state = CommandPaletteFeature.State()
    state.filtered = [Self.testItem(id: "app.open-settings", title: "Open Settings")]
    state.selectionID = "app.open-settings"
    let store = TestStore(initialState: state) { CommandPaletteFeature() }
    store.exhaustivity = .off
    await store.send(.selectionCommitted)
    #expect(store.state.recency["app.open-settings"] != nil)
    await store.receive(.delegate(.activate(.openSettings)))
  }

  @Test
  func rowTappedActivatesAndRecords() async {
    var state = CommandPaletteFeature.State()
    state.filtered = [
      Self.testItem(id: "git.toggle-viewer", title: "Toggle Git Viewer", kind: .toggleDiffInspector)
    ]
    let store = TestStore(initialState: state) { CommandPaletteFeature() }
    store.exhaustivity = .off
    await store.send(.rowTapped("git.toggle-viewer"))
    #expect(store.state.recency["git.toggle-viewer"] != nil)
    await store.receive(.delegate(.activate(.toggleDiffInspector)))
  }

  // MARK: - Selection navigation

  @Test
  func selectionMovedWrapsAtBoundaries() async {
    var state = CommandPaletteFeature.State()
    state.filtered = [
      Self.testItem(id: "a", title: "A"),
      Self.testItem(id: "b", title: "B", kind: .toggleDiffInspector),
    ]
    state.selectionID = "a"
    let store = TestStore(initialState: state) { CommandPaletteFeature() }
    await store.send(.selectionMoved(.down)) { $0.selectionID = "b" }
    await store.send(.selectionMoved(.down)) { $0.selectionID = "a" }
    await store.send(.selectionMoved(.up)) { $0.selectionID = "b" }
  }
}
