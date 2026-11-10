import CodansCore
import Foundation
import Testing

@testable import Codans

/// `GitLabGitPlatform` through `RecordingCommandRunner`: the exact argv and env sent to
/// `glab` for every read and write, and how each outcome maps to a result or a
/// `GitPlatformError`.
struct GitLabGitPlatformTests {
  private static let exec = URL(fileURLWithPath: "/opt/homebrew/bin/glab")
  private static let selfManaged = GitPlatformRepository(
    kind: .gitlab, host: "gitlab.example.com", path: "group/sub/app")
  private static let withPort = GitPlatformRepository(kind: .gitlab, host: "192.168.2.158:8929", path: "codans-e2e/app")

  private static func ok(_ stdout: String = "") -> CommandOutcome {
    .exited(code: 0, stdout: Data(stdout.utf8), stderr: Data(), stdoutOverflow: false)
  }

  private static func failed(stdout: String = "", stderr: String) -> CommandOutcome {
    .exited(code: 1, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), stdoutOverflow: false)
  }

  private static let version = ok("glab 1.128.0 (519ea19f7)\n")

  private static func makeService(_ runner: RecordingCommandRunner) -> GitLabGitPlatform {
    GitLabGitPlatform(runner: runner, resolver: CLIExecutableResolver(prober: { exec }), configHosts: { [] })
  }

  // MARK: - availability

  @Test
  func availabilityReportsMissingGlab() async {
    let service = GitLabGitPlatform(runner: RecordingCommandRunner(outcomes: []), resolver: .init(prober: { nil }))
    #expect(await service.availability() == .notInstalled)
    #expect(GitPlatformError.cliNotInstalled(.gitlab).userFacingMessage.contains("brew install glab"))
  }

  @Test
  func availabilityReportsOutdatedGlab() async {
    let runner = RecordingCommandRunner(outcomes: [Self.ok("glab version 1.40.0 (2024-05-01)\n")])
    let result = await Self.makeService(runner).availability()
    #expect(result == .unavailable(reason: GitPlatformError.cliOutdated(.gitlab, minVersion: "1.122.0").userFacingMessage))
    #expect(await runner.calls.map(\.arguments) == [["version"]])
  }

  @Test
  func availabilityReportsNotLoggedIn() async throws {
    let none = try GitLabDecodingTests.loadFixture("glab-auth-status-none")
    let runner = RecordingCommandRunner(outcomes: [
      Self.version, .exited(code: 1, stdout: none, stderr: Data(), stdoutOverflow: false),
    ])
    let result = await Self.makeService(runner).availability()
    #expect(result == .notLoggedIn(host: nil))
    #expect(GitPlatformError.notAuthenticated(.gitlab, host: nil).userFacingMessage.contains("glab auth login"))
  }

  /// Exit 1 because gitlab.com fails its check; the self-managed host is logged in.
  @Test
  func availabilityFromAMixedAuthStatus() async throws {
    let mixed = try GitLabDecodingTests.loadFixture("glab-auth-status-mixed")
    let runner = RecordingCommandRunner(outcomes: [
      Self.version, .exited(code: 1, stdout: mixed, stderr: Data(), stdoutOverflow: false),
      .exited(code: 1, stdout: mixed, stderr: Data(), stdoutOverflow: false),
    ])
    let service = Self.makeService(runner)
    #expect(await service.availability() == .available(host: "192.168.2.158:8929", user: "codans-dev"))
    #expect(await service.availability() == .available(host: "192.168.2.158:8929", user: "codans-dev"))
    let calls = await runner.calls
    #expect(calls.map(\.arguments) == [["version"], ["auth", "status", "--all", "--output", "json"], ["auth", "status", "--all", "--output", "json"]])
    // The version is checked once per executable.
    #expect(calls.filter { $0.arguments == ["version"] }.count == 1)
    #expect(calls.allSatisfy { $0.cwd == GitLabGitPlatform.homeDirectory })
    #expect(calls.allSatisfy { $0.launch == .loginShell })
  }

  // MARK: - batched read

  @Test
  func batchReadArgvForAHostWithoutPort() async throws {
    let fixture = try GitLabDecodingTests.loadFixture("gitlab-graphql-batch-nested")
    let runner = RecordingCommandRunner(outcomes: [
      Self.version, .exited(code: 0, stdout: fixture, stderr: Data(), stdoutOverflow: false),
    ])
    let result = try await Self.makeService(runner).batchPullRequests(
      repository: Self.selfManaged, branches: ["feat-nested", "feat/with-slash"])
    #expect(result["feat-nested"]?.number == 1)
    let call = try #require(await runner.calls.last)
    #expect(
      call.arguments == [
        "api", "graphql", "--hostname", "gitlab.example.com", "-f", "query=\(GitLabMergeRequestQuery.query)",
        "-f", "fullPath=group/sub/app", "-F", #"branches=["feat-nested","feat/with-slash"]"#,
      ])
    #expect(call.env["GITLAB_HOST"] == "gitlab.example.com")
    #expect(call.maxOutputBytes == GitLabGitPlatform.readMaxOutputBytes)
    #expect(call.cwd == GitLabGitPlatform.homeDirectory)
  }

  /// `glab --hostname` rejects `host:port`, so the host goes only through `GITLAB_HOST`.
  @Test
  func batchReadForAHostWithPortUsesGitLabHostOnly() async throws {
    let fixture = try GitLabDecodingTests.loadFixture("gitlab-graphql-batch-app")
    let runner = RecordingCommandRunner(outcomes: [
      Self.version, .exited(code: 0, stdout: fixture, stderr: Data(), stdoutOverflow: false),
    ])
    _ = try await Self.makeService(runner).batchPullRequests(repository: Self.withPort, branches: ["feat-open"])
    let call = try #require(await runner.calls.last)
    #expect(!call.arguments.contains("--hostname"))
    #expect(call.env["GITLAB_HOST"] == "192.168.2.158:8929")
  }

  @Test
  func batchReadWithNoBranchesSpawnsNothing() async throws {
    let runner = RecordingCommandRunner(outcomes: [])
    #expect(try await Self.makeService(runner).batchPullRequests(repository: Self.withPort, branches: []).isEmpty)
    #expect(await runner.calls.isEmpty)
  }

  @Test
  func batchReadChunksBranches() async throws {
    let empty = Self.ok(Self.emptyPage)
    let runner = RecordingCommandRunner(outcomes: [Self.version, empty, empty])
    let branches = (0..<25).map { "b\($0)" }
    _ = try await Self.makeService(runner).batchPullRequests(repository: Self.withPort, branches: branches)
    #expect(await runner.calls.filter { $0.arguments.starts(with: ["api", "graphql"]) }.count == 2)
  }

  @Test
  func batchReadRejectsControlCharactersBeforeSpawn() async {
    let runner = RecordingCommandRunner(outcomes: [Self.version])
    await #expect(throws: GitPlatformError.malformedBranchName("bad\nname")) {
      _ = try await Self.makeService(runner).batchPullRequests(repository: Self.withPort, branches: ["bad\nname"])
    }
    #expect(await runner.calls.map(\.arguments) == [["version"]])
  }

  // MARK: - error translation

  @Test
  func batchReadWithoutGlabThrowsNotInstalled() async {
    let service = GitLabGitPlatform(runner: RecordingCommandRunner(outcomes: []), resolver: .init(prober: { nil }))
    await #expect(throws: GitPlatformError.cliNotInstalled(.gitlab)) {
      _ = try await service.batchPullRequests(repository: Self.withPort, branches: ["main"])
    }
  }

  @Test
  func batchReadWithOutdatedGlabThrowsOutdated() async {
    let runner = RecordingCommandRunner(outcomes: [Self.ok("glab 1.121.9 (abc)\n")])
    await #expect(throws: GitPlatformError.cliOutdated(.gitlab, minVersion: "1.122.0")) {
      _ = try await Self.makeService(runner).batchPullRequests(repository: Self.withPort, branches: ["main"])
    }
  }

  @Test
  func batchReadAnsweredAnonymouslyThrowsNotAuthenticated() async throws {
    let anonymous = try GitLabDecodingTests.loadFixture("gitlab-graphql-batch-anonymous")
    let runner = RecordingCommandRunner(outcomes: [
      Self.version, .exited(code: 0, stdout: anonymous, stderr: Data(), stdoutOverflow: false),
    ])
    let repository = GitPlatformRepository(kind: .gitlab, host: "gitlab.com", path: "gitlab-org/cli")
    await #expect(throws: GitPlatformError.notAuthenticated(.gitlab, host: "gitlab.com")) {
      _ = try await Self.makeService(runner).batchPullRequests(repository: repository, branches: ["main"])
    }
  }

  @Test
  func unauthorizedResponseThrowsNotAuthenticated() async {
    let runner = RecordingCommandRunner(outcomes: [
      Self.version, Self.failed(stdout: #"{"message":"401 Unauthorized"}"#, stderr: "glab: 401 Unauthorized (HTTP 401)"),
    ])
    await #expect(throws: GitPlatformError.notAuthenticated(.gitlab, host: "192.168.2.158:8929")) {
      try await Self.makeService(runner).close(PullRequestReference(repository: Self.withPort, number: 3))
    }
  }

  @Test
  func graphQLErrorOnExitOneThrowsGraphQLError() async throws {
    let body = try GitLabDecodingTests.loadFixture("gitlab-graphql-error")
    let runner = RecordingCommandRunner(outcomes: [
      Self.version,
      .exited(code: 1, stdout: body, stderr: Data("glab: Field 'approvalsLeft' doesn't exist".utf8), stdoutOverflow: false),
    ])
    await #expect(throws: GitPlatformError.self) {
      _ = try await Self.makeService(runner).batchPullRequests(repository: Self.withPort, branches: ["main"])
    }
    do {
      _ = try await Self.makeService(
        RecordingCommandRunner(outcomes: [
          Self.version, .exited(code: 1, stdout: body, stderr: Data(), stdoutOverflow: false),
        ])
      ).batchPullRequests(repository: Self.withPort, branches: ["main"])
    } catch let error as GitPlatformError {
      guard case .graphQLError(let message) = error else {
        Issue.record("expected .graphQLError, got \(error)")
        return
      }
      #expect(message.contains("approvalsLeft"))
    }
  }

  @Test
  func networkFailureThrowsNetwork() async {
    let runner = RecordingCommandRunner(outcomes: [
      Self.version,
      Self.failed(stderr: "          \n   ERROR  \n          \n  Post \"https://10.0.0.1/api/graphql\": dial tcp 10.0.0.1:443: i/o timeout.\n"),
    ])
    await #expect(throws: GitPlatformError.network("post \"https://10.0.0.1/api/graphql\": dial tcp 10.0.0.1:443: i/o timeout.")) {
      _ = try await Self.makeService(runner).batchPullRequests(repository: Self.withPort, branches: ["main"])
    }
  }

  @Test
  func timeoutThrowsTimeout() async {
    let runner = RecordingCommandRunner(outcomes: [Self.version, .timedOut])
    await #expect(throws: GitPlatformError.timeout) {
      _ = try await Self.makeService(runner).batchPullRequests(repository: Self.withPort, branches: ["main"])
    }
  }

  @Test
  func oversizeOutputThrowsOversize() async {
    let runner = RecordingCommandRunner(outcomes: [
      Self.version, .exited(code: 0, stdout: Data(), stderr: Data(), stdoutOverflow: true),
    ])
    await #expect(throws: GitPlatformError.oversizeResponse(bytes: GitLabGitPlatform.readMaxOutputBytes)) {
      _ = try await Self.makeService(runner).batchPullRequests(repository: Self.withPort, branches: ["main"])
    }
  }

  @Test
  func spawnFailureThrowsNotInstalled() async {
    let runner = RecordingCommandRunner(outcomes: [Self.version, .spawnFailed(reason: "ENOENT")])
    await #expect(throws: GitPlatformError.cliNotInstalled(.gitlab)) {
      _ = try await Self.makeService(runner).batchPullRequests(repository: Self.withPort, branches: ["main"])
    }
  }

  // MARK: - writes

  @Test
  func mergeArgvUsesTheProjectMergeMethod() async throws {
    for (strategy, squash) in [(MergeStrategy.mergeCommit, "false"), (.rebase, "false"), (.squash, "true")] {
      let runner = RecordingCommandRunner(outcomes: [Self.version, Self.ok("{}")])
      try await Self.makeService(runner).merge(
        PullRequestReference(repository: Self.selfManaged, number: 7), strategy: strategy, headSHA: "abc123")
      let call = try #require(await runner.calls.last)
      #expect(
        call.arguments == [
          "api", "projects/group%2Fsub%2Fapp/merge_requests/7/merge", "--method", "PUT", "--hostname",
          "gitlab.example.com", "-F", "squash=\(squash)", "-f", "sha=abc123",
        ])
      #expect(call.env["GITLAB_HOST"] == "gitlab.example.com")
      #expect(call.cwd == GitLabGitPlatform.homeDirectory)
    }
  }

  @Test
  func mergeRefusalThrowsMergeConflict() async {
    let runner = RecordingCommandRunner(outcomes: [
      Self.version, Self.failed(stdout: #"{"message":"405 Method Not Allowed"}"#, stderr: "glab: 405 Method Not Allowed (HTTP 405)"),
    ])
    await #expect(throws: GitPlatformError.mergeConflict) {
      try await Self.makeService(runner).merge(
        PullRequestReference(repository: Self.withPort, number: 1), strategy: .squash, headSHA: "abc123")
    }
  }

  /// GitLab refuses a merge whose `sha` is not the source branch head with HTTP 409. It
  /// is not a merge conflict: the branch has new commits.
  @Test
  func mergeWithAMovedHeadThrowsHeadMoved() async {
    let runner = RecordingCommandRunner(outcomes: [
      Self.version,
      Self.failed(
        stdout: #"{"message":"SHA does not match HEAD of source branch: 9f8e7d6c5b4a"}"#,
        stderr: "glab: SHA does not match HEAD of source branch: 9f8e7d6c5b4a (HTTP 409)"),
    ])
    await #expect(throws: GitPlatformError.headMoved) {
      try await Self.makeService(runner).merge(
        PullRequestReference(repository: Self.withPort, number: 1), strategy: .squash, headSHA: "abc123")
    }
  }

  @Test
  func closeArgv() async throws {
    let runner = RecordingCommandRunner(outcomes: [Self.version, Self.ok("{}")])
    try await Self.makeService(runner).close(PullRequestReference(repository: Self.withPort, number: 10))
    #expect(
      await runner.calls.last?.arguments == [
        "api", "projects/codans-e2e%2Fapp/merge_requests/10", "--method", "PUT", "-f", "state_event=close",
      ])
  }

  private static let emptyPage =
    #"{"data":{"currentUser":{"username":"u"},"project":{"mergeRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}"#

  // MARK: - pagination

  /// The read follows `endCursor` until the last page and builds snapshots from all of
  /// them: page 1 holds only the fork's !13 for `feat-open`, the project's !1 is on page 2.
  @Test
  func batchReadFollowsEveryMergeRequestPage() async throws {
    let page1 = try GitLabDecodingTests.loadFixture("gitlab-graphql-batch-app-page1")
    let page2 = try GitLabDecodingTests.loadFixture("gitlab-graphql-batch-app-page2")
    let runner = RecordingCommandRunner(outcomes: [
      Self.version, .exited(code: 0, stdout: page1, stderr: Data(), stdoutOverflow: false),
      .exited(code: 0, stdout: page2, stderr: Data(), stdoutOverflow: false),
    ])
    let result = try await Self.makeService(runner).batchPullRequests(
      repository: Self.withPort, branches: ["feat-open", "feat-ci-fail", "feat-draft"])
    #expect(result["feat-open"]?.number == 1)
    #expect(result["feat-ci-fail"]?.number == 4)
    #expect(result["feat-draft"]?.number == 12)
    let reads = await runner.calls.filter { $0.arguments.starts(with: ["api", "graphql"]) }.map(\.arguments)
    #expect(reads.count == 2)
    #expect(!reads[0].contains { $0.hasPrefix("after=") })
    #expect(reads[1].contains("after=eyJ1cGRhdGVkX2F0IjoiMjAyNi0xMS0wMyAxNjo0OTozNy4yNDgwMjgwMDAgKzAwMDAiLCJpZCI6IjcifQ"))
  }

  /// A head pipeline with more jobs than the first page: the rest is read per merge
  /// request, so a failed job on a later page reaches the rollup and "Rerun failed".
  @Test
  func batchReadFollowsEveryJobPage() async throws {
    let truncated = #"""
      {"data":{"currentUser":{"username":"u"},"project":{"mergeRequests":{"pageInfo":{"hasNextPage":false,"endCursor":"m"},"nodes":[
        {"iid":"4","state":"opened","sourceBranch":"feat-ci-fail","targetBranch":"main","sourceProject":{"fullPath":"codans-e2e/app"},
         "webUrl":"http://192.168.2.158:8929/codans-e2e/app/-/merge_requests/4","detailedMergeStatus":"CI_MUST_PASS",
         "headPipeline":{"status":"FAILED","jobs":{"pageInfo":{"hasNextPage":true,"endCursor":"c0"},"nodes":[]}}}]}}}}
      """#
    let jobs1 = try GitLabDecodingTests.loadFixture("gitlab-graphql-jobs-page1")
    let jobs2 = try GitLabDecodingTests.loadFixture("gitlab-graphql-jobs-page2")
    let runner = RecordingCommandRunner(outcomes: [
      Self.version, Self.ok(truncated),
      .exited(code: 0, stdout: jobs1, stderr: Data(), stdoutOverflow: false),
      .exited(code: 0, stdout: jobs2, stderr: Data(), stdoutOverflow: false),
    ])
    let result = try await Self.makeService(runner).batchPullRequests(
      repository: Self.withPort, branches: ["feat-ci-fail"])
    let snapshot = try #require(result["feat-ci-fail"])
    #expect(snapshot.checkRollup.map(\.name) == ["fail", "pass"])
    #expect(snapshot.canRerunFailedChecks)
    let calls = await runner.calls.map(\.arguments)
    #expect(
      calls[2] == [
        "api", "graphql", "-f", "query=\(GitLabMergeRequestQuery.jobsQuery)", "-f", "after=c0",
        "-f", "fullPath=codans-e2e/app", "-f", "iid=4",
      ])
    #expect(calls[3].contains("after=eyJpZCI6IjQzIn0"))
  }

  /// A read that would need more than `maxPages` pages fails instead of showing a
  /// partial list.
  @Test
  func batchReadStopsAtThePageCap() async {
    let endless = Self.ok(
      #"{"data":{"currentUser":{"username":"u"},"project":{"mergeRequests":{"pageInfo":{"hasNextPage":true,"endCursor":"c"},"nodes":[]}}}}"#
    )
    let runner = RecordingCommandRunner(
      outcomes: [Self.version] + Array(repeating: endless, count: GitLabMergeRequestQuery.maxPages))
    await #expect(throws: GitPlatformError.other("more than 2000 merge requests for 1 branches")) {
      _ = try await Self.makeService(runner).batchPullRequests(repository: Self.withPort, branches: ["main"])
    }
    #expect(await runner.calls.count == 1 + GitLabMergeRequestQuery.maxPages)
  }

  // MARK: - degraded read

  private static func fixtureText(_ name: String) throws -> String {
    try #require(String(bytes: GitLabDecodingTests.loadFixture(name), encoding: .utf8))
  }

  private static func graphQLReads(_ runner: RecordingCommandRunner) async -> [[String]] {
    await runner.calls.map(\.arguments).filter { $0.starts(with: ["api", "graphql"]) }
  }

  /// An instance that does not know a review or squash field answers the batched query
  /// with an `errors` body (exit 1). The read runs once more without those fields; the
  /// badge, rollup, and merge state show, the review decision is absent.
  @Test
  func unknownOptionalFieldRetriesOnceWithoutReviewAndSquashFields() async throws {
    let error = try Self.fixtureText("gitlab-graphql-error-optional-fields")
    let degraded = try GitLabDecodingTests.loadFixture("gitlab-graphql-batch-degraded")
    let runner = RecordingCommandRunner(outcomes: [
      Self.version, Self.failed(stdout: error, stderr: "glab: graphql error"),
      .exited(code: 0, stdout: degraded, stderr: Data(), stdoutOverflow: false),
    ])
    let result = try await Self.makeService(runner).batchPullRequests(
      repository: Self.withPort, branches: ["feat-open", "feat-fixture-approved", "feat-fixture-changes"])
    let reads = await Self.graphQLReads(runner)
    #expect(reads.count == 2)
    #expect(reads[0].contains("query=\(GitLabMergeRequestQuery.query)"))
    #expect(reads[1].contains("query=\(GitLabMergeRequestQuery.degradedQuery)"))
    for field in GitLabMergeRequestQuery.optionalFieldNames {
      #expect(GitLabMergeRequestQuery.query.contains(field))
      #expect(!GitLabMergeRequestQuery.degradedQuery.contains(field))
    }
    let open = try #require(result["feat-open"])
    #expect(open.mergeState == PullRequestMergeState(status: .clean))
    #expect(open.checkRollup.map(\.name) == ["pass"])
    #expect(open.mergeOptions.allSatisfy { $0.isEnabled })
    #expect(result["feat-fixture-approved"]?.reviewDecision == nil)
    #expect(result["feat-fixture-changes"]?.reviewDecision == nil)
  }

  /// Exactly one retry: when the degraded query fails too, the chunk fails.
  @Test
  func degradedQueryIsNotRetriedAgain() async throws {
    let error = try Self.fixtureText("gitlab-graphql-error-optional-fields")
    let runner = RecordingCommandRunner(outcomes: [
      Self.version, Self.failed(stdout: error, stderr: ""), Self.failed(stdout: error, stderr: ""),
      Self.ok(Self.emptyPage),
    ])
    let message = "Field 'squashReadOnly' doesn't exist on type 'MergeRequest'"
    await #expect(throws: GitPlatformError.graphQLError(message)) {
      _ = try await Self.makeService(runner).batchPullRequests(repository: Self.withPort, branches: ["main"])
    }
    #expect(await Self.graphQLReads(runner).count == 2)
  }

  /// The same unknown-field body on exit 0 also degrades.
  @Test
  func unknownOptionalFieldOnExitZeroAlsoDegrades() async throws {
    let error = try Self.fixtureText("gitlab-graphql-error-optional-fields")
    let runner = RecordingCommandRunner(outcomes: [Self.version, Self.ok(error), Self.ok(Self.emptyPage)])
    let result = try await Self.makeService(runner).batchPullRequests(repository: Self.withPort, branches: ["main"])
    #expect(result.isEmpty)
    let reads = await Self.graphQLReads(runner)
    #expect(reads.count == 2)
    #expect(reads[1].contains("query=\(GitLabMergeRequestQuery.degradedQuery)"))
  }

  /// Other GraphQL errors fail the chunk without a retry.
  @Test(arguments: [
    "gitlab-graphql-error",
    #"{"errors":[{"message":"Internal server error"}]}"#,
    #"{"errors":[{"message":"Field 'reviewState' doesn't exist on type 'X'","extensions":{"code":"undefinedField","fieldName":"reviewState"}},{"message":"Internal server error"}]}"#,
  ])
  func otherGraphQLErrorsAreNotRetried(body: String) async throws {
    let stdout = body.hasPrefix("{") ? body : try Self.fixtureText(body)
    for outcome in [Self.failed(stdout: stdout, stderr: ""), Self.ok(stdout)] {
      let runner = RecordingCommandRunner(outcomes: [Self.version, outcome, Self.ok(Self.emptyPage)])
      await #expect(throws: GitPlatformError.self) {
        _ = try await Self.makeService(runner).batchPullRequests(repository: Self.withPort, branches: ["main"])
      }
      #expect(await Self.graphQLReads(runner).count == 1)
    }
  }

  // MARK: - reviewers

  private static func reviewerPage(_ states: [String], next: String?) -> CommandOutcome {
    let nodes = states.map { #"{"mergeRequestInteraction":{"reviewState":"\#($0)"}}"# }.joined(separator: ",")
    let pageInfo =
      next.map { #"{"hasNextPage":true,"endCursor":"\#($0)"}"# } ?? #"{"hasNextPage":false,"endCursor":null}"#
    return ok(
      #"{"data":{"project":{"mergeRequest":{"reviewers":{"pageInfo":\#(pageInfo),"nodes":[\#(nodes)]}}}}}"#)
  }

  /// An approved merge request whose first reviewer page approves; the rest is read per
  /// merge request, and a requested change on a later page wins.
  @Test
  func batchReadFollowsEveryReviewerPage() async throws {
    let first = GitLabDecodingTests.approvedPage(
      reviewers:
        #"{"pageInfo":{"hasNextPage":true,"endCursor":"r1"},"nodes":[{"mergeRequestInteraction":{"reviewState":"APPROVED"}}]}"#
    )
    let runner = RecordingCommandRunner(outcomes: [
      Self.version, Self.ok(first), Self.reviewerPage(["APPROVED"], next: "r2"),
      Self.reviewerPage(["REQUESTED_CHANGES"], next: nil),
    ])
    let result = try await Self.makeService(runner).batchPullRequests(
      repository: Self.selfManaged, branches: ["feat-approved"])
    #expect(result["feat-approved"]?.reviewDecision == .changesRequested)
    let reads = await Self.graphQLReads(runner)
    #expect(reads.count == 3)
    #expect(
      reads[1] == [
        "api", "graphql", "--hostname", "gitlab.example.com", "-f", "query=\(GitLabMergeRequestQuery.reviewersQuery)",
        "-f", "after=r1", "-f", "fullPath=group/sub/app", "-f", "iid=16",
      ])
    #expect(reads[2].contains("after=r2"))
  }

  /// Every reviewer page read and every reviewer approving → approved.
  @Test
  func completeReviewerPagesKeepApproved() async throws {
    let first = GitLabDecodingTests.approvedPage(
      reviewers: #"{"pageInfo":{"hasNextPage":true,"endCursor":"r1"},"nodes":[]}"#)
    let runner = RecordingCommandRunner(outcomes: [
      Self.version, Self.ok(first), Self.reviewerPage(["APPROVED"], next: nil),
    ])
    let result = try await Self.makeService(runner).batchPullRequests(
      repository: Self.selfManaged, branches: ["feat-approved"])
    #expect(result["feat-approved"]?.reviewDecision == .approved)
  }

  /// A later reviewer page without `nodes` or usable `pageInfo` leaves the list
  /// incomplete: the snapshot keeps its badge, rollup, and merge state, and the decision
  /// is none. A requested change on that page still counts.
  @Test(arguments: [
    (#"{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":null}"#, nil),
    (#"{"pageInfo":{"hasNextPage":false,"endCursor":null}}"#, nil),
    (#"{"nodes":[{"mergeRequestInteraction":{"reviewState":"APPROVED"}}]}"#, nil),
    (#"{"pageInfo":{"hasNextPage":true,"endCursor":null},"nodes":[]}"#, nil),
    (#"{"nodes":[{"mergeRequestInteraction":{"reviewState":"REQUESTED_CHANGES"}}]}"#, ReviewDecision.changesRequested),
  ])
  func laterReviewerPageWithoutPageInfoKeepsTheSnapshot(reviewers: String, decision: ReviewDecision?) async throws {
    let first = GitLabDecodingTests.approvedPage(
      reviewers: #"{"pageInfo":{"hasNextPage":true,"endCursor":"r1"},"nodes":[]}"#)
    let runner = RecordingCommandRunner(outcomes: [
      Self.version, Self.ok(first),
      Self.ok(#"{"data":{"project":{"mergeRequest":{"reviewers":\#(reviewers)}}}}"#),
    ])
    let result = try await Self.makeService(runner).batchPullRequests(
      repository: Self.selfManaged, branches: ["feat-approved"])
    let snapshot = try #require(result["feat-approved"])
    #expect(snapshot.number == 16)
    #expect(snapshot.mergeState == PullRequestMergeState(status: .clean))
    #expect(snapshot.reviewDecision == decision)
    #expect(await Self.graphQLReads(runner).count == 2)
  }

  /// A first reviewer page without `nodes` is unknown: a complete later page must not
  /// make the list complete. The read does not follow the next page.
  @Test(arguments: [
    #"{"pageInfo":{"hasNextPage":true,"endCursor":"r1"},"nodes":null}"#,
    #"{"pageInfo":{"hasNextPage":true,"endCursor":"r1"}}"#,
  ])
  func firstReviewerPageWithoutNodesIsNotApproved(reviewers: String) async throws {
    let first = GitLabDecodingTests.approvedPage(reviewers: reviewers)
    let runner = RecordingCommandRunner(outcomes: [
      Self.version, Self.ok(first), Self.reviewerPage(["APPROVED"], next: nil),
    ])
    let result = try await Self.makeService(runner).batchPullRequests(
      repository: Self.selfManaged, branches: ["feat-approved"])
    let snapshot = try #require(result["feat-approved"])
    #expect(snapshot.mergeState == PullRequestMergeState(status: .clean))
    #expect(snapshot.reviewDecision == nil)
  }

  /// A reviewer list longer than `maxPages` pages stays incomplete: the read succeeds
  /// and the decision is none, not approved.
  @Test
  func reviewerListBeyondThePageCapIsNotApproved() async throws {
    let first = GitLabDecodingTests.approvedPage(
      reviewers: #"{"pageInfo":{"hasNextPage":true,"endCursor":"r"},"nodes":[]}"#)
    let endless = Self.reviewerPage(["APPROVED"], next: "r")
    let runner = RecordingCommandRunner(
      outcomes: [Self.version, Self.ok(first)] + Array(repeating: endless, count: GitLabMergeRequestQuery.maxPages))
    let result = try await Self.makeService(runner).batchPullRequests(
      repository: Self.selfManaged, branches: ["feat-approved"])
    #expect(result["feat-approved"] != nil)
    #expect(result["feat-approved"]?.reviewDecision == nil)
    #expect(await Self.graphQLReads(runner).count == GitLabMergeRequestQuery.maxPages)
  }

  @Test
  func markReadyArgvAndMutationErrors() async throws {
    let runner = RecordingCommandRunner(outcomes: [
      Self.version, Self.ok(#"{"data":{"mergeRequestSetDraft":{"errors":[],"mergeRequest":{"draft":false}}}}"#),
    ])
    let service = Self.makeService(runner)
    try await service.markReady(PullRequestReference(repository: Self.selfManaged, number: 12))
    #expect(
      await runner.calls.last?.arguments == [
        "api", "graphql", "--hostname", "gitlab.example.com", "-f", "query=\(GlabCommand.markReadyMutation)",
        "-f", "iid=12", "-f", "projectPath=group/sub/app",
      ])
    let failing = RecordingCommandRunner(outcomes: [
      Self.version, Self.ok(#"{"data":{"mergeRequestSetDraft":{"errors":["not allowed"]}}}"#),
    ])
    await #expect(throws: GitPlatformError.other("not allowed")) {
      try await Self.makeService(failing).markReady(PullRequestReference(repository: Self.selfManaged, number: 12))
    }
  }

  /// Only a payload that confirms the merge request is no longer a draft is a success.
  @Test(arguments: [
    (#"{}"#, "mark ready: GitLab returned no mutation result"),
    (#"{"data":{"mergeRequestSetDraft":null}}"#, "mark ready: GitLab returned no mutation result"),
    (#"{"data":{"mergeRequestSetDraft":{"mergeRequest":{"draft":false}}}}"#, "mark ready: GitLab returned no mutation result"),
    (#"{"data":{"mergeRequestSetDraft":{"errors":[]}}}"#, "mark ready: the merge request is still a draft"),
    (#"{"data":{"mergeRequestSetDraft":{"errors":[],"mergeRequest":{"draft":true}}}}"#, "mark ready: the merge request is still a draft"),
  ])
  func markReadyRejectsAnUnconfirmedResponse(body: String, message: String) async {
    let runner = RecordingCommandRunner(outcomes: [Self.version, Self.ok(body)])
    await #expect(throws: GitPlatformError.other(message)) {
      try await Self.makeService(runner).markReady(PullRequestReference(repository: Self.selfManaged, number: 12))
    }
  }

  @Test
  func rerunRetriesTheHeadPipeline() async throws {
    let runner = RecordingCommandRunner(outcomes: [
      Self.version, Self.ok(#"{"iid":4,"head_pipeline":{"id":42,"status":"failed"}}"#), Self.ok("{}"),
    ])
    try await Self.makeService(runner).rerunFailedChecks(PullRequestReference(repository: Self.withPort, number: 4))
    let calls = await runner.calls.map(\.arguments)
    #expect(
      calls.suffix(2) == [
        ["api", "projects/codans-e2e%2Fapp/merge_requests/4", "--method", "GET"],
        ["api", "projects/codans-e2e%2Fapp/pipelines/42/retry", "--method", "POST"],
      ])
  }

  @Test
  func rerunWithoutPipelineThrows() async {
    let runner = RecordingCommandRunner(outcomes: [Self.version, Self.ok(#"{"iid":4,"head_pipeline":null}"#)])
    await #expect(throws: GitPlatformError.other("merge request !4 has no pipeline")) {
      try await Self.makeService(runner).rerunFailedChecks(PullRequestReference(repository: Self.withPort, number: 4))
    }
  }

  // MARK: - env contract

  @Test
  func envStripsTokensAndUserHostSettings() {
    let parent = [
      "PATH": "/usr/bin", "HOME": "/Users/u", "GLAB_CONFIG_DIR": "/cfg", "XDG_CONFIG_HOME": "/xdg",
      "GITLAB_TOKEN": "secret", "GITLAB_ACCESS_TOKEN": "secret", "OAUTH_TOKEN": "secret", "GH_TOKEN": "secret",
      "GITLAB_HOST": "other.example.com", "GITLAB_REPO": "x/y", "GLAB_DEBUG_HTTP": "true", "EDITOR": "vim",
    ]
    let env = GitLabGitPlatform.makeEnv(host: "192.168.2.158:8929", parent: parent)
    #expect(
      env == [
        "PATH": "/usr/bin", "HOME": "/Users/u", "GLAB_CONFIG_DIR": "/cfg", "XDG_CONFIG_HOME": "/xdg",
        "GITLAB_HOST": "192.168.2.158:8929", "LC_ALL": "en_US.UTF-8", "NO_COLOR": "1", "GLAB_NO_PROMPT": "true",
        "GLAB_CHECK_UPDATE": "false", "GLAB_SEND_TELEMETRY": "false", "GLAB_SHOW_WHATS_NEW": "false",
      ])
    #expect(GitLabGitPlatform.makeEnv(host: nil, parent: parent)["GITLAB_HOST"] == nil)
  }

  // MARK: - web URLs

  @Test
  func webURLsUseTheSchemeGlabReportsForTheHost() async throws {
    let mixed = try GitLabDecodingTests.loadFixture("glab-auth-status-mixed")
    let runner = RecordingCommandRunner(outcomes: [
      Self.version, .exited(code: 1, stdout: mixed, stderr: Data(), stdoutOverflow: false),
    ])
    let service = Self.makeService(runner)
    _ = await service.availability()
    let nested = GitPlatformRepository(kind: .gitlab, host: "192.168.2.158:8929", path: "codans-e2e/nested/deep-app")
    #expect(service.repositoryWebURL(nested) == URL(string: "http://192.168.2.158:8929/codans-e2e/nested/deep-app"))
    #expect(
      service.pullRequestWebURL(PullRequestReference(repository: nested, number: 1))
        == URL(string: "http://192.168.2.158:8929/codans-e2e/nested/deep-app/-/merge_requests/1"))
    let dotCom = GitPlatformRepository(kind: .gitlab, host: "gitlab.com", path: "group/app")
    #expect(service.repositoryWebURL(dotCom) == URL(string: "https://gitlab.com/group/app"))
  }

  // MARK: - helpers

  @Test
  func versionParsing() {
    #expect(GitLabJSONParsers.parseVersion(Data("glab 1.128.0 (519ea19f7)\n".utf8)) == "1.128.0")
    #expect(GitLabJSONParsers.parseVersion(Data("glab version 1.22.0 (2022-01-01)\n".utf8)) == "1.22.0")
    #expect(GitLabJSONParsers.parseVersion(Data("nonsense".utf8)) == nil)
    #expect(GitLab.isVersion("1.122.0", atLeast: "1.122.0"))
    #expect(GitLab.isVersion("1.128.0", atLeast: "1.122.0"))
    #expect(GitLab.isVersion("2.0.0", atLeast: "1.122.0"))
    #expect(!GitLab.isVersion("1.99.9", atLeast: "1.122.0"))
  }
}
