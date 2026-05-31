import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// Negative and happy path coverage for LiveGitHubService. Uses RecordingCommandRunner
/// (the existing actor test double from touch-code/Process/) to feed canned
/// CommandOutcomes and asserts both the returned value + the exact argv sent to gh.
///
/// Integration tests against a real gh live in LiveGitHubServiceIntegrationTests,
/// env-gated by TC_RUN_GITHUB_INTEGRATION_TESTS=1.
struct LiveGitHubServiceTests {
  // MARK: - availability

  @Test
  func availabilityReturnsUnavailableWhenGhMissing() async throws {
    let runner = RecordingCommandRunner()
    let resolver = GhExecutableResolver(prober: { nil })
    let service = LiveGitHubService(runner: runner, resolver: resolver)
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

  // MARK: - latestWorkflowRun

  @Test
  func latestWorkflowRunReturnsNilOnEmptyList() async throws {
    let data = try Self.loadFixture("gh-run-list-empty")
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: data, stderr: Data(), stdoutOverflow: false)
    ])
    let service = Self.makeService(runner: runner)
    let run = try await service.latestWorkflowRun(branch: "main", worktreePath: Self.worktreePath)
    #expect(run == nil)
  }

  // MARK: - merge / close / markReady / rerunFailedJobs

  @Test
  func mergeSendsCorrectArgvWithStrategyFlag() async throws {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data(), stderr: Data(), stdoutOverflow: false)
    ])
    let service = Self.makeService(runner: runner)
    try await service.merge(number: 42, strategy: .squash, worktreePath: Self.worktreePath)
    let calls = await runner.calls
    #expect(calls.first?.arguments == ["pr", "merge", "42", "--squash"])
    #expect(calls.first?.cwd == Self.worktreePath)
  }

  @Test
  func mergeThrowsMergeConflictOnStderr() async {
    let stderr = Data("pull request #42 is not mergeable\n".utf8)
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 1, stdout: Data(), stderr: stderr, stdoutOverflow: false)
    ])
    let service = Self.makeService(runner: runner)
    await #expect(throws: GitHubError.mergeConflict) {
      try await service.merge(number: 42, strategy: .squash, worktreePath: Self.worktreePath)
    }
  }

  @Test
  func closeSendsCorrectArgv() async throws {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data(), stderr: Data(), stdoutOverflow: false)
    ])
    let service = Self.makeService(runner: runner)
    try await service.close(number: 7, worktreePath: Self.worktreePath)
    let calls = await runner.calls
    #expect(calls.first?.arguments == ["pr", "close", "7"])
  }

  @Test
  func markReadySendsCorrectArgv() async throws {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data(), stderr: Data(), stdoutOverflow: false)
    ])
    let service = Self.makeService(runner: runner)
    try await service.markReady(number: 11, worktreePath: Self.worktreePath)
    let calls = await runner.calls
    #expect(calls.first?.arguments == ["pr", "ready", "11"])
  }

  @Test
  func rerunFailedJobsSendsCorrectArgv() async throws {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data(), stderr: Data(), stdoutOverflow: false)
    ])
    let service = Self.makeService(runner: runner)
    try await service.rerunFailedJobs(runID: 123, worktreePath: Self.worktreePath)
    let calls = await runner.calls
    #expect(calls.first?.arguments == ["run", "rerun", "123", "--failed"])
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
    _ = try await service.latestWorkflowRun(branch: "feature/github01", worktreePath: Self.worktreePath)
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

  private static let worktreePath = URL(fileURLWithPath: "/tmp/touch-code-test-worktree")

  private static func makeService(runner: any CommandRunner) -> LiveGitHubService {
    let resolver = GhExecutableResolver(prober: {
      URL(fileURLWithPath: "/opt/homebrew/bin/gh")
    })
    return LiveGitHubService(runner: runner, resolver: resolver)
  }

  private static func loadFixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures", isDirectory: true)
      .appendingPathComponent("\(name).json", isDirectory: false)
    return try Data(contentsOf: url)
  }
}
