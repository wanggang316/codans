import CoreGraphics
import Foundation

/// Numeric design tokens for the Tab bar. Kept as an enum (no instances) so
/// the values live in one grep-able place; any layout tweak is a one-file
/// diff.
///
/// Values are measured from AppKit's own window-tabbing tab bar on macOS 26
/// (`NSTabBar` / `NSTabButton`, the bar Finder uses): view frames read from
/// the live view tree, colors and curves sampled from 2x captures.
enum TabBarMetrics {
  /// Height of the full Tab bar row: the track plus `trackBottomInset`.
  static let barHeight: CGFloat = trackHeight + trackBottomInset

  /// Recessed capsule track that hosts the chips.
  static let trackHeight: CGFloat = 34
  /// The system bar sits flush under the toolbar and leaves this gap to
  /// the content below it.
  static let trackBottomInset: CGFloat = 8
  /// Gap between the bar's leading edge and the track.
  static let trackLeadingInset: CGFloat = 0
  /// Chips are inset from the track on every side by this much.
  static let trackContentInset: CGFloat = 3

  /// Chip height inside the track. The hover / selected capsule fills the
  /// whole chip.
  static let chipHeight: CGFloat = trackHeight - trackContentInset * 2

  /// Chips share the track width equally; below `chipMinWidth` they stop
  /// shrinking and the row scrolls instead.
  static let chipMinWidth: CGFloat = 120
  /// Chips do not stretch to fill the bar: the track is only as wide as
  /// this many points per chip, and the chips share that width.
  static let chipIdealWidth: CGFloat = 200

  /// Widest the track grows for `count` chips: `chipIdealWidth` each, plus
  /// the gaps and the track's own inset.
  static func trackMaxWidth(chipCount count: Int) -> CGFloat {
    CGFloat(count) * chipIdealWidth + CGFloat(max(count - 1, 0)) * chipSpacing
      + trackContentInset * 2
  }

  /// Chips are laid out with a 1-pt gap; the separator is drawn inside it.
  static let chipSpacing: CGFloat = 1

  /// Close button (leading) and trailing accessory slot: a square this
  /// size, inset `chipSlotInset` from the chip edge.
  static let closeButtonSize: CGFloat = 16
  static let chipSlotInset: CGFloat = 5
  /// Leading inset of the icon + title, and the trailing inset that keeps
  /// the title clear of the trailing slot (close button / color dot).
  static let chipContentLeadingInset: CGFloat = 12
  static let chipTitleTrailingInset: CGFloat = chipSlotInset + closeButtonSize + 6

  /// Point size of the chip title and the close glyph.
  static let titleFontSize: CGFloat = 13
  static let closeGlyphSize: CGFloat = 9

  /// Separator in the gap between two chips, vertically centered.
  static let dividerWidth: CGFloat = chipSpacing
  static let dividerHeight: CGFloat = 20

  /// Delay before the trailing split buttons show their pane-tree preview
  /// popover.
  static let hoverPreviewDelay: Duration = .milliseconds(350)

  /// Drag-reorder kicks in only after the pointer moves this far — keeps
  /// plain taps from being interpreted as drags.
  static let reorderMovementThreshold: CGFloat = 3

  /// How long a tab added from the UI waits before its first pane opens. A
  /// terminal surface entering the window stalls compositing for a few
  /// frames; opened once the tab bar's insertion animation (~0.15 s) has
  /// played, the stall lands on a still frame instead of freezing it.
  static let firstPaneDelay: Duration = .milliseconds(160)
}
