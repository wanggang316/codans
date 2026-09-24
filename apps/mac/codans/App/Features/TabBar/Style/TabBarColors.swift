import AppKit
import SwiftUI

/// Semantic color tokens for the Tab bar. Each token maps to a role, not a
/// hex value, so dark-mode and accent-color changes propagate without
/// per-view overrides. Any visual-system shift lives here, not in the
/// individual chip views.
enum TabBarColors {
  /// Recessed track behind the chips. `primary` at low opacity reads as
  /// slightly darker than the titlebar in light mode and slightly lighter
  /// in dark mode — the same relationship the system tab bar has.
  static let trackBackground: Color = Color.primary.opacity(0.05)

  /// Chip background when the tab is not selected and the pointer is
  /// elsewhere.
  static let idleBackground: Color = .clear

  /// Chip background while the pointer is over it but the mouse button
  /// is up. Subtle so it reads as affordance, not selection.
  static let hoverBackground: Color = Color.primary.opacity(0.06)

  /// Chip background while an idle chip is being clicked, before the
  /// selection commits.
  static let pressedBackground: Color = Color.primary.opacity(0.10)

  /// Raised plate of the selected chip. Not expressible as a `primary`
  /// opacity: light mode wants a near-white plate over the grey track, dark
  /// mode a lighter grey one.
  static let activeBackground: Color = adaptive(
    light: NSColor.white.withAlphaComponent(0.95),
    dark: NSColor.white.withAlphaComponent(0.11)
  )

  /// Hairline border around the selected plate.
  static let activeBorder: Color = adaptive(
    light: NSColor.black.withAlphaComponent(0.10),
    dark: NSColor.white.withAlphaComponent(0.14)
  )

  /// Soft drop shadow under the selected plate; carries the "raised" read
  /// in light mode, where the border alone is too faint.
  static let activeShadow: Color = Color.black.opacity(0.08)

  /// Opaque surface stamped under a chip while it is lifted in a drag, so
  /// the floating copy fully occludes the chips it passes over instead of
  /// letting their text bleed through the otherwise-`.clear` idle fill.
  static let draggingBackground: Color = Color(nsColor: .windowBackgroundColor)

  /// Separator drawn between adjacent idle chips. Hidden next to the
  /// selected chip, whose plate already carries the boundary.
  static let divider: Color = Color(nsColor: .separatorColor)

  /// Foreground tint for the close-button glyph.
  static let closeButtonForeground: Color = Color.primary.opacity(0.7)

  /// Title color for the active chip — full primary strength so the
  /// selected tab reads first when the bar holds many idle ones.
  static let activeText: Color = Color.primary

  /// Title color for idle / hovered chips — softened to keep visual
  /// weight on the active chip rather than competing with it.
  static let inactiveText: Color = Color.secondary

  private static func adaptive(light: NSColor, dark: NSColor) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
      })
  }
}
