import CodansCore
import Testing

@testable import Codans

/// The capability list of each `GitPlatformKind` (shown in Settings) agrees with what its
/// implementation decodes: the merge options it offers, their names, and whether it can
/// rerun failed checks.
struct GitPlatformCapabilityAgreementTests {
  private static let clean = PullRequestMergeState(status: .clean)

  /// Merge options the decoding layer of `kind` offers for a Pull Request that merges cleanly.
  private static func mergeOptions(_ kind: GitPlatformKind) -> [PullRequestMergeOption] {
    switch kind {
    case .github:
      return GitHubWire.mergeOptions(mergeable: "MERGEABLE", mergeState: clean)
    case .gitlab:
      return GitLabWire.mergeOptions(mergeState: clean, squashReadOnly: false, squashOnMerge: false)
    }
  }

  /// Whether the decoding layer of `kind` turns "Rerun failed" on for a failed check.
  private static func canRerunFailedChecks(_ kind: GitPlatformKind) -> Bool {
    switch kind {
    case .github:
      let failed = GitHubWire.RollupCheck(
        isCheckRun: true, conclusion: "FAILURE",
        detailsURL: "https://github.com/owner/repo/actions/runs/42/job/7")
      return !GitHubWire.failedWorkflowRunIDs([failed]).isEmpty
    case .gitlab:
      let failed = GitLabWire.Job(name: "test", status: "FAILED", allowFailure: false, manualJob: false)
      return GitLabWire.canRetryPipeline([failed])
    }
  }

  @Test(arguments: GitPlatformKind.allCases)
  func mergeCapabilitiesMatchTheMergeOptions(kind: GitPlatformKind) {
    let options = Self.mergeOptions(kind)
    #expect(options.map(\.strategy) == kind.supportedMergeStrategies)
    for option in options {
      #expect(kind.capability(.merge(option.strategy))?.title == option.displayName)
    }
  }

  @Test(arguments: GitPlatformKind.allCases)
  func rerunCapabilityMatchesTheDecodingLayer(kind: GitPlatformKind) {
    #expect(kind.capability(.rerunFailedChecks)?.isSupported == Self.canRerunFailedChecks(kind))
  }
}
