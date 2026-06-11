import SwiftUI

/// Semantic color tokens for the Tab bar. Each token maps to a role, not a
/// hex value, so dark-mode and accent-color changes propagate without
/// per-view overrides. Any visual-system shift lives here, not in the
/// individual chip views.
enum TabBarColors {
  /// Chip background when the tab is not selected and the pointer is
  /// elsewhere.
  static let idleBackground: Color = .clear

  /// Chip background while the pointer is over it but the mouse button
  /// is up. Subtle so it reads as affordance, not selection.
  static let hoverBackground: Color = Color.primary.opacity(0.06)

  /// Opaque surface stamped under a chip while it is lifted in a drag, so
  /// the floating copy fully occludes the chips it passes over instead of
  /// letting their text bleed through the otherwise-`.clear` idle fill.
  static let draggingBackground: Color = Color(nsColor: .windowBackgroundColor)

  /// Accent-tinted underline sitting on the top edge of the active chip.
  static let activeUnderline: Color = .accentColor

  /// Separator drawn between adjacent idle chips. Hidden adjacent to the
  /// active chip so the underline carries the boundary.
  static let divider: Color = Color(nsColor: .separatorColor).opacity(0.7)

  /// Foreground tint for the close-button glyph.
  static let closeButtonForeground: Color = Color.primary.opacity(0.7)

  /// Title color for the active chip — full primary strength so the
  /// selected tab reads first when the bar holds many idle ones.
  static let activeText: Color = Color.primary

  /// Title color for idle / hovered chips — softened to keep visual
  /// weight on the active chip rather than competing with it.
  static let inactiveText: Color = Color.secondary
}
