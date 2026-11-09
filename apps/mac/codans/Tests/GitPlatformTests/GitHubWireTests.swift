import CodansCore
import Foundation
import Testing

@testable import Codans

/// GitHub wire values → provider-neutral model. These assertions used to pin the core
/// enums' raw values to GitHub strings; only the GitHub decoding layer knows them now.
struct GitHubWireTests {
  @Test
  func pullRequestStates() {
    #expect(GitHubWire.pullRequestState("OPEN") == .open)
    #expect(GitHubWire.pullRequestState("MERGED") == .merged)
    #expect(GitHubWire.pullRequestState("CLOSED") == .closed)
    #expect(GitHubWire.pullRequestState("NEW_CASE") == nil)
  }

  @Test
  func checkStatuses() {
    #expect(GitHubWire.checkStatus("QUEUED") == .queued)
    #expect(GitHubWire.checkStatus("IN_PROGRESS") == .inProgress)
    #expect(GitHubWire.checkStatus("COMPLETED") == .completed)
    #expect(GitHubWire.checkStatus("WAITING") == .waiting)
    #expect(GitHubWire.checkStatus("PENDING") == .pending)
    #expect(GitHubWire.checkStatus("REQUESTED") == nil)
  }

  @Test
  func checkConclusions() {
    let pairs: [(String, CheckConclusion)] = [
      ("SUCCESS", .success), ("FAILURE", .failure), ("CANCELLED", .cancelled),
      ("SKIPPED", .skipped), ("NEUTRAL", .neutral), ("TIMED_OUT", .timedOut),
      ("ACTION_REQUIRED", .actionRequired), ("STALE", .stale), ("STARTUP_FAILURE", .startupFailure),
    ]
    for (wire, expected) in pairs {
      #expect(GitHubWire.checkConclusion(wire) == expected)
    }
    #expect(GitHubWire.checkConclusion("") == nil)
  }

  @Test
  func reviewDecisionUnknownIsNil() {
    #expect(GitHubWire.reviewDecision("APPROVED") == .approved)
    #expect(GitHubWire.reviewDecision("CHANGES_REQUESTED") == .changesRequested)
    #expect(GitHubWire.reviewDecision("REVIEW_REQUIRED") == .reviewRequired)
    #expect(GitHubWire.reviewDecision("UNEXPECTED_NEW_CASE") == nil)
    #expect(GitHubWire.reviewDecision("") == nil)
    #expect(GitHubWire.reviewDecision(nil) == nil)
  }

  @Test
  func mergeStateStatuses() {
    func status(_ mergeable: String?, _ mss: String?) -> PullRequestMergeState.Status {
      GitHubWire.mergeState(mergeable: mergeable, mergeStateStatus: mss).status
    }
    #expect(status("MERGEABLE", "CLEAN") == .clean)
    #expect(status("MERGEABLE", "HAS_HOOKS") == .clean)
    #expect(status("MERGEABLE", "UNSTABLE") == .clean)
    #expect(status("CONFLICTING", "DIRTY") == .conflicted)
    #expect(status("CONFLICTING", "UNKNOWN") == .conflicted)
    #expect(status("MERGEABLE", "BLOCKED") == .blocked)
    #expect(status("MERGEABLE", "BEHIND") == .behind)
    #expect(status("MERGEABLE", "DRAFT") == .draft)
    #expect(status("UNKNOWN", "UNKNOWN") == .unknown)
    #expect(status(nil, "UNEXPECTED_NEW_CASE") == .unknown)
  }

  @Test
  func mergeStateReasonsKeepThePopoverOrder() {
    func reason(_ mergeable: String?, _ mss: String?) -> String? {
      GitHubWire.mergeState(mergeable: mergeable, mergeStateStatus: mss).reason
    }
    #expect(reason("MERGEABLE", "CLEAN") == nil)
    #expect(reason("CONFLICTING", "DIRTY") == "Pull request has merge conflicts")
    #expect(reason("MERGEABLE", "BLOCKED") == "Merge blocked by required checks or reviews")
    #expect(reason("MERGEABLE", "BEHIND") == "Behind base branch — update required before merge")
    #expect(reason("CONFLICTING", "CLEAN") == "Pull request has merge conflicts")
    #expect(reason("UNKNOWN", "CLEAN") == "Merge status unknown — try refresh")
    #expect(reason("MERGEABLE", "UNKNOWN") == nil)
  }

  @Test
  func mergeOptionsFollowMergeable() {
    let blocked = GitHubWire.mergeState(mergeable: "CONFLICTING", mergeStateStatus: "DIRTY")
    let disabled = GitHubWire.mergeOptions(mergeable: "CONFLICTING", mergeState: blocked)
    #expect(disabled.map(\.strategy) == MergeStrategy.allCases)
    #expect(disabled.allSatisfy { !$0.isEnabled && $0.disabledReason == "Pull request has merge conflicts" })

    let clean = GitHubWire.mergeState(mergeable: "MERGEABLE", mergeStateStatus: "CLEAN")
    let enabled = GitHubWire.mergeOptions(mergeable: "MERGEABLE", mergeState: clean)
    #expect(enabled.allSatisfy { $0.isEnabled && $0.disabledReason == nil })
  }

  @Test
  func failedWorkflowRunIDsComeOnlyFromFailedActionsCheckRuns() {
    let checks: [GitHubWire.RollupCheck] = [
      .init(isCheckRun: true, conclusion: "FAILURE", detailsURL: "https://github.com/o/r/actions/runs/111/job/1"),
      .init(isCheckRun: true, conclusion: "FAILURE", detailsURL: "https://github.com/o/r/actions/runs/111/job/2"),
      .init(isCheckRun: true, conclusion: "SUCCESS", detailsURL: "https://github.com/o/r/actions/runs/222/job/3"),
      .init(isCheckRun: true, conclusion: "FAILURE", detailsURL: "https://app.example.com/checks/9"),
      .init(isCheckRun: false, conclusion: "FAILURE", detailsURL: "https://github.com/o/r/actions/runs/333/job/4"),
      .init(isCheckRun: true, conclusion: "FAILURE", detailsURL: "https://ghe.example.com/o/r/actions/runs/444/job/5"),
    ]
    #expect(GitHubWire.failedWorkflowRunIDs(checks) == [111, 444])
  }

  /// The run id sits at a fixed place after `<owner>/<repo>`, so an owner or a repository
  /// named `actions` must not be taken for the `actions/runs` segment.
  @Test
  func failedWorkflowRunIDsAcceptAnOwnerOrRepositoryNamedActions() {
    let checks: [GitHubWire.RollupCheck] = [
      .init(isCheckRun: true, conclusion: "FAILURE", detailsURL: "https://github.com/actions/checkout/actions/runs/123/job/4"),
      .init(isCheckRun: true, conclusion: "FAILURE", detailsURL: "https://github.com/acme/actions/actions/runs/456/job/7"),
      .init(isCheckRun: true, conclusion: "FAILURE", detailsURL: "https://github.com/actions/actions/actions/runs/789/job/1"),
    ]
    #expect(GitHubWire.failedWorkflowRunIDs(checks) == [123, 456, 789])
  }

  @Test
  func failedWorkflowRunIDsRejectOtherPathShapes() {
    let checks: [GitHubWire.RollupCheck] = [
      // `actions/runs` not right after owner/repo.
      .init(isCheckRun: true, conclusion: "FAILURE", detailsURL: "https://github.com/o/r/pull/1/actions/runs/5"),
      .init(isCheckRun: true, conclusion: "FAILURE", detailsURL: "https://github.com/actions/runs/9/job/1"),
      .init(isCheckRun: true, conclusion: "FAILURE", detailsURL: "https://github.com/o/r/actions/runs/abc/job/1"),
    ]
    #expect(GitHubWire.failedWorkflowRunIDs(checks).isEmpty)
  }

  @Test
  func noFailedWorkflowRunMeansNoRerun() {
    let checks: [GitHubWire.RollupCheck] = [
      .init(isCheckRun: true, conclusion: "SUCCESS", detailsURL: "https://github.com/o/r/actions/runs/222/job/3")
    ]
    #expect(GitHubWire.failedWorkflowRunIDs(checks).isEmpty)
  }
}
