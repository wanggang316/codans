import Foundation
import Testing

@testable import Codans
@testable import CodansCore
@testable import CodansIPC

/// terminal.sendInput / broadcastInput are intentionally backed by
/// an injectable `TerminalHandlers.InputSink` protocol — the
/// bootstrap passes `nil`, so both RPCs must surface `.unsupported`
/// cleanly (exit code 4 for the CLI). These tests pin that contract + a
/// minimum-viable fake-sink path proving the routing wires up.
@MainActor
struct TerminalHandlersTests {
  // MARK: - .unsupported when no sink

  @Test
  func sendInputReturnsUnsupportedWhenNoSink() async throws {
    let server = Self.makeHarness(sink: nil)
    defer { server.stop() }
    try InMemoryIPCServerTests.sendHello(server)
    _ = try await server.awaitResponse()

    struct Params: Codable {
      let paneID: PaneID
      let text: String
    }
    let params = try JSONValue.encoded(Params(paneID: PaneID(), text: "hello"))
    try server.send(
      IPC.Request(id: "s1", method: .terminalSendInput, params: params)
    )
    let response = try await server.awaitResponse()
    if case .unsupported = response.error {
      // expected — the bootstrap intentionally ships without a live
      // GhosttyRuntime.
    } else {
      Issue.record("expected .unsupported, got \(String(describing: response.error))")
    }
  }

  @Test
  func broadcastReturnsUnsupportedWhenNoSink() async throws {
    let server = Self.makeHarness(sink: nil)
    defer { server.stop() }
    try InMemoryIPCServerTests.sendHello(server)
    _ = try await server.awaitResponse()

    struct Params: Codable {
      let scope: IPC.BroadcastScope
      let text: String
    }
    let params = try JSONValue.encoded(Params(scope: .label("agent"), text: "date"))
    try server.send(
      IPC.Request(id: "b1", method: .terminalBroadcastInput, params: params)
    )
    let response = try await server.awaitResponse()
    if case .unsupported = response.error {
      // expected
    } else {
      Issue.record("expected .unsupported, got \(String(describing: response.error))")
    }
  }

  // MARK: - Fake-sink routing

  @Test
  func sendInputDeliversViaFakeSink() async throws {
    let sink = FakeSink()
    let server = Self.makeHarness(sink: sink)
    defer { server.stop() }
    try InMemoryIPCServerTests.sendHello(server)
    _ = try await server.awaitResponse()

    let pid = PaneID()
    sink.registered.insert(pid.raw)
    struct Params: Codable {
      let paneID: PaneID
      let text: String
    }
    let params = try JSONValue.encoded(Params(paneID: pid, text: "ls\n"))
    try server.send(
      IPC.Request(id: "s2", method: .terminalSendInput, params: params)
    )
    let response = try await server.awaitResponse()
    #expect(response.error == nil)
    #expect(sink.delivered.first?.text == "ls\n")
  }

  @Test
  func sendInputToUnknownPaneReturnsNotFound() async throws {
    let sink = FakeSink()
    let server = Self.makeHarness(sink: sink)
    defer { server.stop() }
    try InMemoryIPCServerTests.sendHello(server)
    _ = try await server.awaitResponse()

    struct Params: Codable {
      let paneID: PaneID
      let text: String
    }
    let params = try JSONValue.encoded(Params(paneID: PaneID(), text: "x"))
    try server.send(
      IPC.Request(id: "s3", method: .terminalSendInput, params: params)
    )
    let response = try await server.awaitResponse()
    if case .notFound = response.error {
      // expected
    } else {
      Issue.record("expected .notFound, got \(String(describing: response.error))")
    }
  }

  @Test
  func resetPaneReturnsUnsupportedWhenNoSink() async throws {
    let server = Self.makeHarness(sink: nil)
    defer { server.stop() }
    try InMemoryIPCServerTests.sendHello(server)
    _ = try await server.awaitResponse()

    struct Params: Codable {
      let paneID: PaneID
    }
    let params = try JSONValue.encoded(Params(paneID: PaneID()))
    try server.send(
      IPC.Request(id: "rp1", method: .terminalResetPane, params: params)
    )
    let response = try await server.awaitResponse()
    if case .unsupported = response.error {
      // expected
    } else {
      Issue.record("expected .unsupported, got \(String(describing: response.error))")
    }
  }

  @Test
  func resetPaneDeliversViaFakeSink() async throws {
    let sink = FakeSink()
    let server = Self.makeHarness(sink: sink)
    defer { server.stop() }
    try InMemoryIPCServerTests.sendHello(server)
    _ = try await server.awaitResponse()

    let pid = PaneID()
    sink.registered.insert(pid.raw)
    struct Params: Codable {
      let paneID: PaneID
    }
    let params = try JSONValue.encoded(Params(paneID: pid))
    try server.send(
      IPC.Request(id: "rp2", method: .terminalResetPane, params: params)
    )
    let response = try await server.awaitResponse()
    #expect(response.error == nil)
    #expect(sink.resets == [pid.raw])
  }

  @Test
  func resetPaneOnUnknownPaneReturnsNotFound() async throws {
    let sink = FakeSink()
    let server = Self.makeHarness(sink: sink)
    defer { server.stop() }
    try InMemoryIPCServerTests.sendHello(server)
    _ = try await server.awaitResponse()

    struct Params: Codable {
      let paneID: PaneID
    }
    let params = try JSONValue.encoded(Params(paneID: PaneID()))
    try server.send(
      IPC.Request(id: "rp3", method: .terminalResetPane, params: params)
    )
    let response = try await server.awaitResponse()
    if case .notFound = response.error {
      // expected
    } else {
      Issue.record("expected .notFound, got \(String(describing: response.error))")
    }
  }

  @Test
  func readTextDeliversViaFakeSink() async throws {
    let sink = FakeSink()
    let server = Self.makeHarness(sink: sink)
    defer { server.stop() }
    try InMemoryIPCServerTests.sendHello(server)
    _ = try await server.awaitResponse()

    let pid = PaneID()
    sink.registered.insert(pid.raw)
    sink.textByPane[pid.raw] = "prompt\noutput"
    struct Params: Codable {
      let paneID: PaneID
      let extent: String
    }
    let params = try JSONValue.encoded(Params(paneID: pid, extent: "viewport"))
    try server.send(
      IPC.Request(id: "r1", method: .terminalReadText, params: params)
    )
    let response = try await server.awaitResponse()
    struct Result: Codable {
      let text: String
    }
    let result = try response.result?.decoded(as: Result.self)
    #expect(response.error == nil)
    #expect(result?.text == "prompt\noutput")
  }

  @Test
  func readTextWaitStablePollsUntilSettled() async throws {
    let sink = FakeSink()
    // Auto-advancing clock keeps the routed poll loop deterministic and
    // instant — no real waiting inside the RPC round-trip.
    let clock = TerminalStabilityWaiterTests.VirtualClock()
    let server = Self.makeHarness(sink: sink, clock: clock)
    defer { server.stop() }
    try InMemoryIPCServerTests.sendHello(server)
    _ = try await server.awaitResponse()

    let pid = PaneID()
    sink.registered.insert(pid.raw)
    // Output churns for the first reads, then holds on "done".
    sink.textScript[pid.raw] = ["boot", "boot\nrun", "done", "done"]
    struct WaitStable: Codable {
      let stableMillis: Int
      let intervalMillis: Int
      let timeoutMillis: Int
    }
    struct Params: Codable {
      let paneID: PaneID
      let extent: String
      let waitStable: WaitStable
    }
    let params = try JSONValue.encoded(
      Params(
        paneID: pid, extent: "viewport",
        waitStable: WaitStable(stableMillis: 30, intervalMillis: 10, timeoutMillis: 1000)))
    try server.send(
      IPC.Request(id: "ws1", method: .terminalReadText, params: params)
    )
    let response = try await server.awaitResponse()
    struct Result: Codable {
      let text: String
      let stabilized: Bool?
      let waitedMillis: Int?
      let samples: Int?
    }
    let result = try response.result?.decoded(as: Result.self)
    #expect(response.error == nil)
    #expect(result?.text == "done")
    #expect(result?.stabilized == true)
    #expect((result?.samples ?? 0) >= 2)
  }

  @Test
  func readTextWaitStableOnUnknownPaneReturnsNotFound() async throws {
    let sink = FakeSink()
    let clock = TerminalStabilityWaiterTests.VirtualClock()
    let server = Self.makeHarness(sink: sink, clock: clock)
    defer { server.stop() }
    try InMemoryIPCServerTests.sendHello(server)
    _ = try await server.awaitResponse()

    struct WaitStable: Codable {
      let stableMillis: Int
      let intervalMillis: Int
      let timeoutMillis: Int
    }
    struct Params: Codable {
      let paneID: PaneID
      let extent: String
      let waitStable: WaitStable
    }
    let params = try JSONValue.encoded(
      Params(
        paneID: PaneID(), extent: "viewport",
        waitStable: WaitStable(stableMillis: 30, intervalMillis: 10, timeoutMillis: 1000)))
    try server.send(
      IPC.Request(id: "ws2", method: .terminalReadText, params: params)
    )
    let response = try await server.awaitResponse()
    if case .notFound = response.error {
      // expected — an unregistered pane fails the first read.
    } else {
      Issue.record("expected .notFound, got \(String(describing: response.error))")
    }
  }

  // MARK: - Harness

  static func makeHarness(
    sink: TerminalHandlers.InputSink?,
    clock: StabilityClock = SystemStabilityClock()
  ) -> InMemoryIPCServer {
    let systemHandlers = SystemHandlers(
      versions: .init(server: "0.4.0", appBundle: "0.4.0+test")
    )
    let catalogStore = CatalogStore(fileURL: Self.tempURL())
    let catalog = (try? catalogStore.load()) ?? Catalog()
    let hierarchy = HierarchyManager(
      catalog: catalog,
      store: catalogStore,
      runtime: FakeHierarchyRuntime()
    )
    let hierarchyHandlers = HierarchyHandlers(manager: hierarchy)
    let terminalHandlers = TerminalHandlers(sink: sink, catalog: { hierarchy.catalog }, clock: clock)
    let router = MethodRouter(
      systemHandlers: systemHandlers,
      hierarchyHandlers: hierarchyHandlers,
      terminalHandlers: terminalHandlers
    )
    let server = InMemoryIPCServer(router: router)
    server.start()
    return server
  }

  static func tempURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("codans-terminal-tests-\(UUID().uuidString).json")
  }
}

/// Records every invocation; returns success iff the pane id was
/// pre-registered.
final class FakeSink: TerminalHandlers.InputSink, @unchecked Sendable {
  struct Delivery: Equatable {
    let paneID: UUID
    let text: String
  }

  var registered: Set<UUID> = []
  private(set) var delivered: [Delivery] = []
  private(set) var broadcasts: [(scope: IPC.BroadcastScope, text: String)] = []
  private(set) var resets: [UUID] = []
  private(set) var keys: [(paneID: UUID, key: IPC.TerminalNamedKey)] = []
  private(set) var rawBytes: [(paneID: UUID, bytes: [UInt8])] = []
  var textByPane: [UUID: String] = [:]
  /// A sequence of successive `readText` returns per pane — models output
  /// that changes across polls then holds steady. Clamps to the last
  /// element once exhausted. Takes precedence over `textByPane`.
  var textScript: [UUID: [String]] = [:]
  private var scriptCursor: [UUID: Int] = [:]
  private let lock = NSLock()

  func sendInput(paneID: PaneID, text: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard registered.contains(paneID.raw) else { return false }
    delivered.append(Delivery(paneID: paneID.raw, text: text))
    return true
  }

  func sendKey(paneID: PaneID, key: IPC.TerminalNamedKey) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard registered.contains(paneID.raw) else { return false }
    keys.append((paneID.raw, key))
    return true
  }

  func sendRawBytes(paneID: PaneID, bytes: [UInt8]) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard registered.contains(paneID.raw) else { return false }
    rawBytes.append((paneID.raw, bytes))
    return true
  }

  func fanOut(scope: IPC.BroadcastScope, text: String, catalog: Catalog) -> Int {
    lock.lock()
    defer { lock.unlock() }
    broadcasts.append((scope, text))
    return registered.count
  }

  func readText(paneID: PaneID, extent: TerminalHandlers.ReadExtent) -> String? {
    lock.lock()
    defer { lock.unlock() }
    guard registered.contains(paneID.raw) else { return nil }
    if let script = textScript[paneID.raw], !script.isEmpty {
      let cursor = scriptCursor[paneID.raw] ?? 0
      scriptCursor[paneID.raw] = cursor + 1
      return script[min(cursor, script.count - 1)]
    }
    return textByPane[paneID.raw] ?? ""
  }

  func resetPane(paneID: PaneID) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard registered.contains(paneID.raw) else { return false }
    resets.append(paneID.raw)
    return true
  }
}
