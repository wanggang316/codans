import CodansCore
import Foundation
import Testing

@testable import Codans

/// The batched read asks GitLab to recheck open merge requests it left `UNCHECKED`, with
/// a per-merge-request cooldown and a per-read cap, and never fails the read for it.
struct GitLabMergeStatusRecheckTests {
  private static let exec = URL(fileURLWithPath: "/opt/homebrew/bin/glab")
  private static let nested = CodeHostRepository(kind: .gitlab, host: "gitlab.example.com", path: "group/sub/app")
  private static let withPort = CodeHostRepository(kind: .gitlab, host: "192.168.2.158:8929", path: "codans-e2e/app")
  private static let version = ok("glab 1.128.0 (519ea19f7)\n")
  private static let recheckOK = ok(#"{"iid":1,"detailed_merge_status":"unchecked"}"#)

  private static func ok(_ stdout: String) -> CommandOutcome {
    .exited(code: 0, stdout: Data(stdout.utf8), stderr: Data(), stdoutOverflow: false)
  }

  /// A mutable clock for the cooldown.
  private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
  }

  private static func makeService(_ runner: RecordingCommandRunner, clock: Clock = Clock()) -> GitLabCodeHost {
    GitLabCodeHost(runner: runner, resolver: CLIExecutableResolver(prober: { exec }), now: { clock.now })
  }

  /// One page with a merge request per `(branch, iid, status, state)`.
  private static func page(
    _ mergeRequests: [(branch: String, iid: Int, status: String, state: String)], project: String = "codans-e2e/app"
  ) -> CommandOutcome {
    let nodes = mergeRequests.map { mr in
      #"{"iid":"\#(mr.iid)","state":"\#(mr.state)","sourceBranch":"\#(mr.branch)","targetBranch":"main","#
        + #""sourceProject":{"fullPath":"\#(project)"},"targetProject":{"fullPath":"\#(project)"},"#
        + #""webUrl":"https://h/\#(project)/-/merge_requests/\#(mr.iid)","detailedMergeStatus":"\#(mr.status)"}"#
    }
    return ok(
      #"{"data":{"currentUser":{"username":"u"},"project":{"mergeRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":["#
        + nodes.joined(separator: ",") + "]}}}}")
  }

  private static func rechecks(_ runner: RecordingCommandRunner) async -> [RecordingCommandRunner.Recorded] {
    await runner.calls.filter { $0.arguments.first == "api" && $0.arguments.dropFirst().first != "graphql" }
  }

  @Test
  func uncheckedMergeRequestIsRecheckedWithHostAndEncodedNestedPath() async throws {
    let runner = RecordingCommandRunner(outcomes: [
      Self.version, Self.page([("feat", 7, "UNCHECKED", "opened")], project: "group/sub/app"), Self.recheckOK,
    ])
    let result = try await Self.makeService(runner).batchPullRequests(repository: Self.nested, branches: ["feat"])
    #expect(result["feat"]?.mergeState.status == .unknown)
    let call = try #require(await Self.rechecks(runner).first)
    #expect(
      call.arguments == [
        "api", "projects/group%2Fsub%2Fapp/merge_requests/7?with_merge_status_recheck=true", "--method", "GET",
        "--hostname", "gitlab.example.com",
      ])
    #expect(call.env["GITLAB_HOST"] == "gitlab.example.com")
    #expect(call.cwd == GitLabCodeHost.homeDirectory)
  }

  @Test
  func hostWithPortGoesThroughGitLabHostOnly() async throws {
    let runner = RecordingCommandRunner(outcomes: [
      Self.version, Self.page([("feat-open", 1, "UNCHECKED", "opened")]), Self.recheckOK,
    ])
    _ = try await Self.makeService(runner).batchPullRequests(repository: Self.withPort, branches: ["feat-open"])
    let call = try #require(await Self.rechecks(runner).first)
    #expect(
      call.arguments == [
        "api", "projects/codans-e2e%2Fapp/merge_requests/1?with_merge_status_recheck=true", "--method", "GET",
      ])
    #expect(call.env["GITLAB_HOST"] == "192.168.2.158:8929")
  }

  /// Checked merge requests, and unchecked ones that are not open, are left alone.
  @Test
  func checkedOrClosedMergeRequestsAreNotRechecked() async throws {
    let runner = RecordingCommandRunner(outcomes: [
      Self.version,
      Self.page([
        ("a", 1, "MERGEABLE", "opened"), ("b", 2, "CONFLICT", "opened"), ("c", 3, "UNCHECKED", "merged"),
        ("d", 4, "UNCHECKED", "closed"),
      ]),
    ])
    _ = try await Self.makeService(runner).batchPullRequests(
      repository: Self.withPort, branches: ["a", "b", "c", "d"])
    #expect(await Self.rechecks(runner).isEmpty)
  }

  /// One recheck per merge request per cooldown; a later read after the cooldown asks again.
  @Test
  func recheckIsRateLimitedPerMergeRequest() async throws {
    let unchecked = Self.page([("feat-open", 1, "UNCHECKED", "opened")])
    let runner = RecordingCommandRunner(outcomes: [
      Self.version, unchecked, Self.recheckOK, unchecked, unchecked, Self.recheckOK,
    ])
    let clock = Clock()
    let service = Self.makeService(runner, clock: clock)
    _ = try await service.batchPullRequests(repository: Self.withPort, branches: ["feat-open"])
    clock.advance(10)
    _ = try await service.batchPullRequests(repository: Self.withPort, branches: ["feat-open"])
    #expect(await Self.rechecks(runner).count == 1)
    clock.advance(GitLabMergeStatusRecheck.cooldown)
    _ = try await service.batchPullRequests(repository: Self.withPort, branches: ["feat-open"])
    #expect(await Self.rechecks(runner).count == 2)
  }

  /// A read with many unchecked merge requests rechecks at most `maxPerBatch`; the rest
  /// wait for the next read.
  @Test
  func recheckIsCappedPerRead() async throws {
    let many = Self.page((1...5).map { ("b\($0)", $0, "UNCHECKED", "opened") })
    let branches = (1...5).map { "b\($0)" }
    let runner = RecordingCommandRunner(
      outcomes: [
        Self.version, many, Self.recheckOK, Self.recheckOK, Self.recheckOK, many, Self.recheckOK, Self.recheckOK,
      ])
    let clock = Clock()
    let service = Self.makeService(runner, clock: clock)
    _ = try await service.batchPullRequests(repository: Self.withPort, branches: branches)
    let first = await Self.rechecks(runner).map(\.arguments[1])
    #expect(first.count == GitLabMergeStatusRecheck.maxPerBatch)
    #expect(
      first.allSatisfy {
        $0.contains("/merge_requests/1?") || $0.contains("/merge_requests/2?") || $0.contains("/merge_requests/3?")
      })
    clock.advance(5)
    _ = try await service.batchPullRequests(repository: Self.withPort, branches: branches)
    let second = await Self.rechecks(runner).map(\.arguments[1]).dropFirst(3)
    #expect(
      second.sorted()
        == ["4", "5"].map { "projects/codans-e2e%2Fapp/merge_requests/\($0)?with_merge_status_recheck=true" })
  }

  /// `CHECKING` is GitLab's own check: it is rechecked only when it does not settle.
  @Test
  func checkingIsRecheckedOnlyWhenItDoesNotSettle() async throws {
    let checking = Self.page([("feat", 2, "CHECKING", "opened")])
    let runner = RecordingCommandRunner(outcomes: [Self.version, checking, checking, Self.recheckOK])
    let clock = Clock()
    let service = Self.makeService(runner, clock: clock)
    _ = try await service.batchPullRequests(repository: Self.withPort, branches: ["feat"])
    #expect(await Self.rechecks(runner).isEmpty)
    clock.advance(GitLabMergeStatusRecheck.cooldown)
    _ = try await service.batchPullRequests(repository: Self.withPort, branches: ["feat"])
    #expect(await Self.rechecks(runner).count == 1)
  }

  /// A merge request that settled starts a new cycle when it becomes unchecked again.
  @Test
  func settledMergeRequestIsRecheckedAgainOnTheNextTargetMove() async throws {
    let unchecked = Self.page([("feat", 1, "UNCHECKED", "opened")])
    let mergeable = Self.page([("feat", 1, "MERGEABLE", "opened")])
    let runner = RecordingCommandRunner(outcomes: [
      Self.version, unchecked, Self.recheckOK, mergeable, unchecked, Self.recheckOK,
    ])
    let clock = Clock()
    let service = Self.makeService(runner, clock: clock)
    _ = try await service.batchPullRequests(repository: Self.withPort, branches: ["feat"])
    clock.advance(10)
    let settled = try await service.batchPullRequests(repository: Self.withPort, branches: ["feat"])
    #expect(settled["feat"]?.mergeState.status == .clean)
    clock.advance(10)
    _ = try await service.batchPullRequests(repository: Self.withPort, branches: ["feat"])
    // Inside the cooldown of the first recheck, but the merge request settled in between.
    #expect(await Self.rechecks(runner).count == 2)
  }

  @Test(arguments: [
    CommandOutcome.exited(
      code: 1, stdout: Data(#"{"message":"403 Forbidden"}"#.utf8), stderr: Data("glab: 403".utf8),
      stdoutOverflow: false),
    .timedOut,
    .spawnFailed(reason: "ENOENT"),
  ])
  func failingRecheckDoesNotFailTheRead(outcome: CommandOutcome) async throws {
    let runner = RecordingCommandRunner(outcomes: [
      Self.version, Self.page([("feat-open", 1, "UNCHECKED", "opened"), ("feat-b", 2, "UNCHECKED", "opened")]),
      outcome, Self.recheckOK,
    ])
    let result = try await Self.makeService(runner).batchPullRequests(
      repository: Self.withPort, branches: ["feat-open", "feat-b"])
    #expect(result.keys.sorted() == ["feat-b", "feat-open"])
    #expect(await Self.rechecks(runner).count == 2)
  }
}
