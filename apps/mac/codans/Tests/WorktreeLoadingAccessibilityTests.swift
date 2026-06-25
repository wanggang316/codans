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

  @Test
  func streamingOutputIDIsStableContractKey() {
    #expect(WorktreeLoadingView.AccessibilityID.streamingOutput == "streaming-output")
  }
}

/// Pins the pure phase → operation-label mapping the detail loading view's
/// command chip renders (and exposes as its accessibility value). This is
/// the probeable core of VAL-DETAIL-007 / VAL-CROSS-001: the label MUST
/// track the creation phase rather than staying pinned to git. The chip
/// *rendering* + a11y wiring is dogfood-tier; only the string mapping is a
/// fixed contract, so it gets a focused value test (no rendered tree).
struct WorktreeLoadingOperationLabelTests {
  private typealias Progress = WorktreeLoadingInfo.Progress

  @Test
  func creatingWorktreePhaseShowsGitCheckoutLabel() {
    #expect(
      Progress.operationLabel(for: .creatingWorktree, setupCommand: "npm install")
        == "git worktree add"
    )
    // The git leg ignores any configured setup command.
    #expect(
      Progress.operationLabel(for: .creatingWorktree, setupCommand: nil)
        == "git worktree add"
    )
  }

  @Test
  func setupScriptPhaseShowsConfiguredCommand() {
    #expect(
      Progress.operationLabel(for: .runningSetupScript, setupCommand: "npm install")
        == "npm install"
    )
  }

  @Test
  func setupScriptPhaseFallsBackWhenCommandMissingOrBlank() {
    #expect(
      Progress.operationLabel(for: .runningSetupScript, setupCommand: nil)
        == "setup script"
    )
    #expect(
      Progress.operationLabel(for: .runningSetupScript, setupCommand: "   ")
        == "setup script"
    )
  }

  @Test
  func setupScriptCommandCollapsesToFirstLine() {
    #expect(
      Progress.operationLabel(
        for: .runningSetupScript,
        setupCommand: "  npm ci\nnpm run build  "
      ) == "npm ci"
    )
  }

  /// The contract that actually matters: the label is NOT pinned to git
  /// once the run advances into the setup leg.
  @Test
  func labelChangesBetweenPhases() {
    let git = Progress.operationLabel(for: .creatingWorktree, setupCommand: "make setup")
    let setup = Progress.operationLabel(for: .runningSetupScript, setupCommand: "make setup")
    #expect(git != setup)
  }
}
