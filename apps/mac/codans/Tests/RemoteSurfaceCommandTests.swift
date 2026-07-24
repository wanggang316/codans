import CodansCore
import Foundation
import Testing

@testable import Codans

struct RemoteSurfaceCommandTests {
  private let host = RemoteHost(alias: "example.com", username: "alice", port: 2222)
  private let paneID = PaneID(raw: UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!)

  @Test
  func reconnectLoopRetriesOnly255() {
    let script = SSHReconnectLoop.script(connect: "CONNECT", reconnect: "RECONNECT")
    // Non-255 exits pass through and close the surface; 255 retries.
    #expect(script.contains("[ \"$codans_rc\" -ne 255 ] && exit \"$codans_rc\""))
    #expect(script.contains("CONNECT"))
    #expect(script.contains("RECONNECT"))
    // Ctrl-C escape hatch and capped backoff.
    #expect(script.contains("trap 'exit 130' INT"))
    #expect(script.contains("-gt \(SSHReconnectLoop.maxDelaySeconds)"))
  }

  @Test
  func hostSessionNameIsPrefixed() {
    #expect(RemoteSurfaceCommand.hostSessionName(for: paneID)
      == "codans-00000000-0000-0000-0000-0000000000AB")
  }

  @Test
  func connectScriptAttachesHostSessionWhenPersistent() {
    let script = RemoteSurfaceCommand.connectScript(
      hostSession: "codans-x", remotePath: "/srv/app", hostPersistence: true
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
      hostSession: "codans-x", remotePath: "/srv/app", hostPersistence: false
    )
    #expect(!script.contains("zmx attach"))
    #expect(script.contains("cd --"))
    #expect(script.contains("/srv/app"))
    #expect(script.contains("exec \"$SHELL\" -l"))
  }

  @Test
  func reconnectScriptNeverRecreatesButReattaches() {
    let script = RemoteSurfaceCommand.reconnectScript(
      hostSession: "codans-x", remotePath: "/srv/app", hostPersistence: true
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
