import CodansCore
import ComposableArchitecture
import Foundation

/// Reducer for the Place picker (GLOSSARY: Place, ADR 0013). Shows each Place
/// region the Tab can fill as a thumbnail with a fixed key and lifts the
/// user's choice to the parent. It changes nothing itself: the parent places
/// the Pane through the Pane action router, so the picker, the Command
/// Palette, and the menus share one Place path.
@Reducer
struct PlacePickerFeature {
  /// One thumbnail: a region and the key that applies it.
  struct Item: Equatable {
    let key: Character
    let region: PlaceRegion
  }

  @ObservableState
  struct State: Equatable {
    /// The Tab the picker places in. Once another Tab is shown, the picker
    /// closes with no change.
    let tabID: TabID
    /// The Pane that Place moves. Key focus goes back to it when the picker
    /// closes.
    let paneID: PaneID
    /// The Tab's split tree when the picker opened; the thumbnails show
    /// the result of Place on it.
    let splitTree: SplitTree<PaneID>
    /// In display order. Each key is fixed: a hidden region leaves its key
    /// unused, and the other regions keep theirs.
    let items: [Item]
    /// Index into `items` of the thumbnail that Return applies.
    var selectedIndex = 0

    /// `nil` when the Tab has fewer than two Panes or does not hold
    /// `focusedPaneID`: a one-Pane Tab ignores Place.
    init?(tabID: TabID, splitTree: SplitTree<PaneID>, focusedPaneID: PaneID) {
      let paneCount = splitTree.leaves().count
      guard paneCount >= 2, splitTree.contains(focusedPaneID) else { return nil }
      self.tabID = tabID
      self.paneID = focusedPaneID
      self.splitTree = splitTree
      self.items = PlacePickerFeature.allItems.filter { PlacePickerFeature.canFill($0.region, paneCount: paneCount) }
    }

    var selectedRegion: PlaceRegion { items[selectedIndex].region }

    /// The Tab after placing the Pane in `region`, one slot per Pane in the
    /// unit square, labelled with the Pane number it has now. Uses the same
    /// Place code as the Tab.
    func thumbnail(_ region: PlaceRegion) -> [PickerSlot] {
      guard let placed = try? splitTree.placing(paneID, in: region) else { return [] }
      return placed.spatialSlots().compactMap { slot in
        guard let number = splitTree.paneNumber(of: slot.leaf) else { return nil }
        return PickerSlot(paneNumber: number, bounds: slot.bounds, isFocused: slot.leaf == paneID)
      }
    }
  }

  /// Thumbnails per row; the arrow keys move in this grid. Four puts the
  /// halves, the two-thirds regions, and the side thirds on rows of their own.
  static let columnCount = 4

  /// Every region with its fixed key, in display order (ADR 0013).
  static let allItems: [Item] = [
    Item(key: "1", region: .leftHalf),
    Item(key: "2", region: .rightHalf),
    Item(key: "3", region: .topHalf),
    Item(key: "4", region: .bottomHalf),
    Item(key: "5", region: .leftTwoThirds),
    Item(key: "6", region: .rightTwoThirds),
    Item(key: "7", region: .topTwoThirds),
    Item(key: "8", region: .bottomTwoThirds),
    Item(key: "9", region: .leftThird),
    Item(key: "A", region: .rightThird),
    Item(key: "B", region: .topThird),
    Item(key: "C", region: .bottomThird),
    Item(key: "D", region: .centerThird),
    Item(key: "E", region: .middleThird),
  ]

  /// A center third needs a Pane on each side of it, so three or more Panes.
  static func canFill(_ region: PlaceRegion, paneCount: Int) -> Bool {
    region.position == .center ? paneCount >= 3 : paneCount >= 2
  }

  enum Action: Equatable {
    /// A key typed while the picker is open. Letters match in either case;
    /// a key with no shown region does nothing.
    case keyPressed(Character)
    case selectionMoved(PickerGrid.Direction)
    /// Return: applies the selected region.
    case selectionCommitted
    case regionTapped(PlaceRegion)
    /// Esc or a click outside: closes with no change.
    case cancelled
    case delegate(Delegate)

    @CasePathable
    enum Delegate: Equatable {
      case apply(PlaceRegion)
      case cancel
    }
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .keyPressed(let key):
        let key = Character(key.uppercased())
        guard let index = state.items.firstIndex(where: { $0.key == key }) else { return .none }
        state.selectedIndex = index
        return .send(.delegate(.apply(state.selectedRegion)))

      case .selectionMoved(let direction):
        if let target = PickerGrid.index(
          moving: direction, from: state.selectedIndex, count: state.items.count, columns: Self.columnCount)
        {
          state.selectedIndex = target
        }
        return .none

      case .selectionCommitted:
        return .send(.delegate(.apply(state.selectedRegion)))

      case .regionTapped(let region):
        guard let index = state.items.firstIndex(where: { $0.region == region }) else { return .none }
        state.selectedIndex = index
        return .send(.delegate(.apply(region)))

      case .cancelled:
        return .send(.delegate(.cancel))

      case .delegate:
        return .none
      }
    }
  }
}
