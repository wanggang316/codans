import CodansIPC
import Foundation
import Network
import os

/// Long-lived JSON-RPC client over one byte channel. Unlike the CLI's
/// one-call-per-connection client it sends `system.hello` once, then keeps
/// an id → waiter table so several requests can be in flight, and routes
/// streaming frames to per-request `AsyncThrowingStream`s.
///
/// The server serves one connection's frames serially and closes it after a
/// stream ends, so callers keep unary calls and a long-lived subscription on
/// separate clients (the iOS app's control and events connections).
public actor RemoteRPCClient {
  public enum ClientError: Error, Equatable, Sendable {
    case ipc(IPCError)
    case timeout
    case connectionClosed
    case noResult
    case decodeFailed(String)
    case protocolMismatch(server: Int, client: Int)
    case writeFailed(String)
  }

  /// IPC protocol major this client speaks; `connect` rejects any other.
  public static let supportedProtocolMajor = 1

  private enum Waiter {
    case unary(CheckedContinuation<IPC.Response, Error>)
    case stream(StreamSink)
  }

  /// Type-erased consumer of one stream's frames.
  private struct StreamSink {
    /// Returns false when the consumer failed (e.g. a frame did not
    /// decode) and has already finished itself.
    let yield: @Sendable (JSONValue) -> Bool
    let finish: @Sendable (Error?) -> Void
  }

  private let write: @Sendable (Data) async throws -> Void
  private let closeChannel: @Sendable () -> Void
  private let defaultTimeout: Duration
  private var waiters: [String: Waiter] = [:]
  private var timeouts: [String: Task<Void, Never>] = [:]
  private var nextRequestNumber = 0
  private var isClosed = false
  /// Held until the first request starts the read loop; an actor's
  /// initializer cannot start isolated work itself.
  private var pendingReader: AsyncStream<Data>?
  private var readTask: Task<Void, Never>?
  private let logger = Logger(subsystem: "com.gumpw.codans.remote", category: "rpc")

  /// The server's handshake answer, once `hello(...)` has succeeded.
  public private(set) var serverHello: HelloResponse?

  /// Wraps an already-connected channel. Call `hello(...)` before anything
  /// else; `connect(...)` does both.
  public init(
    reader: AsyncStream<Data>,
    write: @escaping @Sendable (Data) async throws -> Void,
    close: @escaping @Sendable () -> Void,
    defaultTimeout: Duration = .seconds(15)
  ) {
    self.write = write
    self.closeChannel = close
    self.defaultTimeout = defaultTimeout
    self.pendingReader = reader
  }

  /// Connects to a gateway, authenticates with `credential`, and performs
  /// the `system.hello` handshake.
  public static func connect(
    to endpoint: NWEndpoint,
    credential: RemoteTLS.PSKCredential,
    hello request: HelloRequest,
    timeout: Duration = RemoteHandshake.defaultTimeout
  ) async throws -> RemoteRPCClient {
    let transport = try await RemoteHandshake.connect(to: endpoint, credential: credential, timeout: timeout)
    let client = RemoteRPCClient(
      reader: transport.makeReader(),
      write: { try await transport.write($0) },
      close: { transport.close() }
    )
    do {
      _ = try await client.hello(request, timeout: timeout)
    } catch {
      await client.close()
      throw error
    }
    return client
  }

  /// Sends `system.hello` and checks the protocol major.
  @discardableResult
  public func hello(_ request: HelloRequest, timeout: Duration? = nil) async throws -> HelloResponse {
    let response = try await call(.systemHello, params: request, as: HelloResponse.self, timeout: timeout)
    guard response.protocolMajor == Self.supportedProtocolMajor else {
      throw ClientError.protocolMismatch(server: response.protocolMajor, client: Self.supportedProtocolMajor)
    }
    serverHello = response
    return response
  }

  /// Unary call. Throws `ClientError`.
  public func call<Params: Encodable, Result: Decodable>(
    _ method: IPC.Method,
    params: Params,
    as resultType: Result.Type = Result.self,
    timeout: Duration? = nil
  ) async throws -> Result {
    let json = try await callRaw(method, params: params, timeout: timeout)
    do {
      return try json.decoded(as: Result.self)
    } catch {
      throw ClientError.decodeFailed(String(describing: error))
    }
  }

  /// Unary call returning the raw `result`.
  public func callRaw<Params: Encodable>(
    _ method: IPC.Method,
    params: Params,
    timeout: Duration? = nil
  ) async throws -> JSONValue {
    guard !isClosed else { throw ClientError.connectionClosed }
    let id = makeRequestID()
    let frame = try encodeFrame(IPC.Request(id: id, method: method, params: JSONValue.encoded(params)))
    let deadline = timeout ?? defaultTimeout

    let response = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<IPC.Response, Error>) in
        waiters[id] = .unary(continuation)
        timeouts[id] = Task { [weak self] in
          try? await Task.sleep(for: deadline)
          guard !Task.isCancelled else { return }
          await self?.resolve(id, with: ClientError.timeout)
        }
        Task { [weak self] in await self?.send(frame, for: id) }
      }
    } onCancel: {
      Task { [weak self] in await self?.resolve(id, with: CancellationError()) }
    }

    if let error = response.error { throw ClientError.ipc(error) }
    guard let result = response.result else { throw ClientError.noResult }
    return result
  }

  /// Streaming call. Returns once the request is written; frames arrive on
  /// the stream until the server's terminator (normal finish), an error
  /// frame (thrown), or the connection closing (`.connectionClosed`).
  /// Dropping the stream stops delivery locally; the server keeps its side
  /// open until the connection closes.
  public func subscribe<Params: Encodable, Element: Decodable & Sendable>(
    _ method: IPC.Method,
    params: Params,
    as elementType: Element.Type = Element.self
  ) async throws -> AsyncThrowingStream<Element, Error> {
    guard !isClosed else { throw ClientError.connectionClosed }
    let id = makeRequestID()
    let frame = try encodeFrame(
      IPC.Request(id: id, method: method, params: JSONValue.encoded(params), stream: true))

    let (stream, continuation) = AsyncThrowingStream<Element, Error>.makeStream()
    waiters[id] = .stream(
      StreamSink(
        yield: { json in
          do {
            continuation.yield(try json.decoded(as: Element.self))
            return true
          } catch {
            continuation.finish(throwing: ClientError.decodeFailed(String(describing: error)))
            return false
          }
        },
        finish: { error in continuation.finish(throwing: error) }
      ))
    continuation.onTermination = { [weak self] _ in
      Task { await self?.dropStream(id) }
    }

    do {
      try await write(frame)
    } catch {
      let failure = ClientError.writeFailed(String(describing: error))
      resolve(id, with: failure)
      throw failure
    }
    return stream
  }

  /// Closes the channel and fails everything in flight. Idempotent.
  public func close() {
    guard !isClosed else { return }
    isClosed = true
    readTask?.cancel()
    closeChannel()
    failAll(ClientError.connectionClosed)
  }

  public var isConnected: Bool { !isClosed }

  // MARK: - Internals

  private func startReadingIfNeeded() {
    guard let reader = pendingReader else { return }
    pendingReader = nil
    readTask = Task { [weak self] in await self?.readLoop(reader) }
  }

  private func makeRequestID() -> String {
    startReadingIfNeeded()
    nextRequestNumber += 1
    return "r\(nextRequestNumber)"
  }

  private func encodeFrame(_ request: IPC.Request) throws -> Data {
    try Framing.encode(JSONEncoder().encode(request))
  }

  private func send(_ frame: Data, for id: String) async {
    do {
      try await write(frame)
    } catch {
      resolve(id, with: ClientError.writeFailed(String(describing: error)))
    }
  }

  private func readLoop(_ reader: AsyncStream<Data>) async {
    var buffer = Data()
    readFrames: for await chunk in reader {
      buffer.append(chunk)
      do {
        while let body = try Framing.decode(from: &buffer) {
          dispatch(body)
        }
      } catch {
        logger.error("remote rpc: framing error \(String(describing: error), privacy: .public)")
        break readFrames
      }
    }
    isClosed = true
    closeChannel()
    failAll(ClientError.connectionClosed)
  }

  private func dispatch(_ body: Data) {
    guard let response = try? JSONDecoder().decode(IPC.Response.self, from: body) else {
      logger.error("remote rpc: undecodable response frame")
      return
    }
    switch waiters[response.id] {
    case .unary(let continuation):
      removeWaiter(response.id)
      continuation.resume(returning: response)
    case .stream(let sink):
      if let error = response.error {
        removeWaiter(response.id)
        sink.finish(ClientError.ipc(error))
      } else if response.stream {
        if let result = response.result, !sink.yield(result) {
          removeWaiter(response.id)
        }
      } else {
        removeWaiter(response.id)
        sink.finish(nil)
      }
    case nil:
      // A late reply to a request that already timed out or was cancelled.
      logger.debug("remote rpc: response for unknown id \(response.id, privacy: .public)")
    }
  }

  private func resolve(_ id: String, with error: Error) {
    guard let waiter = removeWaiter(id) else { return }
    switch waiter {
    case .unary(let continuation): continuation.resume(throwing: error)
    case .stream(let sink): sink.finish(error)
    }
  }

  private func dropStream(_ id: String) {
    if case .stream = waiters[id] { removeWaiter(id) }
  }

  @discardableResult
  private func removeWaiter(_ id: String) -> Waiter? {
    timeouts.removeValue(forKey: id)?.cancel()
    return waiters.removeValue(forKey: id)
  }

  private func failAll(_ error: Error) {
    for id in Array(waiters.keys) {
      resolve(id, with: error)
    }
  }
}
