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

    func isListening() -> Bool {
      guard let fd = try? ZmxControlClient.openConnection(socketPath: socketPath) else {
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
}
