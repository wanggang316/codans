import CodansIPC
import Foundation
import Testing
import os

@testable import CodansRemote

/// In-memory peer for `RemoteRPCClient`: captures the client's requests and
/// lets a test answer them in any order, over the same framing the real
/// transport carries.
final class FakeServer: Sendable {
  let toClient: AsyncStream<Data>
  private let toClientSink: AsyncStream<Data>.Continuation
  private let requestSink: AsyncStream<IPC.Request>.Continuation
  let requests: AsyncStream<IPC.Request>
  private let buffer = OSAllocatedUnfairLock(initialState: Data())
  private let closed = OSAllocatedUnfairLock(initialState: false)

  init() {
    (toClient, toClientSink) = AsyncStream<Data>.makeStream()
    (requests, requestSink) = AsyncStream<IPC.Request>.makeStream()
  }

  var isClosed: Bool { closed.withLock { $0 } }

  func makeClient(timeout: Duration = .seconds(5)) -> RemoteRPCClient {
    RemoteRPCClient(
      reader: toClient,
      write: { [self] data in receive(data) },
      close: { [self] in
        closed.withLock { $0 = true }
        toClientSink.finish()
      },
      defaultTimeout: timeout
    )
  }

  func reply(_ response: IPC.Response) throws {
    // Split each frame in two so the client's reassembly is exercised.
    let frame = try Framing.encode(JSONEncoder().encode(response))
    toClientSink.yield(frame.prefix(3))
    toClientSink.yield(frame.dropFirst(3))
  }

  func reply<T: Encodable>(to id: String, result: T, stream: Bool = false) throws {
    try reply(IPC.Response(id: id, stream: stream, result: JSONValue.encoded(result)))
  }

  /// Simulates the peer going away.
  func hangUp() {
    toClientSink.finish()
  }

  private func receive(_ data: Data) {
    let frames = buffer.withLock { buffer -> [Data] in
      buffer.append(data)
      var frames: [Data] = []
      while let frame = try? Framing.decode(from: &buffer) { frames.append(frame) }
      return frames
    }
    for frame in frames {
      if let request = try? JSONDecoder().decode(IPC.Request.self, from: frame) {
        requestSink.yield(request)
      }
    }
  }
}

@Suite(.timeLimit(.minutes(1)))
struct RemoteRPCClientTests {
  private static let hello = HelloRequest(clientVersion: "1.0", clientBinary: "CodansMobile")

  private static func helloResponse(major: Int = 1) -> HelloResponse {
    HelloResponse(serverVersion: "0.7.4", appBundleVersion: "1", protocolMajor: major, protocolMinor: 3)
  }

  @Test
  func helloChecksProtocolMajor() async throws {
    let server = FakeServer()
    let client = server.makeClient()
    var requests = server.requests.makeAsyncIterator()

    async let answer = client.hello(Self.hello)
    let request = try #require(await requests.next())
    #expect(request.method == .systemHello)
    try server.reply(to: request.id, result: Self.helloResponse())
    #expect(try await answer.protocolMajor == 1)
    #expect(await client.serverHello?.serverVersion == "0.7.4")

    let mismatch = Task { try await client.hello(Self.hello) }
    let second = try #require(await requests.next())
    try server.reply(to: second.id, result: Self.helloResponse(major: 2))
    await #expect(throws: RemoteRPCClient.ClientError.protocolMismatch(server: 2, client: 1)) {
      try await mismatch.value
    }
  }

  @Test
  func concurrentCallsResolveByIDRegardlessOfOrder() async throws {
    let server = FakeServer()
    let client = server.makeClient()
    var requests = server.requests.makeAsyncIterator()

    async let a = client.call(.systemPing, params: ["n": 1], as: [String: Int].self)
    async let b = client.call(.systemVersion, params: ["n": 2], as: [String: Int].self)
    let r1 = try #require(await requests.next())
    let r2 = try #require(await requests.next())
    #expect(r1.id != r2.id)

    // Answer in reverse order; each caller still gets its own result.
    for request in [r2, r1] {
      let n = request.method == .systemPing ? 1 : 2
      try server.reply(to: request.id, result: ["echo": n])
    }
    #expect(try await a == ["echo": 1])
    #expect(try await b == ["echo": 2])
  }

  @Test
  func errorResponsesSurfaceAsIPCErrors() async throws {
    let server = FakeServer()
    let client = server.makeClient()
    var requests = server.requests.makeAsyncIterator()

    let call = Task { try await client.callRaw(.paneRead, params: ["pane": "nope"]) }
    let request = try #require(await requests.next())
    try server.reply(IPC.Response(id: request.id, error: .notFound(kind: "pane", id: "nope")))
    await #expect(throws: RemoteRPCClient.ClientError.ipc(.notFound(kind: "pane", id: "nope"))) {
      try await call.value
    }
  }

  @Test
  func unansweredCallTimesOutAndLateReplyIsIgnored() async throws {
    let server = FakeServer()
    let client = server.makeClient(timeout: .milliseconds(100))
    var requests = server.requests.makeAsyncIterator()

    let call = Task { try await client.callRaw(.systemPing, params: [String: String]()) }
    let request = try #require(await requests.next())
    await #expect(throws: RemoteRPCClient.ClientError.timeout) { try await call.value }

    // A late reply must not crash or poison the next call.
    try server.reply(to: request.id, result: ["late": true])
    async let next = client.call(.systemPing, params: [String: String](), as: [String: Bool].self)
    let nextRequest = try #require(await requests.next())
    try server.reply(to: nextRequest.id, result: ["ok": true])
    #expect(try await next == ["ok": true])
  }

  @Test
  func streamDeliversFramesThenFinishesOnTerminator() async throws {
    let server = FakeServer()
    let client = server.makeClient()
    var requests = server.requests.makeAsyncIterator()

    let stream = try await client.subscribe(
      .eventsSubscribe, params: IPC.EventsSubscribeRequest(), as: IPC.EventFrame.self)
    let request = try #require(await requests.next())
    #expect(request.method == .eventsSubscribe)
    #expect(request.stream)

    // A unary call on the same client is answered while the stream is open.
    async let ping = client.call(.systemPing, params: [String: String](), as: [String: Bool].self)
    let pingRequest = try #require(await requests.next())

    try server.reply(to: request.id, result: IPC.EventFrame(seq: 0, payload: .heartbeat), stream: true)
    try server.reply(to: pingRequest.id, result: ["pong": true])
    try server.reply(to: request.id, result: IPC.EventFrame(seq: 1, payload: .heartbeat), stream: true)
    try server.reply(IPC.Response(id: request.id))

    var seqs: [Int] = []
    for try await frame in stream { seqs.append(frame.seq) }
    #expect(seqs == [0, 1])
    #expect(try await ping == ["pong": true])
  }

  @Test
  func streamErrorFrameFailsTheStream() async throws {
    let server = FakeServer()
    let client = server.makeClient()
    var requests = server.requests.makeAsyncIterator()

    let stream = try await client.subscribe(
      .eventsSubscribe, params: IPC.EventsSubscribeRequest(), as: IPC.EventFrame.self)
    let request = try #require(await requests.next())
    try server.reply(IPC.Response(id: request.id, error: .unsupported(reason: "not wired")))

    await #expect(throws: RemoteRPCClient.ClientError.ipc(.unsupported(reason: "not wired"))) {
      for try await _ in stream {}
    }
  }

  @Test
  func peerHangUpFailsEverythingInFlight() async throws {
    let server = FakeServer()
    let client = server.makeClient()
    var requests = server.requests.makeAsyncIterator()

    let stream = try await client.subscribe(
      .eventsSubscribe, params: IPC.EventsSubscribeRequest(), as: IPC.EventFrame.self)
    _ = await requests.next()
    let call = Task { try await client.callRaw(.systemPing, params: [String: String]()) }
    _ = await requests.next()

    server.hangUp()
    await #expect(throws: RemoteRPCClient.ClientError.connectionClosed) { try await call.value }
    await #expect(throws: RemoteRPCClient.ClientError.connectionClosed) {
      for try await _ in stream {}
    }
    #expect(await !client.isConnected)
    #expect(server.isClosed)
    await #expect(throws: RemoteRPCClient.ClientError.connectionClosed) {
      try await client.callRaw(.systemPing, params: [String: String]())
    }
  }

  @Test
  func localCloseFailsPendingCallsAndClosesTheChannel() async throws {
    let server = FakeServer()
    let client = server.makeClient()
    var requests = server.requests.makeAsyncIterator()

    let call = Task { try await client.callRaw(.systemPing, params: [String: String]()) }
    _ = await requests.next()
    await client.close()
    await #expect(throws: RemoteRPCClient.ClientError.connectionClosed) { try await call.value }
    #expect(server.isClosed)
  }
}
