import CodansCore
import Foundation
import Testing

@testable import Codans

struct SurfaceReclaimPolicyTests {
  private let policy = SurfaceReclaimPolicy(hiddenThreshold: 600, quietThreshold: 60)

  private static func job(_ argv0: String, _ commandLine: String? = nil) -> ForegroundJob {
    ForegroundJob(
      processGroupID: 100,
      processes: [
        ForegroundProcess(
          pid: 100, parentPID: 1, processGroupID: 100,
          argv0: argv0, commandLine: commandLine ?? argv0)
      ])
  }

  private func candidate(
    hiddenFor: TimeInterval = 700,
    quietFor: TimeInterval = 120,
    job: ForegroundJob? = SurfaceReclaimPolicyTests.job("zsh"),
    isRemote: Bool = false,
    isReady: Bool = true,
    isVetoed: Bool = false,
    recency: Int? = nil
  ) -> SurfaceReclaimPolicy.Candidate {
    .init(
      hiddenFor: hiddenFor, quietFor: quietFor, foregroundJob: job,
      isRemote: isRemote, isSurfaceReady: isReady, isVetoed: isVetoed,
      selectedTabRecency: recency)
  }

  @Test
  func idleShellHiddenLongEnoughIsReclaimable() {
    #expect(policy.shouldReclaim(candidate()))
  }

  @Test
  func idleAgentIsReclaimable() {
    let claude = Self.job("claude", "claude --resume")
    #expect(policy.shouldReclaim(candidate(job: claude)))
  }

  @Test
  func recentlyDisplayedIsKept() {
    #expect(!policy.shouldReclaim(candidate(hiddenFor: 599)))
    #expect(policy.shouldReclaim(candidate(hiddenFor: 600)))
  }

  @Test
  func recentOutputIsKept() {
    #expect(!policy.shouldReclaim(candidate(quietFor: 59)))
  }

  @Test
  func runningCommandIsKept() {
    #expect(!policy.shouldReclaim(candidate(job: Self.job("make", "make test"))))
  }

  @Test
  func unknownForegroundIsKept() {
    #expect(!policy.shouldReclaim(candidate(job: nil)))
    #expect(!policy.shouldReclaim(candidate(job: ForegroundJob(processGroupID: 0, processes: []))))
  }

  @Test
  func environmentOverrideScalesThresholdsDown() throws {
    let fast = try #require(SurfaceReclaimPolicy(overrideSeconds: "6"))
    #expect(fast.hiddenThreshold == 6)
    #expect(fast.quietThreshold == 6)
    #expect(fast.sweepInterval == 3)
  }

  @Test
  func environmentOverrideNeverRaisesBuiltInLimits() throws {
    let slow = try #require(SurfaceReclaimPolicy(overrideSeconds: "7200"))
    #expect(slow.hiddenThreshold == 7200)
    #expect(slow.quietThreshold == 60)
    #expect(slow.sweepInterval == 60)
  }

  @Test
  func environmentOverrideRejectsGarbage() {
    #expect(SurfaceReclaimPolicy(overrideSeconds: nil) == nil)
    #expect(SurfaceReclaimPolicy(overrideSeconds: "") == nil)
    #expect(SurfaceReclaimPolicy(overrideSeconds: "abc") == nil)
    #expect(SurfaceReclaimPolicy(overrideSeconds: "0") == nil)
    #expect(SurfaceReclaimPolicy(overrideSeconds: "-5") == nil)
  }

  @Test
  func remoteNotReadyAndVetoedPanesAreKept() {
    #expect(!policy.shouldReclaim(candidate(isRemote: true)))
    #expect(!policy.shouldReclaim(candidate(isReady: false)))
    #expect(!policy.shouldReclaim(candidate(isVetoed: true)))
  }

  @Test
  func memoryPressureIgnoresHiddenAndQuietThresholds() {
    let fresh = candidate(hiddenFor: 0, quietFor: 0)
    #expect(!policy.shouldReclaim(fresh))
    #expect(policy.shouldReclaim(fresh, ignoringThresholds: true))
  }

  @Test
  func memoryPressureKeepsEveryOtherRule() {
    let make = Self.job("make", "make test")
    #expect(!policy.shouldReclaim(candidate(hiddenFor: 0, job: make), ignoringThresholds: true))
    #expect(!policy.shouldReclaim(candidate(hiddenFor: 0, job: nil), ignoringThresholds: true))
    #expect(!policy.shouldReclaim(candidate(hiddenFor: 0, isRemote: true), ignoringThresholds: true))
    #expect(!policy.shouldReclaim(candidate(hiddenFor: 0, isReady: false), ignoringThresholds: true))
    #expect(!policy.shouldReclaim(candidate(hiddenFor: 0, isVetoed: true), ignoringThresholds: true))
  }

  @Test
  func selectedTabOfRecentWorktreeIsKeptByTimedSweep() {
    #expect(policy.recentWorktreeCount == 3)
    for rank in 0..<3 {
      #expect(!policy.shouldReclaim(candidate(hiddenFor: 10_000, recency: rank)))
    }
  }

  @Test
  func selectedTabOfOlderWorktreeIsReclaimable() {
    #expect(policy.shouldReclaim(candidate(recency: 3)))
    #expect(policy.shouldReclaim(candidate(recency: nil)))
  }

  @Test
  func memoryPressureIgnoresRecency() {
    #expect(policy.shouldReclaim(candidate(hiddenFor: 0, recency: 0), ignoringThresholds: true))
    #expect(policy.shouldReclaim(candidate(hiddenFor: 0, recency: 2), ignoringThresholds: true))
  }
}
