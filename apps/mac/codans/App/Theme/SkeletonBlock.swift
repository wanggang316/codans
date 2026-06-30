import SwiftUI

/// A single rounded-rect grey placeholder block with the decorative
/// light-sweep. Reuses the system `.secondary` grey (no new color system)
/// so it sits flush with the app's other neutral surfaces. The sweep is
/// gated off under Reduce Motion; the block itself stays so the skeleton
/// keeps its structure (VAL-DETAIL-008).
///
/// Shared by the worktree-detail loading surfaces: the window-toolbar
/// skeleton items (`WorktreeDetailView.pendingSkeletonToolbarContent`) that
/// stand in for the branch label + status pill during creation, and any
/// other in-progress placeholder that wants the same look. Reads Reduce
/// Motion from the environment so each call site gates the shimmer without
/// threading the flag — the shared `ShimmerModifier` stays untouched.
struct SkeletonBlock: View {
  let width: CGFloat
  let height: CGFloat

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    RoundedRectangle(cornerRadius: height / 3)
      .fill(.secondary.opacity(0.25))
      .frame(width: width, height: height)
      .shimmer(isActive: !reduceMotion)
  }
}
