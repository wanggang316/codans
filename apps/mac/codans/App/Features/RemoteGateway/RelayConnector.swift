import CodansIPC
import CodansRemote
import Foundation
import Network
import Observation
import os

/// Keeps this Mac reachable through the relay while the user allows access
/// from outside the LAN (design doc D55–D60).
///
/// It holds the control WebSocket, tells the relay which phone tokens may
/// connect (hashes only), and for every `incoming` session opens the
/// session WebSocket plus a plain TCP connection to the gateway on
/// 127.0.0.1 and pumps bytes between them. The TLS-PSK session runs
/// inside, end to end, so the gateway sees an ordinary client.
@MainActor
@Observable
final class RelayConnector {
  enum Status: Equatable {
    case off
    case connecting
    case online
    case failed(String)
  }

  private(set) var status: Status = .off
  let coordinates: RemoteRelayCoordinates

  @ObservationIgnored private let bearer: String
  @ObservationIgnored private let gatewayPort: () -> UInt16?
  @ObservationIgnored private let urlSession: URLSession
  @ObservationIgnored private var tokenHashes: [String] = []
  @ObservationIgnored private var control: URLSessionWebSocketTask?
  /// The HTTP status of the last control upgrade, to explain a refusal.
  @ObservationIgnored private var lastStatusCode: Int?
  @ObservationIgnored private var loop: Task<Void, Never>?
  @ObservationIgnored private var pipes: [ObjectIdentifier: RelayPipe] = [:]
  @ObservationIgnored private let queue = DispatchQueue(label: "com.gumpw.codans.remote.relay")
  @ObservationIgnored private let logger = Logger(subsystem: "com.gumpw.codans.remote", category: "relay")

  init(
    baseURL: String,
    secret: Data,
    gatewayPort: @escaping () -> UInt16?,
    urlSession: URLSession = .shared
  ) {
    self.coordinates = RemoteRelayCoordinates(url: baseURL, macID: RemoteRelay.macID(forMacSecret: secret))
    self.bearer = RemoteRelay.bearer(forMacSecret: secret)
    self.gatewayPort = gatewayPort
    self.urlSession = urlSession
  }

  // Explicit: a synthesized isolated deinit on an observable owned from
  // SwiftUI has crashed on release.
  deinit {}

  func start() {
    guard loop == nil else { return }
    loop = Task { [weak self] in await self?.run() }
  }

  /// Closes the control connection and every relayed session.
  func stop() {
    loop?.cancel()
    loop = nil
    control?.cancel(with: .goingAway, reason: nil)
    control = nil
    for pipe in pipes.values { pipe.cancel() }
    pipes = [:]
    status = .off
  }

  /// The phones allowed to connect: hashes of their relay tokens. Sent now
  /// if connected, and on every (re)connect.
  func setTokenHashes(_ hashes: [String]) {
    let sorted = hashes.sorted()
    guard sorted != tokenHashes else { return }
    tokenHashes = sorted
    guard let control else { return }
    let message = tokensMessage()
    Task {
      do {
        try await control.send(.string(message))
      } catch {
        control.cancel(with: .goingAway, reason: nil)
      }
    }
  }

  // MARK: - Control connection

  private func run() async {
    var failures = 0
    while !Task.isCancelled {
      status = .connecting
      do {
        try await serveControl()
        failures = 0
      } catch {
        if Task.isCancelled { break }
        failures += 1
        status = .failed(Self.describe(statusCode: lastStatusCode))
        logger.notice("relay control failed: \(String(describing: error), privacy: .public)")
      }
      if Task.isCancelled { break }
      // 1 s doubling to 30 s, with up to a quarter off so Macs behind one
      // outage do not return in lockstep.
      let base = min(30, pow(2, Double(min(failures, 5))))
      try? await Task.sleep(for: .seconds(base * Double.random(in: 0.75...1)))
    }
  }

  /// Returns when the relay closes the control connection; throws when it
  /// cannot be opened or fails.
  private func serveControl() async throws {
    guard let url = RemoteRelay.controlURL(coordinates) else { throw RelayError.invalidURL }
    let task = urlSession.webSocketTask(with: RemoteRelay.request(url, bearer: bearer))
    control = task
    task.resume()
    defer {
      lastStatusCode = (task.response as? HTTPURLResponse)?.statusCode
      task.cancel(with: .goingAway, reason: nil)
      if control === task { control = nil }
    }
    // Completes once the upgrade succeeded; a refused upgrade throws here.
    try await task.send(.string(tokensMessage()))
    status = .online
    logger.info("relay control online as \(self.coordinates.macID.prefix(6), privacy: .public)…")
    let pinger = Task.detached { await RelaySocket.keepAlive(task) }
    defer { pinger.cancel() }
    while !Task.isCancelled {
      let message = try await task.receive()
      guard case .string(let text) = message,
        let notice = try? JSONDecoder().decode(ControlMessage.self, from: Data(text.utf8))
      else { continue }
      if notice.type == "incoming", let session = notice.session {
        openSession(session)
      }
    }
  }

  private func tokensMessage() -> String {
    guard let data = try? JSONEncoder().encode(TokensMessage(hashes: tokenHashes)),
      let text = String(bytes: data, encoding: .utf8)
    else { return #"{"type":"tokens","hashes":[]}"# }
    return text
  }

  // MARK: - Sessions

  private func openSession(_ session: String) {
    guard let port = gatewayPort().flatMap(NWEndpoint.Port.init(rawValue:)),
      let url = RemoteRelay.sessionURL(coordinates, session: session)
    else {
      logger.notice("relay session dropped: gateway not listening")
      return
    }
    let socket = urlSession.webSocketTask(with: RemoteRelay.request(url, bearer: bearer))
    let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
    let pipe = RelayPipe(connection: connection, socket: socket, queue: queue)
    let key = ObjectIdentifier(pipe)
    pipes[key] = pipe
    pipe.start { [weak self] in
      Task { @MainActor in self?.pipes[key] = nil }
    }
  }

  // MARK: - Errors

  enum RelayError: Error {
    case invalidURL
  }

  private struct ControlMessage: Decodable {
    let type: String
    let session: String?
  }

  private struct TokensMessage: Encodable {
    var type = "tokens"
    let hashes: [String]
  }

  private static func describe(statusCode: Int?) -> String {
    switch statusCode {
    case 403: return "The relay refused this Mac"
    case 429: return "The relay is limiting connections"
    default: return "Can't reach the relay"
    }
  }
}

/// WebSocket helpers kept off the main actor: their completion handlers
/// run on URLSession's queue.
nonisolated enum RelaySocket {
  /// Pings every `RemoteRelay.pingInterval` until cancelled; a missed pong
  /// closes the socket so the control loop reconnects.
  static func keepAlive(_ task: URLSessionWebSocketTask) async {
    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(RemoteRelay.pingInterval))
      if Task.isCancelled { return }
      do {
        try await ping(task)
      } catch {
        task.cancel(with: .goingAway, reason: nil)
        return
      }
    }
  }

  static func ping(_ task: URLSessionWebSocketTask) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      task.sendPing { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }
}
