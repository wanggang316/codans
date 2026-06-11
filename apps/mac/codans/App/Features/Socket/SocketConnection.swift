import Foundation
import CodansCore
import CodansIPC
import os

/// One accepted connection's request/response loop. Shared by the real
/// `SocketServer` (on accept) and the test `InMemoryIPCServer` harness.
///
/// Wire protocol (exec-plan 0003 DEC-3): length-prefixed JSON envelopes,
/// UInt32 big-endian prefix + body, 16 MiB per-frame cap. First frame
/// must be `system.hello`; subsequent frames are unary OR one streaming
/// call before connection close (C4 §D10).
public actor SocketConnection {
  public let id: UUID
  public let inflightLimit: Int
  private let router: MethodRouter
  private let reader: AsyncStream<Data>
  private let write: @Sendable (Data) async -> Void
  private let close: @Sendable () async -> Void
  private let logger = Logger(subsystem: "com.gumpw.codans.ipc", category: "connection")

  private var helloCompleted = false
  private var readBuffer = Data()
  /// Frames that have been decoded but not yet fully responded to.
  /// Incremented at decode time, decremented when the response
  /// (unary or streaming-terminator) has been flushed to the write
  /// closure. Caps per-connection state growth — DEC-9 in
  /// exec-plan 0003 fixes this at 64.
  private var inflight = 0

  public init(
    id: UUID = UUID(),
    router: MethodRouter,
    reader: AsyncStream<Data>,
    write: @escaping @Sendable (Data) async -> Void,
    close: @escaping @Sendable () async -> Void,
    inflightLimit: Int = 64
  ) {
    self.id = id
    self.router = router
    self.reader = reader
    self.write = write
    self.close = close
    self.inflightLimit = inflightLimit
  }

  /// Run the connection loop until the peer closes or we write a
  /// terminal frame that triggers close on our end. One call per
  /// connection.
  public func serve() async {
    logger.debug("connection \(self.id.uuidString, privacy: .public) opened")
    defer {
      Task { [close] in await close() }
      logger.debug("connection \(self.id.uuidString, privacy: .public) closed")
    }

    for await chunk in reader {
      readBuffer.append(chunk)
      do {
        while let frame = try Framing.decode(from: &readBuffer) {
          await handleFrame(frame)
        }
      } catch {
        // DEC-3: oversize / malformed frames close the connection after
        // a single well-formed `.invalidFrame` response. Swallowing the
        // error and continuing to append to the buffer would desync the
        // byte stream and hang the peer.
        await sendError(id: "<malformed>", .invalidFrame(reason: "\(error)"))
        return
      }
    }
  }

  // MARK: - Frame handling

  private func handleFrame(_ frame: Data) async {
    let request: IPC.Request
    do {
      request = try JSONDecoder().decode(IPC.Request.self, from: frame)
    } catch {
      await sendError(id: "<malformed>", .invalidFrame(reason: "request decode failed: \(error)"))
      return
    }

    if !helloCompleted {
      guard request.method == .systemHello else {
        // Non-hello first frame is a handshake-ordering violation, not
        // a version clash — `.invalidParams` carries the correct
        // semantics and lets clients distinguish this from an actual
        // versionMismatch on a well-formed `system.hello`.
        await sendError(
          id: request.id,
          .invalidParams(
            message: "first frame on a new connection must be system.hello",
            path: ["method"]
          ))
        return
      }
    } else if inflight >= inflightLimit {
      // Per-connection backpressure cap (DEC-9). Actor-serialized
      // handling keeps the real inflight count at ≤ 1 today, so this
      // branch is reached only when a future concurrent-dispatch
      // refactor (tracked as M3.1.1) lets multiple handlers run in
      // parallel. Leave the cap wired now so the wire contract is
      // locked: overflow returns `.overloaded` (CLIExitCode 5) and
      // the connection stays open for later requests.
      await sendError(id: request.id, .overloaded)
      return
    }

    inflight += 1
    defer { inflight -= 1 }

    if request.stream {
      await handleStreaming(request)
    } else {
      await handleUnary(request)
    }
  }

  private func handleUnary(_ request: IPC.Request) async {
    let outcome = await router.route(request)
    switch outcome {
    case .unary(let result):
      if request.method == .systemHello { helloCompleted = true }
      await sendResponse(IPC.Response(id: request.id, result: result))
    case .streaming:
      await sendError(
        id: request.id,
        .invalidParams(
          message: "\(request.method.rawValue) requires stream: true on the request",
          path: nil
        ))
    case .failed(let error):
      await sendError(id: request.id, error)
    }
  }

  private func handleStreaming(_ request: IPC.Request) async {
    let outcome = await router.route(request)
    switch outcome {
    case .streaming(let subscribe):
      let stream = subscribe()
      for await frame in stream {
        await sendResponse(IPC.Response(id: request.id, stream: true, result: frame))
      }
      // Graceful server-initiated end: final frame with stream: false.
      await sendResponse(IPC.Response(id: request.id, stream: false))
    case .unary(let result):
      // Caller sent stream: true on a non-streaming method.
      await sendResponse(IPC.Response(id: request.id, result: result))
    case .failed(let error):
      await sendError(id: request.id, error)
    }
  }

  // MARK: - Wire

  private func sendResponse(_ response: IPC.Response) async {
    do {
      let body = try JSONEncoder().encode(response)
      let frame = try Framing.encode(body)
      await write(frame)
    } catch {
      logger.error("encode response failed: \(String(describing: error), privacy: .public)")
    }
  }

  private func sendError(id: String, _ error: IPCError) async {
    await sendResponse(IPC.Response(id: id, error: error))
  }
}
