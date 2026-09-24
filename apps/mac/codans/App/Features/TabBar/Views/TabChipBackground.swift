import SwiftUI

/// Background plate for one tab chip. State-aware so chips share a single
/// background type — future state expansion (e.g. dirty styling) lives here
/// rather than being scattered across the chip view.
///
/// Mirrors the macOS system tab bar: the selected chip is a raised rounded
/// plate (fill + hairline border + soft shadow) inset inside the track;
/// idle chips are transparent and only pick up a flat fill on hover / press.
/// All tokens come from `TabBarMetrics` / `TabBarColors` so visual-system
/// shifts are a one-file diff.
struct TabChipBackground: View {
  let isActive: Bool
  let isHovering: Bool
  let isPressing: Bool

  var body: some View {
    let plate = RoundedRectangle(
      cornerRadius: TabBarMetrics.chipCornerRadius, style: .continuous)
    Group {
      if isActive {
        plate
          .fill(TabBarColors.activeBackground)
          .overlay(plate.strokeBorder(TabBarColors.activeBorder, lineWidth: 0.5))
          .shadow(color: TabBarColors.activeShadow, radius: 1, y: 0.5)
      } else {
        plate.fill(idleFill)
      }
    }
    .padding(TabBarMetrics.chipPlateInset)
  }

  private var idleFill: Color {
    if isPressing { return TabBarColors.pressedBackground }
    if isHovering { return TabBarColors.hoverBackground }
    return TabBarColors.idleBackground
  }
}
