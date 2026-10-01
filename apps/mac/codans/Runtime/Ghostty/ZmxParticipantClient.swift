import Darwin
import Foundation
import os.log

/// A remote device's own seat at a pane's zmx daemon: a terminal client
/// like the Mac's `zmx attach`, opened by the app on the device's behalf.
///
/// zmx sizes the PTY for its leader, the client that last typed (or
/// claimed the lead), the way tmux's `window-size latest` does. With a seat
/// of its own, a phone that types — or claims the lead while the Mac is
/// idle — gets the pane laid out for its screen; typing on the Mac takes it
/// back, and when the seat closes the daemon returns the lead to the Mac.
///
/// It sends `.init` with the device's size, answers the daemon's size
/// requests (sent to a new leader) with that size, and forwards input the
/// device encoded. PTY output the daemon also sends every terminal client
/// is read and dropped: the device watches through its own observer
/// stream. The socket is non-blocking and drained on a private queue
/// whenever readable, so the daemon never buffers for this client.
nonisolated final class ZmxParticipantClient: @unchecked Sendable {
  enum Event: Sendable, Equatable {
    /// The daemon made this seat the leader and asked for its size.
    case becameLeader
    /// The connection ended (the daemon went away or it failed). Last event.
    case closed
  }

  let events: AsyncStream<Event>

  private let logger = Logger(subsystem: "com.gumpw.codans.runtime", category: "runtime.zmx.participant")
  private let queue = DispatchQueue(label: "com.gumpw.codans.zmx-participant")
  private let continuation: AsyncStream<Event>.Continuation
  private let source: any DispatchSourceRead
  private let fd: Int32
  // Touched only on `queue`.
  private var pending = Data()
  private var size: ZmxResizePayload
  private var isClosed = false

  /// Connects and introduces the seat with `size`. The daemon makes it the
  /// leader right away only when no client leads (the pane is not open on
  /// the Mac); otherwise it waits for input or `claim()`.
  init(socketPath: String, cols: UInt16, rows: UInt16) throws {
    let fd = try ZmxSocket.openConnection(socketPath: socketPath)
    let flags = fcntl(fd, F_GETFL)
    if flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 {
      let err = errno
      Darwin.close(fd)
      throw ZmxSocket.SocketError.connectFailed(errno: err)
    }
    self.fd = fd
    self.size = ZmxResizePayload(cols: cols, rows: rows)
    (events, continuation) = AsyncStream.makeStream(of: Event.self)
    source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self] in self?.drain() }
    source.setCancelHandler { Darwin.close(fd) }
    continuation.onTermination = { [weak self] _ in self?.close() }
    source.resume()
    send(ZmxFrame(tag: .`init`, payload: size.encode()))
  }

  deinit {
    if !source.isCancelled { source.cancel() }
  }

  /// The device's grid changed (rotation, keyboard). Takes effect at once
  /// while this seat leads; the daemon ignores it otherwise, and asks
  /// again when it hands this seat the lead.
  func setSize(cols: UInt16, rows: UInt16) {
    queue.async { [self] in
      size = ZmxResizePayload(cols: cols, rows: rows)
      write(ZmxFrame(tag: .resize, payload: size.encode()))
    }
  }

  /// Bytes the device typed, already encoded for the terminal. Real input
  /// makes this seat the leader.
  func sendInput(_ bytes: Data) {
    guard !bytes.isEmpty else { return }
    send(ZmxFrame(tag: .input, payload: bytes))
  }

  /// Take the lead without typing.
  func claim() { send(ZmxFrame(tag: .claim)) }

  /// Give the lead back to the Mac.
  func release() { send(ZmxFrame(tag: .release)) }

  /// Closes the seat; the daemon hands the lead back if it had it.
  /// Idempotent.
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
    queue.async { [self] in write(frame) }
  }

  private func write(_ frame: ZmxFrame) {
    guard !isClosed else { return }
    do {
      try ZmxSocket.sendAll(fd: fd, data: ZmxFraming.encode(frame))
    } catch {
      finish(error)
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
        handleFrames()
        finish(nil)
        return
      }
      let err = errno
      if err == EINTR { continue }
      if err == EAGAIN || err == EWOULDBLOCK { break }
      finish(ZmxSocket.SocketError.connectFailed(errno: err))
      return
    }
    handleFrames()
  }

  private func handleFrames() {
    do {
      while let frame = try ZmxFraming.decodeSkippingUnknown(buffer: &pending) {
        // An empty `.resize` is the daemon asking a new leader for its size.
        guard frame.tag == .resize, frame.payload.isEmpty else { continue }
        write(ZmxFrame(tag: .resize, payload: size.encode()))
        continuation.yield(.becameLeader)
      }
    } catch {
      finish(error)
    }
  }

  private func finish(_ error: (any Error)?) {
    guard !isClosed else { return }
    isClosed = true
    if let error {
      logger.notice("zmx participant closed: \(String(describing: error), privacy: .public)")
    }
    continuation.yield(.closed)
    continuation.finish()
    source.cancel()
  }
}
