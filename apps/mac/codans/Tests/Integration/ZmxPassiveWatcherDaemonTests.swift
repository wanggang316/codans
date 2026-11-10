import CodansCore
import Darwin
import Foundation
import Testing

@testable import Codans

/// The passive watcher against a real zmx daemon (the binary the test host
/// bundles): it receives PTY output without attaching, its disconnect does
/// not end the session, and a killed daemon is reported as gone.
@Suite(.serialized)
struct ZmxPassiveWatcherDaemonTests {
  private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ZmxPassiveWatcher.Event] = []
    func append(_ event: ZmxPassiveWatcher.Event) { lock.withLock { events.append(event) } }
    var all: [ZmxPassiveWatcher.Event] { lock.withLock { events } }
    var reports: [ProgramStatusReport] {
      all.flatMap { event -> [ProgramStatusReport] in
        guard case .signals(let signals) = event else { return [] }
        return signals.compactMap {
          if case .programStatus(let report) = $0 { return report }
          return nil
        }
      }
    }
  }

  /// Same lookup as `PaneDaemonBringup.zmxBinaryURL()`, which is main-actor
  /// isolated: the test host bundles `bin/zmx`.
  private static var zmx: URL? {
    Bundle.main.url(forResource: "zmx", withExtension: nil, subdirectory: "bin")
  }

  private struct Daemon {
    let zmx: URL
    let directory: URL
    let session = "w\(UUID().uuidString.prefix(6))"
    var socketPath: String { directory.appendingPathComponent(session).path }

    init(zmx: URL) {
      self.zmx = zmx
      // `sun_path` is short: keep the socket directory near the root.
      directory = URL(fileURLWithPath: "/tmp/czd-\(UUID().uuidString.prefix(6))")
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @discardableResult
    func run(_ arguments: String...) throws -> Int32 {
      let process = Process()
      process.executableURL = zmx
      process.arguments = arguments
      process.environment = ProcessInfo.processInfo.environment.merging(
        ["ZMX_DIR": directory.path]) { _, new in new }
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus
    }

    /// Run zmx and return its standard output.
    func output(_ arguments: String...) throws -> String {
      let process = Process()
      process.executableURL = zmx
      process.arguments = arguments
      process.environment = ProcessInfo.processInfo.environment.merging(
        ["ZMX_DIR": directory.path]) { _, new in new }
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice
      try process.run()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// Connect like `zmx attach`: a client that sends `.Init`.
    func attachTerminal() throws -> Int32 {
      let fd = try ZmxSocket.openConnection(socketPath: socketPath)
      let frame = ZmxFraming.encode(
        ZmxFrame(tag: .`init`, payload: ZmxResizePayload(cols: 80, rows: 24).encode()))
      _ = frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
      return fd
    }

    func isListening() -> Bool {
      guard let fd = try? ZmxSocket.openConnection(socketPath: socketPath) else {
        return false
      }
      Darwin.close(fd)
      return true
    }

    func cleanUp() {
      _ = try? run("kill", session)
      try? FileManager.default.removeItem(at: directory)
    }
  }

  private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  @Test(.enabled(if: zmx != nil))
  func observesARealDaemonWithoutAttaching() async throws {
    let daemon = Daemon(zmx: try #require(Self.zmx))
    defer { daemon.cleanUp() }
    #expect(try daemon.run("serve", daemon.session, "--command", "/bin/sh") == 0)
    try await waitUntil { daemon.isListening() }

    let log = EventLog()
    let watcher = ZmxPassiveWatcher(socketPath: daemon.socketPath) { log.append($0) }
    watcher.start()
    try await waitUntil { watcher.isConnected }

    // The typed line echoes `\033` as text; only printf's output is an OSC.
    try daemon.run(
      "send", daemon.session, "printf '\\033]7501;state=working:app=claude-code\\033\\\\'\n")
    try await waitUntil { !log.reports.isEmpty }
    #expect(log.reports == [ProgramStatusReport(state: .working, app: "claude-code")])

    // The watcher leaving does not end the session.
    watcher.stop()
    try await Task.sleep(for: .milliseconds(200))
    #expect(daemon.isListening())
  }

  @Test(.enabled(if: zmx != nil))
  func reportsAKilledDaemonAsGone() async throws {
    let daemon = Daemon(zmx: try #require(Self.zmx))
    defer { daemon.cleanUp() }
    #expect(try daemon.run("serve", daemon.session, "--command", "/bin/sh") == 0)
    try await waitUntil { daemon.isListening() }

    let log = EventLog()
    let watcher = ZmxPassiveWatcher(socketPath: daemon.socketPath) { log.append($0) }
    watcher.start()
    defer { watcher.stop() }
    try await waitUntil { watcher.isConnected }

    let killedAt = Date()
    try daemon.run("kill", daemon.session)
    try await waitUntil { log.all.contains(.daemonGone) }

    #expect(log.all.contains(.daemonGone))
    // Default backoff: EOF, then three refused connects 0.25 + 0.5 + 1 s apart.
    #expect(Date().timeIntervalSince(killedAt) < 3)
  }

  /// A program started after the last terminal detached still gets an
  /// answer to the OSC 7501 support query, with the watcher connected.
  /// Claude Code reports program status only after that answer.
  @Test(.enabled(if: zmx != nil))
  func answersTheProgramStatusQueryAfterTheTerminalDetached() async throws {
    let daemon = Daemon(zmx: try #require(Self.zmx))
    defer { daemon.cleanUp() }
    let script = daemon.directory.appendingPathComponent("probe.sh")
    try #"""
      read go
      stty -icanon -echo min 0 time 30
      printf '\033]7501;?\033\\'
      reply=$(dd bs=1 count=9 2>/dev/null)
      stty sane
      printf 'REPLY[%s]\n' "$reply" | tr '\033' 'E'
      sleep 30
      """#.write(to: script, atomically: true, encoding: .utf8)
    #expect(try daemon.run("serve", daemon.session, "--command", "/bin/sh", script.path) == 0)
    try await waitUntil { daemon.isListening() }

    let terminal = try daemon.attachTerminal()
    try await Task.sleep(for: .milliseconds(300))
    Darwin.close(terminal)
    let watcher = ZmxPassiveWatcher(socketPath: daemon.socketPath) { _ in }
    watcher.start()
    defer { watcher.stop() }
    try await waitUntil { watcher.isConnected }

    try daemon.run("send", daemon.session, "go\n")
    var history = ""
    try await waitUntil(timeout: 8) {
      history = (try? daemon.output("history", daemon.session)) ?? ""
      return history.contains("REPLY[")
    }
    #expect(history.contains("REPLY[E]7501;?:]"), "\(history)")
  }
}
