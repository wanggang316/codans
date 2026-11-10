import CodansCore
import Darwin
import Foundation
import Testing

@testable import Codans

struct FoundationCommandRunnerTests {
  @Test
  func returnsWhenABackgroundProcessKeepsStdoutOpen() async throws {
    // The shell exits at once, but its background `sleep` inherited stdout
    // and keeps the pipe from reaching EOF — the same shape as a zmx daemon
    // that inherited the write end.
    let runner = FoundationCommandRunner(eofGrace: .milliseconds(200))
    let clock = ContinuousClock()
    let start = clock.now

    let outcome = await runner.run(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "sleep 30 & echo $!"],
      env: [:],
      cwd: URL(fileURLWithPath: NSTemporaryDirectory()),
      timeout: .seconds(60),
      maxOutputBytes: 1024
    )

    let elapsed = clock.now - start
    guard case .exited(let code, let stdout, _, _) = outcome else {
      Issue.record("expected .exited, got \(outcome)")
      return
    }
    let sleeperPID = String(bytes: stdout, encoding: .utf8)
      .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    if let sleeperPID { kill(sleeperPID, SIGKILL) }
    #expect(code == 0)
    #expect(sleeperPID != nil)
    #expect(elapsed < .seconds(10))
  }

  /// A Remote Project location (`codans-host://…`) is not a local directory.
  /// `Process.currentDirectoryURL` raises an Objective-C exception for a
  /// non-file URL, so the runner must refuse it before it reaches `Process`.
  @Test
  func nonFileWorkingDirectoryFailsWithoutSpawning() async {
    let runner = FoundationCommandRunner()
    let remote = GitLocation.url(path: "/srv/app", hostID: HostID(raw: UUID()))
    #expect(!remote.isFileURL)

    let outcome = await runner.run(
      executable: URL(fileURLWithPath: "/usr/bin/true"),
      arguments: [],
      env: [:],
      cwd: remote,
      timeout: .seconds(5),
      maxOutputBytes: 1024
    )

    guard case .spawnFailed(let reason) = outcome else {
      Issue.record("expected .spawnFailed, got \(outcome)")
      return
    }
    #expect(reason.contains("/srv/app"))
  }
}
