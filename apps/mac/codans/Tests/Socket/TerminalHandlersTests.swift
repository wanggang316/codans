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

  // MARK: - Raw hex decoding

  // MARK: - A catalog pane with no attached terminal

  /// A stopped pane is in the catalog, but no daemon runs for it: there is
  /// no surface (the fake sink does not know it) and nothing to attach.
  /// Terminal and probe verbs must say `PANE_NOT_LIVE`, not `notFound`, so
  /// a script can tell it from a wrong id.
  @Test(arguments: [
    IPC.Method.terminalReadText, .terminalSendInput, .terminalSendKey, .terminalSendRawBytes,
    .terminalResetPane, .paneRead, .paneInfo,
  ])
  func verbsOnACatalogPaneWithoutATerminalReturnPaneNotLive(method: IPC.Method) async throws {
    let pane = Pane(workingDirectory: "/repo")
    let tab = Tab(name: "dev", splitTree: SplitTree(leaf: pane.id), panes: [pane])
    let worktree = Worktree(name: "main", path: "/repo", branch: "main", tabs: [tab])
    let project = Project(name: "repo", rootPath: "/repo", gitRoot: "/repo", worktrees: [worktree])
    let server = Self.makeHarness(sink: FakeSink(), catalog: Catalog(projects: [project]))
    defer { server.stop() }
    try InMemoryIPCServerTests.sendHello(server)
    _ = try await server.awaitResponse()

    try server.send(IPC.Request(id: "nl", method: method, params: try Self.paneParams(method, pane.id)))
    let response = try await server.awaitResponse()

    #expect(response.error == .paneNotLive(pane.id.description), "\(method.rawValue)")
  }

  // MARK: - A detached pane

  /// A detached pane (restored and not opened yet, or reclaimed) runs with
  /// no surface, so `pane.describe` reports it live. A send must attach a
  /// surface and land, not fail with `PANE_NOT_LIVE`.
  @Test
  func sendInputAttachesADetachedPaneAndDelivers() async throws {
    let sink = FakeSink()
    let pane = PaneID()
    let server = Self.makeHarness(
      sink: sink,
      attachDetached: { paneID in
        sink.registered.insert(paneID.raw)
        return true
      },
      daemonScreen: { _ in "" })
    defer { server.stop() }
    try InMemoryIPCServerTests.sendHello(server)
    _ = try await server.awaitResponse()

    try server.send(
      IPC.Request(id: "ra", method: .terminalSendInput, params: try Self.paneParams(.terminalSendInput, pane)))
    let response = try await server.awaitResponse()

    #expect(response.error == nil)
    #expect(sink.delivered == [FakeSink.Delivery(paneID: pane.raw, text: "x")])
  }

  /// A new surface starts blank and fills in as the daemon replays its
  /// screen; a plain read waits for that instead of returning blank.
  @Test
  func readTextAfterAnAttachWaitsForTheReplay() async throws {
    let sink = FakeSink()
    let pane = PaneID()
    sink.textScript[pane.raw] = ["", "", "claude> ready"]
    let server = Self.makeHarness(
      sink: sink,
      attachDetached: { paneID in
        sink.registered.insert(paneID.raw)
        return true
      },
      daemonScreen: { _ in "claude> ready" })
    defer { server.stop() }
    try InMemoryIPCServerTests.sendHello(server)
    _ = try await server.awaitResponse()

    try server.send(
      IPC.Request(id: "rr", method: .terminalReadText, params: try Self.paneParams(.terminalReadText, pane)))
    let response = try await server.awaitResponse()

    #expect(response.error == nil)
    #expect(try response.result?.decoded(as: TerminalHandlers.ReadTextResult.self).text == "claude> ready")
  }

  /// The replay wait is best effort: a surface that never shows the
  /// daemon's screen does not block the verb past `replayWaitMillis`.
  @Test
  func aReplayThatNeverCatchesUpDoesNotBlockTheVerb() async throws {
    let sink = FakeSink()
    let pane = PaneID()
    sink.textScript[pane.raw] = [""]
    let clock = TerminalStabilityWaiterTests.VirtualClock()
    let server = Self.makeHarness(
      sink: sink, clock: clock,
      attachDetached: { paneID in
        sink.registered.insert(paneID.raw)
        return true
      },
      daemonScreen: { _ in "claude> ready" })
    defer { server.stop() }
    try InMemoryIPCServerTests.sendHello(server)
    _ = try await server.awaitResponse()

    try server.send(
      IPC.Request(id: "rk", method: .terminalSendKey, params: try Self.paneParams(.terminalSendKey, pane)))
    let response = try await server.awaitResponse()

    #expect(response.error == nil)
    #expect(sink.keys.count == 1)
    #expect(clock.current >= TerminalHandlers.replayWaitMillis)
  }

  /// `pane send --capture` on a pane this call attached diffs the daemon's
  /// own screen, which does not replay. The surface is still filling in:
  /// it shows a partial old screen whose bottom rows already match the
  /// daemon's (repeated rows), and the rest of the old screen lands after
  /// the send. None of those old rows may come back as output.
  @Test
  func sendWithCaptureAfterAnAttachDiffsTheDaemonScreen() async throws {
    let sink = FakeSink()
    let pane = PaneID()
    let rowsA = Array(repeating: "A", count: 20)
    let oldScreen = (rowsA + Array(repeating: "B", count: 5) + rowsA).joined(separator: "\n")
    let partial = rowsA.joined(separator: "\n")
    sink.textScript[pane.raw] = [partial, partial, oldScreen + "\ntrue\nok"]
    let server = Self.makeHarness(
      sink: sink, clock: TerminalStabilityWaiterTests.VirtualClock(),
      attachDetached: { paneID in
        sink.registered.insert(paneID.raw)
        return true
      },
      daemonScreen: { _ in sink.delivered.isEmpty ? oldScreen : oldScreen + "\ntrue\nok" })
    defer { server.stop() }
    try InMemoryIPCServerTests.sendHello(server)
    _ = try await server.awaitResponse()

    let params = try JSONValue.encoded(
      TerminalHandlers.SendInputParams(
        paneID: pane, text: "true\n",
        wait: TerminalHandlers.SendWaitParams(timeoutMillis: 2000, stableMillis: 50, graceMillis: 50),
        capture: true))
    try server.send(IPC.Request(id: "rc", method: .terminalSendInput, params: params))
    let response = try await server.awaitResponse()

    #expect(response.error == nil)
    #expect(sink.delivered.count == 1)
    let result = try #require(try response.result?.decoded(as: TerminalHandlers.SendInputResult.self))
    #expect(result.output == "ok")
  }

  /// A just-attached pane's capture must come from the daemon only. When
  /// the daemon cannot be read before the send, the call fails and types
  /// nothing; it never falls back to the replaying surface.
  @Test
  func sendWithCaptureAfterAnAttachFailsBeforeSendingWhenTheDaemonCannotBeRead() async throws {
    let sink = FakeSink()
    let pane = PaneID()
    sink.textScript[pane.raw] = ["A\nA"]  // a partial replay
    let server = Self.makeHarness(
      sink: sink, clock: TerminalStabilityWaiterTests.VirtualClock(),
      attachDetached: { paneID in
        sink.registered.insert(paneID.raw)
        return true
      },
      daemonScreen: { _ in nil })
    defer { server.stop() }
    try InMemoryIPCServerTests.sendHello(server)
    _ = try await server.awaitResponse()

    try server.send(IPC.Request(id: "nb", method: .terminalSendInput, params: try Self.captureParams(pane)))
    let response = try await server.awaitResponse()

    guard case .internal(let message) = response.error else {
      Issue.record("expected internal, got \(String(describing: response.error))")
      return
    }
    #expect(message.contains("nothing was sent"))
    #expect(sink.delivered.isEmpty)
  }

  /// When the daemon read after the send fails, the call reports that the
  /// text was sent but its output cannot be captured, instead of diffing
  /// the daemon's "before" against the surface's "after".
  @Test
  func sendWithCaptureAfterAnAttachFailsWithoutMixingSourcesWhenTheLaterReadFails() async throws {
    let sink = FakeSink()
    let pane = PaneID()
    let oldScreen = "A\nB\nA"
    sink.textScript[pane.raw] = [oldScreen, oldScreen + "\ntrue\nok"]
    let server = Self.makeHarness(
      sink: sink, clock: TerminalStabilityWaiterTests.VirtualClock(),
      attachDetached: { paneID in
        sink.registered.insert(paneID.raw)
        return true
      },
      daemonScreen: { _ in sink.delivered.isEmpty ? oldScreen : nil })
    defer { server.stop() }
    try InMemoryIPCServerTests.sendHello(server)
    _ = try await server.awaitResponse()

    try server.send(IPC.Request(id: "na", method: .terminalSendInput, params: try Self.captureParams(pane)))
    let response = try await server.awaitResponse()

    guard case .internal(let message) = response.error else {
      Issue.record("expected internal, got \(String(describing: response.error))")
      return
    }
    #expect(message.contains("the text was sent"))
    #expect(sink.delivered.count == 1)
    #expect(response.result == nil)
  }

  static func captureParams(_ pane: PaneID) throws -> JSONValue {
    try JSONValue.encoded(
      TerminalHandlers.SendInputParams(
        paneID: pane, text: "true\n",
        wait: TerminalHandlers.SendWaitParams(timeoutMillis: 2000, stableMillis: 50, graceMillis: 50),
        capture: true))
  }

  /// A pane that was attached before the call keeps the surface as its
  /// capture source; the daemon is not read.
  @Test
  func sendWithCaptureOnAnAttachedPaneReadsTheSurface() async throws {
    let sink = FakeSink()
    let pane = PaneID()
    sink.registered.insert(pane.raw)
    sink.textScript[pane.raw] = ["$ ", "$ true\nok\n$ "]
    let daemonReads = CallCounter()
    let server = Self.makeHarness(
      sink: sink,
      daemonScreen: { _ in
        daemonReads.value += 1
        return nil
      })
    defer { server.stop() }
    try InMemoryIPCServerTests.sendHello(server)
    _ = try await server.awaitResponse()

    let params = try JSONValue.encoded(
      TerminalHandlers.SendInputParams(
        paneID: pane, text: "true\n",
        wait: TerminalHandlers.SendWaitParams(timeoutMillis: 2000, stableMillis: 50, graceMillis: 50),
        capture: true))
    try server.send(IPC.Request(id: "ca", method: .terminalSendInput, params: params))
    let response = try await server.awaitResponse()

    #expect(response.error == nil)
    #expect(try response.result?.decoded(as: TerminalHandlers.SendInputResult.self).output == "ok")
    #expect(daemonReads.value == 0)
  }

  @Test
  func replayCaughtUpComparesTheBottomRowsWithoutTrailingWhitespace() {
    let daemon = "row 1\nrow 2\n$ \n\n"
    #expect(TerminalHandlers.replayCaughtUp(surface: "row 1   \nrow 2\n$\n", daemon: daemon))
    // More scrollback above on the surface is fine; the bottom rows decide.
    #expect(TerminalHandlers.replayCaughtUp(surface: "older\nrow 1\nrow 2\n$ ", daemon: daemon))
    #expect(!TerminalHandlers.replayCaughtUp(surface: "row 1", daemon: daemon))
    #expect(!TerminalHandlers.replayCaughtUp(surface: "", daemon: daemon))
    #expect(TerminalHandlers.replayCaughtUp(surface: "", daemon: "\n  \n"))
  }

  @Test(arguments: [IPC.Method.terminalReadText, .paneRead])
  func verbsOnAnUnknownPaneStillReturnNotFound(method: IPC.Method) async throws {
    let server = Self.makeHarness(sink: FakeSink())
    defer { server.stop() }
    try InMemoryIPCServerTests.sendHello(server)
    _ = try await server.awaitResponse()

    let id = PaneID()
    try server.send(IPC.Request(id: "nf", method: method, params: try Self.paneParams(method, id)))
    let response = try await server.awaitResponse()

    #expect(response.error == .notFound(kind: "pane", id: id.description), "\(method.rawValue)")
  }

  @Test
  func decodeHexAcceptsPerTokenPrefixesAndWhitespace() {
    #expect(TerminalHandlers.decodeHex("1b5b41") == [0x1b, 0x5b, 0x41])
    #expect(TerminalHandlers.decodeHex("0x1b 5b 0X41") == [0x1b, 0x5b, 0x41])
    #expect(TerminalHandlers.decodeHex("0x15 0x0d") == [0x15, 0x0d])
    #expect(TerminalHandlers.decodeHex(" 0d\n0a ") == [0x0d, 0x0a])
    #expect(TerminalHandlers.decodeHex("") == nil)
    #expect(TerminalHandlers.decodeHex("0x") == nil)
    #expect(TerminalHandlers.decodeHex("abc") == nil)
    #expect(TerminalHandlers.decodeHex("zz") == nil)
  }

  // MARK: - Harness

  /// Valid params for a pane-targeted verb, so the handler reaches its
  /// pane lookup instead of failing on decode.
  static func paneParams(_ method: IPC.Method, _ paneID: PaneID) throws -> JSONValue {
    if method == .paneRead { return try JSONValue.encoded(IPC.PaneReadRequest(paneID: paneID)) }
    return .object([
      "paneID": try JSONValue.encoded(paneID), "text": .string("x"), "key": .string("enter"),
      "hex": .string("0d"),
    ])
  }

  static func makeHarness(
    sink: TerminalHandlers.InputSink?,
    clock: StabilityClock = SystemStabilityClock(),
    catalog seed: Catalog? = nil,
    attachDetached: @escaping @MainActor (PaneID) async -> Bool = { _ in false },
    daemonScreen: @escaping @MainActor (PaneID) async -> String? = { _ in nil }
  ) -> InMemoryIPCServer {
    let systemHandlers = SystemHandlers(
      versions: .init(server: "0.4.0", appBundle: "0.4.0+test")
    )
    let catalogStore = CatalogStore(fileURL: Self.tempURL())
    let catalog = seed ?? (try? catalogStore.load()) ?? Catalog()
    let hierarchy = HierarchyManager(
      catalog: catalog,
      store: catalogStore,
      runtime: FakeHierarchyRuntime()
    )
    let hierarchyHandlers = HierarchyHandlers(manager: hierarchy)
    let terminalHandlers = TerminalHandlers(
      sink: sink, catalog: { hierarchy.catalog }, clock: clock, attachDetached: attachDetached,
      daemonScreen: daemonScreen)
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
@MainActor
private final class CallCounter {
  var value = 0
}

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
