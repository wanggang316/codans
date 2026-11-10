import CodansRemote
import Foundation
import Network
import Testing

@testable import Codans
@testable import CodansCore
@testable import CodansIPC

/// The whole relay path against a real relay server: the gateway's relay
/// connector on one side, the phone's loopback bridge and an ordinary
/// TLS-PSK client on the other. Runs only when `CODANS_RELAY_TEST_URL`
/// points at a relay (`TEST_RUNNER_CODANS_RELAY_TEST_URL` through
/// xcodebuild), e.g. one started with `make -C apps/relay run`.
@MainActor
struct RelayEndToEndTests {
  nonisolated private static let relayURL = ProcessInfo.processInfo.environment["CODANS_RELAY_TEST_URL"]

  @Test(.enabled(if: relayURL != nil), .timeLimit(.minutes(1)))
  func aPairedPhoneReachesTheGatewayThroughTheRelay() async throws {
    let relayURL = try #require(Self.relayURL)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("relay-e2e-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = PairedDeviceStore(fileURL: dir.appendingPathComponent("d.json"), keys: InMemoryRemoteKeyStore())
    let systemHandlers = SystemHandlers(versions: .init(server: "1", appBundle: "1"))
    let gateway = RemoteGatewayServer(
      router: MethodRouter(systemHandlers: systemHandlers), devices: store,
      environment: ["CODANS_RELAY_URL": relayURL], hostName: "Relay Test", scope: .loopback,
      relaySecrets: InMemoryRelaySecretStore(secret: RemoteRelay.newMacSecret()))
    systemHandlers.relayCoordinates = { [weak gateway] in gateway?.relayCoordinates }
    defer { gateway.setEnabled(false) }

    gateway.setRelayAllowed(true)
    gateway.setEnabled(true)
    let payload = try gateway.pairNewDevice(permission: .interactive)
    let relay = try #require(payload.relay)
    try await Self.waitUntil { gateway.relay?.status == .online && gateway.listenerPort != nil }

    // The phone: only the relay, never the gateway's own port.
    let bridge = RelayLoopbackBridge(relay: relay, token: RemoteRelay.phoneToken(psk: payload.psk))
    defer { bridge.stop() }
    let endpoint = try await bridge.start()
    let client = try await RemoteRPCClient.connect(
      to: endpoint, credential: payload.credential,
      hello: HelloRequest(clientVersion: "1", clientBinary: "relay-test"))
    let hello = try #require(await client.serverHello)
    #expect(hello.remotePermission == .interactive)
    #expect(hello.relay == relay)
    #expect(store.device(payload.deviceID)?.state == .active)
    _ = try await client.callRaw(.systemPing, params: [String: String]())
    await client.close()

    // A token the Mac never listed is refused by the relay itself.
    let strangerKey = Data(repeating: 9, count: 32)
    let stranger = RelayLoopbackBridge(relay: relay, token: RemoteRelay.phoneToken(psk: strangerKey))
    defer { stranger.stop() }
    let strangerEndpoint = try await stranger.start()
    await #expect(throws: (any Error).self) {
      try await RemoteRPCClient.connect(
        to: strangerEndpoint, credential: RemoteTLS.PSKCredential(identity: "x", key: strangerKey),
        hello: HelloRequest(clientVersion: "1", clientBinary: "relay-test"), timeout: .seconds(5))
    }
    #expect(stranger.lastRefusal == 403)

    // Revoking the device takes its token off the relay's list.
    store.revoke(payload.deviceID)
    try await Task.sleep(for: .milliseconds(300))
    await #expect(throws: (any Error).self) {
      try await RemoteRPCClient.connect(
        to: endpoint, credential: payload.credential,
        hello: HelloRequest(clientVersion: "1", clientBinary: "relay-test"), timeout: .seconds(5))
    }
    #expect(bridge.lastRefusal == 403)

    // With outside access turned off the Mac leaves the relay.
    gateway.setRelayAllowed(false)
    #expect(gateway.relay == nil)
  }

  private static func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<250 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("condition not met within 5 seconds")
  }
}
