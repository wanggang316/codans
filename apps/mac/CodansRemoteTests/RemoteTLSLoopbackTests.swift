import CodansIPC
import Foundation
import Network
import Testing

@testable import CodansRemote

/// Proves the gateway's transport security end to end on a real
/// `NWListener` / `NWConnection` pair: TLS-PSK with per-device keys, plus
/// the peer proof that binds the device identity to the session.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RemoteTLSLoopbackTests {
  @Test
  func pairedDeviceHandshakesAndAuthenticates() async throws {
    let phone = try TestKeys.credential("device-phone")
    let tablet = try TestKeys.credential("device-tablet")
    let gateway = try await LoopbackGateway.start(credentials: [phone, tablet])
    defer { gateway.stop() }

    let client = try await RemoteHandshake.connect(to: gateway.endpoint, credential: tablet)
    defer { client.close() }

    guard case .accepted(let identity, let server) = await gateway.nextOutcome() else {
      Issue.record("server did not accept the paired device")
      return
    }
    defer { server.close() }
    #expect(identity == "device-tablet")
    #expect(
      RemoteTLS.negotiatedCipherSuite(of: client.connection)?.rawValue
        == RemoteTLS.cipherSuite.rawValue)

    // Application bytes flow both ways after the handshake.
    try await client.write(Data("ping".utf8))
    var serverReader = server.makeReader().makeAsyncIterator()
    #expect(await serverReader.next() == Data("ping".utf8))
    try await server.write(Data("pong".utf8))
    var clientReader = client.makeReader().makeAsyncIterator()
    #expect(await clientReader.next() == Data("pong".utf8))
  }

  @Test
  func wrongKeyFailsTheTLSHandshake() async throws {
    let paired = try TestKeys.credential("device-phone")
    let gateway = try await LoopbackGateway.start(credentials: [paired])
    defer { gateway.stop() }

    let forged = RemoteTLS.PSKCredential(identity: paired.identity, key: try PairingPayload.generateKey())
    let error = await #expect(throws: RemoteHandshake.HandshakeError.self) {
      try await RemoteHandshake.connect(to: gateway.endpoint, credential: forged)
    }
    #expect(error.map(Self.isRefusal) == true)
    guard case .rejected = await gateway.nextOutcome() else {
      Issue.record("server accepted a wrong key")
      return
    }
  }

  @Test
  func unknownIdentityFailsTheTLSHandshake() async throws {
    let paired = try TestKeys.credential("device-phone")
    let gateway = try await LoopbackGateway.start(credentials: [paired])
    defer { gateway.stop() }

    let stranger = try TestKeys.credential("device-stranger")
    let error = await #expect(throws: RemoteHandshake.HandshakeError.self) {
      try await RemoteHandshake.connect(to: gateway.endpoint, credential: stranger)
    }
    #expect(error.map(Self.isRefusal) == true)
    guard case .rejected = await gateway.nextOutcome() else {
      Issue.record("server accepted an unknown identity")
      return
    }
  }

  /// Revocation rebuilds the listener without the device's key; the
  /// device's next connection must fail.
  @Test
  func revokedDeviceCannotReconnect() async throws {
    let phone = try TestKeys.credential("device-phone")
    let tablet = try TestKeys.credential("device-tablet")

    let before = try await LoopbackGateway.start(credentials: [phone, tablet])
    let session = try await RemoteHandshake.connect(to: before.endpoint, credential: phone)
    session.close()
    before.stop()

    let after = try await LoopbackGateway.start(credentials: [tablet])
    defer { after.stop() }
    // A refusal, not a timeout: the phone counts these to stop retrying.
    let error = await #expect(throws: RemoteHandshake.HandshakeError.self) {
      try await RemoteHandshake.connect(to: after.endpoint, credential: phone)
    }
    #expect(error.map(Self.isRefusal) == true)
  }

  /// A device that handshakes with its own key cannot claim another
  /// device's identity: the proof is keyed by the claimed identity.
  @Test
  func pairedDeviceCannotImpersonateAnother() async throws {
    let readOnly = try TestKeys.credential("device-readonly")
    let interactive = try TestKeys.credential("device-interactive")
    let gateway = try await LoopbackGateway.start(credentials: [readOnly, interactive])
    defer { gateway.stop() }

    let connection = NWConnection(
      to: gateway.endpoint, using: RemoteTLS.clientParameters(credential: readOnly))
    let transport = NWFrameTransport(connection: connection)
    defer { transport.close() }
    try await transport.start()
    let binding = try #require(transport.channelBinding)
    let ownProof = RemotePeerProof.make(credential: readOnly, channelBinding: binding)
    let forged = RemotePeerProof(identity: interactive.identity, mac: ownProof.mac)
    try await transport.writeFrame(JSONEncoder().encode(forged))

    guard case .rejected(let error) = await gateway.nextOutcome() else {
      Issue.record("server accepted an impersonated identity")
      return
    }
    #expect(
      error as? RemoteHandshake.HandshakeError == .invalidProof(identity: interactive.identity))
  }

  /// A proof is bound to its TLS session; one captured from another
  /// connection does not verify.
  @Test
  func proofFromAnotherSessionIsRejected() async throws {
    let phone = try TestKeys.credential("device-phone")
    let gateway = try await LoopbackGateway.start(credentials: [phone])
    defer { gateway.stop() }

    let connection = NWConnection(
      to: gateway.endpoint, using: RemoteTLS.clientParameters(credential: phone))
    let transport = NWFrameTransport(connection: connection)
    defer { transport.close() }
    try await transport.start()
    let stale = RemotePeerProof.make(credential: phone, channelBinding: Data(repeating: 7, count: 32))
    try await transport.writeFrame(JSONEncoder().encode(stale))

    guard case .rejected(let error) = await gateway.nextOutcome() else {
      Issue.record("server accepted a proof from another session")
      return
    }
    #expect(error as? RemoteHandshake.HandshakeError == .invalidProof(identity: phone.identity))
  }

  @Test
  func silentPeerTimesOutOnTheServer() async throws {
    let phone = try TestKeys.credential("device-phone")
    let gateway = try await LoopbackGateway.start(
      credentials: [phone], handshakeTimeout: .milliseconds(300))
    defer { gateway.stop() }

    // Completes TLS but never sends the proof.
    let connection = NWConnection(
      to: gateway.endpoint, using: RemoteTLS.clientParameters(credential: phone))
    let transport = NWFrameTransport(connection: connection)
    defer { transport.close() }
    try await transport.start()

    guard case .rejected(let error) = await gateway.nextOutcome() else {
      Issue.record("server kept a silent peer")
      return
    }
    #expect(error as? RemoteHandshake.HandshakeError == .timedOut)
  }

  /// A peer that accepts TCP but never answers TLS reads as a timeout,
  /// never as a refusal.
  @Test
  func silentServerTimesOutInsteadOfRefusing() async throws {
    let listener = try NWListener(using: .tcp, on: .any)
    let accepted = LockIsolatedConnections()
    listener.newConnectionHandler = { connection in
      accepted.append(connection)
      connection.start(queue: .global())
    }
    let ready = AsyncStream<NWEndpoint.Port> { continuation in
      listener.stateUpdateHandler = { state in
        if case .ready = state, let port = listener.port { continuation.yield(port) }
      }
    }
    listener.start(queue: .global())
    defer {
      listener.cancel()
      accepted.cancelAll()
    }
    var ports = ready.makeAsyncIterator()
    let port = try #require(await ports.next())

    let phone = try TestKeys.credential("device-phone")
    await #expect(throws: RemoteHandshake.HandshakeError.timedOut) {
      try await RemoteHandshake.connect(
        to: .hostPort(host: "127.0.0.1", port: port), credential: phone, timeout: .milliseconds(500))
    }
  }

  private static func isRefusal(_ error: RemoteHandshake.HandshakeError) -> Bool {
    if case .refused = error { return true }
    return false
  }
}

/// Keeps the silent server's accepted connections alive for the test.
private final class LockIsolatedConnections: @unchecked Sendable {
  private let lock = NSLock()
  private var connections: [NWConnection] = []

  func append(_ connection: NWConnection) {
    lock.withLock { connections.append(connection) }
  }

  func cancelAll() {
    lock.withLock { connections.forEach { $0.cancel() } }
  }
}
