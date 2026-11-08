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
    try Self.parse(
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
    let result = try Self.parse(
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
    func decide(
      _ status: String = "MERGEABLE", approved: Bool = true, approvers: Int = 1, states: [String?] = [],
      complete: Bool = true
    ) -> ReviewDecision? {
      GitLabWire.reviewDecision(
        detailedMergeStatus: status, approved: approved, approverCount: approvers, reviewerStates: states,
        reviewersComplete: complete)
    }
    #expect(decide("NOT_APPROVED", approved: false, approvers: 0) == .reviewRequired)
    #expect(decide(approvers: 0) == nil)
    #expect(decide(states: ["APPROVED"]) == .approved)
    #expect(decide(states: ["REQUESTED_CHANGES"]) == .changesRequested)
    // A requested change stands even when other reviewers are missing.
    #expect(decide(states: [nil, "REQUESTED_CHANGES"], complete: false) == .changesRequested)
  }

  /// "Approved" needs complete reviewer data: a reviewer codans did not read, or one
  /// without a state, could have requested changes.
  @Test
  func incompleteReviewerDataIsNeverApproved() {
    func decide(states: [String?], complete: Bool) -> ReviewDecision? {
      GitLabWire.reviewDecision(
        detailedMergeStatus: "MERGEABLE", approved: true, approverCount: 1, reviewerStates: states,
        reviewersComplete: complete)
    }
    #expect(decide(states: ["APPROVED"], complete: false) == nil)
    #expect(decide(states: ["APPROVED", nil], complete: true) == nil)
    #expect(decide(states: [], complete: false) == nil)
  }

  /// The decoder reads completeness from the reviewer connection: a next page, a missing
  /// `pageInfo`, or a reviewer without `mergeRequestInteraction` withholds "approved".
  @Test(arguments: [
    #"{"pageInfo":{"hasNextPage":true,"endCursor":"r1"},"nodes":[{"mergeRequestInteraction":{"reviewState":"APPROVED"}}]}"#,
    #"{"nodes":[{"mergeRequestInteraction":{"reviewState":"APPROVED"}}]}"#,
    #"{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"mergeRequestInteraction":null}]}"#,
    #"{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"mergeRequestInteraction":{"reviewState":null}}]}"#,
  ])
  func approvedMergeRequestWithIncompleteReviewersHasNoDecision(reviewers: String) throws {
    let body = Self.approvedPage(reviewers: reviewers)
    let result = try Self.parse(Data(body.utf8), branches: ["feat-approved"], projectPath: "g/app", host: Self.host)
    #expect(try #require(result["feat-approved"]).reviewDecision == nil)
    let complete = Self.approvedPage(
      reviewers: #"{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}"#)
    let approved = try Self.parse(
      Data(complete.utf8), branches: ["feat-approved"], projectPath: "g/app", host: Self.host)
    #expect(approved["feat-approved"]?.reviewDecision == .approved)
  }

  nonisolated static func approvedPage(reviewers: String) -> String {
    """
    {"data":{"currentUser":{"username":"u"},"project":{"mergeRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
      {"iid":"16","state":"opened","sourceBranch":"feat-approved","targetBranch":"main","sourceProject":{"fullPath":"g/app"},
       "webUrl":"https://gitlab.example.com/g/app/-/merge_requests/16","detailedMergeStatus":"MERGEABLE",
       "approved":true,"approvedBy":{"nodes":[{"username":"r"}]},"reviewers":\(reviewers)}]}}}}
    """
  }

  // MARK: - degraded read

  /// The read without review and squash fields (`degradedQuery`) still gives the badge,
  /// the rollup, and the merge state; the review decision is absent and both merge
  /// options follow the merge state.
  @Test
  func degradedResponseDecodesWithoutReviewAndSquashFields() throws {
    let result = try Self.parse(
      Self.loadFixture("gitlab-graphql-batch-degraded"), branches: Self.appBranches, projectPath: "codans-e2e/app",
      host: Self.host)
    let full = try Self.app()
    #expect(Set(result.keys) == Set(full.keys))
    for (branch, snapshot) in result {
      #expect(snapshot.reviewDecision == nil, "\(branch)")
      #expect(snapshot.mergeState == full[branch]?.mergeState, "\(branch)")
      #expect(snapshot.checkRollup == full[branch]?.checkRollup, "\(branch)")
      #expect(snapshot.number == full[branch]?.number, "\(branch)")
    }
    let open = try #require(result["feat-open"])
    #expect(
      open.mergeOptions == [
        PullRequestMergeOption(strategy: .mergeCommit, isEnabled: true, label: "Merge"),
        PullRequestMergeOption(strategy: .squash, isEnabled: true),
      ])
  }

  /// Only an `errors` body whose every error is an unknown review or squash field asks
  /// for the degraded read.
  @Test
  func optionalFieldErrorDetection() throws {
    #expect(GitLabJSONParsers.isOptionalFieldError(try Self.loadFixture("gitlab-graphql-error-optional-fields")))
    // Unknown field outside the optional set.
    #expect(!GitLabJSONParsers.isOptionalFieldError(try Self.loadFixture("gitlab-graphql-error")))
    // Message only, without `extensions`.
    let messageOnly = #"{"errors":[{"message":"Field 'reviewState' doesn't exist on type 'UserMergeRequestInteraction'"}]}"#
    #expect(GitLabJSONParsers.isOptionalFieldError(Data(messageOnly.utf8)))
    // An optional field error next to another error.
    #expect(
      !GitLabJSONParsers.isOptionalFieldError(
        Data(
          #"{"errors":[{"message":"Field 'reviewState' doesn't exist on type 'X'","extensions":{"code":"undefinedField","fieldName":"reviewState"}},{"message":"Internal server error"}]}"#
            .utf8)))
    let timeout = #"{"errors":[{"message":"Timeout on validation of query"}]}"#
    #expect(!GitLabJSONParsers.isOptionalFieldError(Data(timeout.utf8)))
    #expect(!GitLabJSONParsers.isOptionalFieldError(Data(#"{"errors":[]}"#.utf8)))
    #expect(!GitLabJSONParsers.isOptionalFieldError(try Self.loadFixture("gitlab-graphql-batch-app")))
  }

  /// A later reviewer page decodes like the jobs page.
  @Test
  func reviewerPageCarriesItsNextCursor() throws {
    let page = try GitLabJSONParsers.parseReviewerPage(
      Data(
        #"{"data":{"project":{"mergeRequest":{"reviewers":{"pageInfo":{"hasNextPage":true,"endCursor":"r2"},"nodes":[{"mergeRequestInteraction":{"reviewState":"REQUESTED_CHANGES"}}]}}}}}"#
          .utf8))
    #expect(page.pageInfo?.hasNextPage == true)
    #expect(page.pageInfo?.endCursor == "r2")
    #expect(page.nodes?.map { $0.mergeRequestInteraction?.reviewState } == ["REQUESTED_CHANGES"])
    let noPageInfo = try GitLabJSONParsers.parseReviewerPage(
      Data(#"{"data":{"project":{"mergeRequest":{"reviewers":{"nodes":[]}}}}}"#.utf8))
    #expect(noPageInfo.pageInfo == nil)
    #expect(throws: GitPlatformError.other("reviewers: no reviewer list in the response")) {
      _ = try GitLabJSONParsers.parseReviewerPage(Data(#"{"data":{"project":null}}"#.utf8))
    }
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
    let result = try Self.parse(
      Self.loadFixture("gitlab-graphql-batch-app"), branches: ["feat-open"], projectPath: "codans-forker/app",
      host: Self.host)
    #expect(result["feat-open"]?.number == 13)
  }

  @Test
  func nestedGroupProject() throws {
    let result = try Self.parse(
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
    #expect(throws: GitPlatformError.notAuthenticated(.gitlab, host: "gitlab.com")) {
      _ = try Self.parse(
        Self.loadFixture("gitlab-graphql-batch-anonymous"), branches: ["main"], projectPath: "gitlab-org/cli",
        host: "gitlab.com")
    }
  }

  @Test
  func graphQLErrorsBodyThrows() {
    #expect(
      throws: GitPlatformError.graphQLError("Field 'approvalsLeft' doesn't exist on type 'MergeRequest' (Did you mean `approved`?)")
    ) {
      _ = try Self.parse(
        Self.loadFixture("gitlab-graphql-error"), branches: ["x"], projectPath: "codans-e2e/app", host: Self.host)
    }
  }

  @Test
  func unreadableBodyThrowsOther() {
    #expect(throws: GitPlatformError.self) {
      _ = try Self.parse(
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

  /// Decodes one complete page of the batched read into snapshots.
  nonisolated static func parse(
    _ data: Data, branches: [String], projectPath: String, host: String
  ) throws -> [String: PullRequestSnapshot] {
    let page = try GitLabJSONParsers.parseMergeRequestPage(data, host: host)
    #expect(page.nextCursor == nil)
    return GitLabJSONParsers.snapshots(from: page.nodes, branches: branches, projectPath: projectPath)
  }

  // MARK: - pages

  /// Page 1 of a 7-per-page read holds only the fork's newer MR !13 for `feat-open`; the
  /// project's own !1 is on page 2. Snapshots built from page 1 alone would pick the
  /// fork's MR, so the service reads every page first.
  @Test
  func pageCarriesItsNextCursor() throws {
    let first = try GitLabJSONParsers.parseMergeRequestPage(
      Self.loadFixture("gitlab-graphql-batch-app-page1"), host: Self.host)
    #expect(first.nodes.count == 7)
    #expect(first.nextCursor == "eyJ1cGRhdGVkX2F0IjoiMjAyNi0xMS0wMyAxNjo0OTozNy4yNDgwMjgwMDAgKzAwMDAiLCJpZCI6IjcifQ")
    let second = try GitLabJSONParsers.parseMergeRequestPage(
      Self.loadFixture("gitlab-graphql-batch-app-page2"), host: Self.host)
    #expect(second.nextCursor == nil)
    let onlyFirst = GitLabJSONParsers.snapshots(
      from: first.nodes, branches: ["feat-open"], projectPath: "codans-e2e/app")
    #expect(onlyFirst["feat-open"]?.number == 13)
    let all = GitLabJSONParsers.snapshots(
      from: first.nodes + second.nodes, branches: ["feat-open"], projectPath: "codans-e2e/app")
    #expect(all["feat-open"]?.number == 1)
  }

  @Test
  func connectionWithoutPageInfoIsAnError() {
    let noPageInfo = #"{"data":{"currentUser":{"username":"u"},"project":{"mergeRequests":{"nodes":[]}}}}"#
    #expect(throws: GitPlatformError.other("merge requests: response has no pageInfo")) {
      _ = try GitLabJSONParsers.parseMergeRequestPage(Data(noPageInfo.utf8), host: Self.host)
    }
    let jobsWithoutPageInfo =
      #"{"data":{"currentUser":{"username":"u"},"project":{"mergeRequests":{"pageInfo":{"hasNextPage":false},"nodes":[{"iid":"1","headPipeline":{"jobs":{"nodes":[]}}}]}}}}"#
    #expect(throws: GitPlatformError.other("pipeline jobs: response has no pageInfo")) {
      _ = try GitLabJSONParsers.parseMergeRequestPage(Data(jobsWithoutPageInfo.utf8), host: Self.host)
    }
    let nextWithoutCursor =
      #"{"data":{"currentUser":{"username":"u"},"project":{"mergeRequests":{"pageInfo":{"hasNextPage":true},"nodes":[]}}}}"#
    #expect(throws: GitPlatformError.other("merge requests: next page without endCursor")) {
      _ = try GitLabJSONParsers.parseMergeRequestPage(Data(nextWithoutCursor.utf8), host: Self.host)
    }
  }

  @Test
  func jobPageDecodes() throws {
    let first = try GitLabJSONParsers.parseJobPage(Self.loadFixture("gitlab-graphql-jobs-page1"))
    #expect(first.nodes.map(\.name) == ["fail"])
    #expect(first.nextCursor == "eyJpZCI6IjQzIn0")
    let last = try GitLabJSONParsers.parseJobPage(Self.loadFixture("gitlab-graphql-jobs-page2"))
    #expect(last.nodes.map(\.name) == ["pass"])
    #expect(last.nextCursor == nil)
    #expect(throws: GitPlatformError.self) {
      _ = try GitLabJSONParsers.parseJobPage(Data(#"{"data":{"project":{"mergeRequest":null}}}"#.utf8))
    }
  }

  nonisolated static func loadFixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures", isDirectory: true)
      .appendingPathComponent("\(name).json", isDirectory: false)
    return try Data(contentsOf: url)
  }
}
