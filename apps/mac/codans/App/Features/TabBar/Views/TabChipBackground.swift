import SwiftUI

/// Rounded-rectangle background for one tab chip. State-aware so chips
/// share a single background type — future state expansion (e.g. dirty
/// styling, selection outline) lives here rather than being scattered
/// across the chip view.
///
/// Renders top-only corners so the chip reads as a folder tab rather than
/// a floating card, and stamps a 2-pt accent-tinted underline on the top
/// edge when the tab is selected. All tokens come from `TabBarMetrics` /
/// `TabBarColors` so visual-system shifts are a one-file diff.
struct TabChipBackground: View {
  let isActive: Bool
  let isHovering: Bool
  let isPressing: Bool

  var body: some View {
    ZStack(alignment: .top) {
      UnevenRoundedRectangle(
        topLeadingRadius: TabBarMetrics.chipCornerRadius,
        bottomLeadingRadius: 0,
        bottomTrailingRadius: 0,
        topTrailingRadius: TabBarMetrics.chipCornerRadius
      )
      .fill(backgroundFill)

      if isActive {
        Rectangle()
          .fill(TabBarColors.activeUnderline)
          .frame(height: TabBarMetrics.activeUnderlineHeight)
      } else {
        // Idle / hover chips ride along a 1-pt baseline that doubles as
        // the row's bottom border. The active chip omits this so the
        // top accent + filled background read as the selection, not as
        // "still part of the row".
        VStack(spacing: 0) {
          Spacer(minLength: 0)
          Rectangle()
            .fill(TabBarColors.divider)
            .frame(height: 1)
        }
      }
    }
  }

  /// Active chips show no fill — selection is communicated by the top
  /// accent stripe plus the missing baseline (see `body`). Pressing on
  /// an idle chip borrows the hover fill so the click still has visual
  /// feedback before selection commits.
  private var backgroundFill: Color {
    if isActive { return TabBarColors.idleBackground }
    if isHovering || isPressing { return TabBarColors.hoverBackground }
    return TabBarColors.idleBackground
  }
}
