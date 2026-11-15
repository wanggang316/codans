import CodansCore
import ComposableArchitecture
import SwiftUI

/// The Layout picker: a floating card over the split viewport of the current
/// Tab with one numbered thumbnail per Layout preset. Each thumbnail draws
/// the preset's regions, labelled with the Pane number that lands in each.
/// The card owns the keyboard while it is open (digits, arrows, Return,
/// Esc); a click outside the card closes it with no change. `RootFeature`
/// gives key focus back to the focused Pane when it closes.
struct LayoutPickerView: View {
  let store: StoreOf<LayoutPickerFeature>

  private let cardCornerRadius: CGFloat = 12
  private let thumbnailSize = CGSize(width: 104, height: 66)
  @FocusState private var cardFocused: Bool

  var body: some View {
    ZStack {
      Color.clear
        .contentShape(.rect)
        .onTapGesture { store.send(.cancelled) }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Dismiss Layout Picker")

      VStack(alignment: .leading, spacing: 12) {
        header
        grid
      }
      .padding(16)
      .fixedSize()
      .floatingCard(cornerRadius: cardCornerRadius)
      .focusable()
      .focusEffectDisabled()
      .focused($cardFocused)
      .onKeyPress(.leftArrow) { move(.left) }
      .onKeyPress(.rightArrow) { move(.right) }
      .onKeyPress(.upArrow) { move(.up) }
      .onKeyPress(.downArrow) { move(.down) }
      .onKeyPress(.return) {
        store.send(.selectionCommitted)
        return .handled
      }
      .onKeyPress(.escape) {
        store.send(.cancelled)
        return .handled
      }
      .onKeyPress(characters: .decimalDigits, phases: .down) { press in
        guard let digit = Int(press.characters) else { return .ignored }
        store.send(.digitPressed(digit))
        return .handled
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Layout Picker")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear { cardFocused = true }
    // The picker owns the keyboard while it is open. A terminal surface can
    // still claim first responder behind the overlay (focus restore after a
    // layout rebuild); take the focus back so digits do not go to the Pane.
    .onChange(of: cardFocused) { _, focused in
      guard !focused else { return }
      cardFocused = true
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      Text("Arrange Panes")
        .font(.headline)
      Spacer(minLength: 16)
      Text("1–\(store.presets.count) to apply · Esc to cancel")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var grid: some View {
    let columns = Array(
      repeating: GridItem(.fixed(thumbnailSize.width), spacing: 12),
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
    return Button {
      store.send(.presetTapped(preset))
    } label: {
      VStack(spacing: 6) {
        thumbnail(preset)
          .frame(width: thumbnailSize.width, height: thumbnailSize.height)
          .padding(4)
          .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .strokeBorder(
                isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
          }
          .overlay(alignment: .topTrailing) {
            if isCurrent {
              Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.accentColor)
                .font(.system(size: 14))
                .offset(x: 4, y: -4)
                .accessibilityHidden(true)
            }
          }
        HStack(spacing: 4) {
          Text(verbatim: "\(number)")
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 16, minHeight: 16)
            .background(
              RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(0.08)))
          Text(title)
            .font(.caption)
            .foregroundStyle(isCurrent ? .primary : .secondary)
            .lineLimit(1)
        }
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(isCurrent ? "\(number), \(title), current layout" : "\(number), \(title)")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  /// The preset's regions; the focused Pane's region is tinted so main
  /// presets show where that Pane goes.
  private func thumbnail(_ preset: LayoutPreset) -> some View {
    let slots = LayoutPickerFeature.thumbnail(
      preset, paneCount: store.paneCount, focusedPaneNumber: store.focusedPaneNumber)
    let focused = store.focusedPaneNumber
    return GeometryReader { geo in
      ForEach(slots, id: \.leaf) { slot in
        let rect = CGRect(
          x: slot.bounds.minX * geo.size.width, y: slot.bounds.minY * geo.size.height,
          width: slot.bounds.width * geo.size.width, height: slot.bounds.height * geo.size.height
        ).insetBy(dx: 1.5, dy: 1.5)
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(slot.leaf == focused ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.1))
          .overlay {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
              .strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
          }
          .overlay {
            if rect.width >= 12, rect.height >= 12 {
              Text(verbatim: "\(slot.leaf)")
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            }
          }
          .frame(width: rect.width, height: rect.height)
          .position(x: rect.midX, y: rect.midY)
      }
    }
    .accessibilityHidden(true)
  }

  private func move(_ direction: LayoutPickerFeature.Action.Direction) -> KeyPress.Result {
    store.send(.selectionMoved(direction))
    return .handled
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
