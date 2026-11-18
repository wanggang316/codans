import SwiftUI

/// The overlay that the Layout picker and the Place picker share: a floating
/// card over the split viewport with a header and a grid of thumbnails. The
/// card owns the keyboard while it is open (item keys, arrows, Return, Esc);
/// a click outside the card cancels. `RootFeature` gives key focus back to
/// the focused Pane when the picker closes.
struct PickerOverlay<Content: View>: View {
  let title: String
  let hint: String
  let accessibilityLabel: String
  /// The keys that `onKey` receives.
  let keys: CharacterSet
  let onKey: (Character) -> Void
  let onMove: (PickerGrid.Direction) -> Void
  let onCommit: () -> Void
  let onCancel: () -> Void
  @ViewBuilder let content: Content

  @FocusState private var cardFocused: Bool

  var body: some View {
    ZStack {
      Color.clear
        .contentShape(.rect)
        .onTapGesture(perform: onCancel)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Dismiss \(accessibilityLabel)")

      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline) {
          Text(title)
            .font(.headline)
          Spacer(minLength: 16)
          Text(hint)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        content
      }
      .padding(16)
      .fixedSize()
      .floatingCard(cornerRadius: 12)
      .focusable()
      .focusEffectDisabled()
      .focused($cardFocused)
      .onKeyPress(.leftArrow) { move(.left) }
      .onKeyPress(.rightArrow) { move(.right) }
      .onKeyPress(.upArrow) { move(.up) }
      .onKeyPress(.downArrow) { move(.down) }
      .onKeyPress(.return) {
        onCommit()
        return .handled
      }
      .onKeyPress(.escape) {
        onCancel()
        return .handled
      }
      .onKeyPress(characters: keys, phases: .down) { press in
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]),
          let key = press.characters.first, press.characters.count == 1
        else { return .ignored }
        onKey(key)
        return .handled
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(accessibilityLabel)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear { cardFocused = true }
    // The picker owns the keyboard while it is open. A terminal surface can
    // still claim first responder behind the overlay (focus restore after a
    // layout rebuild); take the focus back so keys do not go to the Pane.
    .onChange(of: cardFocused) { _, focused in
      guard !focused else { return }
      cardFocused = true
    }
  }

  private func move(_ direction: PickerGrid.Direction) -> KeyPress.Result {
    onMove(direction)
    return .handled
  }
}

/// One thumbnail of a picker grid: the drawing, a key badge, and a title.
/// The selected cell has an accent border; the current cell has a check.
struct PickerCell<Thumbnail: View>: View {
  static var thumbnailSize: CGSize { CGSize(width: 104, height: 66) }

  let key: String
  let title: String
  let isSelected: Bool
  var isCurrent = false
  let accessibilityLabel: String
  let action: () -> Void
  @ViewBuilder let thumbnail: Thumbnail

  var body: some View {
    Button(action: action) {
      VStack(spacing: 6) {
        thumbnail
          .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
          .padding(4)
          .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
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
          Text(verbatim: key)
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
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

/// Draws the Pane regions of a thumbnail (`PickerSlot`).
struct PickerThumbnail: View {
  let slots: [PickerSlot]

  var body: some View {
    GeometryReader { geo in
      ForEach(slots, id: \.paneNumber) { slot in
        let rect = CGRect(
          x: slot.bounds.minX * geo.size.width, y: slot.bounds.minY * geo.size.height,
          width: slot.bounds.width * geo.size.width, height: slot.bounds.height * geo.size.height
        ).insetBy(dx: 1.5, dy: 1.5)
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(slot.isFocused ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.1))
          .overlay {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
              .strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
          }
          .overlay {
            if rect.width >= 12, rect.height >= 12 {
              Text(verbatim: "\(slot.paneNumber)")
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
}
