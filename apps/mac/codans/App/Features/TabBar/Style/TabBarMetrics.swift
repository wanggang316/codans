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
  static let trackHeight: CGFloat = 28
  /// The system bar sits flush under the toolbar and leaves this gap to
  /// the content below it.
  static let trackBottomInset: CGFloat = 8
  /// Gap between the bar's leading edge and the track.
  static let trackLeadingInset: CGFloat = 8
  /// Chips are inset from the track on every side by this much.
  static let trackContentInset: CGFloat = 2

  /// Chip height inside the track. The hover / selected capsule fills the
  /// whole chip.
  static let chipHeight: CGFloat = trackHeight - trackContentInset * 2

  /// Chips share the track width equally; below `chipMinWidth` they stop
  /// shrinking and the row scrolls instead.
  static let chipMinWidth: CGFloat = 120

  /// Chips are laid out with a 1-pt gap; the separator is drawn inside it.
  static let chipSpacing: CGFloat = 1

  /// Close button (leading) and trailing accessory slot: a square this
  /// size, inset `chipSlotInset` from the chip edge.
  static let closeButtonSize: CGFloat = 16
  static let chipSlotInset: CGFloat = 5
  /// Horizontal inset of the centered title on both sides — slot inset +
  /// slot + 8-pt gap — so the title stays centered and never runs under
  /// the close button or the trailing slot.
  static let chipTitleInset: CGFloat = chipSlotInset + closeButtonSize + 8

  /// Point size of the chip title and the close glyph.
  static let titleFontSize: CGFloat = 11
  static let closeGlyphSize: CGFloat = 9

  /// Separator in the gap between two chips, vertically centered.
  static let dividerWidth: CGFloat = chipSpacing
  static let dividerHeight: CGFloat = 18

  /// Delay before the trailing split buttons show their pane-tree preview
  /// popover.
  static let hoverPreviewDelay: Duration = .milliseconds(350)

  /// Drag-reorder kicks in only after the pointer moves this far — keeps
  /// plain taps from being interpreted as drags.
  static let reorderMovementThreshold: CGFloat = 3
}
