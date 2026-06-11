import Darwin
import Foundation
import CodansCore
import os.log

/// One-shot query client for a running zmx daemon's control socket.
///
/// The live byte stream is owned by the in-surface `zmx attach` client (see
/// `ZmxAttachCommand`). Out-of-band requests — the daemon's shell-child PID
/// (`.info`) and rendered scrollback (`.history`) — instead open a
/// short-lived connection, send a single framed command, read the single
/// framed reply, and close. The daemon answers `.info` / `.history` to any
/// connected client and only promotes a client to "leader" on `.init` /
/// `.resize` / `.input`, so these queries never disturb the leader's
/// session or its terminal size.
nonisolated enum ZmxControlClient {
  private static let logger = Logger(
    subsystem: "com.gumpw.codans.runtime", category: "runtime.zmx.control"
  )

  enum ControlError: Error, Equatable, Sendable {
    case socketCreateFailed(errno: Int32)
    case pathTooLong(String)
    case connectFailed(errno: Int32)
    case timedOut
    case closedWithoutReply
  }

  /// Filesystem path of the daemon control socket for a Pane. Must match
  /// the `ZMX_DIR` pin in `PaneDaemonBringup.canonicalSocketDirectory()`
  /// and the session name in `ZmxAttachCommand.session(for:)` — the daemon
  /// binds `<ZMX_DIR>/<session>` (codans sets no `ZMX_SESSION_PREFIX`).
  static func socketPath(for paneID: PaneID) -> String {
    canonicalSocketDirectory().appendingPathComponent(paneID.raw.uuidString).path
  }

  /// Query the daemon's shell-child PID (and cwd). Used by foreground-job /
  /// agent detection, which resolves the foreground process group from the
  /// shell PID via `proc_pidinfo` — it needs only the PID, not a PTY fd.
  static func info(
    for paneID: PaneID, timeout: Duration = .seconds(2)
  ) async throws -> ZmxInfoPayload {
    let reply = try await query(
      socketPath: socketPath(for: paneID),
      request: ZmxFrame(tag: .info),
      expect: .info,
      timeout: timeout
    )
    return try ZmxInfoPayload.decode(reply.payload)
  }

  /// Query the daemon's rendered scrollback in the given format (backs
  /// `codans pane read`). Returns the raw `.history` payload bytes.
  static func history(
    for paneID: PaneID, format: ZmxHistoryFormat, timeout: Duration = .seconds(5)
  ) async throws -> Data {
    var payload = Data(capacity: 1)
    payload.append(format.rawValue)
    let reply = try await query(
      socketPath: socketPath(for: paneID),
      request: ZmxFrame(tag: .history, payload: payload),
      expect: .history,
      timeout: timeout
    )
    return reply.payload
  }

  // MARK: - Transport

  /// Canonical `ZMX_DIR`. Delegates to `AppDirectories.cacheDirectory()` —
  /// a `nonisolated` Core helper that is the single source of truth shared
  /// with `PaneDaemonBringup.canonicalSocketDirectory()`, so the two stay
  /// byte-identical (including the Debug `-dev` suffix) while this type stays
  /// `nonisolated` and off the main actor.
  private static func canonicalSocketDirectory() -> URL {
    AppDirectories.cacheDirectory()
  }

  /// Run the blocking connect/send/read on a background queue and bridge
  /// the result back through a continuation. Reads frames until one with
  /// `expect` arrives (ignoring any unsolicited `.output` the daemon may
  /// emit on connect) or the deadline elapses.
  private static func query(
    socketPath: String, request: ZmxFrame, expect: ZmxTag, timeout: Duration
  ) async throws -> ZmxFrame {
    let deadlineMs = max(Int(timeout.components.seconds * 1000), 1)
    return try await withCheckedThrowingContinuation {
      (cont: CheckedContinuation<ZmxFrame, Error>) in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          cont.resume(
            returning: try runQuery(
              socketPath: socketPath, request: request, expect: expect, deadlineMs: deadlineMs
            ))
        } catch {
          cont.resume(throwing: error)
        }
      }
    }
  }

  /// Best-effort `.kill`: tell a pane's daemon to exit (dropping its PTY
  /// child). Used when a pane is destroyed for good. Fire-and-forget — the
  /// daemon closes its socket on `.kill`, so there is no reply to await. A
  /// missing socket (daemon already gone) is a silent no-op.
  static func kill(for paneID: PaneID) {
    let path = socketPath(for: paneID)
    DispatchQueue.global(qos: .utility).async {
      guard let fd = try? openConnection(socketPath: path) else { return }
      defer { Darwin.close(fd) }
      try? sendAll(fd: fd, data: ZmxFraming.encode(ZmxFrame(tag: .kill)))
    }
  }

  private static func openConnection(socketPath: String) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { throw ControlError.socketCreateFailed(errno: errno) }
    var noSigPipe: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
      Darwin.close(fd)
      throw ControlError.pathTooLong(socketPath)
    }
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
        pathBytes.withUnsafeBufferPointer { src in
          _ = memcpy(dst, src.baseAddress, pathBytes.count)
        }
      }
    }
    let connected = withUnsafePointer(to: &addr) { addrPtr in
      addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if connected < 0 {
      let err = errno
      Darwin.close(fd)
      throw ControlError.connectFailed(errno: err)
    }
    return fd
  }

  private static func runQuery(
    socketPath: String, request: ZmxFrame, expect: ZmxTag, deadlineMs: Int
  ) throws -> ZmxFrame {
    let fd = try openConnection(socketPath: socketPath)
    defer { Darwin.close(fd) }

    try sendAll(fd: fd, data: ZmxFraming.encode(request))

    var pending = Data()
    var buf = [UInt8](repeating: 0, count: 8192)
    let start = DispatchTime.now().uptimeNanoseconds
    while true {
      let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
      let remaining = deadlineMs - elapsedMs
      if remaining <= 0 { throw ControlError.timedOut }
      var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let pr = withUnsafeMutablePointer(to: &pfd) { Darwin.poll($0, 1, Int32(remaining)) }
      if pr < 0 {
        if errno == EINTR { continue }
        throw ControlError.connectFailed(errno: errno)
      }
      if pr == 0 { throw ControlError.timedOut }
      let n = buf.withUnsafeMutableBufferPointer { Darwin.read(fd, $0.baseAddress, 8192) }
      if n < 0 {
        if errno == EINTR { continue }
        throw ControlError.connectFailed(errno: errno)
      }
      if n == 0 { throw ControlError.closedWithoutReply }
      pending.append(contentsOf: buf.prefix(n))
      while let frame = try ZmxFraming.decode(buffer: &pending) {
        if frame.tag == expect { return frame }
        // Ignore unsolicited frames (e.g. .output) until our reply lands.
      }
    }
  }

  private static func sendAll(fd: Int32, data: Data) throws {
    try data.withUnsafeBytes { raw in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
      var off = 0
      while off < raw.count {
        let n = Darwin.send(fd, base + off, raw.count - off, 0)
        if n < 0 {
          if errno == EINTR { continue }
          throw ControlError.connectFailed(errno: errno)
        }
        off += n
      }
    }
  }
}
