import Foundation

/// Abstract request/response byte channel. The production transport is
/// `UnixSocketTransport`; tests inject `InMemoryTransport` (CodansKitTests)
/// to exercise `RPCClient` without a real socket.
public protocol Transport: Sendable {
  /// Write one framed request body (length-prefixed). Thread-safe.
  func send(_ frame: Data) async throws

  /// Stream of inbound framed response bodies. Finishes when the peer
  /// closes or the transport shuts down.
  var inbound: AsyncStream<Data> { get }

  func close()
}
