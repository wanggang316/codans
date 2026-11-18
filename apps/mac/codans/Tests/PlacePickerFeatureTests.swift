import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

@MainActor
struct PlacePickerFeatureTests {
  private static func panes(_ count: Int) throws -> (SplitTree<PaneID>, [PaneID]) {
    let ids = (0..<count).map { _ in PaneID() }
    var tree = SplitTree(leaf: ids[0])
    for index in 1..<ids.count {
      tree = try tree.inserting(ids[index], at: ids[index - 1], direction: .right)
    }
    return (tree, ids)
  }

  private static func state(paneCount: Int, focus: Int = 0) throws -> PlacePickerFeature.State {
    let (tree, ids) = try panes(paneCount)
    return try #require(PlacePickerFeature.State(tabID: TabID(), splitTree: tree, focusedPaneID: ids[focus]))
  }

  @Test
  func openListsTheRegionsWithTheirFixedKeysAndSelectsTheFirst() throws {
    let state = try Self.state(paneCount: 3, focus: 1)
    #expect(state.items.map(\.key) == ["1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E"])
    #expect(
      state.items.map(\.region) == [
        .leftHalf, .rightHalf, .topHalf, .bottomHalf,
        .leftTwoThirds, .rightTwoThirds, .topTwoThirds, .bottomTwoThirds,
        .leftThird, .rightThird, .topThird, .bottomThird,
        .centerThird, .middleThird,
      ])
    #expect(state.selectedIndex == 0)
  }

  @Test
  func twoPanesHideTheCenterThirdsAndKeepTheOtherKeys() throws {
    let two = try Self.state(paneCount: 2)
    let three = try Self.state(paneCount: 3)
    #expect(!two.items.contains { $0.key == "D" || $0.key == "E" })
    #expect(!two.items.contains { $0.region == .centerThird || $0.region == .middleThird })
    #expect(three.items.contains { $0.key == "D" && $0.region == .centerThird })
    #expect(three.items.contains { $0.key == "E" && $0.region == .middleThird })
    #expect(Array(three.items.prefix(two.items.count)) == two.items)
  }

  @Test
  func onePaneTabHasNoPicker() {
    let a = PaneID()
    #expect(PlacePickerFeature.State(tabID: TabID(), splitTree: SplitTree(leaf: a), focusedPaneID: a) == nil)
  }

  @Test
  func paneOutsideTheTabHasNoPicker() throws {
    let (tree, _) = try Self.panes(2)
    #expect(PlacePickerFeature.State(tabID: TabID(), splitTree: tree, focusedPaneID: PaneID()) == nil)
  }

  @Test
  func digitAppliesItsRegion() async throws {
    let state = try Self.state(paneCount: 2)
    let store = TestStore(initialState: state) { PlacePickerFeature() }
    await store.send(.keyPressed("6")) { $0.selectedIndex = 5 }
    await store.receive(\.delegate.apply, .rightTwoThirds)
  }

  @Test
  func letterAppliesItsRegionInEitherCase() async throws {
    let state = try Self.state(paneCount: 3)
    let store = TestStore(initialState: state) { PlacePickerFeature() }
    await store.send(.keyPressed("a")) { $0.selectedIndex = 9 }
    await store.receive(\.delegate.apply, .rightThird)
    await store.send(.keyPressed("E")) { $0.selectedIndex = 13 }
    await store.receive(\.delegate.apply, .middleThird)
  }

  @Test
  func hiddenOrUnknownKeyDoesNothing() async throws {
    let state = try Self.state(paneCount: 2)
    let store = TestStore(initialState: state) { PlacePickerFeature() }
    await store.send(.keyPressed("D"))
    await store.send(.keyPressed("e"))
    await store.send(.keyPressed("0"))
    await store.send(.keyPressed("Z"))
  }

  @Test
  func arrowsMoveSelectionInTheGridAndReturnApplies() async throws {
    // Three Panes: 14 regions in rows of four.
    let state = try Self.state(paneCount: 3)
    let store = TestStore(initialState: state) { PlacePickerFeature() }
    await store.send(.selectionMoved(.left))  // edge: stays
    await store.send(.selectionMoved(.up))  // edge: stays
    await store.send(.selectionMoved(.right)) { $0.selectedIndex = 1 }
    await store.send(.selectionMoved(.down)) { $0.selectedIndex = 5 }
    await store.send(.selectionMoved(.down)) { $0.selectedIndex = 9 }
    await store.send(.selectionMoved(.down)) { $0.selectedIndex = 13 }
    await store.send(.selectionMoved(.down))  // edge: stays
    await store.send(.selectionMoved(.right))  // short last row: stays
    await store.send(.selectionCommitted)
    await store.receive(\.delegate.apply, .middleThird)
  }

  @Test
  func tapAppliesTheRegion() async throws {
    let state = try Self.state(paneCount: 2)
    let store = TestStore(initialState: state) { PlacePickerFeature() }
    await store.send(.regionTapped(.topThird)) { $0.selectedIndex = 10 }
    await store.receive(\.delegate.apply, .topThird)
  }

  @Test
  func escapeCancels() async throws {
    let state = try Self.state(paneCount: 2)
    let store = TestStore(initialState: state) { PlacePickerFeature() }
    await store.send(.cancelled)
    await store.receive(\.delegate.cancel)
  }

  /// The thumbnail is the Tab after Place: the focused Pane fills the region
  /// and the other Panes keep their Pane numbers in the rest.
  @Test
  func thumbnailShowsTheTabAfterPlace() throws {
    let state = try Self.state(paneCount: 3, focus: 2)
    let slots = state.thumbnail(.leftTwoThirds)
    #expect(slots.count == 3)
    let focused = try #require(slots.first { $0.isFocused })
    #expect(focused.paneNumber == 3)
    #expect(abs(focused.bounds.width - 2.0 / 3) < 1e-9)
    #expect(focused.bounds.minX == 0)
    #expect(Set(slots.filter { !$0.isFocused }.map(\.paneNumber)) == [1, 2])
  }
}
