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
    isVetoed: Bool = false
  ) -> SurfaceReclaimPolicy.Candidate {
    .init(
      hiddenFor: hiddenFor, quietFor: quietFor, foregroundJob: job,
      isRemote: isRemote, isSurfaceReady: isReady, isVetoed: isVetoed)
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
  func remoteNotReadyAndVetoedPanesAreKept() {
    #expect(!policy.shouldReclaim(candidate(isRemote: true)))
    #expect(!policy.shouldReclaim(candidate(isReady: false)))
    #expect(!policy.shouldReclaim(candidate(isVetoed: true)))
  }
}
