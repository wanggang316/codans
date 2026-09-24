import CoreGraphics
import Foundation

/// Numeric design tokens for the Tab bar. Kept as an enum (no instances) so
/// the values live in one grep-able place; any layout tweak is a one-file
/// diff.
///
/// The geometry follows the macOS 26 system tab bar (Safari / Finder): a
/// recessed rounded track holds equal-width tabs, and the selected tab is a
/// raised rounded plate inset inside that track.
enum TabBarMetrics {
  /// Height of the full Tab bar row — the track plus its vertical margin.
  static let barHeight: CGFloat = 36

  /// Height of the recessed track that hosts the chips.
  static let trackHeight: CGFloat = 28

  /// Corner radius of the track. The chip plate radius is derived from it
  /// so the two curves stay concentric.
  static let trackCornerRadius: CGFloat = 9

  /// Leading gap between the bar's edge and the track.
  static let trackLeadingInset: CGFloat = 8

  /// A chip cell spans the full track height; its visible plate (selected
  /// / hover fill) is inset by `chipPlateInset` on every side.
  static let chipHeight: CGFloat = trackHeight
  static let chipPlateInset: CGFloat = 2
  static let chipCornerRadius: CGFloat = trackCornerRadius - chipPlateInset

  /// Chips share the track width equally; below `chipMinWidth` they stop
  /// shrinking and the row scrolls instead of truncating titles to nothing.
  static let chipMinWidth: CGFloat = 120

  /// Symmetric horizontal inset for chip content (close button / trailing
  /// accessory on either side of the centered label).
  static let chipHorizontalPadding: CGFloat = 6

  /// Close-button hit / hover square. Visible only on chip hover.
  static let closeButtonSize: CGFloat = 16

  /// Short vertical separator between two adjacent non-selected chips.
  static let dividerWidth: CGFloat = 1
  static let dividerHeight: CGFloat = 14

  /// Delay before the trailing split buttons show their pane-tree preview
  /// popover.
  static let hoverPreviewDelay: Duration = .milliseconds(350)

  /// Drag-reorder kicks in only after the pointer moves this far — keeps
  /// plain taps from being interpreted as drags.
  static let reorderMovementThreshold: CGFloat = 3
}
