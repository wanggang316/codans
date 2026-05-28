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
    let calls = await runner.calls
    #expect(calls.count == 2)  // ensureIsRepo + symbolic-ref
    #expect(calls.last?.arguments == ["symbolic-ref", "--short", "HEAD"])
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
    let calls = await runner.calls
    #expect(calls.count == 2)
    #expect(
      calls.last?.arguments == [
        "-c", "core.quotePath=false",
        "for-each-ref",
        "--format=%(refname)%09%(refname:short)%09%(upstream:short)%09%(HEAD)",
        "refs/heads", "refs/remotes",
      ]
    )
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

  // MARK: - renameBranch

  @Test
  func renameBranchIssuesTwoArgBranchM() async throws {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data("true\n".utf8), stderr: Data(), stdoutOverflow: false),
      .exited(code: 0, stdout: Data(), stderr: Data(), stdoutOverflow: false),
    ])
    let service = LiveGitService(runner: runner)
    try await service.renameBranch(
      from: "old",
      to: "new",
      at: URL(fileURLWithPath: "/tmp")
    )
    let calls = await runner.calls
    #expect(calls.count == 2)
    #expect(calls.last?.arguments == ["branch", "-m", "old", "new"])
  }

  @Test
  func renameBranchPropagatesGitError() async {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data("true\n".utf8), stderr: Data(), stdoutOverflow: false),
      .exited(
        code: 128,
        stdout: Data(),
        stderr: Data("fatal: A branch named 'main' already exists.\n".utf8),
        stdoutOverflow: false
      ),
    ])
    let service = LiveGitService(runner: runner)
    await #expect(
      throws: GitError.exec(code: 128, stderr: "fatal: A branch named 'main' already exists.\n")
    ) {
      _ = try await service.renameBranch(
        from: "feat/x",
        to: "main",
        at: URL(fileURLWithPath: "/tmp")
      )
    }
  }

  // MARK: - createAndSwitchBranch

  @Test
  func createAndSwitchBranchIssuesSwitchCArgv() async throws {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data("true\n".utf8), stderr: Data(), stdoutOverflow: false),
      .exited(code: 0, stdout: Data(), stderr: Data(), stdoutOverflow: false),
    ])
    let service = LiveGitService(runner: runner)
    try await service.createAndSwitchBranch(
      name: "feat/y",
      from: "main",
      at: URL(fileURLWithPath: "/tmp")
    )
    let calls = await runner.calls
    #expect(calls.count == 2)
    #expect(calls.last?.arguments == ["switch", "-c", "feat/y", "main"])
  }

  @Test
  func createAndSwitchBranchPropagatesGitError() async {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data("true\n".utf8), stderr: Data(), stdoutOverflow: false),
      .exited(
        code: 128,
        stdout: Data(),
        stderr: Data("fatal: A branch named 'main' already exists.\n".utf8),
        stdoutOverflow: false
      ),
    ])
    let service = LiveGitService(runner: runner)
    await #expect(
      throws: GitError.exec(code: 128, stderr: "fatal: A branch named 'main' already exists.\n")
    ) {
      _ = try await service.createAndSwitchBranch(
        name: "main",
        from: "main",
        at: URL(fileURLWithPath: "/tmp")
      )
    }
  }

  // MARK: - commitMessage

  @Test
  func commitMessageReturnsTrimmedMultiLineMessage() async throws {
    let body = "subject line\n\nbody paragraph one\nbody paragraph two\n"
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data("true\n".utf8), stderr: Data(), stdoutOverflow: false),
      .exited(code: 0, stdout: Data(body.utf8), stderr: Data(), stdoutOverflow: false),
    ])
    let service = LiveGitService(runner: runner)
    let message = try await service.commitMessage(
      sha: "deadbeef",
      at: URL(fileURLWithPath: "/tmp")
    )
    // Trailing newline trimmed; multi-line body otherwise preserved verbatim.
    #expect(message == "subject line\n\nbody paragraph one\nbody paragraph two")
    let calls = await runner.calls
    #expect(calls.count == 2)
    #expect(calls.last?.arguments == ["log", "-1", "--format=%B", "deadbeef"])
  }

  @Test
  func commitMessagePropagatesGitErrorForUnknownSha() async {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data("true\n".utf8), stderr: Data(), stdoutOverflow: false),
      .exited(
        code: 128,
        stdout: Data(),
        stderr: Data("fatal: bad revision 'nope'\n".utf8),
        stdoutOverflow: false
      ),
    ])
    let service = LiveGitService(runner: runner)
    // `bad revision` is one of the canonical phrases the shared `run` helper
    // remaps to `.notARepo` (worktree-removed race). The exec branch for
    // commitMessage thus surfaces as `.notARepo` rather than `.exec`.
    await #expect(throws: GitError.notARepo) {
      _ = try await service.commitMessage(
        sha: "nope",
        at: URL(fileURLWithPath: "/tmp")
      )
    }
  }
}
