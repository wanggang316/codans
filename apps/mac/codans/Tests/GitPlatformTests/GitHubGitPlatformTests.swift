import Foundation
import Testing
import CodansCore

@testable import Codans

/// Negative and happy path coverage for GitHubGitPlatform. Uses RecordingCommandRunner
/// (the existing actor test double from codans/Process/) to feed canned
/// CommandOutcomes and asserts both the returned value + the exact argv sent to gh.
struct GitHubGitPlatformTests {
  // MARK: - availability

  @Test
  func availabilityReturnsNotInstalledWhenGhMissing() async throws {
    let runner = RecordingCommandRunner()
    let resolver = CLIExecutableResolver(prober: { nil })
    let service = GitHubGitPlatform(runner: runner, resolver: resolver)
    #expect(await service.availability() == .notInstalled)
  }

  @Test
  func availabilityReturnsAvailableWhenAuthStatusDecodes() async throws {
    let data = try Self.loadFixture("gh-auth-status-available")
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: data, stderr: Data(), stdoutOverflow: false)
    ])
    let service = Self.makeService(runner: runner)
    let result = await service.availability()
    guard case .available(let host, let user) = result else {
      Issue.record("expected .available, got \(result)")
      return
    }
    #expect(host == "github.com")
    #expect(user == "gump")
    let calls = await runner.calls
    #expect(calls.first?.arguments == ["auth", "status", "--json", "hosts"])
  }

  @Test
  func availabilityReportsNotLoggedInOnEmptyHosts() async throws {
    let data = try Self.loadFixture("gh-auth-status-unauth")
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 1, stdout: data, stderr: Data(), stdoutOverflow: false)
    ])
    let service = Self.makeService(runner: runner)
    #expect(await service.availability() == .notLoggedIn(host: nil))
  }

  @Test
  func authenticatedHostsListsEveryLoggedInHost() async throws {
    let data = Data(
      #"{"hosts":{"github.com":[{"login":"gump","active":true}],"ghe.example.com":[{"login":"g","active":true}],"stale.example.com":[]}}"#
        .utf8)
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: data, stderr: Data(), stdoutOverflow: false)
    ])
    let service = Self.makeService(runner: runner)
    #expect(await service.authenticatedHosts() == ["github.com", "ghe.example.com"])
  }

  // MARK: - merge / close / markReady / rerunFailedChecks

  @Test
  func mergeSendsCorrectArgvWithStrategyFlag() async throws {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data(), stderr: Data(), stdoutOverflow: false)
    ])
    let service = Self.makeService(runner: runner)
    try await service.merge(Self.reference(42), strategy: .squash)
    let calls = await runner.calls
    #expect(calls.first?.arguments == ["pr", "merge", "42", "--squash", "--repo", Self.repoArgument])
    // The repository comes from the reference, never from a working directory.
    #expect(calls.first?.cwd == GitHubGitPlatform.homeDirectory)
  }

  @Test
  func mergeThrowsMergeConflictOnStderr() async {
    let stderr = Data("pull request #42 is not mergeable\n".utf8)
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 1, stdout: Data(), stderr: stderr, stdoutOverflow: false)
    ])
    let service = Self.makeService(runner: runner)
    await #expect(throws: GitPlatformError.mergeConflict) {
      try await service.merge(Self.reference(42), strategy: .squash)
    }
  }

  @Test
  func closeSendsCorrectArgv() async throws {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data(), stderr: Data(), stdoutOverflow: false)
    ])
    let service = Self.makeService(runner: runner)
    try await service.close(Self.reference(7))
    let calls = await runner.calls
    #expect(calls.first?.arguments == ["pr", "close", "7", "--repo", Self.repoArgument])
  }

  @Test
  func markReadySendsCorrectArgv() async throws {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data(), stderr: Data(), stdoutOverflow: false)
    ])
    let service = Self.makeService(runner: runner)
    try await service.markReady(Self.reference(11))
    let calls = await runner.calls
    #expect(calls.first?.arguments == ["pr", "ready", "11", "--repo", Self.repoArgument])
  }

  /// Workflow A failed (run 111); workflow B ran later and passed (run 222). The rerun
  /// must target A — the run whose failure made the button appear — not B.
  @Test
  func rerunFailedChecksTargetsTheFailedRunOfThePullRequestHead() async throws {
    let rollup = Data(
      #"""
      {"statusCheckRollup":[
        {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"FAILURE",
         "detailsUrl":"https://github.com/wanggang316/codans/actions/runs/111/job/1"},
        {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS",
         "detailsUrl":"https://github.com/wanggang316/codans/actions/runs/222/job/2"},
        {"__typename":"StatusContext","context":"ci/external","state":"FAILURE",
         "targetUrl":"https://ci.example.com/build/3"}
      ]}
      """#.utf8)
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: rollup, stderr: Data(), stdoutOverflow: false),
      .exited(code: 0, stdout: Data(), stderr: Data(), stdoutOverflow: false),
    ])
    let service = Self.makeService(runner: runner)
    try await service.rerunFailedChecks(Self.reference(42))
    let calls = await runner.calls
    #expect(calls.count == 2)
    #expect(
      calls[0].arguments == ["pr", "view", "42", "--repo", Self.repoArgument, "--json", "statusCheckRollup"])
    #expect(calls[1].arguments == ["run", "rerun", "111", "--failed", "--repo", Self.repoArgument])
  }

  @Test
  func rerunFailedChecksWithoutAFailedWorkflowRunRerunsNothing() async throws {
    let rollup = Data(
      #"{"statusCheckRollup":[{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://github.com/o/r/actions/runs/222/job/2"}]}"#
        .utf8)
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: rollup, stderr: Data(), stdoutOverflow: false)
    ])
    let service = Self.makeService(runner: runner)
    await #expect(throws: GitPlatformError.self) {
      try await service.rerunFailedChecks(Self.reference(42))
    }
    #expect(await runner.calls.count == 1)
  }

  // MARK: - web URLs

  @Test
  func webURLsUseTheRepositoryHostAndPath() {
    let service = Self.makeService(runner: RecordingCommandRunner())
    let ghes = GitPlatformRepository(kind: .github, host: "ghe.example.com", path: "platform/monorepo")
    #expect(service.repositoryWebURL(ghes)?.absoluteString == "https://ghe.example.com/platform/monorepo")
    #expect(
      service.pullRequestWebURL(PullRequestReference(repository: ghes, number: 7))?.absoluteString
        == "https://ghe.example.com/platform/monorepo/pull/7")
  }

  // MARK: - env contract

  @Test
  func envIsAllowlistedToPathHomeAndForcedLC() async throws {
    // Exercises the env filter via any `runExpecting` call.
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data(), stderr: Data(), stdoutOverflow: false)
    ])
    let service = Self.makeService(runner: runner)
    try await service.close(Self.reference(7))
    let calls = await runner.calls
    let env = try #require(calls.first?.env)
    #expect(env["LC_ALL"] == "en_US.UTF-8")
    // PATH + HOME are inherited from the parent when present; strict test environments
    // may not set either, so we only assert the forced key and the absence of leakage.
    #expect(env["GITHUB_TOKEN"] == nil)
    #expect(env["GH_TOKEN"] == nil)
    #expect(env["EDITOR"] == nil)
  }

  // MARK: - Not logged in to the repository's host

  /// `gh` output when it has no token for the host: exit 4 and the login prompt
  /// (no config), or HTTP 401 from a host it is not logged in to. Both must be a login
  /// error that names the repository's host, so the row shows the actionable message
  /// (ADR 0005 item 4: an alias whose API host is not logged in).
  @Test(arguments: [
    (Int32(4), "To get started with GitHub CLI, please run:  gh auth login\nAlternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token.\n"),
    (Int32(1), "gh: Requires authentication (HTTP 401)\n"),
    (Int32(1), "HTTP 401: Bad credentials (https://ghe.example.com/api/graphql)\n"),
  ])
  func aBatchReadWithoutALoginForTheHostIsALoginError(code: Int32, stderr: String) async {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: code, stdout: Data(), stderr: Data(stderr.utf8), stdoutOverflow: false)
    ])
    let service = Self.makeService(runner: runner)
    let repository = GitPlatformRepository(kind: .github, host: "ghe.example.com", path: "platform/app")
    await #expect(throws: GitPlatformError.notAuthenticated(.github, host: "ghe.example.com")) {
      _ = try await service.batchPullRequests(repository: repository, branches: ["feat"])
    }
  }

  /// "to get started" must not read as the host "get".
  @Test
  func theLoginPromptGivesNoHostHint() {
    #expect(
      GitHubGitPlatform.translateError(stderr: "To get started with GitHub CLI, please run:  gh auth login")
        == .notAuthenticated(.github, host: nil))
  }

  // MARK: - Helpers

  private static let repository = GitPlatformRepository(
    kind: .github, host: "github.com", path: "wanggang316/codans")
  private static let repoArgument = "github.com/wanggang316/codans"

  private static func reference(_ number: Int) -> PullRequestReference {
    PullRequestReference(repository: repository, number: number)
  }

  private static func makeService(runner: any CommandRunner) -> GitHubGitPlatform {
    let resolver = CLIExecutableResolver(prober: {
      URL(fileURLWithPath: "/opt/homebrew/bin/gh")
    })
    return GitHubGitPlatform(runner: runner, resolver: resolver)
  }

  private static func loadFixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures", isDirectory: true)
      .appendingPathComponent("\(name).json", isDirectory: false)
    return try Data(contentsOf: url)
  }
}
