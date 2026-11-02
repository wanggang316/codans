import SwiftUI

/// The chord a control answers to (`⌘1`, `⌃2`, `⌥3`), shown while ⌘ is held.
///
/// Every hint in the app renders through this view so they share one look: plain secondary
/// text in the system font, no keycap frame, like the chord column of a macOS menu. The view
/// carries its own insertion/removal transition; `CommandKeyObserver` flips its flag inside
/// `Animation.shortcutHint`, so a hint inserted under that flag blurs in and out instead of
/// popping.
struct ShortcutHintLabel: View {
  let chord: String
  /// `.caption` suits a row or a tab title. A hint beside a 13–16pt toolbar glyph passes a
  /// larger font so it does not read as a footnote.
  var font: Font = .caption
  /// Gaps around the chord. Inside the view, not padded on by the caller, so the
  /// transition stays on the outermost view that the caller inserts.
  var leadingGap: CGFloat = 0
  var trailingGap: CGFloat = 0
  /// Timing of this hint's own transition. The flag flip in `CommandKeyObserver` starts
  /// it; this value overrides that flip's animation for this hint only.
  var animation: Animation = .shortcutHint

  var body: some View {
    Text(chord)
      .font(font)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .fixedSize()
      .padding(.leading, leadingGap)
      .padding(.trailing, trailingGap)
      .accessibilityHidden(true)
      .transition(AnyTransition(.blurReplace).animation(animation))
  }
}

extension Animation {
  /// Timing of the hint show/hide. Short and decelerating: the hints answer a held key, so
  /// they must settle before the eye reaches them.
  static let shortcutHint: Animation = .easeOut(duration: 0.16)
  /// Faster variant for lists (sidebar rows, Agents View rows), where a column of hints
  /// appears at once and a slower fade reads as lag.
  static let shortcutHintFast: Animation = .easeOut(duration: 0.08)
}
