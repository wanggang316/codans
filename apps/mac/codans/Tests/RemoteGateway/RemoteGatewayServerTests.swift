import CodansRemote
import Foundation
import Network
import Testing

@testable import Codans
@testable import CodansCore
@testable import CodansIPC

/// End to end on 127.0.0.1 (the `.loopback` scope never advertises over
/// Bonjour): pairing, TLS-PSK handshake, per-request permission, revoke.
@MainActor
struct RemoteGatewayServerTests {
  @Test(.timeLimit(.minutes(1)))
  func pairedDeviceIsServedWithinItsTierUntilRevoked() async throws {
    let dir = try Self.makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = PairedDeviceStore(fileURL: dir.appendingPathComponent("d.json"), keys: InMemoryRemoteKeyStore())
    let gateway = Self.makeGateway(store: store)
    defer { gateway.setEnabled(false) }

    gateway.setEnabled(true)
    #expect(gateway.status == .noDevices)
    let payload = try gateway.pairNewDevice()
    #expect(payload.channel == BuildChannel.current.slug)
    let port = try await Self.waitUntilListening(gateway)

    let client = try await RemoteRPCClient.connect(
      to: .hostPort(host: "127.0.0.1", port: port),
      credential: payload.credential,
      hello: HelloRequest(clientVersion: "1", clientBinary: "test")
    )
    #expect(store.device(payload.deviceID)?.state == .active)
    #expect(gateway.connectedDeviceIDs == [payload.deviceID])

    _ = try await client.callRaw(.systemPing, params: [String: String]())
    #expect(await Self.errorCode(client, .terminalSendInput) == "forbidden")

    // A permission change applies to the next request, no reconnect.
    store.setPermission(payload.deviceID, to: .interactive)
    #expect(await Self.errorCode(client, .terminalSendInput) == "unsupported")
    #expect(await Self.errorCode(client, .systemQuit) == "forbidden")

    store.revoke(payload.deviceID)
    for _ in 0..<250 where await client.isConnected {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await !client.isConnected)
    #expect(gateway.status == .noDevices)
  }

  /// The listener keeps an expired code's key until its next rebuild, so
  /// the post-handshake check must reject the code on its own.
  @Test(.timeLimit(.minutes(1)))
  func expiredPairingCodeIsRejectedWhileTheListenerStillHoldsIt() async throws {
    let dir = try Self.makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
    let store = PairedDeviceStore(
      fileURL: dir.appendingPathComponent("d.json"), keys: InMemoryRemoteKeyStore(), now: { clock.date })
    let gateway = Self.makeGateway(store: store)
    defer { gateway.setEnabled(false) }

    gateway.setEnabled(true)
    let payload = try gateway.pairNewDevice()
    let port = try await Self.waitUntilListening(gateway)
    clock.date += PairedDeviceStore.pendingLifetimeSeconds + 1

    await #expect(throws: (any Error).self) {
      let client = try await RemoteRPCClient.connect(
        to: .hostPort(host: "127.0.0.1", port: port),
        credential: payload.credential,
        hello: HelloRequest(clientVersion: "1", clientBinary: "test")
      )
      await client.close()
    }
    #expect(store.device(payload.deviceID) == nil)
    #expect(gateway.status == .noDevices)
  }

  /// A code issued before a relaunch is not re-issued, so the gateway must
  /// arm its expiry from the persisted record.
  @Test(.timeLimit(.minutes(1)))
  func pendingPairingLoadedAtLaunchExpiresOnTime() async throws {
    let dir = try Self.makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("d.json")
    let keys = InMemoryRemoteKeyStore()
    let issuedAt = Date(timeIntervalSince1970: 1_000_000)
    let pending = try PairedDeviceStore(fileURL: url, keys: keys, now: { issuedAt }).beginPairing()

    let clock = MutableClock(issuedAt + PairedDeviceStore.pendingLifetimeSeconds - 0.5)
    let store = PairedDeviceStore(fileURL: url, keys: keys, now: { clock.date })
    let gateway = Self.makeGateway(store: store)
    defer { gateway.setEnabled(false) }
    gateway.setEnabled(true)
    _ = try await Self.waitUntilListening(gateway)
    #expect(store.device(pending.id) != nil)

    clock.date = issuedAt + PairedDeviceStore.pendingLifetimeSeconds
    for _ in 0..<250 where store.device(pending.id) != nil {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(store.device(pending.id) == nil)
    #expect(gateway.status == .noDevices)
  }

  @Test(.timeLimit(.minutes(1)))
  func revokingADeviceEndsItsLiveEventStream() async throws {
    try await expectLiveStreamEnds { _, store, deviceID in store.revoke(deviceID) }
  }

  @Test(.timeLimit(.minutes(1)))
  func turningTheGatewayOffEndsLiveEventStreams() async throws {
    try await expectLiveStreamEnds { gateway, _, _ in gateway.setEnabled(false) }
  }

  /// Subscribes over a real TLS connection, reads the snapshot, applies
  /// `end`, and requires the stream to finish rather than hang.
  private func expectLiveStreamEnds(
    _ end: (RemoteGatewayServer, PairedDeviceStore, UUID) -> Void
  ) async throws {
    let dir = try Self.makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = PairedDeviceStore(fileURL: dir.appendingPathComponent("d.json"), keys: InMemoryRemoteKeyStore())
    let hub = EventHub(
      sources: EventHub.Sources(
        hierarchy: { IPC.HierarchySummary(projects: [], selectedProjectID: nil) },
        agents: { [] }
      ))
    let router = MethodRouter(
      systemHandlers: SystemHandlers(versions: .init(server: "1", appBundle: "1")), eventHub: hub)
    let gateway = RemoteGatewayServer(
      router: router, devices: store, environment: [:], hostName: "Test", scope: .loopback)
    defer { gateway.setEnabled(false) }

    gateway.setEnabled(true)
    let payload = try gateway.pairNewDevice()
    let port = try await Self.waitUntilListening(gateway)
    let client = try await RemoteRPCClient.connect(
      to: .hostPort(host: "127.0.0.1", port: port),
      credential: payload.credential,
      hello: HelloRequest(clientVersion: "1", clientBinary: "test")
    )
    defer { Task { await client.close() } }

    let frames = try await client.subscribe(
      .eventsSubscribe, params: IPC.EventsSubscribeRequest(), as: IPC.EventFrame.self)
    var iterator = frames.makeAsyncIterator()
    let first = try await iterator.next()
    guard case .snapshot = first?.payload else {
      Issue.record("expected a snapshot first, got \(String(describing: first))")
      return
    }

    end(gateway, store, payload.deviceID)
    // The stream must terminate: either a clean finish or a closed-connection error.
    do {
      while try await iterator.next() != nil {}
    } catch {}
    // The client notices the server's close on its next read.
    for _ in 0..<250 where await client.isConnected {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await !client.isConnected)
  }

  @Test
  func environmentOverrideKeepsTheGatewayOff() throws {
    let dir = try Self.makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = PairedDeviceStore(fileURL: dir.appendingPathComponent("d.json"), keys: InMemoryRemoteKeyStore())
    let gateway = Self.makeGateway(store: store, environment: ["CODANS_REMOTE_DISABLED": "1"])
    _ = try store.beginPairing()
    gateway.setEnabled(true)
    #expect(gateway.status == .forcedOff)
  }

  @Test
  func debugAndReleaseAdvertiseDistinctNames() throws {
    let dir = try Self.makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = PairedDeviceStore(fileURL: dir.appendingPathComponent("d.json"), keys: InMemoryRemoteKeyStore())
    let dev = RemoteGatewayServer(
      router: Self.makeRouter(), devices: store, channel: .development, environment: [:], hostName: "Mac",
      scope: .loopback)
    let release = RemoteGatewayServer(
      router: Self.makeRouter(), devices: store, channel: .release, environment: [:], hostName: "Mac",
      scope: .loopback)
    #expect(dev.serviceName == "Mac (codans-dev)")
    #expect(release.serviceName == "Mac")
  }

  // MARK: - Helpers

  private static func makeRouter() -> MethodRouter {
    MethodRouter(systemHandlers: SystemHandlers(versions: .init(server: "1", appBundle: "1")))
  }

  private static func makeGateway(
    store: PairedDeviceStore,
    environment: [String: String] = [:]
  ) -> RemoteGatewayServer {
    RemoteGatewayServer(
      router: makeRouter(), devices: store, environment: environment, hostName: "Test", scope: .loopback)
  }

  private static func waitUntilListening(_ gateway: RemoteGatewayServer) async throws -> NWEndpoint.Port {
    for _ in 0..<250 {
      if case .listening(let port) = gateway.status, let endpoint = NWEndpoint.Port(rawValue: port) {
        return endpoint
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw CancellationError()
  }

  private static func errorCode(_ client: RemoteRPCClient, _ method: IPC.Method) async -> String? {
    do {
      _ = try await client.callRaw(method, params: [String: String]())
      return nil
    } catch RemoteRPCClient.ClientError.ipc(let error) {
      return error.code
    } catch {
      return "\(error)"
    }
  }

  private static func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("remote-gateway-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }
}

@MainActor
private final class MutableClock {
  var date: Date

  init(_ date: Date) {
    self.date = date
  }
}
