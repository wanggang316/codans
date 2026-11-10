import Darwin
import Foundation
import Testing

@testable import Codans
@testable import CodansIPC

/// `PaneStreamSession` against the bundled zmx binary, in a private
/// `ZMX_DIR`: the observer gets an exact snapshot, follows live output and
/// the leader's resizes, and never changes the PTY size itself.
///
/// Skipped when `apps/mac/.build/zmx/bin/zmx` has not been built.
@Suite(.serialized, .enabled(if: RealZmx.binary != nil, "zmx not built (run scripts/build-zmx.sh)"))
struct PaneStreamRealZmxTests {
  @Test(.timeLimit(.minutes(1)))
  func observerMirrorsThePaneWithoutResizingIt() async throws {
    let zmx = try RealZmx()
    defer { zmx.tearDown() }
    try zmx.run(["run", zmx.session, "-d", "true"])
    try await zmx.waitForSocket()
    try zmx.claimLead(rows: 30, cols: 100)
    // Shell arithmetic keeps the typed command line from matching.
    try zmx.run(["send", zmx.session, "echo before-$((40+1))\r"])
    try await zmx.waitForPTYText("before-41")

    let client = try ZmxStreamClient(socketPath: zmx.socketPath)
    let session = PaneStreamSession(connection: client)
    defer { Task { await session.end() } }

    let reset = try #require(await session.next())
    #expect(reset.payload == .reset(cols: 100, rows: 30, fidelity: .exact))
    var screen = try await Self.collectOutput(session, until: "before-41")
    #expect(screen.contains("before-41"))

    // Live output after the snapshot arrives in order.
    try zmx.run(["send", zmx.session, "echo live-$((40+2))\r"])
    screen = try await Self.collectOutput(session, until: "live-42")
    #expect(screen.contains("live-42"))

    // Observing never made the observer the leader: the PTY is still 30x100.
    #expect(try await zmx.ptySize() == "30 100")

    // A real client taking the lead resizes the PTY; the observer is told.
    try zmx.claimLead(rows: 40, cols: 120)
    var sawResize = false
    for _ in 0..<50 {
      guard let frame = await session.next() else { break }
      if frame.payload == .resized(cols: 120, rows: 40) {
        sawResize = true
        break
      }
    }
    #expect(sawResize)
    #expect(try await zmx.ptySize() == "40 120")

    // The session ending is reported as `exited`.
    try zmx.run(["kill", zmx.session, "--force"])
    var exited = false
    for _ in 0..<200 {
      guard let frame = await session.next() else { break }
      if case .exited = frame.payload {
        exited = true
        break
      }
    }
    #expect(exited)
  }

  /// Pulls `output` frames until their text contains `marker`.
  private static func collectOutput(_ session: PaneStreamSession, until marker: String) async throws -> String {
    var text = ""
    for _ in 0..<500 {
      guard let frame = await session.next() else { break }
      if case .output(let data) = frame.payload {
        text += String(bytes: data, encoding: .utf8) ?? ""
        if text.contains(marker) { break }
      }
    }
    return text
  }
}

/// A throwaway zmx daemon world: a short private `ZMX_DIR` (socket paths
/// cap at 104 bytes), a bare `HOME` and `/bin/sh` so no user rc runs.
struct RealZmx {
  static let binary: String? = {
    let mac = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Integration
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // codans
      .deletingLastPathComponent()  // mac
    let path = mac.appendingPathComponent(".build/zmx/bin/zmx").path
    return FileManager.default.isExecutableFile(atPath: path) ? path : nil
  }()

  let directory: String
  let session = "obs"

  var socketPath: String { directory + "/" + session }

  init() throws {
    directory = "/tmp/zit-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: directory + "/home", withIntermediateDirectories: true)
  }

  func tearDown() {
    try? run(["kill", session, "--force"])
    try? FileManager.default.removeItem(atPath: directory)
  }

  @discardableResult
  func run(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: try #require(Self.binary))
    process.arguments = arguments
    var env = ProcessInfo.processInfo.environment
    env["ZMX_DIR"] = directory
    env["HOME"] = directory + "/home"
    env["SHELL"] = "/bin/sh"
    env["TERM"] = "xterm-256color"
    env.removeValue(forKey: "ZMX_SESSION")
    env.removeValue(forKey: "ZMX_SESSION_PREFIX")
    process.environment = env
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return String(bytes: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  }

  func waitForSocket() async throws {
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: socketPath) {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(FileManager.default.fileExists(atPath: socketPath))
  }

  /// Connects as a real terminal client, takes the lead at `rows`×`cols`
  /// and hangs up; the PTY keeps the size. The daemon answers the lead
  /// with a `.resize` request queued after the ioctl, so once it arrives
  /// the PTY has been resized.
  func claimLead(rows: UInt16, cols: UInt16) throws {
    let fd = try ZmxSocket.openConnection(socketPath: socketPath)
    defer { Darwin.close(fd) }
    try ZmxSocket.sendAll(
      fd: fd, data: ZmxFraming.encode(ZmxFrame(tag: .`init`, payload: ZmxResizePayload(cols: cols, rows: rows).encode())))
    var pending = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    while true {
      let n = buffer.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress, $0.count) }
      guard n > 0 else { throw POSIXError(.ETIMEDOUT) }
      pending.append(contentsOf: buffer.prefix(n))
      while let frame = try ZmxFraming.decodeSkippingUnknown(buffer: &pending) {
        if frame.tag == .resize { return }
      }
    }
  }

  /// Polls the daemon's plain-text history until it contains `text`.
  func waitForPTYText(_ text: String) async throws {
    for _ in 0..<100 {
      if try run(["history", session]).contains(text) { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("pane never showed \(text)")
  }

  /// The PTY size as the pane's shell sees it, "rows cols".
  func ptySize() async throws -> String {
    let out = directory + "/stty-\(UUID().uuidString.prefix(6))"
    try run(["send", session, "stty size > \(out)\r"])
    for _ in 0..<100 {
      if let size = try? String(contentsOfFile: out, encoding: .utf8), !size.isEmpty {
        return size.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    return ""
  }
}
