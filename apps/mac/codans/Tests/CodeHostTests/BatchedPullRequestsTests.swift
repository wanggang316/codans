import Foundation
import Testing
import CodansCore

@testable import Codans

/// Covers the v2 batched PR fetch path: query builder, chunker, parser (dynamic
/// keys + union-type + fork-PR filter), and the `GitHubCodeHost.batchPullRequests`
/// orchestration.
struct BatchedPullRequestsTests {
  // MARK: - Query builder

  @Test
  func buildQueryAssignsMonotonicAliases() throws {
    let (query, aliasMap) = try BatchedPullRequestQuery.buildQuery(
      branches: ["main", "feature/github01", "feat/test-005"]
    )
    #expect(
      aliasMap == [
        "branch0": "main",
        "branch1": "feature/github01",
        "branch2": "feat/test-005",
      ])
    #expect(query.contains("branch0: pullRequests"))
    #expect(query.contains("branch1: pullRequests"))
    #expect(query.contains("branch2: pullRequests"))
    #expect(query.contains("headRefName: \"feature/github01\""))
    #expect(query.contains("statusCheckRollup"))
  }

  @Test
  func buildQueryEscapesBackslashAndQuote() throws {
    let (query, _) = try BatchedPullRequestQuery.buildQuery(
      branches: [#"weird\name"#, #"quote"inside"#]
    )
    #expect(query.contains(#"headRefName: "weird\\name""#))
    #expect(query.contains(#"headRefName: "quote\"inside""#))
  }

  @Test
  func buildQueryRejectsNewlineInBranch() {
    #expect(
      throws: BatchedPullRequestQuery.ValidationError.invalidBranchName("bad\nname")
    ) {
      _ = try BatchedPullRequestQuery.buildQuery(branches: ["bad\nname"])
    }
  }

  @Test
  func buildQueryRejectsNullByteInBranch() {
    #expect(
      throws: BatchedPullRequestQuery.ValidationError.invalidBranchName("bad\u{0}name")
    ) {
      _ = try BatchedPullRequestQuery.buildQuery(branches: ["bad\u{0}name"])
    }
  }

  @Test
  func buildQueryEmptyBranchesReturnsPlaceholder() throws {
    let (query, aliasMap) = try BatchedPullRequestQuery.buildQuery(branches: [])
    #expect(aliasMap.isEmpty)
    #expect(query.contains("repository"))
    #expect(!query.contains("pullRequests"))
  }

  // MARK: - Chunker

  @Test
  func chunkerSplitsEvenly() {
    let chunks = BatchedPullRequestQuery.chunk(Array(0..<60).map { "b\($0)" })
    #expect(chunks.count == 3)
    #expect(chunks[0].count == 25)
    #expect(chunks[1].count == 25)
    #expect(chunks[2].count == 10)
  }

  @Test
  func chunkerHandlesEmpty() {
    let chunks = BatchedPullRequestQuery.chunk([])
    #expect(chunks.isEmpty)
  }

  // MARK: - Parser (happy path)

  @Test
  func parserHappyPathProducesSnapshotWithCheckRollup() throws {
    let data = try Self.loadFixture("gh-api-graphql-batched-happy")
    let aliasMap = ["branch0": "feature/github01", "branch1": "main"]
    let result = try GitHubJSONParsers.parseBatchedPullRequests(
      data, aliasMap: aliasMap, remoteOwner: "wanggang316"
    )
    // feature/github01 → PR #39; main has empty nodes array → absent from result.
    #expect(result.keys.sorted() == ["feature/github01"])
    let snap = result["feature/github01"]!
    #expect(snap.number == 39)
    #expect(snap.state == .merged)
    #expect(snap.mergeState.status == .clean)
    #expect(snap.headRepositoryOwner == "wanggang316")
    #expect(snap.additions == 5759)
    #expect(snap.deletions == 73)
    #expect(snap.checkRollup.count == 2)
    #expect(snap.checkRollup[0].name == "build")
    #expect(snap.checkRollup[0].status == .completed)
    #expect(snap.checkRollup[0].conclusion == .success)
    #expect(snap.checkRollup[1].conclusion == .failure)
    // The failed `tests` job belongs to Actions run 1, so it can be rerun.
    #expect(snap.canRerunFailedChecks)
  }

  /// "Rerun failed" shows only for a failed GitHub Actions CheckRun on the PR head — the
  /// same runs `GitHubCodeHost.rerunFailedChecks` targets. A failed outside status
  /// context does not count: `gh run rerun` cannot rerun it.
  @Test
  func rerunCapabilityFollowsFailedActionsRunsOnly() throws {
    func snapshot(_ contexts: String) throws -> PullRequestSnapshot? {
      let json = """
        {"data":{"repository":{"branch0":{"nodes":[{"number":7,"state":"OPEN","headRefName":"f",
        "baseRefName":"main","headRepository":{"owner":{"login":"o"}},
        "statusCheckRollup":{"contexts":{"nodes":[\(contexts)]}}}]}}}}
        """
      return try GitHubJSONParsers.parseBatchedPullRequests(
        Data(json.utf8), aliasMap: ["branch0": "f"], remoteOwner: "o")["f"]
    }
    let failedA = #"{"name":"lint","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://github.com/o/r/actions/runs/111/job/1"}"#
    let passedB = #"{"name":"build","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://github.com/o/r/actions/runs/222/job/2"}"#
    let failedStatus = #"{"context":"ci/external","state":"FAILURE","targetUrl":"https://ci.example.com/3"}"#
    #expect(try snapshot("\(failedA),\(passedB)")?.canRerunFailedChecks == true)
    #expect(try snapshot(passedB)?.canRerunFailedChecks == false)
    #expect(try snapshot("\(passedB),\(failedStatus)")?.canRerunFailedChecks == false)
  }

  // MARK: - Fork-PR filter

  @Test
  func forkFilterKeepsUpstreamOverForkNoise() throws {
    let data = try Self.loadFixture("gh-api-graphql-batched-fork-noise")
    let aliasMap = [
      "branch0": "main",
      "branch1": "fork-feature",
      "branch2": "shared-name",
    ]
    let result = try GitHubJSONParsers.parseBatchedPullRequests(
      data, aliasMap: aliasMap, remoteOwner: "wanggang316"
    )
    // branch0 (main): upstream PR #42 wins over fork PR #501.
    #expect(result["main"]?.number == 42)
    #expect(result["main"]?.headRepositoryOwner == "wanggang316")
    // branch1 (fork-feature): no upstream, fork PR with base != head → kept.
    #expect(result["fork-feature"]?.number == 601)
    #expect(result["fork-feature"]?.headRepositoryOwner == "fork-contributor")
    // branch2 (shared-name): only fork PR with base == head → dropped; branch absent.
    #expect(result["shared-name"] == nil)
  }

  // MARK: - GraphQL errors + malformed payloads

  @Test
  func graphQLErrorsArrayThrowsGraphQLError() {
    let payload = Data(
      #"""
      {"data": null, "errors": [{"message": "Field 'foo' doesn't exist on type 'Repository'"}]}
      """#.utf8)
    #expect(throws: CodeHostError.graphQLError("Field 'foo' doesn't exist on type 'Repository'")) {
      _ = try GitHubJSONParsers.parseBatchedPullRequests(
        payload, aliasMap: [:], remoteOwner: "owner"
      )
    }
  }

  @Test
  func nullRepositoryReturnsEmptyDictionary() throws {
    let payload = Data(
      #"""
      {"data": {"repository": null}}
      """#.utf8)
    let result = try GitHubJSONParsers.parseBatchedPullRequests(
      payload, aliasMap: ["branch0": "main"], remoteOwner: "owner"
    )
    #expect(result.isEmpty)
  }

  // MARK: - Service orchestration

  @Test
  func batchPullRequestsEmptyBranchesSpawnsNoSubprocess() async throws {
    let runner = RecordingCommandRunner(outcomes: [])
    let service = GitHubCodeHost(runner: runner, resolver: .init(prober: { nil }))
    let result = try await service.batchPullRequests(
      repository: CodeHostRepository(kind: .github, host: "github.com", path: "w/r"), branches: []
    )
    #expect(result.isEmpty)
  }

  @Test
  func batchPullRequestsHappyPathDecodesFixture() async throws {
    let fixture = try Self.loadFixture("gh-api-graphql-batched-happy")
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: fixture, stderr: Data(), stdoutOverflow: false)
    ])
    let service = GitHubCodeHost(
      runner: runner,
      resolver: Self.stubResolver()
    )
    let result = try await service.batchPullRequests(
      repository: CodeHostRepository(kind: .github, host: "github.com", path: "wanggang316/codans"),
      branches: ["feature/github01", "main"]
    )
    #expect(result.keys.sorted() == ["feature/github01"])
    #expect(result["feature/github01"]?.number == 39)
    #expect(result["feature/github01"]?.checkRollup.count == 2)
  }

  @Test
  func batchPullRequestsRejectsMalformedBranchBeforeSpawn() async {
    let runner = RecordingCommandRunner(outcomes: [])
    let service = GitHubCodeHost(
      runner: runner,
      resolver: Self.stubResolver()
    )
    await #expect(throws: CodeHostError.malformedBranchName("bad\nname")) {
      _ = try await service.batchPullRequests(
        repository: CodeHostRepository(kind: .github, host: "github.com", path: "o/r"), branches: ["bad\nname"]
      )
    }
  }

  @Test
  func batchPullRequestsGHMissingSurfacesNotInstalled() async {
    let runner = RecordingCommandRunner(outcomes: [])
    let service = GitHubCodeHost(
      runner: runner,
      resolver: .init(prober: { nil })  // executable resolution fails
    )
    await #expect(throws: CodeHostError.cliNotInstalled(.github)) {
      _ = try await service.batchPullRequests(
        repository: CodeHostRepository(kind: .github, host: "github.com", path: "o/r"), branches: ["main"]
      )
    }
  }

  @Test
  func batchPullRequestsOversizeStdoutSurfacesOversizeResponse() async {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data(), stderr: Data(), stdoutOverflow: true)
    ])
    let service = GitHubCodeHost(
      runner: runner,
      resolver: Self.stubResolver()
    )
    await #expect(
      throws: CodeHostError.oversizeResponse(bytes: 8 * 1024 * 1024)
    ) {
      _ = try await service.batchPullRequests(
        repository: CodeHostRepository(kind: .github, host: "github.com", path: "o/r"), branches: ["main"]
      )
    }
  }

  // MARK: - Fixture + resolver helpers

  private static func loadFixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures", isDirectory: true)
      .appendingPathComponent("\(name).json", isDirectory: false)
    return try Data(contentsOf: url)
  }

  /// Resolver that pretends a gh executable exists at a fixed path. Bypasses the real
  /// which / login-shell probe so tests run without a `gh` install.
  private static func stubResolver() -> CLIExecutableResolver {
    CLIExecutableResolver(prober: { URL(fileURLWithPath: "/opt/homebrew/bin/gh") })
  }
}
