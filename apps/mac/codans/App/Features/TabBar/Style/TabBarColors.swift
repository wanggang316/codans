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

  /// Raised capsule of the selected chip. In light mode the system's glass
  /// tab takes on the hue of the backdrop it sits on, which here is the
  /// terminal background seen through the window glass. A white fill, opaque
  /// or translucent, reads as a flat plate on a tinted bar. So the fill keeps
  /// the hue and saturation of `backdrop` and takes the luminosity of the
  /// sampled system value (#F8F8F8): on a neutral backdrop it lands exactly
  /// on that value. In dark mode a translucent white already takes on the
  /// backdrop.
  static func activeBackground(over backdrop: NSColor, colorScheme: ColorScheme) -> Color {
    colorScheme == .dark
      ? Color(nsColor: .white.withAlphaComponent(0.14))
      : Color(nsColor: backdrop.withLuminosity(248 / 255))
  }

  /// Selected capsule while the pointer is over it — a codans addition (the
  /// system bar keeps the selected tab unchanged on hover). Light mode takes
  /// the luminosity of #F0F0F0.
  static func activeHoverBackground(over backdrop: NSColor, colorScheme: ColorScheme) -> Color {
    colorScheme == .dark
      ? Color(nsColor: .white.withAlphaComponent(0.18))
      : Color(nsColor: backdrop.withLuminosity(240 / 255))
  }

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

  /// Round hover affordance of the trailing accessory buttons (+, history,
  /// splits) — the bar's generic icon-button hover, not a chip state.
  static let hoverBackground: Color = Color.primary.opacity(0.06)

  /// Title color for the active chip.
  static let activeText: Color = Color.primary

  /// Idle / hovered chip titles: `activeText` at this opacity. `labelColor`
  /// and `secondaryLabelColor` share their RGB and differ only in alpha
  /// (0.847 vs 0.498 light / 0.549 dark), so this lands exactly on the
  /// secondary label color.
  static func inactiveTextOpacity(for colorScheme: ColorScheme) -> Double {
    (colorScheme == .dark ? 0.549 : 0.498) / 0.847
  }

  private static func adaptive(light: NSColor, dark: NSColor) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
      })
  }
}

extension NSColor {
  /// This color's hue and saturation at luminosity `target`, as the
  /// `luminosity` blend mode computes it (W3C Compositing, SetLum + ClipColor).
  fileprivate func withLuminosity(_ target: CGFloat) -> NSColor {
    guard let rgb = usingColorSpace(.sRGB) else { return NSColor(white: target, alpha: 1) }
    func luminosity(_ c: [CGFloat]) -> CGFloat { 0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2] }
    let source = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
    let shift = target - luminosity(source)
    var c = source.map { $0 + shift }
    let l = luminosity(c)
    let low = c.min() ?? l
    let high = c.max() ?? l
    if low < 0 { c = c.map { l + ($0 - l) * l / (l - low) } }
    if high > 1 { c = c.map { l + ($0 - l) * (1 - l) / (high - l) } }
    return NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: 1)
  }
}
