import Foundation
import Testing
import tcKit

@testable import TouchCodeCore
@testable import TouchCodeIPC
@testable import TouchCode

/// End-to-end integration tests: a real `RPCClient` (with its pipelined
/// handshake, inbound-pump actor, and typed Codable decode) driving a
/// real `MethodRouter` + real app-side handlers (`HierarchyHandlers`,
/// `SystemHandlers`, `TerminalHandlers`) over a `RouterBackedTransport`.
/// The transport preserves the full wire stack — Framing + `SocketConnection`'s
/// read-dispatch-write loop — and skips only the Unix socket fd itself.
@MainActor
struct EndToEndRPCIntegrationTests {
  // MARK: - System verbs

  @Test
  func systemPingRoundtrips() async throws {
    try await withStack { client in
      struct PingResult: Codable { let pong: Bool }
      let result: PingResult = try await client.call(.systemPing, params: Empty())
      #expect(result.pong == true)
    }
  }

  @Test
  func systemVersionReportsHarnessVersions() async throws {
    try await withStack { client in
      struct Version: Codable {
        let server: String
        let appBundle: String
      }
      let version: Version = try await client.call(.systemVersion, params: Empty())
      #expect(version.server == "0.3.0")
      #expect(version.appBundle == "0.3.0+test")
    }
  }

  // MARK: - Error-path contract

  @Test
  func editorOpenFallsThroughToUnsupported() async throws {
    try await withStack { client in
      // `editor.open` is in IPC.Method but has no handler in this plan's
      // router (C8 owns the handler). Proves the notWired fall-through
      // returns `.unsupported` so the CLI exits 4 post-merge too.
      struct Params: Codable {
        let worktreeID: WorktreeID?
        let path: String?
        let editor: String?
      }
      do {
        _ = try await client.callRaw(
          .editorOpen,
          params: Params(worktreeID: nil, path: "/tmp", editor: nil)
        )
        Issue.record("expected throw")
      } catch RPCClient.RPCError.ipc(let err) {
        if case .unsupported = err {
          // expected
        } else {
          Issue.record("expected .unsupported, got \(err)")
        }
      }
    }
  }

  @Test
  func terminalSendWithNoSinkReturnsUnsupported() async throws {
    try await withStack { client in
      struct Params: Codable {
        let paneID: PaneID
        let text: String
      }
      do {
        _ = try await client.callRaw(
          .terminalSendInput,
          params: Params(paneID: PaneID(raw: UUID()), text: "hello")
        )
        Issue.record("expected throw")
      } catch RPCClient.RPCError.ipc(let err) {
        if case .unsupported = err {
          // expected — this harness binds `sink: nil`, matching the
          // AppBootstrap shape until a real GhosttyRuntime is wired.
        } else {
          Issue.record("expected .unsupported, got \(err)")
        }
      }
    }
  }

  // MARK: - Harness

  struct Empty: Codable, Sendable {}

  /// Scoped stack builder with deterministic, awaited teardown. Review
  /// #5 on M8 flagged that the earlier `defer { Task { await
  /// client.shutdown() } }` pattern in each test fired off an
  /// unstructured Task that was never awaited — the test body returned
  /// before the client released its inbound-pump / transport. This
  /// closure form tears down in order: `client.shutdown()` *awaited*,
  /// then `transport.stop()` (sync). Errors propagate unchanged.
  func withStack<T>(
    _ body: (RPCClient) async throws -> T
  ) async throws -> T {
    let (client, transport) = try makeStack()
    do {
      let result = try await body(client)
      await client.shutdown()
      transport.stop()
      return result
    } catch {
      await client.shutdown()
      transport.stop()
      throw error
    }
  }

  /// Build a full (router, client) pair connected by a
  /// `RouterBackedTransport`. The server is a real `MethodRouter` with
  /// every handler wired; the client is a real `RPCClient`.
  func makeStack() throws -> (RPCClient, RouterBackedTransport) {
    let systemHandlers = SystemHandlers(
      versions: .init(server: "0.3.0", appBundle: "0.3.0+test")
    )

    let catalogURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("touch-code-integ-catalog-\(UUID().uuidString).json")
    let catalogStore = CatalogStore(fileURL: catalogURL)
    let catalog = (try? catalogStore.load()) ?? Catalog()
    let hierarchy = HierarchyManager(
      catalog: catalog,
      store: catalogStore,
      runtime: FakeHierarchyRuntime()
    )
    let hierarchyHandlers = HierarchyHandlers(manager: hierarchy)
    let terminalHandlers = TerminalHandlers(sink: nil, catalog: { hierarchy.catalog })

    let router = MethodRouter(
      systemHandlers: systemHandlers,
      hierarchyHandlers: hierarchyHandlers,
      terminalHandlers: terminalHandlers
    )

    let transport = RouterBackedTransport(router: router)
    transport.start()
    let client = RPCClient(
      transport: transport,
      versions: .init(clientVersion: "0.3.0", clientBinary: "tc-integration-test")
    )
    return (client, transport)
  }
}

/// A `Transport` implementation that wraps a live `MethodRouter` +
/// `SocketConnection` pair in process, skipping only the Unix-socket
/// fd. The client-facing `send` feeds raw framed request bytes into the
/// connection's inbound stream, and the connection's outbound writes
/// land in this transport's `inbound` stream. Everything in between is
/// the same code the production server runs: Framing, handshake,
/// routing, typed Codable decode.
///
/// **Isolation note (per DEC-16):** this adapter is deliberately
/// `@MainActor` on the class with `nonisolated` `send` / `close` and
/// `@unchecked Sendable` — a simpler concurrency shape than production
/// `UnixSocketTransport`. Scoped to tests; must not leak into the `tc`
/// binary. M8.1's real-socket integration variant inherits the real
/// transport's stricter isolation.
@MainActor
public final class RouterBackedTransport: Transport, @unchecked Sendable {
  private let router: MethodRouter
  private var serverInbound: AsyncStream<Data>.Continuation?
  private var serveTask: Task<Void, Never>?

  private let clientInboundContinuation: AsyncStream<Data>.Continuation
  public let inbound: AsyncStream<Data>

  public init(router: MethodRouter) {
    self.router = router
    var cont: AsyncStream<Data>.Continuation!
    self.inbound = AsyncStream<Data> { cont = $0 }
    self.clientInboundContinuation = cont
  }

  public func start() {
    guard serveTask == nil else { return }

    var serverInboundCont: AsyncStream<Data>.Continuation!
    let serverInboundStream = AsyncStream<Data> { c in serverInboundCont = c }
    self.serverInbound = serverInboundCont

    let clientCont = self.clientInboundContinuation
    let conn = SocketConnection(
      router: router,
      reader: serverInboundStream,
      write: { data in
        clientCont.yield(data)
      },
      close: {
        clientCont.finish()
      }
    )
    serveTask = Task.detached { await conn.serve() }
  }

  public nonisolated func send(_ frame: Data) async throws {
    // Hop back to MainActor to yield into the server's inbound stream.
    await feed(frame)
  }

  private func feed(_ data: Data) {
    serverInbound?.yield(data)
  }

  public nonisolated func close() {
    Task { @MainActor [weak self] in
      self?.stopInternal()
    }
  }

  public func stop() {
    stopInternal()
  }

  private func stopInternal() {
    serverInbound?.finish()
    serverInbound = nil
    serveTask?.cancel()
    serveTask = nil
    clientInboundContinuation.finish()
  }
}
