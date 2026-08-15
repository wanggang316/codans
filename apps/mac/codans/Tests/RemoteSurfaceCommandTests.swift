import CodansCore
import Foundation
import Testing

@testable import Codans

struct RemoteSurfaceCommandTests {
  private let host = RemoteHost(alias: "example.com", username: "alice", port: 2222)
  private let paneID = PaneID(raw: UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!)

  @Test
  func reconnectLoopClosesOnlyAfterARealSession() {
    let script = SSHReconnectLoop.script(connect: "CONNECT", reconnect: "RECONNECT")
    // A session that ran ≥ threshold and exited non-255 closes the pane.
    #expect(script.contains("-ge \(SSHReconnectLoop.minSessionSeconds)"))
    #expect(script.contains("[ \"$codans_rc\" -ne 255 ] && exit \"$codans_rc\""))
    #expect(script.contains("CONNECT"))
    #expect(script.contains("RECONNECT"))
    // Ctrl-C escape hatch and capped backoff.
    #expect(script.contains("trap 'exit 130' INT"))
    #expect(script.contains("-gt \(SSHReconnectLoop.maxDelaySeconds)"))
  }

  @Test
  func reconnectLoopRetriesFastFailureInsteadOfClosing() {
    let script = SSHReconnectLoop.script(connect: "CONNECT", reconnect: "RECONNECT")
    // A launch that dies before an interactive session starts must NOT silently
    // close the pane — it shows the exit code and retries.
    #expect(script.contains("Connection ended (exit %s)"))
    #expect(script.contains("codans_mode=reconnect"))
    // Times each attempt via the shell builtin (no `date` subprocess).
    #expect(script.contains("codans_t0=$SECONDS"))
  }

  @Test
  func buildProducesSyntacticallyValidShellAcrossVariants() throws {
    // Guards the four-level nested quoting: a regression there would make the
    // outer `/bin/sh -c` fail to parse, and the pane would flash-and-close.
    for zmx in ["/opt/zmx", nil] {
      for persistence in [true, false] {
        let command = RemoteSurfaceCommand.build(
          host: host, paneID: paneID, remotePath: "/srv/my app",
          localZmxPath: zmx, hostPersistence: persistence
        )
        try Self.assertShellParses(command, label: "zmx=\(zmx ?? "nil") persist=\(persistence)")
      }
    }
  }

  /// Writes `script` to a temp file and runs `/bin/sh -n` (parse-only). Fails
  /// the test with the stderr when the shell rejects the syntax.
  private static func assertShellParses(_ script: String, label: String) throws {
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("codans-surface-\(UUID().uuidString).sh")
    try script.write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sh")
    proc.arguments = ["-n", file.path]
    let err = Pipe()
    proc.standardError = err
    try proc.run()
    proc.waitUntilExit()
    let stderr =
      String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    #expect(proc.terminationStatus == 0, "sh -n rejected [\(label)]: \(stderr)")
  }

  @Test
  func connectScriptRecordsThePaneTTYForTheForegroundProbe() {
    for persistence in [true, false] {
      let script = RemoteSurfaceCommand.connectScript(
        hostSession: "codans-x", paneUUID: paneID.raw.uuidString, remotePath: "/srv/app",
        hostPersistence: persistence
      )
      // The worktree shell writes its controlling tty under the probe's
      // directory, keyed by the pane UUID, in both persistence modes.
      #expect(script.contains("pane-ttys"))
      #expect(script.contains(paneID.raw.uuidString))
      #expect(script.contains("tty >"))
    }
  }

  @Test
  func hostSessionNameIsPrefixed() {
    #expect(
      RemoteSurfaceCommand.hostSessionName(for: paneID)
        == "codans-00000000-0000-0000-0000-0000000000AB")
  }

  @Test
  func connectScriptAttachesHostSessionWhenPersistent() {
    let script = RemoteSurfaceCommand.connectScript(
      hostSession: "codans-x", paneUUID: paneID.raw.uuidString, remotePath: "/srv/app",
      hostPersistence: true
    )
    #expect(script.contains("command -v zmx"))
    #expect(script.contains("zmx attach codans-x"))
    // The worktree cd is nested inside the session command's single-quoting, so
    // assert on the unambiguous path fragment rather than the raw `'/srv/app'`.
    #expect(script.contains("cd --"))
    #expect(script.contains("/srv/app"))
  }

  @Test
  func connectScriptWithoutPersistenceIsPlainLoginShell() {
    let script = RemoteSurfaceCommand.connectScript(
      hostSession: "codans-x", paneUUID: paneID.raw.uuidString, remotePath: "/srv/app",
      hostPersistence: false
    )
    #expect(!script.contains("zmx attach"))
    #expect(script.contains("cd --"))
    #expect(script.contains("/srv/app"))
    #expect(script.contains("exec \"$SHELL\" -l"))
  }

  @Test
  func worktreeShellWarnsWhenDarwinKeychainIsLocked() throws {
    // macOS-only, and gated on the keychain actually being locked — a Linux
    // host or an unlocked keychain prints nothing.
    let notice = RemoteSurfaceCommand.lockedKeychainNotice
    #expect(notice.contains(#"[ "$(uname)" = Darwin ]"#))
    #expect(notice.contains("security show-keychain-info"))
    #expect(notice.contains("security unlock-keychain"))
    let script = RemoteSurfaceCommand.connectScript(
      hostSession: "codans-x", paneUUID: paneID.raw.uuidString, remotePath: "/srv/app",
      hostPersistence: true
    )
    #expect(script.contains("show-keychain-info"))
    // The full build still parses as valid shell with the notice embedded
    // (its single-quoted printf crosses every quoting layer).
    let command = RemoteSurfaceCommand.build(
      host: host, paneID: paneID, remotePath: "/srv/app",
      localZmxPath: "/opt/zmx", hostPersistence: true
    )
    try Self.assertShellParses(command, label: "keychain-notice")
  }

  @Test
  func reconnectScriptNeverRecreatesButReattaches() {
    let script = RemoteSurfaceCommand.reconnectScript(
      hostSession: "codans-x", paneUUID: paneID.raw.uuidString, remotePath: "/srv/app",
      hostPersistence: true
    )
    // Only reattaches an existing session; exits 0 if it ended while away.
    #expect(script.contains("zmx list --short"))
    #expect(script.contains("exec zmx attach codans-x"))
    #expect(script.contains("exit 0"))
  }

  @Test
  func buildWrapsLoopInLocalZmxWhenAvailable() {
    let command = RemoteSurfaceCommand.build(
      host: host,
      paneID: paneID,
      remotePath: "/srv/app",
      localZmxPath: "/opt/zmx",
      hostPersistence: true
    )
    // Local zmx session is the bare pane UUID (resume parity with local panes).
    #expect(command.contains("'/opt/zmx' attach '\(paneID.raw.uuidString)'"))
    // The inner ssh line targets the host.
    #expect(command.contains("/usr/bin/ssh"))
    #expect(command.contains("alice@example.com"))
  }

  @Test
  func buildFallsBackToBareLoopWithoutLocalZmx() {
    let command = RemoteSurfaceCommand.build(
      host: host,
      paneID: paneID,
      remotePath: "/srv/app",
      localZmxPath: nil,
      hostPersistence: true
    )
    // No local zmx wrapper — just the reconnect loop.
    #expect(!command.contains("attach '\(paneID.raw.uuidString)'"))
    #expect(command.contains("trap 'exit 130' INT"))
    #expect(command.contains("/usr/bin/ssh"))
  }
}
