import Foundation
import Testing

@testable import Codans

/// Classification table for the `git --version` environment probe. Every case runs off a
/// synthesised `CommandOutcome`, so the suite never spawns git and never depends on the
/// host machine's Xcode license state.
struct GitEnvironmentStatusTests {
  private func exited(_ code: Int32, stderr: String = "", stdout: String = "") -> CommandOutcome {
    .exited(
      code: code,
      stdout: Data(stdout.utf8),
      stderr: Data(stderr.utf8),
      stdoutOverflow: false
    )
  }

  @Test
  func successfulVersionIsOk() {
    let status = GitEnvironmentStatus.classify(
      exited(0, stdout: "git version 2.39.5 (Apple Git-154)\n")
    )
    #expect(status == .ok(version: "git version 2.39.5 (Apple Git-154)"))
    #expect(status.block == nil)
  }

  /// Verbatim stderr from a Mac where the license was never accepted — the state this whole
  /// feature exists for.
  @Test
  func xcodeLicenseGateIsClassified() {
    let stderr = """
      Agreeing to the Xcode/iOS license requires admin privileges, \
      please run "sudo xcodebuild -license" and then retry this command.
      """
    #expect(
      GitEnvironmentStatus.classify(exited(69, stderr: stderr))
        == .blocked(.xcodeLicenseNotAccepted)
    )
  }

  /// The license text also ships under other exit codes depending on the shim version, so
  /// classification must key off the message, not the code alone.
  @Test
  func xcodeLicenseGateIsClassifiedRegardlessOfExitCode() {
    let stderr = "You have not agreed to the Xcode license agreements.\n"
    #expect(
      GitEnvironmentStatus.classify(exited(1, stderr: stderr))
        == .blocked(.xcodeLicenseNotAccepted)
    )
  }

  @Test
  func missingDeveloperToolsIsClassified() {
    let stderr = "xcode-select: note: No developer tools were found, requesting install.\n"
    #expect(
      GitEnvironmentStatus.classify(exited(1, stderr: stderr))
        == .blocked(.developerToolsMissing)
    )
  }

  /// Classic post-macOS-upgrade state: the tools directory the shim points at is gone.
  @Test
  func staleDeveloperPathIsClassified() {
    let stderr = """
      xcrun: error: invalid active developer path (/Library/Developer/CommandLineTools), \
      missing xcrun at: /Library/Developer/CommandLineTools/usr/bin/xcrun
      """
    #expect(
      GitEnvironmentStatus.classify(exited(1, stderr: stderr))
        == .blocked(.developerToolsMissing)
    )
  }

  @Test
  func spawnFailureIsGitNotFound() {
    #expect(
      GitEnvironmentStatus.classify(.spawnFailed(reason: "binary not found: /usr/bin/git"))
        == .blocked(.gitNotFound)
    )
  }

  @Test
  func timeoutIsBlockedAsUnknown() {
    #expect(GitEnvironmentStatus.classify(.timedOut).block != nil)
  }

  /// An unrecognised failure echoes git's own first stderr line rather than inventing a remedy.
  @Test
  func unrecognisedFailureEchoesFirstStderrLine() {
    let status = GitEnvironmentStatus.classify(
      exited(128, stderr: "fatal: detected dubious ownership\nsecond line ignored\n")
    )
    #expect(status == .blocked(.unknown(detail: "fatal: detected dubious ownership")))
    #expect(status.block?.remedyCommand == nil)
  }

  @Test
  func unrecognisedFailureWithEmptyStderrFallsBackToExitCode() {
    #expect(
      GitEnvironmentStatus.classify(exited(3))
        == .blocked(.unknown(detail: "git --version exited with code 3."))
    )
  }

  /// The two blocks users can act on must actually offer a command; the banner's Copy button
  /// is the whole point of the feature.
  @Test
  func actionableBlocksCarryARemedyCommand() {
    #expect(GitEnvironmentBlock.xcodeLicenseNotAccepted.remedyCommand == "sudo xcodebuild -license accept")
    #expect(GitEnvironmentBlock.developerToolsMissing.remedyCommand == "xcode-select --install")
    #expect(GitEnvironmentBlock.gitNotFound.remedyCommand == "xcode-select --install")
  }
}

/// Caching / refresh contract of the probe actor. A single-outcome
/// `RecordingCommandRunner` replays that outcome indefinitely and records every call, so
/// `calls.count` is what makes the cache observable.
struct GitEnvironmentProbeTests {
  @Test
  func blockedEnvironmentIsReportedAndCached() async {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(
        code: 69,
        stdout: Data(),
        stderr: Data("Agreeing to the Xcode/iOS license requires admin privileges\n".utf8),
        stdoutOverflow: false
      )
    ])
    let probe = GitEnvironmentProbe(runner: runner)

    #expect(await probe.status() == .blocked(.xcodeLicenseNotAccepted))
    #expect(await probe.status() == .blocked(.xcodeLicenseNotAccepted))
    // Second read must come from the cache — the probe sits on the sidebar's appear path.
    #expect(await runner.calls.count == 1)
  }

  /// The probe must invoke `git --version` and nothing else — a probe that shelled out to a
  /// repository-scoped command would fail for reasons unrelated to the environment.
  @Test
  func probeRunsGitVersionOnly() async {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data("git version 2.51.0\n".utf8), stderr: Data(), stdoutOverflow: false)
    ])
    _ = await GitEnvironmentProbe(runner: runner).status()

    let calls = await runner.calls
    #expect(calls.count == 1)
    #expect(calls.first?.arguments == ["--version"])
    // Locale pinning is what makes English stderr matching sound.
    #expect(calls.first?.env["LC_ALL"] == "C.UTF-8")
  }

  @Test
  func refreshBustsTheCache() async {
    let runner = RecordingCommandRunner(outcomes: [
      .spawnFailed(reason: "binary not found: /usr/bin/git")
    ])
    let probe = GitEnvironmentProbe(runner: runner)

    #expect(await probe.status() == .blocked(.gitNotFound))
    #expect(await probe.refresh() == .blocked(.gitNotFound))
    #expect(await runner.calls.count == 2)
  }

  @Test
  func healthyEnvironmentReportsOk() async {
    let probe = GitEnvironmentProbe(
      runner: RecordingCommandRunner(outcomes: [
        .exited(
          code: 0,
          stdout: Data("git version 2.51.0\n".utf8),
          stderr: Data(),
          stdoutOverflow: false
        )
      ])
    )
    #expect(await probe.status().block == nil)
  }
}
