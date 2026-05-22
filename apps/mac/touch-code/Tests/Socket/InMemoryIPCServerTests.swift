import Foundation
import Testing

@testable import TouchCodeCore
@testable import TouchCodeIPC
@testable import TouchCode

/// Self-test for the harness. Uses `system.hello` + `system.ping` against
/// a minimal router.
@MainActor
struct InMemoryIPCServerTests {
  @Test
  func handshakeThenPingRoundTrips() async throws {
    let server = Self.makeHarness()
    defer { server.stop() }

    try Self.sendHello(server)
    let hello = try await server.awaitResponse()
    #expect(hello.id == "hello-1")
    #expect(hello.error == nil)

    try server.send(IPC.Request(id: "ping-1", method: .systemPing))
    let ping = try await server.awaitResponse()
    #expect(ping.id == "ping-1")
    #expect(ping.error == nil)
  }

  @Test
  func nonHelloFirstFrameIsRejected() async throws {
    let server = Self.makeHarness()
    defer { server.stop() }

    try server.send(IPC.Request(id: "bad-1", method: .systemPing))
    let response = try await server.awaitResponse()
    // M3.1 fix: non-hello first frame is a handshake-ordering violation,
    // surfaced as `.invalidParams` on the `method` path — not
    // `.versionMismatch`, which is reserved for actual version clashes
    // that happen on a well-formed `system.hello`.
    if case .invalidParams(_, let path) = response.error {
      #expect(path == ["method"])
    } else {
      Issue.record("expected invalidParams, got \(String(describing: response.error))")
    }
  }

  @Test
  func inflightCapRejectsPostHelloWithOverloaded() async throws {
    // Server with cap=0 forces every post-hello frame into the
    // `.overloaded` branch — proves the wire contract for DEC-9
    // backpressure even while actor-serialized handling keeps real
    // inflight at ≤ 1 in production.
    let systemHandlers = SystemHandlers(
      versions: .init(server: "0.3.0", appBundle: "0.3.0+test")
    )
    let router = MethodRouter(systemHandlers: systemHandlers)
    let server = InMemoryIPCServer(router: router, inflightLimit: 0)
    server.start()
    defer { server.stop() }

    try Self.sendHello(server)
    let hello = try await server.awaitResponse()
    #expect(hello.error == nil)

    try server.send(IPC.Request(id: "post-1", method: .systemPing))
    let response = try await server.awaitResponse()
    #expect(response.id == "post-1")
    if case .overloaded = response.error {
      // expected
    } else {
      Issue.record("expected .overloaded, got \(String(describing: response.error))")
    }
  }

  @Test
  func oversizeFrameClosesConnection() async throws {
    let server = Self.makeHarness()
    defer { server.stop() }

    try Self.sendHello(server)
    _ = try await server.awaitResponse()

    // Craft a frame whose length header declares a body larger than the
    // 16 MiB cap. The server must respond with `.invalidFrame` and close
    // the connection.
    let oversize = UInt32(Framing.maxFrameBytes) &+ 1
    var header = Data(count: 4)
    header[0] = UInt8((oversize >> 24) & 0xFF)
    header[1] = UInt8((oversize >> 16) & 0xFF)
    header[2] = UInt8((oversize >> 8) & 0xFF)
    header[3] = UInt8(oversize & 0xFF)
    // `InMemoryIPCServer.send` goes through Framing.encode which would
    // reject oversize locally; feed the raw header via the inbound
    // stream instead.
    server._test_feedRaw(header)
    let response = try await server.awaitResponse()
    if case .invalidFrame = response.error {
      // expected
    } else {
      Issue.record("expected .invalidFrame, got \(String(describing: response.error))")
    }
  }

  // MARK: - Harness helpers

  static func makeHarness() -> InMemoryIPCServer {
    let systemHandlers = SystemHandlers(
      versions: .init(server: "0.3.0", appBundle: "0.3.0+test")
    )
    let router = MethodRouter(systemHandlers: systemHandlers)
    let server = InMemoryIPCServer(router: router)
    server.start()
    return server
  }

  static func sendHello(_ server: InMemoryIPCServer, id: String = "hello-1") throws {
    let hello = try JSONValue.encoded(
      HelloRequest(
        clientVersion: "0.3.0", clientBinary: "tc"
      ))
    try server.send(IPC.Request(id: id, method: .systemHello, params: hello))
  }
}
