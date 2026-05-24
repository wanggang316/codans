import Foundation
import TouchCodeCore
import TouchCodeIPC

@testable import TouchCode

/// Test-only RPC harness. Binds a `MethodRouter` to in-memory streams so
/// `tcTests` can drive the full wire protocol — `system.hello`, unary
/// methods, and streaming — without a real Unix socket or blocking
/// `FileHandle.availableData` reads.
///
/// Landed in M3 (exec-plan 0003 DEC-11); consumed by M4/M5 tests.
@MainActor
public final class InMemoryIPCServer {
  private let router: MethodRouter
  private let inflightLimit: Int
  private var inboundContinuation: AsyncStream<Data>.Continuation?
  private var serveTask: Task<Void, Never>?
  private var responseBuffer = Data()

  private var pending: [IPC.Response] = []
  private var waiters: [Waiter] = []

  public init(router: MethodRouter, inflightLimit: Int = 64) {
    self.router = router
    self.inflightLimit = inflightLimit
  }

  /// Start the harness. Must be called once before `send(_:)`.
  public func start() {
    guard serveTask == nil else { return }

    var inboundCont: AsyncStream<Data>.Continuation!
    let inboundStream = AsyncStream<Data> { cont in
      inboundCont = cont
    }
    self.inboundContinuation = inboundCont

    let conn = SocketConnection(
      router: router,
      reader: inboundStream,
      write: { [weak self] data in
        await self?.handleServerWrite(data)
      },
      close: { [weak self] in
        await self?.finishAllWaiters()
      },
      inflightLimit: inflightLimit
    )

    serveTask = Task.detached {
      await conn.serve()
    }
  }

  public func stop() {
    inboundContinuation?.finish()
    serveTask?.cancel()
    serveTask = nil
    finishAllWaiters()
  }

  /// Encode and feed a request into the server's read side.
  public func send(_ request: IPC.Request) throws {
    let body = try JSONEncoder().encode(request)
    let frame = try Framing.encode(body)
    inboundContinuation?.yield(frame)
  }

  /// Test-only escape hatch to inject raw bytes (e.g. a malformed header)
  /// that the normal `send(_:)` path would reject locally.
  public func _test_feedRaw(_ data: Data) {
    inboundContinuation?.yield(data)
  }

  /// Await the next response produced by the server. Fails with a
  /// timeout error if no response arrives within `timeout`.
  public func awaitResponse(timeout: Duration = .seconds(2)) async throws -> IPC.Response {
    if let next = pending.first {
      pending.removeFirst()
      return next
    }
    // Schedule a timeout Task that fulfils the waiter with `.timeout` if no
    // real response arrives first.
    let waiterID = UUID()
    let response = await withCheckedContinuation { (cont: CheckedContinuation<IPC.Response, Never>) in
      waiters.append(Waiter(id: waiterID, continuation: cont))
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: timeout)
        self?.timeoutWaiter(id: waiterID)
      }
    }
    if response.id == "__timeout__" {
      throw HarnessError.timeout
    }
    return response
  }

  private func timeoutWaiter(id: UUID) {
    if let idx = waiters.firstIndex(where: { $0.id == id }) {
      let waiter = waiters.remove(at: idx)
      waiter.continuation.resume(returning: IPC.Response(id: "__timeout__"))
    }
  }

  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<IPC.Response, Never>
  }

  public enum HarnessError: Error, Equatable { case timeout, stopped }

  // MARK: - Wire assembly

  private func handleServerWrite(_ data: Data) {
    responseBuffer.append(data)
    while let frame = try? Framing.decode(from: &responseBuffer) {
      guard let response = try? JSONDecoder().decode(IPC.Response.self, from: frame) else {
        continue
      }
      if waiters.isEmpty {
        pending.append(response)
      } else {
        let waiter = waiters.removeFirst()
        waiter.continuation.resume(returning: response)
      }
    }
  }

  private func finishAllWaiters() {
    for waiter in waiters {
      waiter.continuation.resume(
        returning: IPC.Response(id: "", error: .internal("harness stopped"))
      )
    }
    waiters.removeAll()
  }
}
