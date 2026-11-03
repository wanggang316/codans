import CodansCore
import Foundation
import Testing

@testable import Codans

/// Decodes `glab api graphql` responses recorded from a GitLab CE 19.5 instance (the
/// `gitlab-graphql-*` fixtures) into the neutral snapshot. Each merge request state of
/// ADR 0004 items 6–9 has one fixture entry.
@MainActor
struct GitLabDecodingTests {
  private static let host = "192.168.2.158:8929"
  private static let appBranches = [
    "feat-open", "feat-draft", "feat-conflict", "feat-discussion", "feat-ci-fail", "feat-ci-running",
    "feat-allow-failure", "feat-manual", "feat-fixture-merged", "feat-fixture-closed",
    "feat-fixture-approved", "feat-fixture-changes", "feat-no-mr",
  ]

  private static func app() throws -> [String: PullRequestSnapshot] {
    try GitLabJSONParsers.parseBatchedMergeRequests(
      loadFixture("gitlab-graphql-batch-app"), branches: appBranches, projectPath: "codans-e2e/app", host: host)
  }

  private static func rollup(_ snapshot: PullRequestSnapshot) -> PullRequestBadge.CheckRollup {
    .from(checks: snapshot.checkRollup)
  }

  // MARK: - lifecycle

  @Test
  func openMergeRequestMapsEveryField() throws {
    let snapshot = try #require(try Self.app()["feat-open"])
    #expect(snapshot.number == 1)
    #expect(snapshot.title == "Open MR")
    #expect(snapshot.state == .open)
    #expect(!snapshot.isDraft)
    #expect(snapshot.headRefName == "feat-open")
    #expect(snapshot.author == "codans-dev")
    #expect(snapshot.additions == 1)
    #expect(snapshot.deletions == 0)
    #expect(snapshot.commitCount == 1)
    #expect(snapshot.url == URL(string: "http://192.168.2.158:8929/codans-e2e/app/-/merge_requests/1"))
    #expect(snapshot.mergeState == PullRequestMergeState(status: .clean))
    #expect(
      snapshot.mergeOptions == [
        PullRequestMergeOption(strategy: .mergeCommit, isEnabled: true, label: "Merge"),
        PullRequestMergeOption(strategy: .squash, isEnabled: true),
      ])
    #expect(snapshot.reviewDecision == nil)
    #expect(!snapshot.canRerunFailedChecks)
    #expect(snapshot.baseRefName == "main")
    #expect(snapshot.baseRepositoryURL == URL(string: "http://192.168.2.158:8929/codans-e2e/app"))
    let check = try #require(snapshot.checkRollup.first)
    #expect(check.name == "pass")
    #expect(check.status == .completed)
    #expect(check.conclusion == .success)
    #expect(check.detailsURL == URL(string: "http://192.168.2.158:8929/codans-e2e/app/-/jobs/1"))
    #expect(Self.rollup(snapshot) == .allPassing)
  }

  @Test
  func draftMergeRequest() throws {
    let snapshot = try #require(try Self.app()["feat-draft"])
    #expect(snapshot.isDraft)
    #expect(snapshot.mergeState == PullRequestMergeState(status: .draft, reason: "Merge request is a draft"))
    #expect(snapshot.mergeOptions.allSatisfy { !$0.isEnabled })
  }

  @Test
  func mergedAndClosedMergeRequests() throws {
    let result = try Self.app()
    let merged = try #require(result["feat-fixture-merged"])
    #expect(merged.number == 15)
    #expect(merged.state == .merged)
    #expect(merged.mergeState == PullRequestMergeState(status: .unknown))
    let closed = try #require(result["feat-fixture-closed"])
    #expect(closed.number == 14)
    #expect(closed.state == .closed)
  }

  @Test
  func branchWithoutMergeRequestIsAbsent() throws {
    #expect(try Self.app()["feat-no-mr"] == nil)
  }

  // MARK: - merge state

  @Test
  func conflictedMergeRequest() throws {
    let snapshot = try #require(try Self.app()["feat-conflict"])
    #expect(snapshot.hasMergeConflict)
    #expect(snapshot.mergeState.reason == "Merge request has merge conflicts")
    #expect(snapshot.mergeOption(for: .mergeCommit)?.disabledReason == "Merge request has merge conflicts")
  }

  @Test
  func discussionsNotResolvedBlocksWithReason() throws {
    let snapshot = try #require(try Self.app()["feat-discussion"])
    #expect(snapshot.mergeState == PullRequestMergeState(status: .blocked, reason: "All threads must be resolved"))
    #expect(snapshot.mergeOptions.allSatisfy { !$0.isEnabled })
  }

  /// A fast-forward project with squash "never": behind, and squash off with its reason.
  @Test
  func behindMergeRequestInANoSquashProject() throws {
    let result = try GitLabJSONParsers.parseBatchedMergeRequests(
      Self.loadFixture("gitlab-graphql-batch-no-squash"), branches: ["feat-behind", "feat-no-squash"],
      projectPath: "codans-e2e/no-squash", host: Self.host)
    let snapshot = try #require(result["feat-behind"])
    #expect(snapshot.mergeState.status == .behind)
    #expect(snapshot.mergeState.reason == "Source branch is behind the target branch — rebase required")
    let squash = try #require(snapshot.mergeOption(for: .squash))
    #expect(!squash.isEnabled)
    #expect(squash.disabledReason == "This project does not allow squash")
    #expect(snapshot.mergeStrategy(preferring: .squash) == .squash)
    #expect(snapshot.mergeStrategy(preferring: .rebase) == .mergeCommit)
  }

  // MARK: - pipeline

  @Test
  func failedPipelineBlocksAndCanRerun() throws {
    let snapshot = try #require(try Self.app()["feat-ci-fail"])
    #expect(snapshot.mergeState == PullRequestMergeState(status: .blocked, reason: "The pipeline must succeed"))
    #expect(snapshot.checkRollup.first { $0.name == "fail" }?.conclusion == .failure)
    #expect(snapshot.canRerunFailedChecks)
    #expect(Self.rollup(snapshot) == .anyFailing)
  }

  /// The retried run of `slow` is left out (`jobs(retried: false)`); the current run is
  /// in progress.
  @Test
  func runningPipelineIsPending() throws {
    let snapshot = try #require(try Self.app()["feat-ci-running"])
    #expect(snapshot.mergeState == PullRequestMergeState(status: .blocked, reason: "The pipeline is still running"))
    #expect(snapshot.checkRollup.map(\.name).sorted() == ["pass", "slow"])
    #expect(snapshot.checkRollup.first { $0.name == "slow" }?.status == .inProgress)
    #expect(!snapshot.canRerunFailedChecks)
    #expect(Self.rollup(snapshot) == .anyPending)
  }

  @Test
  func allowFailureFailureIsNeutral() throws {
    let snapshot = try #require(try Self.app()["feat-allow-failure"])
    #expect(snapshot.mergeState.status == .clean)
    let optional = try #require(snapshot.checkRollup.first { $0.name == "optional" })
    #expect(optional.status == .completed)
    #expect(optional.conclusion == .neutral)
    #expect(!snapshot.canRerunFailedChecks)
    #expect(Self.rollup(snapshot) == .allPassing)
  }

  @Test
  func manualJobThatDidNotRunIsSkipped() throws {
    let snapshot = try #require(try Self.app()["feat-manual"])
    let deploy = try #require(snapshot.checkRollup.first { $0.name == "deploy" })
    #expect(deploy.status == .completed)
    #expect(deploy.conclusion == .skipped)
    #expect(Self.rollup(snapshot) == .allPassing)
  }

  // MARK: - review decision

  @Test
  func approvedMergeRequest() throws {
    #expect(try Self.app()["feat-fixture-approved"]?.reviewDecision == .approved)
  }

  @Test
  func changesRequestedMergeRequest() throws {
    #expect(try Self.app()["feat-fixture-changes"]?.reviewDecision == .changesRequested)
  }

  @Test
  func reviewDecisionRules() {
    #expect(
      GitLabWire.reviewDecision(detailedMergeStatus: "NOT_APPROVED", approved: false, approverCount: 0, reviewerStates: [])
        == .reviewRequired)
    #expect(
      GitLabWire.reviewDecision(detailedMergeStatus: "MERGEABLE", approved: true, approverCount: 0, reviewerStates: [])
        == nil)
    #expect(
      GitLabWire.reviewDecision(
        detailedMergeStatus: "MERGEABLE", approved: true, approverCount: 1, reviewerStates: ["REQUESTED_CHANGES"])
        == .changesRequested)
  }

  // MARK: - fork filter, nested group

  /// `codans-forker/app` has an MR from its own `feat-open` into `codans-e2e/app`. The
  /// fetch unit's own MR wins, though the fork's MR is newer.
  @Test
  func forkMergeRequestWithSameNamedBranchIsFilteredOut() throws {
    let snapshot = try #require(try Self.app()["feat-open"])
    #expect(snapshot.number == 1)
    #expect(snapshot.headRepositoryOwner == "codans-e2e/app")
  }

  /// The rule compares the source project with the fetch unit's project: seen from the
  /// fork, the fork's MR is the unit's own.
  @Test
  func forkFilterComparesTheSourceProjectPath() throws {
    let result = try GitLabJSONParsers.parseBatchedMergeRequests(
      Self.loadFixture("gitlab-graphql-batch-app"), branches: ["feat-open"], projectPath: "codans-forker/app",
      host: Self.host)
    #expect(result["feat-open"]?.number == 13)
  }

  @Test
  func nestedGroupProject() throws {
    let result = try GitLabJSONParsers.parseBatchedMergeRequests(
      Self.loadFixture("gitlab-graphql-batch-nested"), branches: ["feat-nested"],
      projectPath: "codans-e2e/nested/deep-app", host: Self.host)
    let snapshot = try #require(result["feat-nested"])
    #expect(snapshot.number == 1)
    #expect(snapshot.url == URL(string: "http://192.168.2.158:8929/codans-e2e/nested/deep-app/-/merge_requests/1"))
    #expect(snapshot.baseRepositoryURL == URL(string: "http://192.168.2.158:8929/codans-e2e/nested/deep-app"))
    #expect(snapshot.headRepositoryOwner == "codans-e2e/nested/deep-app")
  }

  // MARK: - errors

  @Test
  func anonymousAnswerMeansNotLoggedIn() {
    #expect(throws: CodeHostError.notAuthenticated(.gitlab, host: "gitlab.com")) {
      _ = try GitLabJSONParsers.parseBatchedMergeRequests(
        Self.loadFixture("gitlab-graphql-batch-anonymous"), branches: ["main"], projectPath: "gitlab-org/cli",
        host: "gitlab.com")
    }
  }

  @Test
  func graphQLErrorsBodyThrows() {
    #expect(
      throws: CodeHostError.graphQLError("Field 'approvalsLeft' doesn't exist on type 'MergeRequest' (Did you mean `approved`?)")
    ) {
      _ = try GitLabJSONParsers.parseBatchedMergeRequests(
        Self.loadFixture("gitlab-graphql-error"), branches: ["x"], projectPath: "codans-e2e/app", host: Self.host)
    }
  }

  @Test
  func unreadableBodyThrowsOther() {
    #expect(throws: CodeHostError.self) {
      _ = try GitLabJSONParsers.parseBatchedMergeRequests(
        Data("not json".utf8), branches: ["x"], projectPath: "a/b", host: Self.host)
    }
  }

  // MARK: - wire mapping

  @Test
  func detailedMergeStatusMapping() {
    #expect(GitLabWire.mergeState(detailedMergeStatus: "NEED_REBASE").status == .behind)
    #expect(GitLabWire.mergeState(detailedMergeStatus: "NOT_APPROVED").reason == "Approvals are required")
    #expect(GitLabWire.mergeState(detailedMergeStatus: "CHECKING").status == .unknown)
    #expect(GitLabWire.mergeState(detailedMergeStatus: "UNCHECKED").status == .unknown)
    #expect(GitLabWire.mergeState(detailedMergeStatus: nil).status == .unknown)
    let future = GitLabWire.mergeState(detailedMergeStatus: "SOME_NEW_RULE")
    #expect(future.status == .blocked)
    #expect(future.reason == "Merge blocked by GitLab (some new rule)")
  }

  @Test
  func squashAlwaysTurnsPlainMergeOff() {
    let options = GitLabWire.mergeOptions(
      mergeState: PullRequestMergeState(status: .clean), squashReadOnly: true, squashOnMerge: true)
    #expect(options[0].strategy == .mergeCommit)
    #expect(!options[0].isEnabled)
    #expect(options[0].disabledReason == "This project squashes every merge request")
    #expect(options[1].isEnabled)
  }

  @Test
  func jobStatusMapping() {
    func map(_ status: String, allowFailure: Bool = false) -> (CheckStatus, CheckConclusion?) {
      GitLabWire.check(.init(name: "j", status: status, allowFailure: allowFailure, manualJob: false))
    }
    #expect(map("CREATED") == (.queued, nil))
    #expect(map("PENDING") == (.pending, nil))
    #expect(map("RUNNING") == (.inProgress, nil))
    #expect(map("SCHEDULED") == (.waiting, nil))
    #expect(map("FAILED") == (.completed, .failure))
    #expect(map("FAILED", allowFailure: true) == (.completed, .neutral))
    #expect(map("CANCELED") == (.completed, .cancelled))
    #expect(map("MANUAL") == (.completed, .skipped))
    #expect(map("SKIPPED") == (.completed, .skipped))
  }

  @Test
  func stateMapping() {
    #expect(GitLabWire.pullRequestState("opened") == .open)
    #expect(GitLabWire.pullRequestState("locked") == .open)
    #expect(GitLabWire.pullRequestState("merged") == .merged)
    #expect(GitLabWire.pullRequestState("closed") == .closed)
    #expect(GitLabWire.pullRequestState("other") == nil)
  }

  nonisolated static func loadFixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures", isDirectory: true)
      .appendingPathComponent("\(name).json", isDirectory: false)
    return try Data(contentsOf: url)
  }
}
