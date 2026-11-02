import SwiftUI

/// The chord a control answers to (`⌘1`, `⌃2`, `⌥3`), shown while ⌘ is held.
///
/// Every hint in the app renders through this view so they share one look: plain secondary
/// text in the system font, no keycap frame, like the chord column of a macOS menu. The view
/// carries its own insertion/removal transition; `CommandKeyObserver` flips its flag inside
/// `Animation.shortcutHint`, so a hint inserted under that flag cross-fades in and out.
struct ShortcutHintLabel: View {
  let chord: String
  /// `.caption` suits a row or a tab title. A hint beside a 13–16pt toolbar glyph passes a
  /// larger font so it does not read as a footnote.
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

extension Animation {
  /// Timing of the hint show/hide: a quick cross-fade with no motion or blur, so the hints
  /// answer the held key at once.
  static let shortcutHint: Animation = .easeOut(duration: 0.08)
}
