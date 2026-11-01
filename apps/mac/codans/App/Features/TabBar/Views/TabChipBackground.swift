import SwiftUI

/// Background capsule for one tab chip. State-aware so chips share a single
/// background type — future state expansion (e.g. dirty styling) lives here
/// rather than being scattered across the chip view.
///
/// Mirrors the macOS system tab bar: the selected chip is a raised capsule
/// (fill + two 0.5-pt glass rims + a light-mode drop shadow); an idle chip
/// is transparent and picks up a flat capsule only while hovered. Unlike the
/// system bar, the selected capsule also darkens slightly under the pointer,
/// so every chip acknowledges hover. There is
/// no separate pressed look — like the system bar, a chip is selected on
/// mouse-down, so a press renders as the selected capsule immediately.
/// All tokens come from `TabBarMetrics` / `TabBarColors`.
struct TabChipBackground: View {
  let isActive: Bool
  let isHovering: Bool
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    // Both capsules stay in the tree so their geometry animates with the
    // chip during an add / close reflow; only their visibility switches.
    ZStack {
      Capsule().fill(isHovering && !isActive ? TabBarColors.chipHoverBackground : .clear)
      selectedCapsule
        // Selection moves at once, as in the system bar, even inside an
        // animated add / close — no cross-fade between the two capsules.
        .animation(nil) { $0.opacity(isActive ? 1 : 0) }
    }
  }

  private var selectedCapsule: some View {
    ZStack {
      // The dark-mode system bar shows no shadow.
      if colorScheme == .light {
        outerShadow
      }
      Capsule()
        .fill(isHovering ? TabBarColors.activeHoverBackground : TabBarColors.activeBackground)
        .overlay(Capsule().strokeBorder(TabBarColors.activeRimOuter, lineWidth: 0.5))
        .overlay(
          Capsule().strokeBorder(TabBarColors.activeRimInner, lineWidth: 0.5).padding(0.5)
        )
    }
  }

  /// Drop shadow of the selected capsule, cut away under the capsule. The
  /// fill is translucent, so a plain `.shadow` would darken it from below.
  private var outerShadow: some View {
    Capsule()
      .fill(.black)
      .shadow(color: TabBarColors.activeShadow, radius: 1.5, y: 0.5)
      .mask {
        Rectangle()
          .padding(-4)
          .overlay(Capsule().blendMode(.destinationOut))
          .compositingGroup()
      }
  }
}
