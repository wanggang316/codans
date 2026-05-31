import Foundation

/// Subset of color directives a Ghostty theme can declare, captured at catalog
/// build time so the Settings → Terminal picker can render swatches and a
/// sample preview without re-reading any file. `nil` fields mean the directive
/// was absent or unparseable — the UI falls back to neutral chrome rather than
/// inventing colors.
///
/// We parse only the directives the preview UI actually shows: background,
/// foreground, cursor-color, and the 16-entry ANSI palette. Selection colors
/// and other directives are intentionally skipped to keep the per-theme
/// payload small (the catalog map holds ~500 entries).
nonisolated struct GhosttyThemePreview: Equatable, Sendable {
  /// 0–1 normalized RGB. Plain value type so the preview can cross actor
  /// boundaries and live inside `Equatable` TCA state without conversion.
  struct RGB: Equatable, Sendable {
    let r: Double
    let g: Double
    let b: Double
  }

  let background: RGB?
  let foreground: RGB?
  let cursor: RGB?
  /// Sparse palette keyed by index 0..15. Themes typically populate every
  /// slot, but we don't require it — missing slots render as a neutral
  /// placeholder in the swatch row.
  let palette: [Int: RGB]

  static let empty = GhosttyThemePreview(
    background: nil, foreground: nil, cursor: nil, palette: [:]
  )

  /// Six high-signal colors for the compact inline swatch row, in render order:
  /// background, foreground, red (palette 1), green (2), yellow (3), blue (4).
  /// Picked so a glance distinguishes light/dark themes and broadly conveys
  /// the accent palette. `nil` slots fall through to caller-supplied chrome.
  var swatchStrip: [RGB?] {
    [background, foreground, palette[1], palette[2], palette[3], palette[4]]
  }
}
