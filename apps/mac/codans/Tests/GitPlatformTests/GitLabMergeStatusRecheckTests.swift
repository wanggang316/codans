import CodansCore
import Foundation
import Testing

@testable import Codans

/// The batched read asks GitLab to recheck open merge requests it left `UNCHECKED`, with
/// a per-merge-request cooldown and a per-read cap, and never fails the read for it.
struct GitLabMergeStatusRecheckTests {
  private static let exec = URL(fileURLWithPath: "/opt/homebrew/bin/glab")
  private static let nested = GitPlatformRepository(kind: .gitlab, host: "gitlab.example.com", path: "group/sub/app")
  private static let withPort = GitPlatformRepository(kind: .gitlab, host: "192.168.2.158:8929", path: "codans-e2e/app")
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

  private static func makeService(_ runner: RecordingCommandRunner, clock: Clock = Clock()) -> GitLabGitPlatform {
    GitLabGitPlatform(runner: runner, resolver: CLIExecutableResolver(prober: { exec }), now: { clock.now })
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
    let result = try await Self.makeService(runner).readAndRecheck(repository: Self.nested, branches: ["feat"])
    #expect(result["feat"]?.mergeState.status == .unknown)
    let call = try #require(await Self.rechecks(runner).first)
    #expect(
      call.arguments == [
        "api", "projects/group%2Fsub%2Fapp/merge_requests/7?with_merge_status_recheck=true", "--method", "GET",
        "--hostname", "gitlab.example.com",
      ])
    #expect(call.env["GITLAB_HOST"] == "gitlab.example.com")
    #expect(call.cwd == GitLabGitPlatform.homeDirectory)
  }

  @Test
  func hostWithPortGoesThroughGitLabHostOnly() async throws {
    let runner = RecordingCommandRunner(outcomes: [
      Self.version, Self.page([("feat-open", 1, "UNCHECKED", "opened")]), Self.recheckOK,
    ])
    _ = try await Self.makeService(runner).readAndRecheck(repository: Self.withPort, branches: ["feat-open"])
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
    _ = try await Self.makeService(runner).readAndRecheck(
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
    _ = try await service.readAndRecheck(repository: Self.withPort, branches: ["feat-open"])
    clock.advance(10)
    _ = try await service.readAndRecheck(repository: Self.withPort, branches: ["feat-open"])
    #expect(await Self.rechecks(runner).count == 1)
    clock.advance(GitLabMergeStatusRecheck.cooldown)
    _ = try await service.readAndRecheck(repository: Self.withPort, branches: ["feat-open"])
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
    _ = try await service.readAndRecheck(repository: Self.withPort, branches: branches)
    let first = await Self.rechecks(runner).map(\.arguments[1])
    #expect(first.count == GitLabMergeStatusRecheck.maxPerBatch)
    #expect(
      first.allSatisfy {
        $0.contains("/merge_requests/1?") || $0.contains("/merge_requests/2?") || $0.contains("/merge_requests/3?")
      })
    clock.advance(5)
    _ = try await service.readAndRecheck(repository: Self.withPort, branches: branches)
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
    _ = try await service.readAndRecheck(repository: Self.withPort, branches: ["feat"])
    #expect(await Self.rechecks(runner).isEmpty)
    clock.advance(GitLabMergeStatusRecheck.cooldown)
    _ = try await service.readAndRecheck(repository: Self.withPort, branches: ["feat"])
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
    _ = try await service.readAndRecheck(repository: Self.withPort, branches: ["feat"])
    clock.advance(10)
    let settled = try await service.readAndRecheck(repository: Self.withPort, branches: ["feat"])
    #expect(settled["feat"]?.mergeState.status == .clean)
    clock.advance(10)
    _ = try await service.readAndRecheck(repository: Self.withPort, branches: ["feat"])
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
    let result = try await Self.makeService(runner).readAndRecheck(
      repository: Self.withPort, branches: ["feat-open", "feat-b"])
    #expect(result.keys.sorted() == ["feat-b", "feat-open"])
    #expect(await Self.rechecks(runner).count == 2)
  }

  /// More unchecked merge requests than the per-read cap: each read takes the least
  /// recently rechecked, so none of them waits forever.
  @Test
  func rechecksRotateThroughMoreMergeRequestsThanTheCap() async throws {
    let iids = Array(1...7)
    let page = Self.page(iids.map { ("b\($0)", $0, "UNCHECKED", "opened") })
    let runner = RecordingCommandRunner(outcomes: [Self.version, page])
    let clock = Clock()
    let service = Self.makeService(runner, clock: clock)
    var perRead: [[Int]] = []
    for read in 0..<3 {
      let before = await Self.rechecks(runner).count
      _ = try await service.readAndRecheck(repository: Self.withPort, branches: iids.map { "b\($0)" })
      perRead.append(await Self.rechecks(runner).dropFirst(before).map { Self.iid(of: $0) }.sorted())
      if read < 2 { clock.advance(30) }
    }
    // t=0: 1-3; t=30: 1-3 cool down, 4-6; t=60: 7 never rechecked goes first, then 1-2.
    #expect(perRead == [[1, 2, 3], [4, 5, 6], [1, 2, 7]])
  }

  /// The read returns its snapshots without waiting for the rechecks, which run
  /// concurrently.
  @Test
  func readDoesNotWaitForSlowRechecks() async throws {
    let runner = SlowRecheckRunner(
      page: Self.page((1...3).map { ("b\($0)", $0, "UNCHECKED", "opened") }), recheckDelay: .seconds(2))
    let service = GitLabGitPlatform(runner: runner, resolver: CLIExecutableResolver(prober: { Self.exec }))
    let clock = ContinuousClock()
    let start = clock.now
    let result = try await service.batchPullRequests(repository: Self.withPort, branches: ["b1", "b2", "b3"])
    #expect(result.count == 3)
    #expect(clock.now - start < .seconds(1))
    await service.waitForPendingRechecks()
    #expect(await runner.recheckCount == 3)
    // Three 2 s rechecks, concurrent.
    #expect(clock.now - start < .seconds(4))
  }

  private static func iid(of call: RecordingCommandRunner.Recorded) -> Int {
    let path = call.arguments[1]
    let tail = path.split(separator: "/").last.map(String.init) ?? ""
    return Int(tail.prefix { $0.isNumber }) ?? -1
  }
}

/// Answers the batched read at once and each recheck after `recheckDelay`.
private actor SlowRecheckRunner: CommandRunner {
  let page: CommandOutcome
  let recheckDelay: Duration
  private(set) var recheckCount = 0

  init(page: CommandOutcome, recheckDelay: Duration) {
    self.page = page
    self.recheckDelay = recheckDelay
  }

  nonisolated func run(
    executable: URL, arguments: [String], env: [String: String], cwd: URL, timeout: Duration, maxOutputBytes: Int
  ) async -> CommandOutcome {
    if arguments == ["version"] { return .exited(code: 0, stdout: Data("glab 1.128.0 (x)\n".utf8), stderr: Data(), stdoutOverflow: false) }
    if arguments.contains(where: { $0.contains("with_merge_status_recheck=true") }) {
      try? await Task.sleep(for: recheckDelay)
      await countRecheck()
      return .exited(code: 0, stdout: Data("{}".utf8), stderr: Data(), stdoutOverflow: false)
    }
    return page
  }

  private func countRecheck() { recheckCount += 1 }
}

extension GitLabGitPlatform {
  /// A batched read followed by the rechecks it started, so a test sees both in order.
  fileprivate func readAndRecheck(
    repository: GitPlatformRepository, branches: [String]
  ) async throws -> [String: PullRequestSnapshot] {
    let result = try await batchPullRequests(repository: repository, branches: branches)
    await waitForPendingRechecks()
    return result
  }
}
