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

  // MARK: - Harness

  static func makeHarness(sink: TerminalHandlers.InputSink?) -> InMemoryIPCServer {
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
    let terminalHandlers = TerminalHandlers(sink: sink) { hierarchy.catalog }
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
