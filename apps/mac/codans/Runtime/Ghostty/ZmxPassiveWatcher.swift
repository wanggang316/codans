import Darwin
import Foundation
import os.log

/// Observer of a pane that has no surface. `TerminalEngine` owns one per
/// detached pane; tests substitute a fake.
nonisolated protocol DetachedPaneWatching: AnyObject, Sendable {
  func start()
  func stop()
}

/// Passive zmx client for a pane that has no surface. It connects to the
/// pane's daemon socket and never writes: without `.Init` the daemon does
/// not replay the screen, never makes it the leader, and never resizes the
/// PTY for it, but still broadcasts every PTY `.Output` frame to it
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
  private var scanner = ZmxOutputScanner()
  private var pending = Data()
  private var stopped = false
  private var started = false
  private var refusals = 0
  private var delay: TimeInterval
  private var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)

  init(
    socketPath: String,
    queue: DispatchQueue = ZmxPassiveWatcher.sharedQueue,
    backoff: Backoff = .default,
    onEvent: @escaping @Sendable (Event) -> Void
  ) {
    self.socketPath = socketPath
    self.queue = queue
    self.backoff = backoff
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
    } catch ZmxControlClient.ControlError.connectFailed(let code)
      where code == ENOENT || code == ECONNREFUSED
    {
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
    source.resume()
  }

  private func drain(fd: Int32) {
    var signals: [DetachedPaneSignal] = []
    defer { if !signals.isEmpty { onEvent(.signals(signals)) } }
    while source != nil {
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
