import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// Service-level tests for `LiveGitService.remoteInfo(at:)`. Covers the happy path
/// (stdout parses cleanly) and the translation of `RemoteInfo.ParseError.malformed` into
/// the app-layer `GitError.malformedRemoteURL`. Uses `RecordingCommandRunner` so no real
/// git process is spawned.
struct LiveGitServiceRemoteInfoTests {
  @Test
  func returnsParsedRemoteInfoOnCleanStdout() async throws {
    // ensureIsRepo (rev-parse) then the actual git remote get-url call.
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data("true\n".utf8), stderr: Data(), stdoutOverflow: false),
      .exited(
        code: 0,
        stdout: Data("git@github.com:wanggang316/touch-code.git\n".utf8),
        stderr: Data(),
        stdoutOverflow: false
      ),
    ])
    let service = LiveGitService(runner: runner)
    let info = try await service.remoteInfo(at: URL(fileURLWithPath: "/tmp"))
    #expect(info.host == "github.com")
    #expect(info.owner == "wanggang316")
    #expect(info.repo == "touch-code")
  }

  @Test
  func malformedRemoteURLIsTranslatedToGitError() async {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data("true\n".utf8), stderr: Data(), stdoutOverflow: false),
      .exited(
        code: 0,
        stdout: Data("not a url at all\n".utf8),
        stderr: Data(),
        stdoutOverflow: false
      ),
    ])
    let service = LiveGitService(runner: runner)
    await #expect(throws: GitError.malformedRemoteURL("not a url at all")) {
      _ = try await service.remoteInfo(at: URL(fileURLWithPath: "/tmp"))
    }
  }

  @Test
  func nonZeroExitPropagatesAsExec() async {
    // `git remote get-url origin` returns non-zero when the remote does not exist.
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data("true\n".utf8), stderr: Data(), stdoutOverflow: false),
      .exited(
        code: 128,
        stdout: Data(),
        stderr: Data("error: No such remote 'origin'\n".utf8),
        stdoutOverflow: false
      ),
    ])
    let service = LiveGitService(runner: runner)
    await #expect(
      throws: GitError.exec(code: 128, stderr: "error: No such remote 'origin'\n")
    ) {
      _ = try await service.remoteInfo(at: URL(fileURLWithPath: "/tmp"))
    }
  }
}
