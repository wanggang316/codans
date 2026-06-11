import SwiftUI

/// The `xmark` button on the trailing edge of a tab chip. A dedicated view
/// so later milestones can add keyboard-shortcut hints and focus styling
/// without widening `TabChipView`.
///
/// Visible only while the chip is hovered or active; opacity transition is
/// short (100 ms) so the button does not linger after the pointer leaves.
/// Hit testing stays on so space kept for the glyph is never dead.
struct TabChipCloseButton: View {
  let isVisible: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.caption2)
        .foregroundStyle(TabBarColors.closeButtonForeground)
        .frame(
          width: TabBarMetrics.closeButtonSize,
          height: TabBarMetrics.closeButtonSize
        )
        .accessibilityLabel("Close Tab")
    }
    .buttonStyle(.borderless)
    .opacity(isVisible ? 1 : 0)
    .animation(.easeInOut(duration: 0.10), value: isVisible)
  }
}
