import CodansCore
import ComposableArchitecture
import SwiftUI

/// The Layout picker: a floating card (`PickerOverlay`) over the split
/// viewport of the current Tab with one numbered thumbnail per Layout
/// preset. Each thumbnail draws the preset's regions, labelled with the Pane
/// number that lands in each.
struct LayoutPickerView: View {
  let store: StoreOf<LayoutPickerFeature>

  var body: some View {
    PickerOverlay(
      title: "Arrange Panes",
      hint: "1–\(store.presets.count) to apply · Esc to cancel",
      accessibilityLabel: "Layout Picker",
      keys: .decimalDigits,
      onKey: { key in
        guard let digit = key.wholeNumberValue else { return }
        store.send(.digitPressed(digit))
      },
      onMove: { store.send(.selectionMoved($0)) },
      onCommit: { store.send(.selectionCommitted) },
      onCancel: { store.send(.cancelled) },
      content: { grid }
    )
  }

  private var grid: some View {
    let columns = Array(
      repeating: GridItem(.fixed(PickerCell<EmptyView>.thumbnailSize.width), spacing: 12),
      count: min(LayoutPickerFeature.columnCount, store.presets.count))
    return LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
      ForEach(Array(store.presets.enumerated()), id: \.element) { index, preset in
        presetCell(preset, number: index + 1, isSelected: index == store.selectedIndex)
      }
    }
  }

  private func presetCell(_ preset: LayoutPreset, number: Int, isSelected: Bool) -> some View {
    let title = preset.title(forPaneCount: store.paneCount)
    let isCurrent = preset == store.currentPreset
    return PickerCell(
      key: "\(number)",
      title: title,
      isSelected: isSelected,
      isCurrent: isCurrent,
      accessibilityLabel: isCurrent ? "\(number), \(title), current layout" : "\(number), \(title)",
      action: { store.send(.presetTapped(preset)) },
      thumbnail: { PickerThumbnail(slots: slots(preset)) }
    )
  }

  /// The preset's regions; the focused Pane's region is tinted so main
  /// presets show where that Pane goes.
  private func slots(_ preset: LayoutPreset) -> [PickerSlot] {
    let focused = store.focusedPaneNumber
    return LayoutPickerFeature.thumbnail(preset, paneCount: store.paneCount, focusedPaneNumber: focused)
      .map { PickerSlot(paneNumber: $0.leaf, bounds: $0.bounds, isFocused: $0.leaf == focused) }
  }
}

/// Opens the Layout picker for the Tab of a Pane. `ContentView` routes it to
/// `RootFeature.layoutPickerToggle`; the Pane context menu calls it from
/// Layout ▸ Arrange…. Defaults to a no-op so previews and tests need no store.
struct OpenLayoutPickerAction {
  var open: (PaneID) -> Void = { _ in }

  func callAsFunction(_ paneID: PaneID) {
    open(paneID)
  }
}

private struct OpenLayoutPickerKey: EnvironmentKey {
  static let defaultValue = OpenLayoutPickerAction()
}

extension EnvironmentValues {
  var openLayoutPicker: OpenLayoutPickerAction {
    get { self[OpenLayoutPickerKey.self] }
    set { self[OpenLayoutPickerKey.self] = newValue }
  }
}
