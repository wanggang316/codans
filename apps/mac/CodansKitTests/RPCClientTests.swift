import Foundation
import Testing
import CodansCore
import CodansIPC

@testable import CodansKit

/// Drives `RPCClient` against an `InMemoryTransport` backed by a minimal
/// scripted server. Exercises the full pipelined-hello round-trip, the
/// timeout path, and the error-mapping path without needing the real
/// Unix socket server.
@MainActor
struct RPCClientTests {
  @Test
  func callPipelinesHelloAndReturnsTypedResult() async throws {
    let transport = InMemoryTransport()
    transport.script = { requestFrames in
      // The client pipelines two frames: hello + the real request.
      // Respond to both with success results.
      #expect(requestFrames.count == 2)
      let hello = try JSONDecoder().decode(IPC.Request.self, from: requestFrames[0])
      #expect(hello.method == .systemHello)
      let real = try JSONDecoder().decode(IPC.Request.self, from: requestFrames[1])
      #expect(real.method == .systemPing)

      return [
        .success(id: hello.id, result: .object(["ok": .bool(true)])),
        .success(id: real.id, result: .object(["pong": .bool(true)])),
      ]
    }

    let client = RPCClient(
      transport: transport,
      versions: .init(clientVersion: "0.3.0")
    )

    struct Pong: Codable { let pong: Bool }
    let pong: Pong = try await client.call(.systemPing, params: EmptyPayload())
    #expect(pong.pong == true)
  }

  @Test
  func serverErrorOnRealRequestSurfacesAsIpcError() async throws {
    let transport = InMemoryTransport()
    transport.script = { requestFrames in
      let hello = try JSONDecoder().decode(IPC.Request.self, from: requestFrames[0])
      let real = try JSONDecoder().decode(IPC.Request.self, from: requestFrames[1])
      return [
        .success(id: hello.id, result: .object([:])),
        .error(id: real.id, error: .notFound(kind: "subscription", id: "xyz")),
      ]
    }

    let client = RPCClient(transport: transport, versions: .init(clientVersion: "0.3.0"))
    do {
      let _: JSONValue = try await client.call(
        .hierarchyRemoveTag,
        params: EmptyPayload()
      )
      Issue.record("expected RPCError.ipc, got success")
    } catch let error as RPCClient.RPCError {
      if case .ipc(.notFound) = error {
        // expected
      } else {
        Issue.record("got \(error)")
      }
    }
  }

  @Test
  func versionMismatchOnHelloSurfacesBeforeRealRequest() async throws {
    let transport = InMemoryTransport()
    transport.script = { requestFrames in
      let hello = try JSONDecoder().decode(IPC.Request.self, from: requestFrames[0])
      return [
        .error(id: hello.id, error: .versionMismatch(client: "0.3.0", server: "0.4.0"))
      ]
    }

    let client = RPCClient(transport: transport, versions: .init(clientVersion: "0.3.0"))
    do {
      let _: JSONValue = try await client.call(.systemPing, params: EmptyPayload())
      Issue.record("expected RPCError.ipc(.versionMismatch)")
    } catch let error as RPCClient.RPCError {
      if case .ipc(.versionMismatch) = error {
        // expected
      } else {
        Issue.record("got \(error)")
      }
    }
  }

  @Test
  func timeoutWhenNoResponseArrives() async throws {
    let transport = InMemoryTransport()
    transport.script = { _ in [] }  // scripted empty response

    let client = RPCClient(transport: transport, versions: .init(clientVersion: "0.3.0"))
    do {
      let _: JSONValue = try await client.call(
        .systemPing,
        params: EmptyPayload(),
        timeout: .milliseconds(200)
      )
      Issue.record("expected RPCError.timeout")
    } catch let error as RPCClient.RPCError {
      if case .timeout = error {
        // expected
      } else {
        Issue.record("got \(error)")
      }
    }
  }
}

/// Tiny Codable type the tests use as `params`.
struct EmptyPayload: Codable, Sendable {}
