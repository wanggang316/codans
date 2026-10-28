import SwiftUI

/// The `ellipsis` button on the trailing edge of a tab chip, the mirror of
/// `TabChipCloseButton` on the leading edge: same size, same hover rule,
/// same chrome. A press drops the Tab's actions menu below it.
struct TabChipActionsButton: View {
  let isVisible: Bool
  let menuItems: () -> [PullDownMenuItem]

  @State private var isHovering = false

  var body: some View {
    Image(systemName: "ellipsis")
      .font(.system(size: TabBarMetrics.closeGlyphSize, weight: .medium))
      .foregroundStyle(
        isHovering ? TabBarColors.closeButtonHoverForeground : TabBarColors.closeButtonForeground
      )
      .frame(width: TabBarMetrics.closeButtonSize, height: TabBarMetrics.closeButtonSize)
      .background(Circle().fill(isHovering ? TabBarColors.closeButtonHoverBackground : .clear))
      .contentShape(Circle())
      // The press opens an AppKit menu at the button; SwiftUI cannot.
      .overlay(PullDownMenuOverlay(menuItems: menuItems))
      .onHover { isHovering = $0 }
      .accessibilityElement()
      .accessibilityLabel("Tab Actions")
      .accessibilityAddTraits(.isButton)
      .accessibilityIdentifier("tab_chip.actions")
      .opacity(isVisible ? 1 : 0)
      .animation(.easeInOut(duration: 0.10), value: isVisible)
  }
}
