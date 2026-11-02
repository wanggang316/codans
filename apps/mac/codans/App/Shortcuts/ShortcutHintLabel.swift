import SwiftUI

/// The chord a control answers to (`⌘1`, `⌃2`, `⌥3`), shown while ⌘ is held.
///
/// Every hint in the app renders through this view so they share one look: plain secondary
/// text in the system font, no keycap frame. `CommandKeyObserver` flips its flag inside
/// `Animation.shortcutHint`, so a hint inserted under that flag cross-fades in and out.
/// Where a control has a leading glyph, the hint takes the glyph's place instead of adding
/// a column (`shortcutHintReplacing(_:font:onTint:)`).
struct ShortcutHintLabel: View {
  let chord: String
  var font: Font = .caption
  /// Gaps around the chord. Inside the view, not padded on by the caller, so the
  /// transition stays on the outermost view that the caller inserts.
  var leadingGap: CGFloat = 0
  var trailingGap: CGFloat = 0
  /// Draws the chord in white for a hint that sits on a tinted (selected) fill, where
  /// secondary gray would not read.
  var onTint = false

  var body: some View {
    Text(chord)
      .font(font)
      .foregroundStyle(onTint ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
      .lineLimit(1)
      .fixedSize()
      .padding(.leading, leadingGap)
      .padding(.trailing, trailingGap)
      .accessibilityHidden(true)
      .transition(.opacity)
  }
}

extension View {
  /// Cross-fades this glyph into `chord` in place while `chord` is non-nil. The glyph
  /// keeps its frame, so the row or label around it does not move; the chord is centered
  /// on that frame.
  func shortcutHintReplacing(
    _ chord: String?, font: Font = .system(size: 11), onTint: Bool = false
  ) -> some View {
    opacity(chord == nil ? 1 : 0)
      .overlay {
        if let chord {
          ShortcutHintLabel(chord: chord, font: font, onTint: onTint)
        }
      }
  }
}

extension Animation {
  /// Timing of the hint show/hide: a quick cross-fade, so the hints answer the held key
  /// at once and never read as motion.
  static let shortcutHint: Animation = .easeOut(duration: 0.08)
}
