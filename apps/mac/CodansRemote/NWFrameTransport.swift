import CodansIPC
import Foundation
import Network
import os

/// Adapts one `NWConnection` to the byte-stream shape the IPC layer
/// consumes: `makeReader()` (raw inbound chunks), `write(_:)`, `close()`.
/// On the Mac the three feed `SocketConnection`; on iOS they feed
/// `RemoteRPCClient`. Framing stays with those consumers, except for the
/// pre-IPC handshake frame read by `receiveFrame()`.
public final class NWFrameTransport: Sendable {
  public enum TransportError: Error, Equatable, Sendable {
    /// The connection failed, including a TLS handshake the peer rejected.
    case failed(NWError)
    /// The connection was cancelled (locally, or by a handshake deadline).
    case cancelled
    /// The peer closed before a complete frame arrived.
    case closedByPeer
    case framing(Framing.FramingError)
  }

  public let connection: NWConnection
  private let queue: DispatchQueue
  /// Bytes received by `receiveFrame()` beyond the frame it returned; the
  /// reader replays them first so nothing is lost at the hand-off.
  private let leftover = OSAllocatedUnfairLock(initialState: Data())

  private static let maxReceiveLength = 64 * 1024

  public init(
    connection: NWConnection,
    queue: DispatchQueue = DispatchQueue(label: "com.gumpw.codans.remote.transport")
  ) {
    self.connection = connection
    self.queue = queue
  }

  /// Starts the connection and waits until it is ready, i.e. the TLS
  /// handshake succeeded.
  ///
  /// `.waiting` is treated as failure: `NWConnection` would otherwise keep
  /// retrying a rejected PSK handshake forever, hiding the rejection. The
  /// caller owns retry and backoff.
  public func start() async throws {
    let connection = self.connection
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let pending = OSAllocatedUnfairLock<CheckedContinuation<Void, Error>?>(initialState: continuation)
      let resume: @Sendable (Result<Void, Error>) -> Void = { result in
        pending.withLock { slot -> CheckedContinuation<Void, Error>? in
          defer { slot = nil }
          return slot
        }?.resume(with: result)
      }
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          resume(.success(()))
        case .failed(let error):
          resume(.failure(TransportError.failed(error)))
        case .waiting(let error):
          connection.cancel()
          resume(.failure(TransportError.failed(error)))
        case .cancelled:
          resume(.failure(TransportError.cancelled))
        case .setup, .preparing:
          break
        @unknown default:
          break
        }
      }
      connection.start(queue: queue)
    }
  }

  /// Reads exactly one length-prefixed frame. Only valid before
  /// `makeReader()`; used for the handshake frame that precedes IPC.
  public func receiveFrame() async throws -> Data {
    while true {
      let frame = try leftover.withLock { buffer in try Framing.decode(from: &buffer) }
      if let frame { return frame }
      let chunk = try await receiveChunk()
      leftover.withLock { $0.append(chunk) }
    }
  }

  /// Raw inbound bytes until the peer closes or the connection fails.
  /// Call once. Ending iteration early cancels the connection.
  public func makeReader() -> AsyncStream<Data> {
    let buffered = leftover.withLock { buffer -> Data in
      defer { buffer = Data() }
      return buffer
    }
    return AsyncStream { continuation in
      if !buffered.isEmpty { continuation.yield(buffered) }
      continuation.onTermination = { [connection] _ in connection.cancel() }
      pump(into: continuation)
    }
  }

  /// Sends bytes and waits until the stack has processed them.
  public func write(_ data: Data) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.send(
        content: data,
        completion: .contentProcessed { error in
          if let error {
            continuation.resume(throwing: TransportError.failed(error))
          } else {
            continuation.resume()
          }
        })
    }
  }

  /// Frames `body` with the IPC length prefix and sends it.
  public func writeFrame(_ body: Data) async throws {
    let frame: Data
    do {
      frame = try Framing.encode(body)
    } catch let error as Framing.FramingError {
      throw TransportError.framing(error)
    }
    try await write(frame)
  }

  public func close() {
    connection.cancel()
  }

  /// The TLS exporter for this connection; nil until ready.
  public var channelBinding: Data? {
    RemoteTLS.channelBinding(of: connection)
  }

  // MARK: - Internals

  private func receiveChunk() async throws -> Data {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
      connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxReceiveLength) {
        data, _, isComplete, error in
        if let data, !data.isEmpty {
          continuation.resume(returning: data)
        } else if let error {
          continuation.resume(throwing: TransportError.failed(error))
        } else if isComplete {
          continuation.resume(throwing: TransportError.closedByPeer)
        } else {
          continuation.resume(returning: Data())
        }
      }
    }
  }

  private func pump(into continuation: AsyncStream<Data>.Continuation) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxReceiveLength) {
      [self] data, _, isComplete, error in
      if let data, !data.isEmpty { continuation.yield(data) }
      if isComplete || error != nil {
        continuation.finish()
        return
      }
      pump(into: continuation)
    }
  }
}
