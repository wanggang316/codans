import Darwin
import Foundation
import os.log

/// The observer side of a zmx daemon connection, as `PaneStreamSession`
/// drives it. `ZmxStreamClient` is the real one; tests substitute a fake.
nonisolated protocol ZmxObserverConnection: AnyObject, Sendable {
  var events: AsyncStream<ZmxStreamClient.Event> { get }
  func observe(scrollbackRows: UInt32)
  func requestHistory()
  func close()
}

/// Long-lived, read-only connection to a pane's zmx daemon.
///
/// It only ever sends `.observe` and `.history`: `.init`, `.input` and
/// `.resize` would make it the daemon's leader and let it resize the
/// Mac's PTY, and `.run` / `.write` would reach the shell. Keeping the
/// send surface this narrow is what makes a mirror safe to hand to a
/// read-only device.
///
/// The socket is non-blocking and drained by a `DispatchSourceRead` on a
/// private serial queue whenever it is readable, never throttled: a
/// client that stops reading makes the daemon buffer for it without
/// bound. Back-pressure is the consumer's job (see `PaneStreamSession`).
nonisolated final class ZmxStreamClient: ZmxObserverConnection, @unchecked Sendable {
  enum Event: Sendable {
    case frame(ZmxFrame)
    /// The daemon closed the connection (nil) or it failed. Last event.
    case closed((any Error)?)
  }

  /// Frames in wire order. Finishes after `.closed`, or on `close()`.
  let events: AsyncStream<Event>

  private let logger = Logger(subsystem: "com.gumpw.codans.runtime", category: "runtime.zmx.stream")
  private let queue = DispatchQueue(label: "com.gumpw.codans.zmx-stream")
  private let continuation: AsyncStream<Event>.Continuation
  private let source: any DispatchSourceRead
  private let fd: Int32
  // Touched only on `queue`.
  private var pending = Data()
  private var isClosed = false

  /// Connects to `socketPath` and starts draining it. Blocks for the
  /// `connect(2)` only, which is immediate for a local socket.
  init(socketPath: String) throws {
    let fd = try ZmxSocket.openConnection(socketPath: socketPath)
    let flags = fcntl(fd, F_GETFL)
    if flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 {
      let err = errno
      Darwin.close(fd)
      throw ZmxSocket.SocketError.connectFailed(errno: err)
    }
    self.fd = fd
    (events, continuation) = AsyncStream.makeStream(of: Event.self)
    source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self] in self?.drain() }
    // The fd is closed only here, once the source can no longer read it.
    source.setCancelHandler { Darwin.close(fd) }
    continuation.onTermination = { [weak self] _ in self?.close() }
    source.resume()
  }

  deinit {
    // `close()` normally ran already; this is the backstop so a dropped
    // client never leaks its fd.
    if !source.isCancelled { source.cancel() }
  }

  /// Asks for an observer snapshot (and to become an observer, the first
  /// time). The reply is `.observeState`.
  func observe(scrollbackRows: UInt32) {
    send(ZmxFrame(tag: .observe, payload: ZmxObservePayload(scrollbackRows: scrollbackRows).encode()))
  }

  /// Asks for a `vt`-format `.history` snapshot, for daemons that predate
  /// the observer protocol.
  func requestHistory() {
    send(ZmxFrame(tag: .history, payload: Data([ZmxHistoryFormat.vt.rawValue])))
  }

  /// Closes the connection. Idempotent; no events follow.
  func close() {
    queue.async { [self] in
      guard !isClosed else { return }
      isClosed = true
      source.cancel()
      continuation.finish()
    }
  }

  // MARK: - Queue-confined

  private func send(_ frame: ZmxFrame) {
    queue.async { [self] in
      guard !isClosed else { return }
      do {
        try ZmxSocket.sendAll(fd: fd, data: ZmxFraming.encode(frame))
      } catch {
        finish(error)
      }
    }
  }

  private func drain() {
    guard !isClosed else { return }
    var buf = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let n = buf.withUnsafeMutableBufferPointer { Darwin.read(fd, $0.baseAddress, $0.count) }
      if n > 0 {
        pending.append(contentsOf: buf.prefix(n))
        continue
      }
      if n == 0 {
        deliverPending()
        finish(nil)
        return
      }
      let err = errno
      if err == EINTR { continue }
      if err == EAGAIN || err == EWOULDBLOCK { break }
      deliverPending()
      finish(ZmxSocket.SocketError.connectFailed(errno: err))
      return
    }
    deliverPending()
  }

  private func deliverPending() {
    do {
      while let frame = try ZmxFraming.decodeSkippingUnknown(buffer: &pending) {
        continuation.yield(.frame(frame))
      }
    } catch {
      finish(error)
    }
  }

  private func finish(_ error: (any Error)?) {
    guard !isClosed else { return }
    isClosed = true
    if let error {
      logger.notice("zmx stream closed: \(String(describing: error), privacy: .public)")
    }
    continuation.yield(.closed(error))
    continuation.finish()
    source.cancel()
  }
}
