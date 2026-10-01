import Foundation
import Network
import os

/// Pumps bytes both ways between a TCP connection and a relay WebSocket,
/// one binary message per read. Both ends use it: the phone between the
/// loopback socket its TLS-PSK connection dials and the relay, the Mac
/// between the relay and its gateway listener.
///
/// Each direction reads again only after its write completed, so a slow
/// side backs the other up instead of buffering without bound. The pipe
/// keeps itself alive through its in-flight callbacks until it ends;
/// ending either side ends both, once.
public final class RelayPipe: @unchecked Sendable {
  private static let readSize = 64 * 1024

  private let connection: NWConnection
  private let socket: URLSessionWebSocketTask
  private let queue: DispatchQueue
  private let state = OSAllocatedUnfairLock<State>(initialState: State())

  private struct State {
    var ended = false
    var onEnd: (@Sendable () -> Void)?
    var pingTimer: DispatchSourceTimer?
  }

  /// `connection` must not be started yet; the pipe starts it on `queue`.
  public init(connection: NWConnection, socket: URLSessionWebSocketTask, queue: DispatchQueue) {
    self.connection = connection
    self.socket = socket
    self.queue = queue
  }

  public func start(onEnd: @escaping @Sendable () -> Void = {}) {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + RemoteRelay.pingInterval, repeating: RemoteRelay.pingInterval)
    timer.setEventHandler { [self] in
      socket.sendPing { error in
        if error != nil { self.end() }
      }
    }
    state.withLock {
      $0.onEnd = onEnd
      $0.pingTimer = timer
    }
    connection.stateUpdateHandler = { [self] connectionState in
      switch connectionState {
      case .failed, .cancelled: end()
      default: break
      }
    }
    connection.start(queue: queue)
    socket.resume()
    timer.resume()
    pumpConnectionToSocket()
    pumpSocketToConnection()
  }

  /// Ends both sides.
  public func cancel() { end() }

  private func pumpConnectionToSocket() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: Self.readSize) {
      [self] data, _, isComplete, error in
      if let data, !data.isEmpty {
        socket.send(.data(data)) { sendError in
          if sendError != nil || isComplete {
            self.end()
          } else {
            self.pumpConnectionToSocket()
          }
        }
      } else if isComplete || error != nil {
        end()
      } else {
        pumpConnectionToSocket()
      }
    }
  }

  private func pumpSocketToConnection() {
    socket.receive { [self] result in
      let data: Data
      switch result {
      case .failure:
        end()
        return
      case .success(.data(let bytes)):
        data = bytes
      case .success(.string(let text)):
        data = Data(text.utf8)
      case .success:
        end()
        return
      }
      connection.send(
        content: data,
        completion: .contentProcessed { sendError in
          if sendError != nil {
            self.end()
          } else {
            self.pumpSocketToConnection()
          }
        })
    }
  }

  private func end() {
    let finished = state.withLock { state -> (@Sendable () -> Void)?? in
      guard !state.ended else { return nil }
      state.ended = true
      state.pingTimer?.cancel()
      state.pingTimer = nil
      let onEnd = state.onEnd
      state.onEnd = nil
      return .some(onEnd)
    }
    guard let onEnd = finished else { return }
    connection.cancel()
    socket.cancel(with: .normalClosure, reason: nil)
    onEnd?()
  }
}
