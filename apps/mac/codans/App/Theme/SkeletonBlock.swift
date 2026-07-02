import SwiftUI

/// A single rounded-rect grey placeholder block with the decorative
/// light-sweep. Reuses the system `.secondary` grey (no new color system)
/// so it sits flush with the app's other neutral surfaces. The sweep is
/// gated off under Reduce Motion; the block itself stays so the skeleton
/// keeps its structure (VAL-DETAIL-008).
///
/// Shared by the worktree-detail loading surfaces: the window-toolbar
/// skeleton clusters (`WorktreeToolbarSkeleton.swift`) that stand in for
/// the branch identity + status pill + action buttons during creation, and
/// any other in-progress placeholder that wants the same look. Reads Reduce
/// Motion from the environment so each call site gates the shimmer without
/// threading the flag — the shared `ShimmerModifier` stays untouched.
///
/// `width == nil` drops the horizontal constraint so the block fills
/// whatever its container proposes — the sizing hook `SkeletonTextBar`
/// uses to take the exact width of a real laid-out string.
struct SkeletonBlock: View {
  var width: CGFloat?
  let height: CGFloat

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    RoundedRectangle(cornerRadius: height / 3)
      .fill(.secondary.opacity(0.25))
      .frame(width: width, height: height)
      .shimmer(isActive: !reduceMotion)
  }
}

/// A skeleton bar that takes the EXACT footprint of a real rendered
/// string: the text lays out invisibly (participating in layout with its
/// true font metrics) and a width-free `SkeletonBlock` paints over it.
/// Give it the string that will actually render in the slot on completion
/// and the placeholder matches the final content's length and line
/// position — no hand-tuned widths that drift from reality.
struct SkeletonTextBar: View {
  /// The string whose rendered footprint the bar occupies — the real
  /// content when known during loading (e.g. the pending worktree's
  /// name), a representative stand-in otherwise.
  let text: String
  let font: Font
  /// Bar height — slightly slimmer than the font's line height so the
  /// bar reads as "text ink", not a filled row.
  var barHeight: CGFloat = 9

  var body: some View {
    Text(text)
      .font(font)
      .lineLimit(1)
      .foregroundStyle(.clear)
      .overlay { SkeletonBlock(height: barHeight) }
      .accessibilityHidden(true)
  }
}
