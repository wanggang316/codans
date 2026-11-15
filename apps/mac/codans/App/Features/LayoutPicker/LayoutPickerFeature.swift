import ComposableArchitecture
import CodansCore
import Foundation

/// Reducer for the Layout picker (GLOSSARY: Arrange). Shows the Layout
/// presets for the Pane count of one Tab as numbered thumbnails and lifts
/// the user's choice to the parent. It changes nothing itself: the parent
/// applies the preset through the Pane action router, so the picker, the
/// Command Palette, and the menu share one Arrange path.
@Reducer
struct LayoutPickerFeature {
  @ObservableState
  struct State: Equatable {
    /// The focused Pane. Main presets put it in the main area, and key
    /// focus goes back to it when the picker closes.
    let paneID: PaneID
    let paneCount: Int
    /// Position of `paneID` in the Pane order (1-based). The thumbnails
    /// label each region with the Pane number that lands there.
    let focusedPaneNumber: Int
    /// In display order; digit N applies `presets[N - 1]`.
    let presets: [LayoutPreset]
    /// The preset that equals the current layout, marked in the picker.
    let currentPreset: LayoutPreset?
    /// Index into `presets` of the thumbnail that Return applies.
    var selectedIndex: Int

    /// `nil` when the Tab has fewer than two Panes or does not hold
    /// `focusedPaneID`: a one-Pane Tab has nothing to arrange.
    init?(splitTree: SplitTree<PaneID>, focusedPaneID: PaneID) {
      let leaves = splitTree.leaves()
      let presets = LayoutPreset.presets(forPaneCount: leaves.count)
      guard !presets.isEmpty, let focusIndex = leaves.firstIndex(of: focusedPaneID) else {
        return nil
      }
      self.paneID = focusedPaneID
      self.paneCount = leaves.count
      self.focusedPaneNumber = focusIndex + 1
      self.presets = presets
      self.currentPreset = splitTree.matchingPreset()
      self.selectedIndex = currentPreset.flatMap { presets.firstIndex(of: $0) } ?? 0
    }

    var selectedPreset: LayoutPreset { presets[selectedIndex] }
  }

  /// Thumbnails per row; the arrow keys move in this grid.
  static let columnCount = 3

  enum Action: Equatable {
    /// A digit key 1–9. A digit with no preset does nothing.
    case digitPressed(Int)
    case selectionMoved(Direction)
    /// Return: applies the selected preset.
    case selectionCommitted
    case presetTapped(LayoutPreset)
    /// Esc or a click outside: closes with no change.
    case cancelled
    case delegate(Delegate)

    enum Direction: Equatable { case left, right, up, down }

    @CasePathable
    enum Delegate: Equatable {
      case apply(LayoutPreset)
      case cancel
    }
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .digitPressed(let digit):
        guard state.presets.indices.contains(digit - 1) else { return .none }
        state.selectedIndex = digit - 1
        return .send(.delegate(.apply(state.selectedPreset)))

      case .selectionMoved(let direction):
        let step =
          switch direction {
          case .left: -1
          case .right: 1
          case .up: -Self.columnCount
          case .down: Self.columnCount
          }
        let target = state.selectedIndex + step
        // Stop at the edges: no wrap, so a held arrow key settles on a corner.
        if state.presets.indices.contains(target) {
          state.selectedIndex = target
        }
        return .none

      case .selectionCommitted:
        return .send(.delegate(.apply(state.selectedPreset)))

      case .presetTapped(let preset):
        guard let index = state.presets.firstIndex(of: preset) else { return .none }
        state.selectedIndex = index
        return .send(.delegate(.apply(preset)))

      case .cancelled:
        return .send(.delegate(.cancel))

      case .delegate:
        return .none
      }
    }
  }

  /// The regions of `preset` in the unit square, each labelled with the
  /// Pane number that the preset puts there. Built from a stand-in tree of
  /// Pane numbers, so the thumbnail uses the same arrange code as the Tab.
  static func thumbnail(
    _ preset: LayoutPreset, paneCount: Int, focusedPaneNumber: Int
  ) -> [SplitTree<Int>.SpatialSlot] {
    guard paneCount >= 2 else { return [] }
    var tree = SplitTree(leaf: 1)
    for number in 2...paneCount {
      tree = (try? tree.inserting(number, at: number - 1, direction: .right)) ?? tree
    }
    let arranged = try? tree.arranged(preset, focus: focusedPaneNumber)
    return arranged?.spatialSlots() ?? []
  }
}
