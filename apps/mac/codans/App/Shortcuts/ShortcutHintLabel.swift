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
///
/// The view reads `CommandKeyObserver` itself rather than taking a "⌘ held" flag: a flag
/// computed by the caller inside a lazy stack or geometry-reader closure updates late and
/// row by row, so the rows would not change together.
struct ShortcutHintTrailing<Accessories: View>: View {
  /// The chord bound to this row, or `nil` when it has none. The text stays in the view
  /// while the hint fades out, so it fades with the accessories instead of vanishing.
  let chord: String?
  /// Gap between the chord and the row content before it.
  var leadingGap: CGFloat = 0
  @ViewBuilder let accessories: () -> Accessories
  @Environment(CommandKeyObserver.self) private var commandKeyObserver: CommandKeyObserver?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let isShown = commandKeyObserver?.isCommandHeld == true && chord != nil
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
        // Hidden, the chord takes no width, so a row whose accessories are narrower than
        // its chord keeps its layout. It draws past the zero-width frame toward the
        // leading edge while it fades.
        .frame(width: isShown ? nil : 0, alignment: .trailing)
        .opacity(isShown ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    .animation(reduceMotion ? nil : .shortcutHint, value: isShown)
  }
}

extension View {
  /// The content a hint replaces in place (a filter button's label, a tab's color dot). While ⌘
  /// is held and `chord` is non-nil it shrinks, blurs, and fades out; pair it with
  /// `shortcutHintIncoming()` on the hint that takes its place. Both views stay in the layout,
  /// so nothing around them moves.
  func shortcutHintOutgoing(to chord: String?) -> some View {
    modifier(ShortcutHintSwap(hasChord: chord != nil, isOutgoing: true))
  }

  /// The hint that takes a glyph's place while ⌘ is held. It only fades, with the same
  /// timing as `shortcutHintOutgoing(to:)`.
  func shortcutHintIncoming() -> some View {
    modifier(ShortcutHintSwap(hasChord: true, isOutgoing: false))
  }
}

/// Reads `CommandKeyObserver` itself, for the reason given on `ShortcutHintTrailing`.
private struct ShortcutHintSwap: ViewModifier {
  let hasChord: Bool
  let isOutgoing: Bool
  @Environment(CommandKeyObserver.self) private var commandKeyObserver: CommandKeyObserver?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    let isShown = commandKeyObserver?.isCommandHeld == true && hasChord
    let isHidden = isOutgoing == isShown
    let morphs = isOutgoing && isShown && !reduceMotion
    content
      .scaleEffect(morphs ? 0.7 : 1)
      .blur(radius: morphs ? 2 : 0)
      .opacity(isHidden ? 0 : 1)
      .animation(reduceMotion ? nil : .shortcutHint, value: isShown)
  }
}

extension Animation {
  /// The one timing of every ⌘ hint: inserted labels, in-place swaps, and row accessories
  /// all use it, so the sidebar rows, the filter bar, the Agents View, and the tab bar
  /// change together when ⌘ goes down or up.
  static let shortcutHint: Animation = .easeInOut(duration: 0.15)
}
