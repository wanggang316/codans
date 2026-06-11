import CoreGraphics
import Foundation

/// Numeric design tokens for the Tab bar. Kept as an enum (no instances) so
/// the values live in one grep-able place; any layout tweak is a one-file
/// diff. Values tracked to the tab-bar design doc (`docs/design-docs/tab-bar.md`
/// §Visual Spec).
enum TabBarMetrics {
  /// Height of the full Tab bar row.
  static let barHeight: CGFloat = 32

  /// Height of a single chip. Matches `barHeight` so the chip's bottom
  /// edge is flush with the divider beneath the bar (otherwise a hover /
  /// active background reveals a thin gap), and the 2-pt active
  /// underline sitting at the chip's top edge ends up flush with the
  /// bar's top edge.
  static let chipHeight: CGFloat = 32

  /// Chip width clamp — narrower than `chipMinWidth` and the title
  /// truncates to a single glyph; wider than `chipMaxWidth` and one long
  /// title starves its siblings.
  static let chipMinWidth: CGFloat = 120
  static let chipMaxWidth: CGFloat = 220

  /// Symmetric horizontal inset for chip content (label + close button).
  static let chipHorizontalPadding: CGFloat = 8

  /// Thickness of the accent-tinted underline on the active chip.
  static let activeUnderlineHeight: CGFloat = 2

  /// Circular close-button diameter. Visible only on chip hover / focus.
  static let closeButtonSize: CGFloat = 16

  /// Top corner radius on chip backgrounds. Square so the hover / active
  /// fill meets the bar edges flush — the active 2-pt top accent is what
  /// signals selection, no rounding needed.
  static let chipCornerRadius: CGFloat = 0

  /// Thin vertical separator drawn between adjacent non-active chips.
  /// Spans the full bar height so the row reads as a table of cells
  /// rather than centered tick marks.
  static let dividerWidth: CGFloat = 1
  static let dividerHeight: CGFloat = barHeight

  /// Delay before the trailing split buttons show their pane-tree preview
  /// popover, matching the design doc interaction table.
  static let hoverPreviewDelay: Duration = .milliseconds(350)

  /// Drag-reorder kicks in only after the pointer moves this far — keeps
  /// plain taps from being interpreted as drags.
  static let reorderMovementThreshold: CGFloat = 3
}
