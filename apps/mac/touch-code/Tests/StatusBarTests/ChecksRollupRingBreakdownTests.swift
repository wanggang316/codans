import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// Unit coverage for `ChecksRollupRing.Breakdown`. The ring view itself is
/// SwiftUI geometry — we test the pure counts projection that drives it.
@MainActor
struct ChecksRollupRingBreakdownTests {
  private static func passing() -> CheckResult {
    CheckResult(name: "build", status: .completed, conclusion: .success)
  }
  private static func failing() -> CheckResult {
    CheckResult(name: "lint", status: .completed, conclusion: .failure)
  }
  private static func pending() -> CheckResult {
    CheckResult(name: "slow", status: .inProgress)
  }
  private static func skipped() -> CheckResult {
    CheckResult(name: "skipped", status: .completed, conclusion: .skipped)
  }

  @Test
  func emptyInputProducesZeroTotal() {
    let b = ChecksRollupRing.Breakdown(checks: [])
    #expect(b.total == 0)
  }

  @Test
  func fourPassingOneFailingOnePendingOneSkipped() {
    let b = ChecksRollupRing.Breakdown(checks: [
      Self.passing(), Self.passing(), Self.passing(), Self.passing(),
      Self.failing(),
      Self.pending(),
      Self.skipped(),
    ])
    #expect(b.passing == 4)
    #expect(b.failing == 1)
    #expect(b.pending == 1)
    #expect(b.neutral == 1)
    #expect(b.total == 7)
  }

  @Test
  func failingConclusionsAllCountAsFailing() {
    let kinds: [CheckConclusion] = [
      .failure, .cancelled, .timedOut, .actionRequired, .stale, .startupFailure,
    ]
    for kind in kinds {
      let b = ChecksRollupRing.Breakdown(checks: [
        CheckResult(name: "t", status: .completed, conclusion: kind)
      ])
      #expect(b.failing == 1, "expected \(kind) to count as failing")
      #expect(b.passing == 0)
      #expect(b.total == 1)
    }
  }

  @Test
  func completedWithoutConclusionCountsAsNeutral() {
    let b = ChecksRollupRing.Breakdown(checks: [
      CheckResult(name: "nullary", status: .completed, conclusion: nil)
    ])
    #expect(b.neutral == 1)
    #expect(b.total == 1)
  }

  @Test
  func accessibilityValueSkipsZeroSegments() {
    let b = ChecksRollupRing.Breakdown(checks: [
      Self.passing(), Self.passing(),
    ])
    #expect(b.accessibilityValue == "2 passing")
  }
}
