import CodansCore
import Foundation
import Testing

@testable import Codans

/// Pure tests for the load-bearing accessibility vocabulary on
/// `PendingWorktree` — the `in-progress`/`settled` name value (and the
/// `isRunning` gate behind it) that later validation probes (VAL-SIDEBAR-003,
/// VAL-SIDEBAR-006). The shimmer/icon visuals on the row are dogfood-tier;
/// the strings here are the contract, so they get a focused unit test over
/// plain values rather than a snapshot.
@MainActor
struct PendingWorktreeAccessibilityTests {

  private static func makeSpec() -> CreateWorktreeSpec {
    CreateWorktreeSpec(
      repoRoot: URL(fileURLWithPath: "/tmp/repo"),
      baseDirectory: URL(fileURLWithPath: "/tmp/repo/.worktrees"),
      name: "feature-x",
      baseRef: "origin/main",
      fetchOrigin: false,
      copyIgnored: false,
      copyUntracked: false
    )
  }

  private static func pending(status: PendingWorktree.Status) -> PendingWorktree {
    PendingWorktree(
      id: PendingWorktreeID(),
      projectID: ProjectID(),
      spec: makeSpec(),
      displayName: "feat/x",
      status: status,
      lastProgressLine: nil,
      startedAt: Date(timeIntervalSince1970: 0)
    )
  }

  @Test
  func runningReportsInProgress() {
    let row = Self.pending(status: .running)
    #expect(row.isRunning)
    #expect(row.nameProgressAccessibilityValue == "in-progress")
  }

  @Test
  func failedSettlesAndStopsRunning() {
    let row = Self.pending(status: .failed(.executableMissing))
    #expect(!row.isRunning)
    #expect(row.nameProgressAccessibilityValue == "settled")
  }
}
