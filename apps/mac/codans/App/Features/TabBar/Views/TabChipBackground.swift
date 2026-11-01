import AppKit
import SwiftUI

/// Background capsule for one tab chip. State-aware so chips share a single
/// background type — future state expansion (e.g. dirty styling) lives here
/// rather than being scattered across the chip view.
///
/// Mirrors the macOS system tab bar: the selected chip is a raised glass
/// capsule; an idle chip is transparent and picks up a flat capsule only
/// while hovered. Unlike the system bar, the selected capsule also brightens
/// slightly under the pointer, so every chip acknowledges hover. There is
/// no separate pressed look — like the system bar, a chip is selected on
/// mouse-down, so a press renders as the selected capsule immediately.
/// All tokens come from `TabBarMetrics` / `TabBarColors`.
struct TabChipBackground: View {
  let isActive: Bool
  let isHovering: Bool

  var body: some View {
    ZStack {
      // Stays in the tree so its geometry animates with the chip during an
      // add / close reflow.
      Capsule().fill(isHovering && !isActive ? TabBarColors.chipHoverBackground : .clear)
      // Selection moves at once, as in the system bar, even inside an
      // animated add / close — no cross-fade between the two capsules.
      if isActive {
        if #available(macOS 26.0, *) {
          TabGlassCapsule()
            .overlay {
              Capsule()
                .fill(isHovering ? TabBarColors.activeHoverSheen : .clear)
                .allowsHitTesting(false)
            }
        } else {
          legacySelectedCapsule
        }
      }
    }
  }

  /// Selected capsule before macOS 26: fill + two 0.5-pt rims + a
  /// light-mode drop shadow.
  private var legacySelectedCapsule: some View {
    Capsule()
      .fill(isHovering ? TabBarColors.activeHoverBackground : TabBarColors.activeBackground)
      .overlay(Capsule().strokeBorder(TabBarColors.activeRimOuter, lineWidth: 0.5))
      .overlay(
        Capsule().strokeBorder(TabBarColors.activeRimInner, lineWidth: 0.5).padding(0.5)
      )
      // Flatten first: without it SwiftUI shadows each layer separately
      // and the rims cast a grey band onto the inside of the capsule.
      .compositingGroup()
      .shadow(color: TabBarColors.activeShadow, radius: 1.5, y: 0.5)
  }
}

/// The glass of the system tab bar's selected tab: `NSGlassEffectView` in
/// the variant and subvariant `NSTabButton` uses (read from a live window tab
/// bar: `_variant` 1, `_subvariant` "tab"). It lenses the backdrop, so the
/// chip takes on the window tone and carries the system's glass rim and
/// shadow. Public API cannot select this look. The keys are guarded, so a
/// system that drops them falls back to the public glass.
@available(macOS 26.0, *)
private struct TabGlassCapsule: NSViewRepresentable {
  private static let variant = 1
  private static let subvariant = "tab"

  func makeNSView(context: Context) -> NSGlassEffectView {
    let view = NSGlassEffectView()
    view.cornerRadius = TabBarMetrics.chipHeight / 2
    if view.responds(to: NSSelectorFromString("set_variant:")) {
      view.setValue(Self.variant, forKey: "_variant")
    }
    if view.responds(to: NSSelectorFromString("set_subvariant:")) {
      view.setValue(Self.subvariant, forKey: "_subvariant")
    }
    return view
  }

  func updateNSView(_ view: NSGlassEffectView, context: Context) {}
}
