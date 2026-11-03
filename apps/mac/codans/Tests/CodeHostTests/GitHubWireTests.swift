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
  func workflowRunRoundTrip() throws {
    let run = WorkflowRun(
      databaseID: 123_456_789, name: "CI", status: .completed, conclusion: .failure,
      headBranch: "feature/github01", headSHA: "aeafe6f012345", runNumber: 42,
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      url: URL(string: "https://github.com/owner/repo/actions/runs/123456789")!
    )
    let decoded = try JSONDecoder().decode(WorkflowRun.self, from: JSONEncoder().encode(run))
    #expect(decoded == run)
    #expect(decoded.id == run.databaseID)
  }
}
