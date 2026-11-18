import CodansCore
import ComposableArchitecture
import SwiftUI

/// The Place picker: the Layout picker's floating card (`PickerOverlay`)
/// with one thumbnail per Place region the Tab can fill, each with its fixed
/// key. A thumbnail shows the Tab after Place: the focused Pane, tinted, in
/// the region, and the other Panes in the rest.
struct PlacePickerView: View {
  let store: StoreOf<PlacePickerFeature>

  var body: some View {
    PickerOverlay(
      title: "Place Pane",
      hint: "\(keyRange) to place · Esc to cancel",
      accessibilityLabel: "Place Picker",
      keys: .alphanumerics,
      onKey: { store.send(.keyPressed($0)) },
      onMove: { store.send(.selectionMoved($0)) },
      onCommit: { store.send(.selectionCommitted) },
      onCancel: { store.send(.cancelled) }
    ) {
      grid
    }
  }

  private var keyRange: String {
    guard let first = store.items.first?.key, let last = store.items.last?.key else { return "" }
    return "\(first)–\(last)"
  }

  private var grid: some View {
    let columns = Array(
      repeating: GridItem(.fixed(PickerCell<EmptyView>.thumbnailSize.width), spacing: 12),
      count: PlacePickerFeature.columnCount)
    return LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
      ForEach(Array(store.items.enumerated()), id: \.element.region) { index, item in
        PickerCell(
          key: String(item.key),
          title: item.region.title,
          isSelected: index == store.selectedIndex,
          accessibilityLabel: "\(item.key), \(item.region.title)",
          action: { store.send(.regionTapped(item.region)) }
        ) {
          PickerThumbnail(slots: store.state.thumbnail(item.region))
        }
      }
    }
  }
}

/// Opens the Place picker for the Tab of a Pane. `ContentView` routes it to
/// `RootFeature.placePickerToggle`; the Pane context menu calls it from
/// Layout ▸ Place…. Defaults to a no-op so previews and tests need no store.
struct OpenPlacePickerAction {
  var open: (PaneID) -> Void = { _ in }

  func callAsFunction(_ paneID: PaneID) {
    open(paneID)
  }
}

private struct OpenPlacePickerKey: EnvironmentKey {
  static let defaultValue = OpenPlacePickerAction()
}

extension EnvironmentValues {
  var openPlacePicker: OpenPlacePickerAction {
    get { self[OpenPlacePickerKey.self] }
    set { self[OpenPlacePickerKey.self] = newValue }
  }
}
