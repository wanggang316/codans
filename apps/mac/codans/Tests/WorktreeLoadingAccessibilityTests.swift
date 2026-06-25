import Foundation
import Testing

@testable import Codans

/// Pins the load-bearing accessibility identifiers on the worktree-detail
/// loading view — the `loading-view container` + `skeleton-left` /
/// `skeleton-middle` keys that later validation probes (VAL-DETAIL-001,
/// VAL-DETAIL-003). The skeleton-header *visuals* (placeholder geometry,
/// shimmer, Reduce-Motion gating) are dogfood-tier and exercised live; only
/// the id vocabulary is a fixed contract, so it gets a focused string test
/// over the constants rather than a snapshot — mirrors
/// `PendingWorktreeAccessibilityTests`.
///
/// Note: ViewInspector is not a dependency here, so this asserts on the
/// `AccessibilityID` constants the view applies, not on a rendered tree. The
/// presence-while-loading / absence-on-completion behaviour itself is a
/// structural fact of `WorktreeDetailView.detailBody` swapping this view out
/// when the pending row resolves, validated by dogfooding.
@MainActor
struct WorktreeLoadingAccessibilityTests {

  @Test
  func containerIDIsStableContractKey() {
    #expect(WorktreeLoadingView.AccessibilityID.container == "loading-view container")
  }

  @Test
  func skeletonRegionIDsAreStableContractKeys() {
    #expect(WorktreeLoadingView.AccessibilityID.skeletonLeft == "skeleton-left")
    #expect(WorktreeLoadingView.AccessibilityID.skeletonMiddle == "skeleton-middle")
  }
}
