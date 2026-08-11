import Darwin
import Foundation
import CodansIPC
import os

/// Production `Transport` over a Unix domain socket. Opens a fresh
/// connection per `codans` invocation; writes are length-prefix framed.
public final class UnixSocketTransport: Transport, @unchecked Sendable {
  private struct State {
    var fd: Int32 = -1
    var readerStarted = false
  }

  private let path: String
  private let logger = Logger(subsystem: "com.gumpw.codans.cli", category: "transport")
  public let inbound: AsyncStream<Data>
  private let continuation: AsyncStream<Data>.Continuation
  private var readTask: Task<Void, Never>?
  private let state = OSAllocatedUnfairLock(initialState: State())

  public init(path: String) throws {
    // Defer socket(2)+connect(2) to the first send. On macOS 26.x, any
    // scheduler gap (Task.yield, await, even an actor hop) between
    // connect(2) and the first send(2) on a Unix-domain SOCK_STREAM
    // client wedges the kernel-side connection: send(2) returns EPIPE and
    // the server's serve loop sees an immediate EOF, so no bytes transit.
    // RPCClient unavoidably introduces such a gap (`call` awaits
    // `pipelinedSend` before `transport.send`), so connecting eagerly here
    // would race the quirk on every invocation. The fix keeps connect +
    // first send in one synchronous block (see `send`); this init only
    // stashes the path and wires up the inbound AsyncStream.
    self.path = path
    var continuation: AsyncStream<Data>.Continuation!
    self.inbound = AsyncStream<Data> { cont in continuation = cont }
    self.continuation = continuation
  }

  // The `async` keyword has no `await` body today, but removing it breaks
  // callers; suppress the lint until a CodansKit concurrency audit revisits it.
  // swiftlint:disable:next async_without_await
  public func send(_ frame: Data) async throws {
    // Darwin.send(2) — not write(2). On macOS 26.x, write(2) on a Unix
    // domain socket whose accept-side handler has not yet called read(2)
    // can return EPIPE before any bytes hit the wire; send(2) on the same
    // fd works identically to BSD sockets and honours SO_NOSIGPIPE. Lazy
    // connect runs inside this method (under the lock) so connect(2) and
    // the first send(2) share one block with no scheduler hop — the gap
    // that triggers the EPIPE quirk.
    let needsReader = try state.withLock { (s: inout State) -> Bool in
      try Self.ensureConnectedLocked(state: &s, path: path)
      var remaining = frame
      while !remaining.isEmpty {
        let written = remaining.withUnsafeBytes { ptr -> Int in
          Darwin.send(s.fd, ptr.baseAddress, remaining.count, 0)
        }
        if written < 0 {
          if errno == EINTR { continue }
          throw SocketConnectionFailure.inFlight(errno: errno, path: path)
        }
        if written == 0 {
          throw SocketConnectionFailure(kind: .connectionLost, path: path)
        }
        remaining.removeFirst(written)
      }
      let wasNotStarted = !s.readerStarted
      s.readerStarted = true
      return wasNotStarted
    }
    // Send-first, read-second: only spawn the inbound pump once we've
    // shipped the first frame. See init() for the macOS 26.x rationale.
    if needsReader { startReader() }
  }

  /// Synchronously open the socket and connect, if not already connected.
  /// Caller MUST hold the state lock. Throws a classified
  /// `SocketConnectionFailure` on any failure; on success populates
  /// `state.fd` with a connected SOCK_STREAM fd.
  private static func ensureConnectedLocked(state: inout State, path: String) throws {
    if state.fd >= 0 { return }
    state.fd = try UnixSocketDial.open(path: path)
  }

  public func close() {
    readTask?.cancel()
    readTask = nil
    let f = state.withLock { (s: inout State) -> Int32 in
      let prev = s.fd
      s.fd = -1
      return prev
    }
    if f >= 0 {
      _ = Darwin.shutdown(f, SHUT_RDWR)
      _ = Darwin.close(f)
    }
    continuation.finish()
  }

  private func startReader() {
    let fd = state.withLock { $0.fd }
    let continuation = self.continuation
    readTask = Task.detached {
      let bufferSize = 8192
      var buffer = [UInt8](repeating: 0, count: bufferSize)
      while !Task.isCancelled {
        await Task.yield()
        let n = buffer.withUnsafeMutableBufferPointer { ptr in
          Darwin.read(fd, ptr.baseAddress, bufferSize)
        }
        if n > 0 {
          continuation.yield(Data(buffer.prefix(n)))
          continue
        }
        if n == 0 { break }
        if errno == EINTR { continue }
        break
      }
      continuation.finish()
    }
  }
}
