import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// Service-level tests for `LiveGitService.currentBranch / listAllBranches /
/// switchBranch`. Drives the `RecordingCommandRunner` seam — no real git
/// process is spawned. Every scenario starts with the `ensureIsRepo`
/// `rev-parse --is-inside-work-tree` outcome (exit 0, stdout "true\n").
struct LiveGitServiceBranchTests {
  // MARK: - currentBranch

  @Test
  func currentBranchReturnsShortNameOnRefHEAD() async throws {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data("true\n".utf8), stderr: Data(), stdoutOverflow: false),
      .exited(code: 0, stdout: Data("main\n".utf8), stderr: Data(), stdoutOverflow: false),
    ])
    let service = LiveGitService(runner: runner)
    let branch = try await service.currentBranch(at: URL(fileURLWithPath: "/tmp"))
    #expect(branch == "main")
  }

  @Test
  func currentBranchReturnsNilOnDetachedHEAD() async throws {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data("true\n".utf8), stderr: Data(), stdoutOverflow: false),
      .exited(
        code: 1,
        stdout: Data(),
        stderr: Data("fatal: ref HEAD is not a symbolic ref\n".utf8),
        stdoutOverflow: false
      ),
    ])
    let service = LiveGitService(runner: runner)
    let branch = try await service.currentBranch(at: URL(fileURLWithPath: "/tmp"))
    #expect(branch == nil)
  }

  @Test
  func currentBranchPropagatesNonDetachedExecError() async {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data("true\n".utf8), stderr: Data(), stdoutOverflow: false),
      .exited(
        code: 128,
        stdout: Data(),
        stderr: Data("fatal: unable to read HEAD\n".utf8),
        stdoutOverflow: false
      ),
    ])
    let service = LiveGitService(runner: runner)
    await #expect(
      throws: GitError.exec(code: 128, stderr: "fatal: unable to read HEAD\n")
    ) {
      _ = try await service.currentBranch(at: URL(fileURLWithPath: "/tmp"))
    }
  }

  // MARK: - listAllBranches

  @Test
  func listAllBranchesParsesInventory() async throws {
    // Three records: current local `main`, untracked local `feature/x`, remote `origin/main`.
    // Fields per record: refname \t shortName \t upstream \t HEAD-marker.
    let stdout = """
      refs/heads/main\tmain\torigin/main\t*
      refs/heads/feature/x\tfeature/x\t\t\u{20}
      refs/remotes/origin/main\torigin/main\t\t\u{20}

      """
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data("true\n".utf8), stderr: Data(), stdoutOverflow: false),
      .exited(code: 0, stdout: Data(stdout.utf8), stderr: Data(), stdoutOverflow: false),
    ])
    let service = LiveGitService(runner: runner)
    let inventory = try await service.listAllBranches(at: URL(fileURLWithPath: "/tmp"))
    #expect(inventory.current == "main")
    // `main` is pinned to position 0 because it's the current branch; the rest are sorted.
    #expect(inventory.local.map(\.shortName) == ["main", "feature/x"])
    #expect(inventory.remote.map(\.shortName) == ["origin/main"])
  }

  // MARK: - switchBranch

  @Test
  func switchBranchLocalIssuesPlainSwitch() async throws {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data("true\n".utf8), stderr: Data(), stdoutOverflow: false),
      .exited(code: 0, stdout: Data(), stderr: Data(), stdoutOverflow: false),
    ])
    let service = LiveGitService(runner: runner)
    try await service.switchBranch(to: .local(name: "main"), at: URL(fileURLWithPath: "/tmp"))
    let calls = await runner.calls
    #expect(calls.last?.arguments == ["switch", "main"])
  }

  @Test
  func switchBranchRemoteTrackingIssuesTrackFlag() async throws {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data("true\n".utf8), stderr: Data(), stdoutOverflow: false),
      .exited(code: 0, stdout: Data(), stderr: Data(), stdoutOverflow: false),
    ])
    let service = LiveGitService(runner: runner)
    try await service.switchBranch(
      to: .remoteTracking(shortName: "origin/feat/x"),
      at: URL(fileURLWithPath: "/tmp")
    )
    let calls = await runner.calls
    #expect(calls.last?.arguments == ["switch", "--track", "origin/feat/x"])
  }

  @Test
  func switchBranchPropagatesDirtyTreeError() async {
    let stderr =
      "error: Your local changes to the following files would be overwritten by checkout:\n"
      + "\tREADME.md\n"
      + "Please commit your changes or stash them before you switch branches.\n"
      + "Aborting\n"
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data("true\n".utf8), stderr: Data(), stdoutOverflow: false),
      .exited(code: 1, stdout: Data(), stderr: Data(stderr.utf8), stdoutOverflow: false),
    ])
    let service = LiveGitService(runner: runner)
    await #expect(throws: GitError.exec(code: 1, stderr: stderr)) {
      try await service.switchBranch(
        to: .local(name: "feature/x"),
        at: URL(fileURLWithPath: "/tmp")
      )
    }
  }
}
