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

  /// Dedicated GCD queue backing the two fd read sources. Kept OFF the Swift
  /// concurrency cooperative pool on purpose: the read loops previously ran on
  /// `Task.detached`, which shares the global executor (width == core count).
  /// Each pane owns two loops, so a handful of panes saturated the pool with
  /// blocking `read`/`poll` spins and starved every other async task (worktree
  /// switches, git fetches) into a permanent hang. DispatchSource is
  /// event-driven, so a thread is borrowed only while bytes are actually ready.
  private let ioQueue = DispatchQueue(label: "com.touch-code.runtime.zmx.io", qos: .userInitiated)
  private var daemonReader: FDReader?
  private var surfaceReader: FDReader?
  /// Main-actor consumer tasks that drain each reader's `AsyncStream`. The
  /// `FDReader` produces byte batches on `ioQueue` (off the cooperative pool);
  /// these tasks process them in FIFO order ON the main actor — matching the
  /// old `await handleFrame` isolation — and suspend (freeing the thread) when
  /// no bytes are ready, so neither the pool nor the main thread is monopolised.
  private var daemonConsumer: Task<Void, Never>?
  private var surfaceConsumer: Task<Void, Never>?
  /// Control-socket bytes accumulated across reads until a full frame
  /// decodes. Main-actor isolated — only `ingestDaemonBytes` touches it.
  private var daemonPending = Data()
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
    logger.info(
      "attach sending init: pane=\(self.paneID, privacy: .public) cols=\(cols, privacy: .public) rows=\(rows, privacy: .public)"
    )
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

  /// Send `.kill` and close the control socket WITHOUT awaiting the
  /// daemon's exit. The daemon terminates on receipt of `.kill` (removing
  /// its socket during shutdown); we do not block on confirmation because
  /// this runs on the synchronous pane-teardown path where awaiting would
  /// stall the caller (often the main thread). Use `kill()` instead when
  /// the caller genuinely needs to observe the daemon going away (e.g. the
  /// IPC `pane.close` handler that reports completion to a CLI client).
  public func requestKill() {
    if isClosed { return }
    try? sendFrame(ZmxFrame(tag: .kill, payload: Data()))
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
    // Half-close to wake the daemon, then tear down the read sources and
    // their main-actor consumers. The sources own controlFD / localFD and
    // close them in their cancel handlers — a DispatchSource requires its fd
    // stay valid until the cancel handler runs, so we must NOT close them
    // directly here.
    if controlFD >= 0 { _ = Darwin.shutdown(controlFD, SHUT_RDWR) }
    if localFD >= 0 { _ = Darwin.shutdown(localFD, SHUT_RDWR) }
    daemonReader?.cancel()
    daemonReader = nil
    surfaceReader?.cancel()
    surfaceReader = nil
    daemonConsumer?.cancel()
    daemonConsumer = nil
    surfaceConsumer?.cancel()
    surfaceConsumer = nil
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

  /// Start the daemon-side read source. The `FDReader` drains the control
  /// socket on `ioQueue` (off the cooperative pool) and yields each batch into
  /// an `AsyncStream`; the consumer task below drains that stream ON the main
  /// actor, in FIFO order, so `ingestDaemonBytes` assembles frames with the
  /// same isolation the old `await handleFrame` had. EOF on the control socket
  /// (daemon exited / snapshot written) routes to `handleDaemonEOF`.
  private func startDaemonReadLoop() {
    let (stream, continuation) = AsyncStream.makeStream(of: (bytes: Data, eof: Bool).self)
    daemonReader = FDReader(fd: controlFD, queue: ioQueue) { bytes, eof in
      continuation.yield((bytes: bytes, eof: eof))
      if eof { continuation.finish() }
    }
    daemonConsumer = Task { @MainActor [weak self] in
      for await chunk in stream {
        guard let self else { break }
        if !chunk.bytes.isEmpty { self.ingestDaemonBytes(chunk.bytes) }
        if chunk.eof { self.handleDaemonEOF() }
      }
    }
  }

  /// Main-actor frame assembly for control-socket bytes. Accumulates into
  /// `daemonPending` and drains every complete frame through `handleFrame`.
  private func ingestDaemonBytes(_ bytes: Data) {
    if isClosed { return }
    daemonPending.append(bytes)
    while true {
      do {
        guard let frame = try ZmxFraming.decode(buffer: &daemonPending) else { break }
        handleFrame(frame)
      } catch {
        handleDecodeError(error)
        return
      }
    }
  }

  /// Start the surface-side read source. Bytes the libghostty External
  /// backend writes into the socketpair are drained on `ioQueue` and forwarded
  /// to the daemon as `.input` frames by the main-actor consumer below.
  /// Surface EOF (libghostty closed the socketpair) needs no teardown here:
  /// the `FDReader` cancels itself and closes `localFD`, the stream finishes,
  /// and the daemon side stays up — matching the pre-DispatchSource behaviour
  /// where the surface loop simply returned on EOF.
  private func startSurfaceReadLoop() {
    let (stream, continuation) = AsyncStream.makeStream(of: (bytes: Data, eof: Bool).self)
    surfaceReader = FDReader(fd: localFD, queue: ioQueue) { bytes, eof in
      continuation.yield((bytes: bytes, eof: eof))
      if eof { continuation.finish() }
    }
    surfaceConsumer = Task { @MainActor [weak self] in
      for await chunk in stream {
        guard let self else { break }
        if !chunk.bytes.isEmpty { self.forwardInput(chunk.bytes) }
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
      // Log every daemon-originated .output frame so we can see whether the
      // serialize-on-second-init replay actually reaches us (large first
      // frame after attach => buffer restore worked) vs. the daemon just
      // sending fresh PTY output (small ongoing frames).
      logger.info(
        "daemon output frame: pane=\(self.paneID, privacy: .public) bytes=\(frame.payload.count, privacy: .public) firstFrame=\(self.attachContinuation != nil, privacy: .public)"
      )
      writeToLocal(frame.payload)
      if let cont = attachContinuation {
        attachContinuation = nil
        logger.info(
          "attach received first output, bytes=\(frame.payload.count, privacy: .public) pane=\(self.paneID, privacy: .public)"
        )
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

/// Event-driven reader for a single non-blocking fd, backed by a GCD
/// `DispatchSourceRead` on a caller-supplied queue. Replaces the former
/// `Task.detached` + blocking `read`/`poll` loops, which ran on the Swift
/// concurrency cooperative pool (width == core count) and — at two loops per
/// pane — saturated it once a few panes were open, starving all other async
/// work (worktree switches, git fetches) into a permanent hang.
///
/// Owns its fd: the source's cancel handler performs the `close(2)`, so the
/// fd stays valid for the source's whole lifetime (a DispatchSource
/// requirement). `deinit` cancels too, so a dropped reader never leaks the fd.
///
/// MUST be `nonisolated`: the module builds with `SWIFT_DEFAULT_ACTOR_ISOLATION
/// = MainActor`, so an unannotated type is implicitly main-actor isolated. Its
/// methods then carry a runtime executor check, and the DispatchSource fires
/// the event handler on `queue` (a background queue) — the check would call
/// `dispatch_assert_queue(main)` off the main thread and trap. Marking the
/// type nonisolated keeps `drainAndDeliver` genuinely queue-agnostic.
private nonisolated final class FDReader: @unchecked Sendable {
  private let fd: Int32
  private let source: DispatchSourceRead
  /// Invoked on the source's serial queue with each drained byte batch. NOT on
  /// the main actor — it must be `@Sendable` and cheap. ZmxClient implements it
  /// as a single `AsyncStream.yield`, which bridges, in order, to a main-actor
  /// consumer task that does the real (main-isolated) frame handling.
  private let onData: @Sendable (_ bytes: Data, _ eof: Bool) -> Void

  init(
    fd: Int32,
    queue: DispatchQueue,
    onData: @escaping @Sendable (_ bytes: Data, _ eof: Bool) -> Void
  ) {
    self.fd = fd
    self.onData = onData
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    self.source = source
    source.setEventHandler { [weak self] in self?.drainAndDeliver() }
    source.setCancelHandler { _ = Darwin.close(fd) }
    source.resume()
  }

  deinit { source.cancel() }

  func cancel() { source.cancel() }

  /// Runs on the source's serial queue. Drains every byte currently available
  /// (the fd is non-blocking) and hands the batch to `onData`. FIFO order is
  /// preserved because the queue is serial: handler invocations never overlap.
  private func drainAndDeliver() {
    let bufferSize = 8192
    var raw = [UInt8](repeating: 0, count: bufferSize)
    var batch = Data()
    var eof = false
    readLoop: while true {
      let n = raw.withUnsafeMutableBufferPointer { ptr -> Int in
        Darwin.read(fd, ptr.baseAddress, bufferSize)
      }
      if n > 0 {
        batch.append(contentsOf: raw.prefix(n))
        continue
      }
      if n == 0 {
        eof = true
        break
      }
      switch errno {
      case EINTR: continue
      case EAGAIN: break readLoop  // fully drained (EWOULDBLOCK == EAGAIN on Darwin)
      default: eof = true; break readLoop
      }
    }
    // Stop the source from re-firing forever on an EOF/errored fd.
    if eof { source.cancel() }
    if batch.isEmpty && !eof { return }
    onData(batch, eof)
  }
}
