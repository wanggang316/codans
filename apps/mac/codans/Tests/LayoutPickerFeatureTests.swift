import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

@MainActor
struct LayoutPickerFeatureTests {
  /// A | B, split 1:1 — the `columns` preset for two Panes.
  private static func twoColumns() throws -> (SplitTree<PaneID>, PaneID, PaneID) {
    let a = PaneID(), b = PaneID()
    return (try SplitTree(leaf: a).inserting(b, at: a, direction: .right), a, b)
  }

  private static func fourPanes() throws -> (SplitTree<PaneID>, [PaneID]) {
    let ids = (0..<4).map { _ in PaneID() }
    var tree = SplitTree(leaf: ids[0])
    for index in 1..<ids.count {
      tree = try tree.inserting(ids[index], at: ids[index - 1], direction: .down)
    }
    return (tree, ids)
  }

  @Test
  func openListsPresetsForPaneCountAndMarksCurrentPreset() throws {
    let (tree, _, b) = try Self.twoColumns()
    let state = try #require(LayoutPickerFeature.State(splitTree: tree, focusedPaneID: b))
    #expect(state.paneID == b)
    #expect(state.paneCount == 2)
    #expect(state.focusedPaneNumber == 2)
    #expect(state.presets == LayoutPreset.presets(forPaneCount: 2))
    #expect(state.currentPreset == .columns)
    #expect(state.selectedIndex == state.presets.firstIndex(of: .columns))
  }

  @Test
  func openSelectsFirstPresetWhenNoPresetMatches() throws {
    let (tree, _, b) = try Self.twoColumns()
    let skewed = try tree.resizing(at: SplitTree<PaneID>.Path(), ratio: 0.42)
    let state = try #require(LayoutPickerFeature.State(splitTree: skewed, focusedPaneID: b))
    #expect(state.currentPreset == nil)
    #expect(state.selectedIndex == 0)
  }

  @Test
  func onePaneTabHasNoPicker() {
    let a = PaneID()
    #expect(LayoutPickerFeature.State(splitTree: SplitTree(leaf: a), focusedPaneID: a) == nil)
  }

  @Test
  func paneOutsideTheTabHasNoPicker() throws {
    let (tree, _, _) = try Self.twoColumns()
    #expect(LayoutPickerFeature.State(splitTree: tree, focusedPaneID: PaneID()) == nil)
  }

  @Test
  func digitAppliesItsPreset() async throws {
    let (tree, ids) = try Self.fourPanes()
    let state = try #require(LayoutPickerFeature.State(splitTree: tree, focusedPaneID: ids[0]))
    let store = TestStore(initialState: state) { LayoutPickerFeature() }
    let expected = state.presets[3]
    await store.send(.digitPressed(4)) { $0.selectedIndex = 3 }
    await store.receive(\.delegate.apply, expected)
  }

  @Test
  func digitWithNoPresetDoesNothing() async throws {
    let (tree, _, a) = try Self.twoColumns()
    let state = try #require(LayoutPickerFeature.State(splitTree: tree, focusedPaneID: a))
    let store = TestStore(initialState: state) { LayoutPickerFeature() }
    await store.send(.digitPressed(7))
    await store.send(.digitPressed(0))
  }

  @Test
  func arrowsMoveSelectionInTheGridAndReturnApplies() async throws {
    // Two Panes: six presets in two rows of three.
    let (tree, a, _) = try Self.twoColumns()
    let state = try #require(LayoutPickerFeature.State(splitTree: tree, focusedPaneID: a))
    #expect(state.selectedIndex == 0)
    let store = TestStore(initialState: state) { LayoutPickerFeature() }
    await store.send(.selectionMoved(.left))  // edge: stays
    await store.send(.selectionMoved(.up))  // edge: stays
    await store.send(.selectionMoved(.right)) { $0.selectedIndex = 1 }
    await store.send(.selectionMoved(.down)) { $0.selectedIndex = 4 }
    await store.send(.selectionMoved(.down))  // edge: stays
    await store.send(.selectionMoved(.right)) { $0.selectedIndex = 5 }
    await store.send(.selectionMoved(.right))  // edge: stays
    await store.send(.selectionCommitted)
    await store.receive(\.delegate.apply, state.presets[5])
  }

  @Test
  func tapAppliesThePreset() async throws {
    let (tree, a, _) = try Self.twoColumns()
    let state = try #require(LayoutPickerFeature.State(splitTree: tree, focusedPaneID: a))
    let store = TestStore(initialState: state) { LayoutPickerFeature() }
    await store.send(.presetTapped(.rowsTwoToOne)) {
      $0.selectedIndex = state.presets.firstIndex(of: .rowsTwoToOne)!
    }
    await store.receive(\.delegate.apply, .rowsTwoToOne)
  }

  @Test
  func escapeCancels() async throws {
    let (tree, a, _) = try Self.twoColumns()
    let state = try #require(LayoutPickerFeature.State(splitTree: tree, focusedPaneID: a))
    let store = TestStore(initialState: state) { LayoutPickerFeature() }
    await store.send(.cancelled)
    await store.receive(\.delegate.cancel)
  }

  @Test
  func thumbnailDrawsThePresetShapeWithPaneNumbers() {
    let columns = LayoutPickerFeature.thumbnail(.columnsTwoToOne, paneCount: 2, focusedPaneNumber: 1)
    #expect(columns.map(\.leaf) == [1, 2])
    #expect(abs(columns[0].bounds.width - 2.0 / 3) < 1e-9)

    // Main Left puts the focused Pane (number 3) in the left half.
    let main = LayoutPickerFeature.thumbnail(.mainLeft, paneCount: 3, focusedPaneNumber: 3)
    #expect(main.first?.leaf == 3)
    #expect(main.first?.bounds == CGRect(x: 0, y: 0, width: 0.5, height: 1))

    let grid = LayoutPickerFeature.thumbnail(.grid, paneCount: 4, focusedPaneNumber: 1)
    #expect(grid.count == 4)
    #expect(grid.allSatisfy { abs($0.bounds.width - 0.5) < 1e-9 && abs($0.bounds.height - 0.5) < 1e-9 })
  }
}
