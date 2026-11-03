import Foundation
import Testing
import CodansCore

@testable import Codans

/// Negative and happy path coverage for GitHubCodeHost. Uses RecordingCommandRunner
/// (the existing actor test double from codans/Process/) to feed canned
/// CommandOutcomes and asserts both the returned value + the exact argv sent to gh.
struct GitHubCodeHostTests {
  // MARK: - availability

  @Test
  func availabilityReturnsUnavailableWhenGhMissing() async throws {
    let runner = RecordingCommandRunner()
    let resolver = GhExecutableResolver(prober: { nil })
    let service = GitHubCodeHost(runner: runner, resolver: resolver)
    let result = await service.availability()
    if case .unavailable = result { /* expected */
    } else {
      Issue.record("expected .unavailable, got \(result)")
    }
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
  func availabilityReportsUnavailableOnEmptyHosts() async throws {
    let data = try Self.loadFixture("gh-auth-status-unauth")
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 1, stdout: data, stderr: Data(), stdoutOverflow: false)
    ])
    let service = Self.makeService(runner: runner)
    let result = await service.availability()
    if case .unavailable = result { /* ok */
    } else {
      Issue.record("expected .unavailable, got \(result)")
    }
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

  // MARK: - latestWorkflowRun

  @Test
  func latestWorkflowRunReturnsNilOnEmptyList() async throws {
    let data = try Self.loadFixture("gh-run-list-empty")
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: data, stderr: Data(), stdoutOverflow: false)
    ])
    let service = Self.makeService(runner: runner)
    let run = try await service.latestWorkflowRun(branch: "main", repo: Self.repoArgument)
    #expect(run == nil)
  }

  // MARK: - merge / close / markReady / rerunFailedJobs

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
    #expect(calls.first?.cwd == GitHubCodeHost.homeDirectory)
  }

  @Test
  func mergeThrowsMergeConflictOnStderr() async {
    let stderr = Data("pull request #42 is not mergeable\n".utf8)
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 1, stdout: Data(), stderr: stderr, stdoutOverflow: false)
    ])
    let service = Self.makeService(runner: runner)
    await #expect(throws: CodeHostError.mergeConflict) {
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

  @Test
  func rerunFailedChecksRerunsTheLatestRunOfTheSourceBranch() async throws {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(
        code: 0, stdout: Data(#"{"headRefName":"feature/github01"}"#.utf8), stderr: Data(),
        stdoutOverflow: false),
      .exited(
        code: 0, stdout: try Self.loadFixture("gh-run-list-success"), stderr: Data(), stdoutOverflow: false),
      .exited(code: 0, stdout: Data(), stderr: Data(), stdoutOverflow: false),
    ])
    let service = Self.makeService(runner: runner)
    try await service.rerunFailedChecks(Self.reference(42))
    let calls = await runner.calls
    #expect(calls.count == 3)
    #expect(calls[0].arguments == ["pr", "view", "42", "--repo", Self.repoArgument, "--json", "headRefName"])
    #expect(Array(calls[1].arguments.prefix(4)) == ["run", "list", "--branch", "feature/github01"])
    #expect(Array(calls[2].arguments) == ["run", "rerun", "123456789", "--failed", "--repo", Self.repoArgument])
  }

  // MARK: - web URLs

  @Test
  func webURLsUseTheRepositoryHostAndPath() {
    let service = Self.makeService(runner: RecordingCommandRunner())
    let ghes = CodeHostRepository(kind: .github, host: "ghe.example.com", path: "platform/monorepo")
    #expect(service.repositoryWebURL(ghes)?.absoluteString == "https://ghe.example.com/platform/monorepo")
    #expect(
      service.pullRequestWebURL(PullRequestReference(repository: ghes, number: 7))?.absoluteString
        == "https://ghe.example.com/platform/monorepo/pull/7")
  }

  // MARK: - env contract

  @Test
  func envIsAllowlistedToPathHomeAndForcedLC() async throws {
    // Exercises the env-filter via any `runExpecting` call — latestWorkflowRun is
    // convenient because gh-run-list-success is already a first-class fixture.
    let runner = RecordingCommandRunner(outcomes: [
      .exited(
        code: 0, stdout: try Self.loadFixture("gh-run-list-success"),
        stderr: Data(), stdoutOverflow: false)
    ])
    let service = Self.makeService(runner: runner)
    _ = try await service.latestWorkflowRun(branch: "feature/github01", repo: Self.repoArgument)
    let calls = await runner.calls
    let env = try #require(calls.first?.env)
    #expect(env["LC_ALL"] == "en_US.UTF-8")
    // PATH + HOME are inherited from the parent when present; strict test environments
    // may not set either, so we only assert the forced key and the absence of leakage.
    #expect(env["GITHUB_TOKEN"] == nil)
    #expect(env["GH_TOKEN"] == nil)
    #expect(env["EDITOR"] == nil)
  }

  // MARK: - Helpers

  private static let repository = CodeHostRepository(
    kind: .github, host: "github.com", path: "wanggang316/codans")
  private static let repoArgument = "github.com/wanggang316/codans"

  private static func reference(_ number: Int) -> PullRequestReference {
    PullRequestReference(repository: repository, number: number)
  }

  private static func makeService(runner: any CommandRunner) -> GitHubCodeHost {
    let resolver = GhExecutableResolver(prober: {
      URL(fileURLWithPath: "/opt/homebrew/bin/gh")
    })
    return GitHubCodeHost(runner: runner, resolver: resolver)
  }

  private static func loadFixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures", isDirectory: true)
      .appendingPathComponent("\(name).json", isDirectory: false)
    return try Data(contentsOf: url)
  }
}
