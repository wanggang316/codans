import Foundation
import CodansCore
import CodansIPC
import os

/// Typed JSON-RPC client. One instance per `codans` invocation.
///
/// On `call(_:params:timeout:)` the client opens a fresh transport, sends
/// `system.hello` pipelined with the real request, reads the hello
/// response (discarded unless it carries an error), then returns the
/// typed `Result`.
public actor RPCClient {
  public struct Versions: Sendable {
    public let clientVersion: String
    public let clientBinary: String
    public init(clientVersion: String, clientBinary: String = CLIInvocation.commandName) {
      self.clientVersion = clientVersion
      self.clientBinary = clientBinary
    }
  }

  public enum RPCError: Error, Equatable, Sendable {
    case ipc(IPCError)
    case timeout
    case noResponse
    case streamClosed
    case decodeFailed(String)
    /// Response `id` did not match the request we just issued. Surfaces
    /// server-side reordering / frame corruption explicitly instead of
    /// letting the client hang forever waiting for the right reply.
    case misorderedResponse(expected: String, got: String)
  }

  private let transport: Transport
  private let versions: Versions
  private var buffer = Data()
  private let inboundPump: InboundPump
  private let logger = Logger(subsystem: "com.gumpw.codans.cli", category: "rpc")
  private var didShutdown = false

  public init(transport: Transport, versions: Versions) {
    self.transport = transport
    self.versions = versions
    self.inboundPump = InboundPump(stream: transport.inbound)
  }

  // swiftlint:disable async_without_await
  // The `async` keyword has no `await` body today, but removing it breaks
  // callers; suppress the lint until a CodansKit concurrency audit revisits it.
  /// Explicit teardown. Call after the last `call(...)` to close the
  /// transport deterministically. Idempotent.
  ///
  /// Prefer this over relying on `deinit` — the actor's deinit races
  /// against the inbound-pump's detached Task and can leak the socket
  /// fd if the pump has not yet observed peer EOF.
  public func shutdown() async {
    guard !didShutdown else { return }
    didShutdown = true
    transport.close()
  }
  // swiftlint:enable async_without_await

  deinit {
    // Fallback. Clients that don't call `shutdown()` still get the
    // transport torn down, but ordering vs. the in-flight pump task is
    // undefined — use `shutdown()` for determinism.
    if !didShutdown {
      transport.close()
    }
  }

  /// Unary call. Returns the decoded `Result` or throws an `RPCError`.
  ///
  /// On the wire: pipelines `system.hello` + the real request, then reads
  /// back two responses IN ORDER. Each response's `id` is matched against
  /// the corresponding outbound request's id — a server that reorders or
  /// replaces frames surfaces as `.misorderedResponse`, never as an
  /// infinite hang.
  public func call<Params: Encodable, ResultType: Decodable>(
    _ method: IPC.Method,
    params: Params,
    resultType: ResultType.Type = ResultType.self,
    timeout: Duration = .seconds(10)
  ) async throws -> ResultType {
    let requestID = UUID().uuidString
    let helloID = "hello-\(UUID().uuidString.prefix(8))"
    let paramsJSON = try JSONValue.encoded(params)
    let request = IPC.Request(id: requestID, method: method, params: paramsJSON)

    try await pipelinedSend(helloID: String(helloID), request: request)

    let start = ContinuousClock.now
    let helloResponse = try await readResponse(deadline: start.advanced(by: timeout))
    if helloResponse.id != helloID {
      throw RPCError.misorderedResponse(expected: helloID, got: helloResponse.id)
    }
    if let error = helloResponse.error {
      throw RPCError.ipc(error)
    }
    let response = try await readResponse(deadline: start.advanced(by: timeout))
    if response.id != requestID {
      throw RPCError.misorderedResponse(expected: requestID, got: response.id)
    }
    if let error = response.error {
      throw RPCError.ipc(error)
    }
    guard let result = response.result else {
      throw RPCError.noResponse
    }
    do {
      return try result.decoded(as: ResultType.self)
    } catch {
      throw RPCError.decodeFailed(String(describing: error))
    }
  }

  /// Call with no typed result payload (uses `JSONValue` so callers can
  /// introspect). Convenience wrapper.
  public func callRaw<Params: Encodable>(
    _ method: IPC.Method,
    params: Params,
    timeout: Duration = .seconds(10)
  ) async throws -> JSONValue {
    try await call(method, params: params, resultType: JSONValue.self, timeout: timeout)
  }

  /// Server-streaming call. Opens a stream: true request, pipelines
  /// `system.hello`, yields each `{id, stream: true, result}` frame as
  /// a decoded `Element` until the terminator `{id, stream: false}` or
  /// the transport closes. The returned stream surfaces `RPCError` via
  /// `AsyncThrowingStream` error termination.
  ///
  /// `idleTimeout` bounds the gap between frames — if the server goes
  /// silent longer than that, the stream throws `RPCError.timeout`.
  /// Set to a very large value (e.g. `.seconds(.infinity.rounded())`)
  /// for long-lived tails.
  public nonisolated func stream<Params: Encodable & Sendable, Element: Decodable & Sendable>(
    _ method: IPC.Method,
    params: Params,
    elementType: Element.Type = Element.self,
    idleTimeout: Duration = .seconds(300)
  ) -> AsyncThrowingStream<Element, Error> {
    // Pre-encode params here (sync, on the calling actor) so the Task
    // below does not need to re-enter `Sendable` rules on a non-Sendable
    // `Params` value.
    let paramsJSON: JSONValue
    do {
      paramsJSON = try JSONValue.encoded(params)
    } catch {
      return AsyncThrowingStream { $0.finish(throwing: error) }
    }

    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          try await self.runStream(
            method: method,
            paramsJSON: paramsJSON,
            idleTimeout: idleTimeout
          ) { frame in
            // Surface per-frame decode failures as stream errors instead
            // of silently dropping them — a shaped-wrong frame is a server
            // bug the caller should see, not a missing line in the tail
            // output.
            do {
              let decoded = try frame.decoded(as: Element.self)
              continuation.yield(decoded)
            } catch {
              continuation.finish(throwing: RPCError.decodeFailed(String(describing: error)))
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func runStream(
    method: IPC.Method,
    paramsJSON: JSONValue,
    idleTimeout: Duration,
    yield: @Sendable (JSONValue) -> Void
  ) async throws {
    let requestID = UUID().uuidString
    let helloID = String("hello-\(UUID().uuidString.prefix(8))")
    let request = IPC.Request(id: requestID, method: method, params: paramsJSON, stream: true)
    try await pipelinedSend(helloID: helloID, request: request)

    // Drain the hello response first.
    let helloDeadline = ContinuousClock.now.advanced(by: idleTimeout)
    let helloResponse = try await readResponse(deadline: helloDeadline)
    if helloResponse.id != helloID {
      throw RPCError.misorderedResponse(expected: helloID, got: helloResponse.id)
    }
    if let error = helloResponse.error {
      throw RPCError.ipc(error)
    }

    while !Task.isCancelled {
      let deadline = ContinuousClock.now.advanced(by: idleTimeout)
      let response = try await readResponse(deadline: deadline)
      if response.id != requestID {
        throw RPCError.misorderedResponse(expected: requestID, got: response.id)
      }
      if let error = response.error {
        throw RPCError.ipc(error)
      }
      if !response.stream {
        return
      }
      if let frame = response.result {
        yield(frame)
      }
    }
  }

  // MARK: - Internals

  /// Pipeline `system.hello` + the real request in one write, saving a
  /// round trip. The caller passes the pre-generated `helloID` so it can
  /// match the id on the inbound response side.
  private func pipelinedSend(helloID: String, request: IPC.Request) async throws {
    let hello = IPC.Request(
      id: helloID,
      method: .systemHello,
      params: try JSONValue.encoded(
        HelloRequest(
          clientVersion: versions.clientVersion,
          clientBinary: versions.clientBinary
        ))
    )
    let helloFrame = try Framing.encode(JSONEncoder().encode(hello))
    let realFrame = try Framing.encode(JSONEncoder().encode(request))
    try await transport.send(helloFrame + realFrame)
  }

  /// Decode the next framed response from the inbound stream, honouring
  /// the deadline. Times out via an outer race between the stream pull
  /// and a sleep.
  private func readResponse(deadline: ContinuousClock.Instant) async throws -> IPC.Response {
    while ContinuousClock.now < deadline {
      if let frame = try? Framing.decode(from: &buffer) {
        return try JSONDecoder().decode(IPC.Response.self, from: frame)
      }
      guard let chunk = try await pullNext(deadline: deadline) else {
        throw RPCError.timeout
      }
      buffer.append(chunk)
    }
    throw RPCError.timeout
  }

  private func pullNext(deadline: ContinuousClock.Instant) async throws -> Data? {
    let remaining = ContinuousClock.now.duration(to: deadline)
    if remaining <= .zero { return nil }
    return await inboundPump.next(timeout: remaining)
  }
}

/// Background iterator that feeds incoming frames onto a
/// `CheckedContinuation`-based queue. Makes `await next(timeout:)`
/// trivially cancellable and sidesteps the `sending` rules that block a
/// naive `AsyncStream.Iterator` capture inside a Task.
actor InboundPump {
  /// Wrapped waiter — continuation paired with a unique id so a late-
  /// firing timeout task from a prior `next(timeout:)` call cannot race
  /// a waiter registered for a *subsequent* call.
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Data?, Never>
  }

  private var pending: [Data] = []
  private var waiter: Waiter?
  private var finished = false

  init(stream: AsyncStream<Data>) {
    Task { [weak self] in
      for await chunk in stream {
        await self?.deliver(chunk)
      }
      await self?.finish()
    }
  }

  func next(timeout: Duration) async -> Data? {
    if let head = pending.first {
      pending.removeFirst()
      return head
    }
    if finished { return nil }

    let waiterID = UUID()
    return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
      waiter = Waiter(id: waiterID, continuation: cont)
      Task { [weak self] in
        try? await Task.sleep(for: timeout)
        await self?.timeoutWaiter(id: waiterID)
      }
    }
  }

  private func deliver(_ chunk: Data) {
    if let w = waiter {
      waiter = nil
      w.continuation.resume(returning: chunk)
    } else {
      pending.append(chunk)
    }
  }

  private func timeoutWaiter(id: UUID) {
    // Only fire the timeout for the waiter we were scheduled against.
    // Without the id guard a sleep-Task from an earlier call could
    // resume a waiter registered for a subsequent call with nil,
    // surfacing as a spurious `.timeout` the user never asked for.
    guard let current = waiter, current.id == id else { return }
    waiter = nil
    current.continuation.resume(returning: nil)
  }

  private func finish() {
    finished = true
    if let w = waiter {
      waiter = nil
      w.continuation.resume(returning: nil)
    }
  }
}
