import CoreGraphics
import Foundation

/// Numeric design tokens for the Tab bar. Kept as an enum (no instances) so
/// the values live in one grep-able place; any layout tweak is a one-file
/// diff.
///
/// Colors and curves are measured from AppKit's own window-tabbing tab bar
/// on macOS 26 (`NSTabBar` / `NSTabButton`, the bar Finder uses), sampled
/// from 2x captures. The track height, the title size, and the gap under the
/// toolbar follow Safari's tab bar on macOS 26, measured from 2x captures.
enum TabBarMetrics {
  /// Height of the full Tab bar row: the track and its insets.
  static let barHeight: CGFloat = trackTopInset + trackHeight + trackBottomInset

  /// Recessed capsule track that hosts the chips.
  static let trackHeight: CGFloat = 32
  /// Gap from the edge above the strip to the track. Equal to the gap below,
  /// so the strip sits centered between what is above it and the content.
  static let trackTopInset: CGFloat = trackBottomInset
  /// Gap between the track and the content below it.
  static let trackBottomInset: CGFloat = 6
  /// Gap between the bar's leading edge and the track.
  static let trackLeadingInset: CGFloat = 4
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
  static let titleFontSize: CGFloat = 13
  static let closeGlyphSize: CGFloat = 9

  /// Separator in the gap between two chips, vertically centered.
  static let dividerWidth: CGFloat = chipSpacing
  static let dividerHeight: CGFloat = 18

  /// Trailing accessory buttons (+, history): a
  /// square hit target, the gap between two of them, and the cluster's
  /// horizontal padding on each side.
  static let accessorySize: CGFloat = 22
  static let accessorySpacing: CGFloat = 4
  static let accessoryClusterPadding: CGFloat = 4
  /// Gap between the chip track and the accessory cluster.
  static let trackAccessoryGap: CGFloat = 4

  /// Width of an accessory cluster holding `count` buttons.
  static func accessoryClusterWidth(count: Int) -> CGFloat {
    guard count > 0 else { return 0 }
    return CGFloat(count) * accessorySize + CGFloat(count - 1) * accessorySpacing
      + accessoryClusterPadding * 2
  }

  /// Whether a strip `stripWidth` wide folds history into the `+` menu.
  /// The full cluster folds once it would leave the track less than one
  /// minimum-width chip, so a narrow Pane keeps room for its chips.
  static func foldsAccessories(stripWidth: CGFloat) -> Bool {
    let fullStrip = trackLeadingInset + chipMinWidth + trackAccessoryGap + accessoryClusterWidth(count: 2)
    return stripWidth < fullStrip
  }

  /// Drag-reorder kicks in only after the pointer moves this far — keeps
  /// plain taps from being interpreted as drags.
  static let reorderMovementThreshold: CGFloat = 3

  /// How long a tab added from the UI waits before its first pane opens. A
  /// terminal surface entering the window stalls compositing for a few
  /// frames; opened once the tab bar's insertion animation (~0.15 s) has
  /// played, the stall lands on a still frame instead of freezing it.
  static let firstPaneDelay: Duration = .milliseconds(160)
}
