import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// Negative-path unit tests for `LiveGitService.run` via the `RecordingCommandRunner` seam.
/// Complements the gated `LiveGitServiceIntegrationTests` by exercising every
/// `CommandOutcome → GitError` branch without a real git process.
struct LiveGitServiceRunnerTests {
  @Test
  func timeoutSurfacesTimedOut() async {
    // rev-parse (first call) exits 0, then the real command times out.
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data("true\n".utf8), stderr: Data(), stdoutOverflow: false),
      .timedOut,
    ])
    let service = LiveGitService(runner: runner)
    await #expect(throws: GitError.timedOut) {
      _ = try await service.log(at: URL(fileURLWithPath: "/tmp"), page: .init(offset: 0, limit: 10))
    }
  }

  @Test
  func outputCapSurfacesOutputTooLarge() async {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data("true\n".utf8), stderr: Data(), stdoutOverflow: false),
      .exited(code: 0, stdout: Data(), stderr: Data(), stdoutOverflow: true),
    ])
    let service = LiveGitService(runner: runner)
    await #expect(throws: GitError.outputTooLarge) {
      _ = try await service.workingTreeDiff(at: URL(fileURLWithPath: "/tmp"))
    }
  }

  @Test
  func nonZeroExitSurfacesExecWithStderr() async {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data("true\n".utf8), stderr: Data(), stdoutOverflow: false),
      .exited(code: 1, stdout: Data(), stderr: Data("fatal: something else\n".utf8), stdoutOverflow: false),
    ])
    let service = LiveGitService(runner: runner)
    await #expect(throws: GitError.exec(code: 1, stderr: "fatal: something else\n")) {
      _ = try await service.workingTreeDiff(at: URL(fileURLWithPath: "/tmp"))
    }
  }

  @Test
  func revParseFailureSurfacesNotARepo() async {
    // The first (only) call is ensureIsRepo; non-zero exit = not a repo.
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 128, stdout: Data(), stderr: Data("fatal: not a git repository\n".utf8), stdoutOverflow: false)
    ])
    let service = LiveGitService(runner: runner)
    await #expect(throws: GitError.notARepo) {
      _ = try await service.log(at: URL(fileURLWithPath: "/tmp"), page: .init(offset: 0, limit: 10))
    }
  }

  @Test
  func binaryNotFoundSurfacesGitMissing() async {
    let runner = RecordingCommandRunner(outcomes: [
      .spawnFailed(reason: "binary not found: /usr/bin/git")
    ])
    let service = LiveGitService(runner: runner)
    await #expect(throws: GitError.gitMissing) {
      _ = try await service.log(at: URL(fileURLWithPath: "/tmp"), page: .init(offset: 0, limit: 10))
    }
  }

  @Test
  func invalidShaRejectedBeforeRunnerCall() async {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data("true\n".utf8), stderr: Data(), stdoutOverflow: false)
    ])
    let service = LiveGitService(runner: runner)
    await #expect(throws: GitError.invalidInput("not a git SHA: 'notahex'")) {
      _ = try await service.commitDiff(at: URL(fileURLWithPath: "/tmp"), sha: "notahex")
    }
    // Only the ensureIsRepo call... wait, invalid SHA check is BEFORE ensureIsRepo? Let's verify.
    let calls = await runner.calls
    // SHA validation happens first, so no runner call at all.
    #expect(calls.isEmpty, "invalid SHA must be rejected before any runner invocation")
  }

  @Test
  func fatalNotARepoInStderrAfterPrecheckAlsoSurfacesNotARepo() async {
    // Stressing the "pre-check race" path: ensureIsRepo passes, but the subsequent command
    // arrives after the worktree vanished. Canonical stderr still maps to .notARepo.
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data("true\n".utf8), stderr: Data(), stdoutOverflow: false),
      .exited(code: 128, stdout: Data(), stderr: Data("fatal: not a git repository\n".utf8), stdoutOverflow: false),
    ])
    let service = LiveGitService(runner: runner)
    await #expect(throws: GitError.notARepo) {
      _ = try await service.status(at: URL(fileURLWithPath: "/tmp"))
    }
  }

  @Test
  func runnerReceivesEnvAllowlistAndCwd() async throws {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data("true\n".utf8), stderr: Data(), stdoutOverflow: false),
      .exited(code: 0, stdout: Data(), stderr: Data(), stdoutOverflow: false),
    ])
    let service = LiveGitService(runner: runner)
    _ = try await service.status(at: URL(fileURLWithPath: "/tmp"))
    let calls = await runner.calls
    #expect(calls.count == 2)
    for call in calls {
      // env allowlist
      #expect(Set(call.env.keys).isSubset(of: Set(["PATH", "HOME", "LC_ALL"])))
      #expect(call.env["LC_ALL"] == "C.UTF-8")
      #expect(call.env["SHELL"] == nil)
      #expect(call.cwd.path == "/tmp")
      #expect(call.executable.path == "/usr/bin/git")
    }
  }
}

/// Tests that the log parser now rejects unparseable dates instead of returning epoch-0.
struct GitOutputParserDateTests {
  @Test
  func unparseableDateThrows() {
    // Hash ok, but the date field is garbage. Six fields total, record-separated by \0.
    let fixture = "abc1234567890abc1234567890abc1234567890a\0Gump\0g@x.com\0not-a-date\0subj\0\0"
    #expect(throws: (any Error).self) {
      try GitOutputParser.parseLog(Data(fixture.utf8))
    }
  }
}

/// Tests the new `@@ -0,0 +1,n @@` new-file boundary form and a few related hunk headers.
struct DiffParserHunkHeaderBoundaryTests {
  @Test
  func newFileBoundaryHeader() throws {
    let fixture = """
      diff --git a/new.txt b/new.txt
      new file mode 100644
      index 0000000..abcdef0
      --- /dev/null
      +++ b/new.txt
      @@ -0,0 +1,2 @@
      +first line
      +second line
      """
    let diff = try DiffParser.parse(Data(fixture.utf8), scope: .working)
    let hunk = diff.files[0].hunks[0]
    #expect(hunk.oldStart == 0)
    #expect(hunk.oldCount == 0)
    #expect(hunk.newStart == 1)
    #expect(hunk.newCount == 2)
  }

  @Test
  func singleLineDeletionHeader() throws {
    let fixture = """
      diff --git a/old.txt b/old.txt
      deleted file mode 100644
      index abcdef0..0000000
      --- a/old.txt
      +++ /dev/null
      @@ -1,2 +0,0 @@
      -first
      -second
      """
    let diff = try DiffParser.parse(Data(fixture.utf8), scope: .working)
    let hunk = diff.files[0].hunks[0]
    #expect(hunk.oldStart == 1)
    #expect(hunk.oldCount == 2)
    #expect(hunk.newStart == 0)
    #expect(hunk.newCount == 0)
  }
}
