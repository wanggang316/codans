import AppKit
import SwiftUI

/// Semantic color tokens for the Tab bar. Each token maps to a role, not a
/// hex value, so dark-mode and accent-color changes propagate without
/// per-view overrides. Any visual-system shift lives here, not in the
/// individual chip views.
///
/// Chip / track tokens reproduce AppKit's macOS 26 window-tabbing tab bar,
/// sampled per appearance. The system draws the track and the selected tab
/// with private Liquid Glass variants that public API cannot select
/// (`.glassEffect` renders visibly different), so they are expressed as
/// translucent fills that land on the same pixels over the window backdrop.
enum TabBarColors {
  /// Recessed capsule track behind the chips.
  static let trackBackground: Color = adaptive(
    light: .black.withAlphaComponent(0.10),
    dark: .white.withAlphaComponent(0.041)
  )

  /// Capsule under an idle chip while the pointer is over it.
  static let chipHoverBackground: Color = adaptive(
    light: .black.withAlphaComponent(0.044),
    dark: .white.withAlphaComponent(0.048)
  )

  /// Raised capsule of the selected chip. Opaque in light mode: its drop
  /// shadow would otherwise show through a translucent fill and grey it.
  static let activeBackground: Color = adaptive(
    light: NSColor(srgbRed: 248 / 255, green: 248 / 255, blue: 248 / 255, alpha: 1),
    dark: .white.withAlphaComponent(0.14)
  )

  /// Two stacked 0.5-pt rims (outer, inner) that give the selected capsule
  /// its glass edge highlight.
  static let activeRimOuter: Color = adaptive(
    light: .white,
    dark: .white.withAlphaComponent(0.22)
  )
  static let activeRimInner: Color = adaptive(
    light: .white.withAlphaComponent(0.7),
    dark: .white.withAlphaComponent(0.13)
  )

  /// Soft drop shadow under the selected capsule — light mode only; the
  /// dark-mode system bar shows none.
  static let activeShadow: Color = adaptive(
    light: .black.withAlphaComponent(0.10),
    dark: .clear
  )

  /// Circle behind the close glyph while the pointer is on the button,
  /// layered over the chip's own hover / selected capsule.
  static let closeButtonHoverBackground: Color = adaptive(
    light: .black.withAlphaComponent(0.073),
    dark: .white.withAlphaComponent(0.106)
  )

  /// Close glyph: secondary while the chip is hovered, primary once the
  /// pointer is on the button itself.
  static let closeButtonForeground: Color = .secondary
  static let closeButtonHoverForeground: Color = .primary

  /// Separator between two adjacent idle chips. Darker than the track in
  /// both appearances (`.separatorColor` is lighter in dark mode).
  static let divider: Color = adaptive(
    light: .black.withAlphaComponent(0.087),
    dark: .black.withAlphaComponent(0.17)
  )

  /// Opaque surface stamped under a chip while it is lifted in a drag, so
  /// the floating copy fully occludes the chips it passes over instead of
  /// letting their text bleed through the otherwise-transparent idle chip.
  static let draggingBackground: Color = Color(nsColor: .windowBackgroundColor)

  /// Round hover affordance of the trailing accessory buttons (+, history,
  /// splits) — the bar's generic icon-button hover, not a chip state.
  static let hoverBackground: Color = Color.primary.opacity(0.06)

  /// Title color for the active chip.
  static let activeText: Color = Color.primary

  /// Title color for idle / hovered chips.
  static let inactiveText: Color = Color.secondary

  private static func adaptive(light: NSColor, dark: NSColor) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
      })
  }
}
