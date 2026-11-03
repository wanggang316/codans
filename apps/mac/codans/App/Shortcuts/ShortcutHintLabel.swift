import SwiftUI

/// The chord a control answers to (`⌘1`, `⌃2`, `⌥3`), shown while ⌘ is held.
///
/// Every hint in the app renders through this view so they share one look: plain secondary
/// text in the system font, no keycap frame, like the chord column of a macOS menu. The view
/// carries its own insertion/removal transition; `CommandKeyObserver` flips its flag inside
/// `Animation.shortcutHint`, so a hint inserted under that flag cross-fades in and out.
///
/// A list row (sidebar, Agents View) instead stacks its chord with its trailing accessories
/// through `ShortcutHintTrailing`.
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

/// A row's trailing accessories that give way to its chord while ⌘ is held.
///
/// The chord and the accessories share one trailing-aligned stack and only their opacity
/// changes, so the chord takes the accessories' place and the row does not reflow around
/// it. Hidden accessories stop taking clicks.
struct ShortcutHintTrailing<Accessories: View>: View {
  /// The chord while ⌘ is held, else `nil`.
  let chord: String?
  /// Gap between the chord and the row content before it.
  var leadingGap: CGFloat = 0
  @ViewBuilder let accessories: () -> Accessories
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let isShown = chord != nil
    ZStack(alignment: .trailing) {
      accessories()
        .opacity(isShown ? 0 : 1)
        .allowsHitTesting(!isShown)
      Text(chord ?? "")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
        .padding(.leading, isShown ? leadingGap : 0)
        .opacity(isShown ? 1 : 0)
        .accessibilityHidden(true)
    }
    // Slower than `Animation.shortcutHint`: a column of rows swaps at once, and a soft
    // fade reads calmer there than a snap.
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isShown)
  }
}

extension Animation {
  /// Timing of the hint show/hide: a quick cross-fade with no motion or blur, so the hints
  /// answer the held key at once.
  static let shortcutHint: Animation = .easeOut(duration: 0.08)
}
