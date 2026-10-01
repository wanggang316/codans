import CodansIPC
import Foundation
import Network
import os

/// Connection setup on both ends of the gateway: TLS-PSK, then one
/// `RemotePeerProof` frame that pins the device identity to the session.
/// Only after both succeed does a connection carry IPC traffic.
public enum RemoteHandshake {
  public enum HandshakeError: Error, Equatable, Sendable {
    case timedOut
    /// TCP connected but the peer failed the TLS handshake (unknown PSK
    /// identity, wrong key). Unlike a timeout this is an answer: the Mac
    /// is there and does not accept this credential, which is what a
    /// revoked or expired pairing looks like. Carries the TLS `OSStatus`.
    case refused(status: Int32)
    case transport(NWFrameTransport.TransportError)
    case missingChannelBinding
    case malformedProof
    /// The proof names an identity the server does not hold a key for.
    case unknownIdentity(String)
    /// The proof does not verify under the named identity's key.
    case invalidProof(identity: String)
  }

  public static let defaultTimeout: Duration = .seconds(10)

  /// Client side: connects to `endpoint` with `credential`, completes TLS,
  /// and sends the peer proof. The returned transport is ready for IPC.
  /// A Bonjour `.service` endpoint is resolved first (see
  /// `RemoteBonjour.resolve`), within the same `timeout`.
  public static func connect(
    to endpoint: NWEndpoint,
    credential: RemoteTLS.PSKCredential,
    timeout: Duration = defaultTimeout
  ) async throws -> NWFrameTransport {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    let target: NWEndpoint
    do {
      target = try await RemoteBonjour.resolve(endpoint, timeout: timeout)
    } catch RemoteBonjour.ResolveError.timedOut {
      throw HandshakeError.timedOut
    } catch RemoteBonjour.ResolveError.failed(let code) {
      throw HandshakeError.transport(.failed(.dns(code)))
    }
    let remaining = deadline - clock.now
    guard remaining > .zero else { throw HandshakeError.timedOut }
    let connection = NWConnection(to: target, using: RemoteTLS.clientParameters(credential: credential))
    let transport = NWFrameTransport(connection: connection)
    try await withDeadline(remaining, cancelling: connection) {
      try await transport.start()
      guard let binding = transport.channelBinding else { throw HandshakeError.missingChannelBinding }
      let proof = RemotePeerProof.make(credential: credential, channelBinding: binding)
      try await transport.writeFrame(JSONEncoder().encode(proof))
    }
    return transport
  }

  /// Server side, for a connection handed over by the listener: completes
  /// TLS, reads the peer proof and verifies it against `key(identity)`.
  /// Returns the authenticated identity; any failure cancels the
  /// connection. `timeout` bounds the whole pre-auth phase so a silent
  /// peer cannot hold a slot.
  public static func accept(
    _ connection: NWConnection,
    timeout: Duration = defaultTimeout,
    key: @escaping @Sendable (String) -> Data?
  ) async throws -> (identity: String, transport: NWFrameTransport) {
    let transport = NWFrameTransport(connection: connection)
    do {
      let identity = try await withDeadline(timeout, cancelling: connection) { () async throws -> String in
        try await transport.start()
        guard let binding = transport.channelBinding else { throw HandshakeError.missingChannelBinding }
        let frame = try await transport.receiveFrame()
        guard let proof = try? JSONDecoder().decode(RemotePeerProof.self, from: frame) else {
          throw HandshakeError.malformedProof
        }
        guard let deviceKey = key(proof.identity) else {
          throw HandshakeError.unknownIdentity(proof.identity)
        }
        guard proof.isValid(key: deviceKey, channelBinding: binding) else {
          throw HandshakeError.invalidProof(identity: proof.identity)
        }
        return proof.identity
      }
      return (identity, transport)
    } catch {
      transport.close()
      throw error
    }
  }

  /// Runs `body`, cancelling `connection` if it has not finished within
  /// `timeout`. Cancelling the connection is what unblocks a pending
  /// Network.framework callback; the cancellation is then reported as
  /// `.timedOut` rather than as a transport error. A TLS-layer failure is
  /// reported as `.refused`, so a client can tell "the Mac said no" from
  /// "nothing answered".
  private static func withDeadline<T: Sendable>(
    _ timeout: Duration,
    cancelling connection: NWConnection,
    _ body: @Sendable () async throws -> T
  ) async throws -> T {
    let fired = OSAllocatedUnfairLock(initialState: false)
    let timer = Task {
      try await Task.sleep(for: timeout)
      fired.withLock { $0 = true }
      connection.cancel()
    }
    defer { timer.cancel() }
    do {
      return try await body()
    } catch let error as NWFrameTransport.TransportError {
      if fired.withLock({ $0 }) { throw HandshakeError.timedOut }
      if case .failed(.tls(let status)) = error { throw HandshakeError.refused(status: status) }
      throw HandshakeError.transport(error)
    }
  }
}
