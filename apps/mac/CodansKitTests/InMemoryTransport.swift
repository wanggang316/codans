import Foundation
import CodansCore
import CodansIPC

@testable import CodansKit

/// Test-only `Transport` — records inbound writes and replays a scripted
/// response sequence back through the `inbound` stream.
///
/// Unlike `InMemoryIPCServer` (codansTests target), this transport
/// does not bring in `MethodRouter` / `SocketConnection` from the app —
/// it's a pure client-side-testing fixture that lets us exercise
/// `RPCClient` in CodansKitTests without depending on the codans binary.
public final class InMemoryTransport: Transport, @unchecked Sendable {
  public enum Scripted {
    /// Unary success.
    case success(id: String, result: JSONValue)
    /// Unary error, OR stream-ending error (stream: false).
    case error(id: String, error: IPCError)
    /// One frame in a streaming response (`stream: true`).
    case streamFrame(id: String, result: JSONValue)
    /// Graceful streaming terminator (`stream: false`, no result, no error).
    case streamEnd(id: String)
  }

  public typealias ScriptBlock = @Sendable ([Data]) throws -> [Scripted]

  /// Invoked once, after the client finishes its pipelined write. The
  /// block inspects the raw request frames (length-prefix stripped) and
  /// returns the scripted responses to play back.
  public var script: ScriptBlock = { _ in [] }

  public let inbound: AsyncStream<Data>
  private let continuation: AsyncStream<Data>.Continuation
  private let lock = NSLock()
  private var writeBuffer = Data()
  private var closed = false
  private var autoRunTask: Task<Void, Never>?

  public init() {
    var continuation: AsyncStream<Data>.Continuation!
    self.inbound = AsyncStream<Data> { cont in continuation = cont }
    self.continuation = continuation
  }

  public func send(_ frame: Data) async throws {
    appendToBuffer(frame)
    scheduleAutoRunIfNeeded()
  }

  /// Trigger `run()` automatically a short time after the first `send(_:)`
  /// call so tests can build a client + issue a call without having to
  /// manually race `transport.run()` against the client's pipelined
  /// write.
  private func scheduleAutoRunIfNeeded() {
    lock.lock()
    defer { lock.unlock() }
    guard autoRunTask == nil else { return }
    autoRunTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(30))
      try? await self?.run()
    }
  }

  public func close() {
    lock.lock()
    closed = true
    lock.unlock()
    continuation.finish()
  }

  /// Drain written bytes into request frames, invoke the script, and
  /// yield the scripted responses back through `inbound`. Call after the
  /// client has issued its pipelined write.
  public func run() async throws {
    // Small yield so the client's `send(_:)` has committed to `writeBuffer`
    // before we try to decode.
    try await Task.sleep(for: .milliseconds(20))

    var buffer = snapshotBuffer()

    var frames: [Data] = []
    while let frame = try Framing.decode(from: &buffer) {
      frames.append(frame)
    }
    let scripted = try script(frames)
    for response in scripted {
      let envelope: IPC.Response
      switch response {
      case .success(let id, let result):
        envelope = IPC.Response(id: id, result: result)
      case .error(let id, let error):
        envelope = IPC.Response(id: id, error: error)
      case .streamFrame(let id, let result):
        envelope = IPC.Response(id: id, stream: true, result: result)
      case .streamEnd(let id):
        envelope = IPC.Response(id: id, stream: false)
      }
      let body = try JSONEncoder().encode(envelope)
      let framed = try Framing.encode(body)
      continuation.yield(framed)
    }
  }

  // MARK: - Synchronous helpers (lock under the hood; safe to call from async)

  private func appendToBuffer(_ data: Data) {
    lock.lock()
    writeBuffer.append(data)
    lock.unlock()
  }

  private func snapshotBuffer() -> Data {
    lock.lock()
    defer { lock.unlock() }
    return writeBuffer
  }
}
