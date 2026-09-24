import SwiftUI

/// The `xmark` button on the leading edge of a tab chip. A dedicated view
/// so later milestones can add keyboard-shortcut hints and focus styling
/// without widening `TabChipView`.
///
/// Visible only while the chip is hovered; opacity transition is short
/// (100 ms) so the button does not linger after the pointer leaves. Hit
/// testing stays on so space kept for the glyph is never dead. Hovering the
/// glyph itself adds a small rounded plate, as the system tab bar does.
struct TabChipCloseButton: View {
  let isVisible: Bool
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(TabBarColors.closeButtonForeground)
        .frame(
          width: TabBarMetrics.closeButtonSize,
          height: TabBarMetrics.closeButtonSize
        )
        .background(
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(isHovering ? TabBarColors.pressedBackground : .clear)
        )
        .contentShape(Rectangle())
        .accessibilityLabel("Close Tab")
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .opacity(isVisible ? 1 : 0)
    .animation(.easeInOut(duration: 0.10), value: isVisible)
  }
}
