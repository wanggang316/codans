import SwiftUI

/// The `xmark` button on the leading edge of a tab chip. A dedicated view
/// so later milestones can add keyboard-shortcut hints and focus styling
/// without widening `TabChipView`.
///
/// Visible only while the chip is hovered (selected or not); opacity
/// transition is short (100 ms) so the button does not linger after the
/// pointer leaves. Hit testing stays on so space kept for the glyph is
/// never dead. With the pointer on the button itself the glyph strengthens
/// and a circle fills in behind it, as in the system tab bar.
struct TabChipCloseButton: View {
  let isVisible: Bool
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.system(size: TabBarMetrics.closeGlyphSize, weight: .medium))
        .foregroundStyle(
          isHovering ? TabBarColors.closeButtonHoverForeground : TabBarColors.closeButtonForeground
        )
        .frame(
          width: TabBarMetrics.closeButtonSize,
          height: TabBarMetrics.closeButtonSize
        )
        .background(Circle().fill(isHovering ? TabBarColors.closeButtonHoverBackground : .clear))
        .contentShape(Circle())
        .accessibilityLabel("Close Tab")
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .opacity(isVisible ? 1 : 0)
    .animation(.easeInOut(duration: 0.10), value: isVisible)
  }
}
