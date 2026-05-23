import Darwin
import Foundation
import TouchCodeCore
import os.log

/// Client for a running zmx pane-resume daemon. Owns a socketpair: the
/// local end (`localFD`) proxies bytes between the daemon's control
/// socket and an external consumer (libghostty's External backend); the
/// other end (`externalBackendFD`) is handed to that backend as its
/// pty fd. Daemon `.output` frames are written to the local end, and
/// any bytes the consumer writes back are wrapped in `.input` frames
/// and forwarded to the daemon.
@MainActor
public final class ZmxClient {
  public enum ConnectError: Error, Equatable, Sendable {
    case socketCreateFailed(errno: Int32)
    case socketpairFailed(errno: Int32)
    case pathTooLong(String)
    case connectFailed(path: String, errno: Int32)
    case alreadyClosed
  }

  /// File descriptor handed to libghostty's External backend. Owned by
  /// the caller once read via this property; ZmxClient does not close
  /// it on ``close()`` (libghostty's surface lifecycle owns the close).
  public let externalBackendFD: Int32

  /// PaneID this client is bound to. Used to construct the snapshot URL
  /// returned from ``snapshot()`` and to disambiguate log lines.
  public let paneID: PaneID

  /// Path of the daemon's Unix control socket. Persisted into
  /// `sessions.json` at quit so the next launch can reconnect.
  public let socketPath: String

  /// PID of the daemon process backing this pane, captured from `zmx
  /// serve` stdout at spawn time. `0` when the spawn helper could not
  /// determine the PID (e.g. an older daemon binary that prints only the
  /// socket path).
  public let daemonPID: Int32

  /// Working directory the daemon was launched with. Recorded into
  /// `sessions.json` so a later restart can offer to reattach panes whose
  /// catalog row has drifted away from their on-disk cwd.
  public let cwd: String

  /// Command-line the daemon was launched with. Empty when the daemon
  /// fell back to the user's login shell (touch-code's standard path).
  public let command: [String]

  /// Reported semantic version of the spawning `zmx` binary (or `""`
  /// when the spawn helper has not learned it). Recorded so reattach can
  /// refuse to talk to a daemon whose IPC schema we do not know.
  public let zmxVersion: String

  /// Wall-clock time the client was constructed. Persisted into
  /// `sessions.json` as the daemon's creation timestamp (close enough
  /// for catalog purposes — the daemon prints its socket path within
  /// milliseconds of fork).
  public let createdAt: Date

  /// Wall-clock time of the most recent successful `attach`. Updated in
  /// place whenever the surface re-handshakes the daemon. Read by the
  /// quit-time `SessionLifecycle` snapshot.
  public private(set) var lastAttachedAt: Date

  /// Snapshot URL the daemon writes when ``snapshot()`` runs. Caller can
  /// also derive this from the socket directory; we expose it explicitly
  /// so ``snapshot()`` does not have to know about the cache layout.
  public let snapshotURL: URL

  /// Async stream of decoded `.info` frames from the daemon.
  public var info: AsyncStream<ZmxInfoPayload> { infoStream }
  private let logger = Logger(subsystem: "com.touch-code.runtime", category: "runtime.zmx")
  private let controlFD: Int32
  private let localFD: Int32
  private let infoStream: AsyncStream<ZmxInfoPayload>
  private let infoContinuation: AsyncStream<ZmxInfoPayload>.Continuation

  private var daemonReadTask: Task<Void, Never>?
  private var surfaceReadTask: Task<Void, Never>?
  private var attachContinuation: CheckedContinuation<Void, Error>?
  private var snapshotContinuation: CheckedContinuation<URL, Error>?
  private var killContinuation: CheckedContinuation<Void, Never>?
  /// One-shot continuation drained by `requestInfo()`. Each call enqueues
  /// itself here; the next `.info` frame from the daemon dequeues and
  /// resolves it. FIFO order matches request order because the daemon
  /// answers `.info` synchronously on its event loop.
  private var infoRequests: [CheckedContinuation<ZmxInfoPayload, Error>] = []
  /// One-shot continuation drained by `readHistory()`. Same FIFO rule
  /// as `infoRequests`; the daemon emits exactly one `.history` frame
  /// per request.
  private var historyRequests: [CheckedContinuation<Data, Error>] = []
  private var lastResize: ZmxResizePayload?
  private var isClosed = false

  // swiftlint:disable async_without_await
  // The `async` keyword is intentional even though the body is currently
  // synchronous: PaneSurface integration in the next slice will hop to
  // await the daemon's first frame inside init, and locking the signature
  // now avoids churning every caller later.
  //
  // - Parameters:
  //   - paneID: identifier the daemon was launched for.
  //   - socketPath: filesystem path of the daemon's control socket.
  //   - daemonPID: daemon process PID reported by `zmx serve` at spawn
  //     time. `0` is accepted to mean "unknown" so reattach paths and
  //     tests can still build a client without one.
  //   - cwd: working directory the daemon was launched with.
  //   - command: argv the daemon was launched with (empty = login shell).
  //   - zmxVersion: version string of the spawning daemon binary.
  //   - createdAt: wall-clock time the daemon was created. Defaults to
  //     `Date()` so reconnect paths (T2.2) can pass through the value
  //     recorded in `sessions.json` instead of re-stamping.
  //   - snapshotDirectory: directory the daemon writes `<paneID>.snap`
  //     into when ``snapshot()`` runs. Caller picks this so tests can
  //     point at a temp directory; defaults to the standard cache.
  public init(
    paneID: PaneID,
    socketPath: String,
    daemonPID: Int32 = 0,
    cwd: String = "",
    command: [String] = [],
    zmxVersion: String = "",
    createdAt: Date = Date(),
    snapshotDirectory: URL? = nil
  ) async throws {
    // swiftlint:enable async_without_await
    self.paneID = paneID
    self.socketPath = socketPath
    self.daemonPID = daemonPID
    self.cwd = cwd
    self.command = command
    self.zmxVersion = zmxVersion
    self.createdAt = createdAt
    self.lastAttachedAt = createdAt
    let snapDir = snapshotDirectory ?? Self.defaultSnapshotDirectory()
    self.snapshotURL = snapDir.appendingPathComponent("\(paneID.raw.uuidString).snap")

    // Open the socketpair first so we don't leak the control fd if the
    // pair fails. Both ends are SOCK_STREAM to match libghostty's PTY
    // shape (it expects byte-stream semantics on external_pty_fd).
    var pairFDs: [Int32] = [-1, -1]
    let pairResult = pairFDs.withUnsafeMutableBufferPointer { ptr -> Int32 in
      Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, ptr.baseAddress)
    }
    if pairResult != 0 {
      throw ConnectError.socketpairFailed(errno: errno)
    }
    self.localFD = pairFDs[0]
    self.externalBackendFD = pairFDs[1]
    Self.setNonBlocking(self.localFD)

    let cfd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    if cfd < 0 {
      Darwin.close(self.localFD)
      Darwin.close(self.externalBackendFD)
      throw ConnectError.socketCreateFailed(errno: errno)
    }
    var noSigPipe: Int32 = 1
    _ = setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
      Darwin.close(cfd)
      Darwin.close(self.localFD)
      Darwin.close(self.externalBackendFD)
      throw ConnectError.pathTooLong(socketPath)
    }
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
        pathBytes.withUnsafeBufferPointer { src in
          _ = memcpy(dst, src.baseAddress, pathBytes.count)
        }
      }
    }
    let connectResult = withUnsafePointer(to: &addr) { addrPtr in
      addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        Darwin.connect(cfd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if connectResult < 0 {
      let err = errno
      Darwin.close(cfd)
      Darwin.close(self.localFD)
      Darwin.close(self.externalBackendFD)
      throw ConnectError.connectFailed(path: socketPath, errno: err)
    }
    Self.setNonBlocking(cfd)
    self.controlFD = cfd

    var infoCont: AsyncStream<ZmxInfoPayload>.Continuation!
    self.infoStream = AsyncStream<ZmxInfoPayload> { cont in infoCont = cont }
    self.infoContinuation = infoCont

    startDaemonReadLoop()
    startSurfaceReadLoop()
  }

  /// Send `.init` with the requested terminal size; resolves when the
  /// daemon's first `.output` frame arrives (the restore stream, or the
  /// first PTY output on a fresh attach). `lastAttachedAt` advances to
  /// the resolution point so the quit-time snapshot reflects the latest
  /// successful handshake.
  public func attach(cols: UInt16, rows: UInt16) async throws {
    if isClosed { throw ConnectError.alreadyClosed }
    let payload = ZmxResizePayload(cols: cols, rows: rows)
    self.lastResize = payload
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      self.attachContinuation = cont
      do {
        try sendFrame(ZmxFrame(tag: .`init`, payload: payload.encode()))
      } catch {
        self.attachContinuation = nil
        cont.resume(throwing: error)
      }
    }
    self.lastAttachedAt = Date()
  }

  /// Fire-and-forget resize. No-op when the dimensions match the last
  /// successfully sent resize — the daemon is happy to receive duplicates
  /// but the socket round-trip is wasted on the common case where AppKit
  /// emits redundant `viewDidLayout` ticks.
  public func resize(cols: UInt16, rows: UInt16) {
    if isClosed { return }
    let payload = ZmxResizePayload(cols: cols, rows: rows)
    if lastResize == payload { return }
    do {
      try sendFrame(ZmxFrame(tag: .resize, payload: payload.encode()))
      lastResize = payload
    } catch {
      logger.warning("resize send failed: \(String(describing: error), privacy: .public)")
    }
  }

  /// Send `.snapshot`; resolves with the snapshot URL once the daemon
  /// closes its socket (signalling that the `.snap` file is fsynced and
  /// the daemon has shut down).
  public func snapshot() async throws -> URL {
    if isClosed { throw ConnectError.alreadyClosed }
    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
      self.snapshotContinuation = cont
      do {
        try sendFrame(ZmxFrame(tag: .snapshot, payload: Data()))
      } catch {
        self.snapshotContinuation = nil
        cont.resume(throwing: error)
      }
    }
  }

  /// Send `.info` and resolve with the daemon's next `.info` response.
  /// Distinct from the unsolicited `info` AsyncStream — that stream
  /// fans every `.info` frame out to passive observers, while this
  /// method waits for the specific frame produced in answer to our
  /// request. Caller-driven (probes used by `tc pane info`).
  public func requestInfo() async throws -> ZmxInfoPayload {
    if isClosed { throw ConnectError.alreadyClosed }
    return try await withCheckedThrowingContinuation {
      (cont: CheckedContinuation<ZmxInfoPayload, Error>) in
      self.infoRequests.append(cont)
      do {
        try sendFrame(ZmxFrame(tag: .info, payload: Data()))
      } catch {
        // Failed before the daemon could answer — pull the continuation
        // back off the queue (it's the one we just appended) and throw.
        if !self.infoRequests.isEmpty {
          self.infoRequests.removeLast()
        }
        cont.resume(throwing: error)
      }
    }
  }

  /// Send `.history` with the given format byte and resolve with the
  /// raw payload of the daemon's `.history` response. The daemon's
  /// `serializeTerminal(... .vt)` output preserves ANSI escapes,
  /// cursor position, terminal modes, and OSC 7 pwd; `.plain` strips
  /// the escapes and returns wrapped text.
  public func readHistory(format: ZmxHistoryFormat) async throws -> Data {
    if isClosed { throw ConnectError.alreadyClosed }
    return try await withCheckedThrowingContinuation {
      (cont: CheckedContinuation<Data, Error>) in
      self.historyRequests.append(cont)
      var payload = Data(capacity: 1)
      payload.append(format.rawValue)
      do {
        try sendFrame(ZmxFrame(tag: .history, payload: payload))
      } catch {
        if !self.historyRequests.isEmpty {
          self.historyRequests.removeLast()
        }
        cont.resume(throwing: error)
      }
    }
  }

  /// Send `.detach` and close the control socket. The daemon survives;
  /// a future attach reopens via a fresh ZmxClient.
  public func detach() {
    if isClosed { return }
    try? sendFrame(ZmxFrame(tag: .detach, payload: Data()))
    close()
  }

  /// Send `.kill` and wait for the daemon's socket file to disappear
  /// (or 2s timeout, whichever comes first). The daemon exits in
  /// response to `.kill`; sockets are removed during its shutdown path.
  public func kill() async {
    if isClosed { return }
    try? sendFrame(ZmxFrame(tag: .kill, payload: Data()))
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      self.killContinuation = cont
      let path = socketPath
      let deadline = Date().addingTimeInterval(2.0)
      Task.detached { [weak self] in
        while Date() < deadline {
          if access(path, F_OK) != 0 {
            await self?.completeKill()
            return
          }
          try? await Task.sleep(for: .milliseconds(25))
        }
        await self?.completeKill()
      }
    }
    close()
  }

  /// Close the control socket and stop the read loops. Idempotent. The
  /// `externalBackendFD` is intentionally NOT closed here: it is owned
  /// by libghostty for the lifetime of the surface.
  public func close() {
    if isClosed { return }
    isClosed = true
    daemonReadTask?.cancel()
    daemonReadTask = nil
    surfaceReadTask?.cancel()
    surfaceReadTask = nil
    if controlFD >= 0 {
      _ = Darwin.shutdown(controlFD, SHUT_RDWR)
      _ = Darwin.close(controlFD)
    }
    if localFD >= 0 {
      _ = Darwin.shutdown(localFD, SHUT_RDWR)
      _ = Darwin.close(localFD)
    }
    infoContinuation.finish()
    if let cont = attachContinuation {
      attachContinuation = nil
      cont.resume(throwing: ConnectError.alreadyClosed)
    }
    if let cont = snapshotContinuation {
      snapshotContinuation = nil
      cont.resume(throwing: ConnectError.alreadyClosed)
    }
    if let cont = killContinuation {
      killContinuation = nil
      cont.resume()
    }
    let pendingInfo = infoRequests
    infoRequests.removeAll()
    for cont in pendingInfo {
      cont.resume(throwing: ConnectError.alreadyClosed)
    }
    let pendingHistory = historyRequests
    historyRequests.removeAll()
    for cont in pendingHistory {
      cont.resume(throwing: ConnectError.alreadyClosed)
    }
  }

  // MARK: - Private helpers

  private func completeKill() {
    if let cont = killContinuation {
      killContinuation = nil
      cont.resume()
    }
  }

  /// Synchronous control-socket write. Length-prefixed encoding handled
  /// by ``ZmxFraming/encode``; partial writes loop until all bytes ship
  /// or the socket errors.
  private func sendFrame(_ frame: ZmxFrame) throws {
    var data = ZmxFraming.encode(frame)
    while !data.isEmpty {
      let written = data.withUnsafeBytes { ptr -> Int in
        Darwin.send(controlFD, ptr.baseAddress, data.count, 0)
      }
      if written < 0 {
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK {
          // Non-blocking socket buffer is full. Poll briefly and retry.
          var pfd = pollfd(fd: controlFD, events: Int16(POLLOUT), revents: 0)
          _ = withUnsafeMutablePointer(to: &pfd) { Darwin.poll($0, 1, 100) }
          continue
        }
        throw ConnectError.connectFailed(path: "(send)", errno: errno)
      }
      if written == 0 {
        throw ConnectError.connectFailed(path: "(send=0)", errno: 0)
      }
      data.removeFirst(written)
    }
  }

  /// Spawn the daemon-side read loop. Runs detached at user-initiated
  /// priority; decoded frames are dispatched back to the main actor for
  /// state mutation (continuations, AsyncStream yields, local socketpair
  /// writes).
  private func startDaemonReadLoop() {
    let fd = controlFD
    daemonReadTask = Task.detached(priority: .userInitiated) { [weak self] in
      var pending = Data()
      let bufferSize = 8192
      var raw = [UInt8](repeating: 0, count: bufferSize)
      while !Task.isCancelled {
        let n = raw.withUnsafeMutableBufferPointer { ptr -> Int in
          Darwin.read(fd, ptr.baseAddress, bufferSize)
        }
        if n > 0 {
          pending.append(contentsOf: raw.prefix(n))
          while true {
            do {
              guard let frame = try ZmxFraming.decode(buffer: &pending) else { break }
              await self?.handleFrame(frame)
            } catch {
              await self?.handleDecodeError(error)
              return
            }
          }
          continue
        }
        if n == 0 {
          // Daemon closed the socket (EOF). Resolve any in-flight
          // snapshot waiter — handleSnapshot shuts the daemon down once
          // the .snap is written, so EOF is the success signal.
          await self?.handleDaemonEOF()
          return
        }
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK {
          var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
          _ = withUnsafeMutablePointer(to: &pfd) { Darwin.poll($0, 1, 100) }
          continue
        }
        await self?.handleDaemonEOF()
        return
      }
    }
  }

  /// Spawn the surface-side read loop. Reads bytes the libghostty
  /// External backend wrote into the socketpair, wraps them in `.input`
  /// frames, and ships them to the daemon. Detached to keep the main
  /// actor free; control-socket writes happen on the main actor via
  /// `MainActor.run`.
  private func startSurfaceReadLoop() {
    let fd = localFD
    surfaceReadTask = Task.detached(priority: .userInitiated) { [weak self] in
      let bufferSize = 8192
      var raw = [UInt8](repeating: 0, count: bufferSize)
      while !Task.isCancelled {
        let n = raw.withUnsafeMutableBufferPointer { ptr -> Int in
          Darwin.read(fd, ptr.baseAddress, bufferSize)
        }
        if n > 0 {
          let bytes = Data(raw.prefix(n))
          await self?.forwardInput(bytes)
          continue
        }
        if n == 0 { return }
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK {
          var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
          _ = withUnsafeMutablePointer(to: &pfd) { Darwin.poll($0, 1, 100) }
          continue
        }
        return
      }
    }
  }

  private func forwardInput(_ bytes: Data) {
    if isClosed { return }
    do {
      try sendFrame(ZmxFrame(tag: .input, payload: bytes))
    } catch {
      logger.warning("input forward failed: \(String(describing: error), privacy: .public)")
    }
  }

  private func handleFrame(_ frame: ZmxFrame) {
    switch frame.tag {
    case .output:
      writeToLocal(frame.payload)
      if let cont = attachContinuation {
        attachContinuation = nil
        cont.resume()
      }
    case .info:
      // Yield to the broadcast stream so passive observers see the
      // payload, then resolve the oldest pending `requestInfo()` (if
      // any) with the same decoded value.
      let decoded = try? ZmxInfoPayload.decode(frame.payload)
      if let info = decoded {
        infoContinuation.yield(info)
      }
      if !infoRequests.isEmpty {
        let cont = infoRequests.removeFirst()
        if let info = decoded {
          cont.resume(returning: info)
        } else {
          cont.resume(throwing: ZmxIPCError.malformedLength)
        }
      }
    case .history:
      if !historyRequests.isEmpty {
        let cont = historyRequests.removeFirst()
        cont.resume(returning: frame.payload)
      } else {
        logger.debug("dropping unsolicited history frame bytes=\(frame.payload.count, privacy: .public)")
      }
    case .ack, .taskComplete, .run, .write, .input, .resize, .detach,
      .detachAll, .kill, .`init`, .`switch`, .snapshot:
      // Tags that the daemon doesn't normally send back as unsolicited
      // updates to clients. Ack arrives for some commands; consumers
      // that need ack-tracking can route through ``info`` once they're
      // wired. For now, log and drop.
      logger.debug("unhandled daemon frame tag=\(frame.tag.rawValue, privacy: .public)")
    }
  }

  private func writeToLocal(_ data: Data) {
    if isClosed || localFD < 0 { return }
    var remaining = data
    while !remaining.isEmpty {
      let written = remaining.withUnsafeBytes { ptr -> Int in
        Darwin.send(localFD, ptr.baseAddress, remaining.count, 0)
      }
      if written < 0 {
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK {
          var pfd = pollfd(fd: localFD, events: Int16(POLLOUT), revents: 0)
          _ = withUnsafeMutablePointer(to: &pfd) { Darwin.poll($0, 1, 100) }
          continue
        }
        logger.warning("local socketpair write failed errno=\(errno, privacy: .public)")
        return
      }
      if written == 0 { return }
      remaining.removeFirst(written)
    }
  }

  private func handleDecodeError(_ error: Error) {
    logger.error("daemon decode error: \(String(describing: error), privacy: .public)")
    handleDaemonEOF()
  }

  private func handleDaemonEOF() {
    if let cont = snapshotContinuation {
      snapshotContinuation = nil
      cont.resume(returning: snapshotURL)
    }
    if let cont = attachContinuation {
      attachContinuation = nil
      cont.resume(throwing: ConnectError.alreadyClosed)
    }
    close()
  }

  private static func setNonBlocking(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFL, 0)
    if flags >= 0 {
      _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }
  }

  private static func defaultSnapshotDirectory() -> URL {
    let fm = FileManager.default
    let base =
      (try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
    return base.appendingPathComponent("touch-code/snapshots", isDirectory: true)
  }
}
