import CodansIPC
import Foundation
import Network
import os

/// The phone's end of the relay: a TCP listener on 127.0.0.1 whose every
/// accepted connection becomes one relay session to the Mac. The caller
/// dials the listener with its ordinary TLS-PSK `NWConnection`, so the
/// handshake and everything after it run end to end through the relay
/// (design doc D56).
///
/// The relay answers a refused session with an HTTP status before the
/// WebSocket upgrade; the bridge keeps the last one, because to the TLS
/// connection it only looks like a dropped socket.
public final class RelayLoopbackBridge: @unchecked Sendable {
  private let relay: RemoteRelayCoordinates
  private let token: String
  private let urlSession: URLSession
  private let queue = DispatchQueue(label: "com.gumpw.codans.remote.relay-bridge")
  private let state = OSAllocatedUnfairLock<State>(initialState: State())
  private let logger = Logger(subsystem: "com.gumpw.codans.remote", category: "relay-bridge")

  private struct State {
    var listener: NWListener?
    var pipes: [ObjectIdentifier: RelayPipe] = [:]
    var lastRefusal: Int?
    var stopped = false
  }

  public init(relay: RemoteRelayCoordinates, token: String, urlSession: URLSession = .shared) {
    self.relay = relay
    self.token = token
    self.urlSession = urlSession
  }

  /// The HTTP status of the most recent refused relay session (403 not
  /// allowed, 404 Mac offline, 429 rate limited), nil when none was
  /// refused. Cleared by every new session.
  public var lastRefusal: Int? { state.withLock { $0.lastRefusal } }

  /// Starts listening and returns the loopback endpoint to dial.
  public func start() async throws -> NWEndpoint {
    guard let connectURL = RemoteRelay.connectURL(relay) else { throw BridgeError.invalidRelay }
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: parameters)
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection, url: connectURL)
    }
    state.withLock { $0.listener = listener }

    let port = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<NWEndpoint.Port, Error>) in
      let resumed = OSAllocatedUnfairLock(initialState: false)
      let resume: @Sendable (Result<NWEndpoint.Port, Error>) -> Void = { result in
        let isFirst = resumed.withLock { done in
          defer { done = true }
          return !done
        }
        guard isFirst else { return }
        continuation.resume(with: result)
      }
      listener.stateUpdateHandler = { listenerState in
        switch listenerState {
        case .ready:
          if let port = listener.port { resume(.success(port)) }
        case .failed(let error):
          resume(.failure(error))
        case .cancelled:
          resume(.failure(BridgeError.stopped))
        default:
          break
        }
      }
      listener.start(queue: queue)
    }
    return .hostPort(host: "127.0.0.1", port: port)
  }

  /// Stops listening and ends every relayed session.
  public func stop() {
    let (listener, pipes) = state.withLock { state -> (NWListener?, [RelayPipe]) in
      state.stopped = true
      defer {
        state.listener = nil
        state.pipes = [:]
      }
      return (state.listener, Array(state.pipes.values))
    }
    listener?.cancel()
    for pipe in pipes { pipe.cancel() }
  }

  private func accept(_ connection: NWConnection, url: URL) {
    let socket = urlSession.webSocketTask(with: RemoteRelay.request(url, bearer: token))
    let pipe = RelayPipe(connection: connection, socket: socket, queue: queue)
    let key = ObjectIdentifier(pipe)
    let accepted = state.withLock { state -> Bool in
      guard !state.stopped else { return false }
      state.pipes[key] = pipe
      // A new attempt: an earlier refusal no longer explains anything.
      state.lastRefusal = nil
      return true
    }
    guard accepted else {
      connection.cancel()
      return
    }
    pipe.start { [weak self] in
      let status = (socket.response as? HTTPURLResponse)?.statusCode
      self?.state.withLock { state in
        state.pipes[key] = nil
        if let status, status != 101 { state.lastRefusal = status }
      }
      if let status, status != 101 {
        self?.logger.notice("relay refused a session: HTTP \(status, privacy: .public)")
      }
    }
  }

  public enum BridgeError: Error {
    case invalidRelay
    case stopped
  }
}
