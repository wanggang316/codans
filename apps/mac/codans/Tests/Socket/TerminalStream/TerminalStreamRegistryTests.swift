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

  @Test(.timeLimit(.minutes(1)))
  func peerHangingUpEndsAQuietStream() async throws {
    let fixture = try Fixture.withLivePane()
    let server = InMemoryIPCServer(router: fixture.router())
    server.start()
    defer { server.stop() }

    let hello = try JSONValue.encoded(HelloRequest(clientVersion: "1", clientBinary: "test"))
    try server.send(IPC.Request(id: "h", method: .systemHello, params: hello))
    _ = try await server.awaitResponse()
    try server.send(
      IPC.Request(
        id: "s", method: .paneAttachStream,
        params: try JSONValue.encoded(IPC.PaneAttachStreamRequest(paneID: fixture.paneID)), stream: true))
    for _ in 0..<100 where fixture.registry.activeCount == 0 {
      await Task.megaYield()
    }
    #expect(fixture.registry.activeCount == 1)

    // Nothing is written on a quiet stream, so only the hang-up can end it.
    server.hangUp()
    for _ in 0..<200 where fixture.registry.activeCount == 1 {
      await Task.megaYield()
    }
    #expect(fixture.registry.activeCount == 0)
    #expect(fixture.connections.value.first?.closeCount == 1)
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
    #expect(SystemHandlers.Versions(server: "1", appBundle: "1").protocolMinor == 4)
  }

  // MARK: - Fixture

  @MainActor
  // MARK: - Seats

  private func seatRequest(_ paneID: PaneID, claim: IPC.TerminalSizeClaim? = nil) -> IPC.PaneAttachStreamRequest {
    .init(paneID: paneID, seat: IPC.TerminalGridSize(cols: 58, rows: 36), claim: claim)
  }

  @Test
  func aCallerThatMayTypeGetsASeatWithItsGrid() throws {
    let fixture = try Fixture.withLivePane()
    _ = try fixture.registry.attach(seatRequest(fixture.paneID), caller: "phone", canType: true).get()
    let seat = try #require(fixture.seats.value.first)
    #expect(seat.size == IPC.TerminalGridSize(cols: 58, rows: 36))
    #expect(seat.log.value.isEmpty, "a seat must not take the lead just by opening")
  }

  @Test
  func aViewOnlyCallerOrOneWithoutAGridGetsNoSeat() throws {
    let fixture = try Fixture.withLivePane()
    _ = try fixture.registry.attach(seatRequest(fixture.paneID), caller: "viewer", canType: false).get()
    _ = try fixture.registry.attach(.init(paneID: fixture.paneID), caller: "phone", canType: true).get()
    let absurd = IPC.PaneAttachStreamRequest(paneID: fixture.paneID, seat: IPC.TerminalGridSize(cols: 2, rows: 1))
    _ = try fixture.registry.attach(absurd, caller: "phone", canType: true).get()
    #expect(fixture.seats.value.isEmpty)
  }

  @Test
  func claimNowTakesTheLeadAndAutoOnlyWhenNobodyIsAtTheMac() throws {
    let fixture = try Fixture.withLivePane()
    _ = try fixture.registry.attach(seatRequest(fixture.paneID, claim: .now), caller: "a", canType: true).get()
    _ = try fixture.registry.attach(seatRequest(fixture.paneID, claim: .auto), caller: "b", canType: true).get()
    fixture.macIsAway = true
    _ = try fixture.registry.attach(seatRequest(fixture.paneID, claim: .auto), caller: "c", canType: true).get()
    _ = try fixture.registry.attach(seatRequest(fixture.paneID, claim: .never), caller: "d", canType: true).get()
    #expect(fixture.seats.value.map(\.log.value) == [["claim"], [], ["claim"], []])
  }

  @Test
  func seatCallsReachTheCallersNewestSeat() throws {
    let fixture = try Fixture.withLivePane()
    _ = try fixture.registry.attach(seatRequest(fixture.paneID), caller: "phone", canType: true).get()
    _ = try fixture.registry.attach(seatRequest(fixture.paneID), caller: "phone", canType: true).get()
    let caller = "phone"
    _ = try fixture.registry.setSeatSize(
      .init(paneID: fixture.paneID, size: .init(cols: 90, rows: 30)), caller: caller
    ).get()
    _ = try fixture.registry.claimSize(.init(paneID: fixture.paneID, claim: true), caller: caller).get()
    _ = try fixture.registry.claimSize(.init(paneID: fixture.paneID, claim: false), caller: caller).get()
    _ = try fixture.registry.input(.init(paneID: fixture.paneID, bytes: Data("ls\r".utf8)), caller: caller).get()
    #expect(fixture.seats.value[0].log.value.isEmpty)
    #expect(fixture.seats.value[1].log.value == ["size 90x30", "claim", "release", "input ls\r"])

    let stranger = fixture.registry.input(.init(paneID: fixture.paneID, bytes: Data("x".utf8)), caller: "other")
    guard case .failure(.unsupported) = stranger else {
      Issue.record("expected unsupported, got \(stranger)")
      return
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func endingTheStreamClosesItsSeat() async throws {
    let fixture = try Fixture.withLivePane()
    let session = try fixture.registry.attach(seatRequest(fixture.paneID), caller: "phone", canType: true).get()
    await session.end()
    let seat = try #require(fixture.seats.value.first)
    for _ in 0..<100 where !seat.log.value.contains("close") {
      await Task.megaYield()
    }
    #expect(seat.log.value == ["close"])
  }

  @MainActor
  private final class Fixture {
    let paneID = PaneID()
    let socketPath = NSTemporaryDirectory() + "stream-registry-\(UUID().uuidString)"
    var knownPanes: Set<PaneID> = []
    var geometryObservers = 0
    let connections = LockIsolated<[FakeObserverConnection]>([])
    let seats = LockIsolated<[FakeSeat]>([])
    var macIsAway = false
    private(set) var registry: TerminalStreamRegistry!

    init() {
      let connections = connections
      let seats = seats
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
          connectSeat: { _, size in
            let seat = FakeSeat(size: size)
            seats.withValue { $0.append(seat) }
            return seat
          },
          isMacAway: { [weak self] _ in self?.macIsAway ?? false },
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

/// Records what the registry asks of a terminal seat.
private final class FakeSeat: ZmxSeatConnection, @unchecked Sendable {
  let size: IPC.TerminalGridSize
  let log = LockIsolated<[String]>([])

  init(size: IPC.TerminalGridSize) { self.size = size }

  func setSize(cols: UInt16, rows: UInt16) { log.withValue { $0.append("size \(cols)x\(rows)") } }
  func sendInput(_ bytes: Data) {
    let text = String(bytes: bytes, encoding: .utf8) ?? "?"
    log.withValue { $0.append("input \(text)") }
  }
  func claim() { log.withValue { $0.append("claim") } }
  func release() { log.withValue { $0.append("release") } }
  func close() { log.withValue { $0.append("close") } }
}
