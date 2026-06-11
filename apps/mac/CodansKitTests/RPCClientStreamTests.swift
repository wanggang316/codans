import Foundation
import Testing
import CodansCore
import CodansIPC

@testable import CodansKit

/// Covers the streaming + timeout + shutdown surface added in M5. Each
/// test drives `RPCClient` against `InMemoryTransport` — no real Unix
/// socket, no codans app.
@MainActor
struct RPCClientStreamTests {
  // MARK: - Happy path

  @Test
  func streamHappyPathYieldsMultipleFramesThenTerminates() async throws {
    let transport = InMemoryTransport()
    transport.script = { frames in
      let hello = try JSONDecoder().decode(IPC.Request.self, from: frames[0])
      let real = try JSONDecoder().decode(IPC.Request.self, from: frames[1])
      #expect(real.method == .systemStatus)
      #expect(real.stream == true)
      return [
        .success(id: hello.id, result: .object([:])),
        .streamFrame(id: real.id, result: .object(["seq": .int(1)])),
        .streamFrame(id: real.id, result: .object(["seq": .int(2)])),
        .streamFrame(id: real.id, result: .object(["seq": .int(3)])),
        .streamEnd(id: real.id),
      ]
    }

    let client = RPCClient(
      transport: transport,
      versions: .init(clientVersion: "0.3.0")
    )
    defer { Task { await client.shutdown() } }

    struct Frame: Codable, Equatable, Sendable { let seq: Int }
    var received: [Frame] = []
    let stream = client.stream(
      .systemStatus,
      params: EmptyPayload(),
      elementType: Frame.self,
      idleTimeout: .seconds(2)
    )
    for try await frame in stream {
      received.append(frame)
    }
    #expect(received.map(\.seq) == [1, 2, 3])
  }

  // MARK: - Cancellation

  @Test
  func streamCancellationCancelsUpstreamTask() async throws {
    let transport = InMemoryTransport()
    transport.script = { frames in
      let hello = try JSONDecoder().decode(IPC.Request.self, from: frames[0])
      let real = try JSONDecoder().decode(IPC.Request.self, from: frames[1])
      return [
        .success(id: hello.id, result: .object([:])),
        .streamFrame(id: real.id, result: .object(["seq": .int(1)])),
      ]
      // Deliberately no streamEnd → the stream stays open until the
      // consumer breaks out of its loop; onTermination must then cancel
      // the task so the transport can tear down cleanly.
    }

    let client = RPCClient(
      transport: transport,
      versions: .init(clientVersion: "0.3.0")
    )

    struct Frame: Codable, Equatable, Sendable { let seq: Int }
    let stream = client.stream(
      .systemStatus,
      params: EmptyPayload(),
      elementType: Frame.self,
      idleTimeout: .seconds(1)
    )
    var received: [Frame] = []
    for try await frame in stream {
      received.append(frame)
      break  // cancel immediately after the first frame
    }
    #expect(received.count == 1)
    await client.shutdown()
  }

  // MARK: - Misorder detection

  @Test
  func unaryCallSurfacesMisorderedRealResponse() async throws {
    let transport = InMemoryTransport()
    transport.script = { frames in
      let hello = try JSONDecoder().decode(IPC.Request.self, from: frames[0])
      // Deliberately return the "real" response with a bogus id.
      return [
        .success(id: hello.id, result: .object([:])),
        .success(id: "not-the-right-id", result: .object(["pong": .bool(true)])),
      ]
    }

    let client = RPCClient(transport: transport, versions: .init(clientVersion: "0.3.0"))
    defer { Task { await client.shutdown() } }

    do {
      let _: JSONValue = try await client.call(.systemPing, params: EmptyPayload())
      Issue.record("expected .misorderedResponse")
    } catch let error as RPCClient.RPCError {
      if case .misorderedResponse(_, let got) = error {
        #expect(got == "not-the-right-id")
      } else {
        Issue.record("got \(error)")
      }
    }
  }

  @Test
  func unaryCallSurfacesMisorderedHelloResponse() async throws {
    let transport = InMemoryTransport()
    transport.script = { _ in
      [
        .success(id: "wrong-hello-id", result: .object([:])),
        .success(id: "also-wrong", result: .object(["pong": .bool(true)])),
      ]
    }

    let client = RPCClient(transport: transport, versions: .init(clientVersion: "0.3.0"))
    defer { Task { await client.shutdown() } }

    do {
      let _: JSONValue = try await client.call(.systemPing, params: EmptyPayload())
      Issue.record("expected .misorderedResponse on hello")
    } catch let error as RPCClient.RPCError {
      if case .misorderedResponse(_, let got) = error {
        #expect(got == "wrong-hello-id")
      } else {
        Issue.record("got \(error)")
      }
    }
  }

  @Test
  func streamSurfacesMisorderedFrame() async throws {
    let transport = InMemoryTransport()
    transport.script = { frames in
      let hello = try JSONDecoder().decode(IPC.Request.self, from: frames[0])
      return [
        .success(id: hello.id, result: .object([:])),
        .streamFrame(id: "wrong-stream-id", result: .object(["seq": .int(1)])),
      ]
    }

    let client = RPCClient(transport: transport, versions: .init(clientVersion: "0.3.0"))
    defer { Task { await client.shutdown() } }

    struct Frame: Codable, Sendable { let seq: Int }
    let stream = client.stream(
      .systemStatus,
      params: EmptyPayload(),
      elementType: Frame.self,
      idleTimeout: .seconds(1)
    )
    do {
      for try await _ in stream {}
      Issue.record("expected misordered error")
    } catch let error as RPCClient.RPCError {
      if case .misorderedResponse = error {
        // expected
      } else {
        Issue.record("got \(error)")
      }
    }
  }

  // MARK: - InboundPump id-gated timeout

  @Test
  func inboundPumpTimeoutDoesNotFireLaterWaiter() async throws {
    // The exact bug the id-gate fixes: waiter A registers with a very
    // short timeout and hits nil; waiter B registers after; a chunk
    // arrives for B; B must receive the chunk, not pick up a stale nil
    // from A's timeout firing.
    let (stream, continuation) = AsyncStream<Data>.makeStream()
    let pump = InboundPump(stream: stream)

    // Waiter A: 50 ms timeout, no data → expect nil.
    let a = await pump.next(timeout: .milliseconds(50))
    #expect(a == nil)

    // Waiter B: generous timeout; deliver a chunk and ensure B receives
    // it (not nil from A's already-fired sleep task).
    async let b = pump.next(timeout: .seconds(2))
    try await Task.sleep(for: .milliseconds(20))
    continuation.yield(Data("hello".utf8))
    let received = await b
    #expect(received == Data("hello".utf8))

    continuation.finish()
  }

  // MARK: - shutdown idempotency

  @Test
  func shutdownIsIdempotent() async throws {
    let transport = ShutdownCountingTransport()
    let client = RPCClient(transport: transport, versions: .init(clientVersion: "0.3.0"))

    await client.shutdown()
    await client.shutdown()
    await client.shutdown()

    #expect(transport.closeCount == 1)
  }

  @Test
  func deinitFallbackClosesTransportWhenShutdownMissed() async throws {
    let transport = ShutdownCountingTransport()
    do {
      let client = RPCClient(transport: transport, versions: .init(clientVersion: "0.3.0"))
      _ = client  // keep the local strong reference scoped
    }
    // Give the actor a tick to deinit.
    try await Task.sleep(for: .milliseconds(50))
    #expect(transport.closeCount >= 1)
  }

  // MARK: - Per-frame decode error surfaces

  @Test
  func streamSurfacesDecodeErrorOnMalformedFrame() async throws {
    let transport = InMemoryTransport()
    transport.script = { frames in
      let hello = try JSONDecoder().decode(IPC.Request.self, from: frames[0])
      let real = try JSONDecoder().decode(IPC.Request.self, from: frames[1])
      return [
        .success(id: hello.id, result: .object([:])),
        // Well-formed first frame.
        .streamFrame(id: real.id, result: .object(["seq": .int(1)])),
        // Malformed: missing `seq`, which the Frame decoder requires.
        .streamFrame(id: real.id, result: .object(["wrong": .bool(true)])),
      ]
    }

    let client = RPCClient(transport: transport, versions: .init(clientVersion: "0.3.0"))
    defer { Task { await client.shutdown() } }

    struct Frame: Codable, Sendable { let seq: Int }
    let stream = client.stream(
      .systemStatus,
      params: EmptyPayload(),
      elementType: Frame.self,
      idleTimeout: .seconds(1)
    )
    do {
      for try await _ in stream {}
      Issue.record("expected decode error to surface")
    } catch let error as RPCClient.RPCError {
      if case .decodeFailed = error {
        // expected — M5 review #1
      } else {
        Issue.record("got \(error)")
      }
    }
  }
}

/// Transport double that counts `close()` calls — for `shutdown` tests.
final class ShutdownCountingTransport: Transport, @unchecked Sendable {
  let inbound: AsyncStream<Data>
  private(set) var closeCount = 0
  private let lock = NSLock()

  init() {
    self.inbound = AsyncStream<Data> { _ in }
  }

  // swiftlint:disable:next async_without_await
  func send(_ frame: Data) async throws {}

  func close() {
    lock.lock()
    closeCount += 1
    lock.unlock()
  }
}
