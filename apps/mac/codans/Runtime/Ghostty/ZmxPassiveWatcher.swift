import Darwin
import Foundation
import os.log

/// Observer of a pane that has no surface. `TerminalEngine` owns one per
/// detached pane; tests substitute a fake.
nonisolated protocol DetachedPaneWatching: AnyObject, Sendable {
  func start()
  func stop()
  /// Ask the daemon to broadcast `payload` as output (zmx `.Mark`). Sent
  /// over the watcher's own socket, so marks reach the daemon in call order.
  func sendMark(_ payload: Data)
}

/// Passive zmx client for a pane that has no surface. It connects to the
/// pane's daemon socket and sends nothing but `.Mark` fences during a
/// re-attach handoff (`sendMark`). Without `.Init`, `.Input` or `.Resize`
/// the daemon does not replay the screen, never makes it the leader, and
/// never resizes the PTY for it, but still broadcasts every PTY `.Output` frame to it
/// (`ThirdParty/zmx/src/main.zig`, PTY read loop). Disconnects use
/// `closeClient(…, shutdown_on_last: false)`, so the watcher going away
/// never ends the session.
///
/// The watcher also observes liveness. EOF means the daemon closed the
/// client: it exited, or an outside `DetachAll` dropped every client. The
/// watcher reconnects with bounded backoff; when the socket refuses or is
/// missing for `refusalsUntilGone` attempts in a row, the daemon is gone.
///
/// Each watcher holds one socket and one dispatch read source on a shared
/// serial queue, so many watchers cost file descriptors, not threads.
nonisolated final class ZmxPassiveWatcher: DetachedPaneWatching, @unchecked Sendable {
  enum Event: Equatable, Sendable {
    /// Signals found in one batch of output, in order.
    case signals([DetachedPaneSignal])
    /// The daemon socket stayed unreachable; the watcher has stopped.
    case daemonGone
  }

  struct Backoff: Equatable, Sendable {
    var initialDelay: TimeInterval = 0.25
    var maxDelay: TimeInterval = 30
    /// Consecutive refused / missing-socket connects that mean the daemon
    /// is gone. With the defaults, an exited daemon is reported about
    /// 1.75 s after its EOF.
    var refusalsUntilGone = 3

    static let `default` = Backoff()
  }

  /// Serial queue shared by every watcher; it only reads sockets.
  static let sharedQueue = DispatchQueue(label: "com.gumpw.codans.zmx.watcher", qos: .utility)

  private static let logger = Logger(
    subsystem: "com.gumpw.codans.runtime", category: "runtime.zmx.watcher"
  )

  let socketPath: String
  private let queue: DispatchQueue
  private let backoff: Backoff
  private let onEvent: @Sendable (Event) -> Void

  // State below is confined to `queue`.
  private var source: DispatchSourceRead?
  private var fd: Int32 = -1
  private var scanner = ZmxOutputScanner()
  private var pending = Data()
  private var stopped = false
  private var started = false
  private var refusals = 0
  private var delay: TimeInterval
  private var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)
  private let readsPerEvent: Int

  init(
    socketPath: String,
    queue: DispatchQueue = ZmxPassiveWatcher.sharedQueue,
    backoff: Backoff = .default,
    readsPerEvent: Int = 4,
    onEvent: @escaping @Sendable (Event) -> Void
  ) {
    self.socketPath = socketPath
    self.queue = queue
    self.backoff = backoff
    self.readsPerEvent = max(1, readsPerEvent)
    self.onEvent = onEvent
    self.delay = backoff.initialDelay
  }

  deinit {
    source?.cancel()
  }

  /// Connect now. Idempotent.
  func start() {
    queue.async { [self] in
      guard !started, !stopped else { return }
      started = true
      connect()
    }
  }

  /// Close the socket and cancel any pending reconnect. Synchronous: when
  /// it returns, the watcher holds no socket and emits no further events
  /// (an event already handed to `onEvent` may still be in flight). Do not
  /// call it from `onEvent`, which runs on the watcher queue.
  func stop() {
    queue.sync { [self] in
      stopped = true
      disconnect()
    }
  }

  /// Whether the watcher holds a connected socket. For tests.
  var isConnected: Bool {
    queue.sync { source != nil }
  }

  // MARK: - Queue-confined

  private func connect() {
    guard !stopped else { return }
    let fd: Int32
    do {
      fd = try ZmxControlClient.openConnection(socketPath: socketPath)
    } catch ZmxControlClient.ControlError.connectFailed(let code) where code == ENOENT || code == ECONNREFUSED {
      refusals += 1
      if refusals >= backoff.refusalsUntilGone {
        stopped = true
        Self.logger.info("daemon gone socket=\(self.socketPath, privacy: .public)")
        onEvent(.daemonGone)
        return
      }
      scheduleReconnect()
      return
    } catch {
      // Transient (fd limit, backlog full): retry without counting it.
      scheduleReconnect()
      return
    }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
    refusals = 0
    delay = backoff.initialDelay
    scanner = ZmxOutputScanner()
    pending.removeAll()
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self] in self?.drain(fd: fd) }
    source.setCancelHandler { Darwin.close(fd) }
    self.source = source
    self.fd = fd
    source.resume()
  }

  func sendMark(_ payload: Data) {
    queue.async { [self] in
      guard source != nil, fd >= 0 else { return }
      let frame = ZmxFraming.encode(ZmxFrame(tag: .mark, payload: payload))
      let sent = frame.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return true }
        var offset = 0
        while offset < raw.count {
          let n = Darwin.write(fd, base + offset, raw.count - offset)
          if n > 0 {
            offset += n
          } else if n < 0, errno == EINTR {
            continue
          } else if n < 0, errno == EAGAIN {
            // A mark is a few dozen bytes; a full socket buffer means the
            // daemon is not reading. Wait briefly for room.
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard Darwin.poll(&pfd, 1, 100) > 0 else { return false }
          } else {
            return false
          }
        }
        return true
      }
      // A half-written frame would corrupt the stream: start over.
      if !sent { dropConnection() }
    }
  }

  /// Read at most `readsPerEvent` buffers, then return. The read source is
  /// level-triggered, so data left in the socket fires the handler again
  /// after the other work on the shared queue. A busy pane therefore cannot
  /// starve the other watchers, and `stop()` (a `sync` from the main actor)
  /// waits for at most one bounded batch.
  private func drain(fd: Int32) {
    var signals: [DetachedPaneSignal] = []
    defer { if !signals.isEmpty { onEvent(.signals(signals)) } }
    var reads = 0
    while source != nil, reads < readsPerEvent {
      reads += 1
      let n = readBuffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
      if n > 0 {
        pending.append(contentsOf: readBuffer[0..<n])
        do {
          while let frame = try ZmxFraming.decode(buffer: &pending) {
            if frame.tag == .output { signals += scanner.scan(frame.payload) }
          }
        } catch {
          // A broken frame stream cannot be resynchronised; start over.
          dropConnection()
          return
        }
        continue
      }
      if n < 0, errno == EINTR { continue }
      if n < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
      // EOF or a read error: the daemon dropped this client.
      dropConnection()
      return
    }
  }

  private func dropConnection() {
    disconnect()
    scheduleReconnect()
  }

  private func disconnect() {
    source?.cancel()
    source = nil
    fd = -1
  }

  private func scheduleReconnect() {
    guard !stopped else { return }
    let wait = delay
    delay = min(delay * 2, backoff.maxDelay)
    queue.asyncAfter(deadline: .now() + wait) { [weak self] in
      guard let self, !self.stopped, self.source == nil else { return }
      self.connect()
    }
  }
}
