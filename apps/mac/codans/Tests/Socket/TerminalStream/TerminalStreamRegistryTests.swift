import ComposableArchitecture
import Foundation
import Testing

@testable import Codans
@testable import CodansCore
@testable import CodansIPC

/// `pane.attachStream` admission: the pane must exist and have a daemon,
/// and a caller (and the Mac) can only hold so many streams.
@MainActor
struct TerminalStreamRegistryTests {
  @Test
  func unknownPaneIsNotFound() {
    let fixture = Fixture()
    let result = fixture.registry.attach(.init(paneID: PaneID()), caller: "a")
    guard case .failure(.notFound(let kind, _)) = result else {
      Issue.record("expected notFound, got \(result)")
      return
    }
    #expect(kind == "pane")
  }

  @Test
  func paneWithoutADaemonIsUnsupported() {
    let fixture = Fixture()
    fixture.knownPanes.insert(fixture.paneID)
    try? FileManager.default.removeItem(atPath: fixture.socketPath)
    let result = fixture.registry.attach(.init(paneID: fixture.paneID), caller: "a")
    guard case .failure(.unsupported(let reason)) = result else {
      Issue.record("expected unsupported, got \(result)")
      return
    }
    #expect(reason == "pane has no running session")
    #expect(fixture.connections.value.isEmpty)
  }

  @Test
  func perCallerLimitIsFour() throws {
    let fixture = try Fixture.withLivePane()
    for _ in 0..<TerminalStreamRegistry.perCallerLimit {
      _ = try fixture.registry.attach(.init(paneID: fixture.paneID), caller: "phone").get()
    }
    let refused = fixture.registry.attach(.init(paneID: fixture.paneID), caller: "phone")
    guard case .failure(.overloaded) = refused else {
      Issue.record("expected overloaded, got \(refused)")
      return
    }
    // Another caller still gets one.
    _ = try fixture.registry.attach(.init(paneID: fixture.paneID), caller: "tablet").get()
    #expect(fixture.registry.activeCount == 5)
  }

  @Test
  func totalLimitIsSixteen() throws {
    let fixture = try Fixture.withLivePane()
    for index in 0..<TerminalStreamRegistry.totalLimit {
      _ = try fixture.registry.attach(.init(paneID: fixture.paneID), caller: "c\(index)").get()
    }
    let refused = fixture.registry.attach(.init(paneID: fixture.paneID), caller: "fresh")
    guard case .failure(.overloaded) = refused else {
      Issue.record("expected overloaded, got \(refused)")
      return
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func endingASessionFreesItsSlotAndStopsGeometryObservation() async throws {
    let fixture = try Fixture.withLivePane()
    var sessions: [PaneStreamSession] = []
    for _ in 0..<TerminalStreamRegistry.perCallerLimit {
      sessions.append(try fixture.registry.attach(.init(paneID: fixture.paneID), caller: "phone").get())
    }
    #expect(fixture.geometryObservers == 4)

    await sessions[0].end()
    for _ in 0..<100 where fixture.registry.activeCount(for: "phone") == 4 {
      await Task.megaYield()
    }
    #expect(fixture.registry.activeCount(for: "phone") == 3)
    #expect(fixture.geometryObservers == 3)
    #expect(fixture.connections.value[0].closeCount == 1)
    _ = try fixture.registry.attach(.init(paneID: fixture.paneID), caller: "phone").get()
  }

  @Test
  func requestedSettingsReachTheSession() throws {
    let fixture = try Fixture.withLivePane()
    let session = try fixture.registry.attach(
      .init(paneID: fixture.paneID, scrollbackRows: 99_999, coalesceMillis: 50), caller: "a"
    ).get()
    #expect(session.configuration.scrollbackRows == 5000)
    #expect(session.configuration.coalesceWindow == .milliseconds(50))
  }

  // MARK: - Router

  @Test
  func readOnlyDeviceMayAttach() async throws {
    let fixture = try Fixture.withLivePane()
    let router = fixture.router()
    let outcome = await router.route(
      IPC.Request(
        id: "s", method: .paneAttachStream,
        params: try JSONValue.encoded(IPC.PaneAttachStreamRequest(paneID: fixture.paneID)), stream: true),
      context: .remote(deviceID: UUID(), permission: .readOnly))
    guard case .streaming = outcome else {
      Issue.record("expected streaming, got \(outcome)")
      return
    }
    #expect(fixture.registry.activeCount == 1)
  }

  @Test
  func unaryAttachIsRefusedWithoutOpeningAConnection() async throws {
    let fixture = try Fixture.withLivePane()
    let outcome = await fixture.router().route(
      IPC.Request(
        id: "s", method: .paneAttachStream,
        params: try JSONValue.encoded(IPC.PaneAttachStreamRequest(paneID: fixture.paneID))),
      context: .local(peerPID: nil))
    guard case .failed(.invalidParams) = outcome else {
      Issue.record("expected invalidParams, got \(outcome)")
      return
    }
    #expect(fixture.connections.value.isEmpty)
  }

  @Test
  func malformedParamsAreInvalid() async {
    let fixture = Fixture()
    let outcome = await fixture.router().route(
      IPC.Request(id: "s", method: .paneAttachStream, params: .object(["paneID": .int(3)]), stream: true),
      context: .local(peerPID: nil))
    guard case .failed(.invalidParams) = outcome else {
      Issue.record("expected invalidParams, got \(outcome)")
      return
    }
  }

  @Test
  func callerKeysSeparateDevicesAndProcesses() {
    let device = UUID()
    #expect(
      CallerContext.remote(deviceID: device, permission: .readOnly).streamCallerKey
        == CallerContext.remote(deviceID: device, permission: .interactive).streamCallerKey)
    #expect(
      CallerContext.local(peerPID: 10).streamCallerKey != CallerContext.local(peerPID: 11).streamCallerKey)
  }

  @Test
  func handshakeAdvertisesProtocolMinorTwo() {
    #expect(SystemHandlers.Versions(server: "1", appBundle: "1").protocolMinor == 2)
  }

  // MARK: - Fixture

  @MainActor
  private final class Fixture {
    let paneID = PaneID()
    let socketPath = NSTemporaryDirectory() + "stream-registry-\(UUID().uuidString)"
    var knownPanes: Set<PaneID> = []
    var geometryObservers = 0
    let connections = LockIsolated<[FakeObserverConnection]>([])
    private(set) var registry: TerminalStreamRegistry!

    init() {
      let connections = connections
      registry = TerminalStreamRegistry(
        dependencies: .init(
          paneExists: { [weak self] in self?.knownPanes.contains($0) ?? false },
          socketPath: { [socketPath] _ in socketPath },
          gridSize: { _ in nil },
          observeGeometry: { [weak self] _, _ in
            self?.geometryObservers += 1
            return { [weak self] in self?.geometryObservers -= 1 }
          },
          connect: { _ in
            let connection = FakeObserverConnection()
            connections.withValue { $0.append(connection) }
            return connection
          },
          clock: TestClock<Duration>()
        ))
    }

    /// A pane the catalog knows, with a file where its socket would be.
    static func withLivePane() throws -> Fixture {
      let fixture = Fixture()
      fixture.knownPanes.insert(fixture.paneID)
      try Data().write(to: URL(fileURLWithPath: fixture.socketPath))
      return fixture
    }

    func router() -> MethodRouter {
      MethodRouter(
        systemHandlers: SystemHandlers(versions: .init(server: "1", appBundle: "1")),
        terminalStreams: registry)
    }

    deinit {
      try? FileManager.default.removeItem(atPath: socketPath)
    }
  }
}
