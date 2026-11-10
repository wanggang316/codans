import CodansIPC
import Foundation
import Network
import os

@testable import CodansRemote

/// A TLS-PSK listener on 127.0.0.1 that runs the server half of
/// `RemoteHandshake` for every connection and reports each outcome, so
/// tests can assert both what the client saw and what the server decided.
final class LoopbackGateway: Sendable {
  enum Outcome: Sendable {
    case accepted(identity: String, transport: NWFrameTransport)
    case rejected(Error)
  }

  let listener: NWListener
  let port: NWEndpoint.Port
  let outcomes: AsyncStream<Outcome>
  private let outcomeSink: AsyncStream<Outcome>.Continuation

  let serviceName: String?

  var endpoint: NWEndpoint { .hostPort(host: "127.0.0.1", port: port) }

  /// The Bonjour endpoint a phone's browser would hand over; only for a
  /// gateway started with `advertisedAs`.
  var serviceEndpoint: NWEndpoint? {
    serviceName.map { .service(name: $0, type: Self.testServiceType, domain: "local.", interface: nil) }
  }

  /// Bonjour type for `advertisedAs`, apart from the real gateway's so a
  /// phone browsing for Macs never lists a test listener.
  static let testServiceType = "_codans-test._tcp"

  /// Starts a listener holding `credentials` and waits until it is ready.
  /// With `advertisedAs`, the listener accepts on every interface (the
  /// advertised host name resolves to LAN addresses) and registers a
  /// Bonjour service of that name, reachable at `serviceEndpoint`.
  static func start(
    credentials: [RemoteTLS.PSKCredential],
    handshakeTimeout: Duration = .seconds(5),
    advertisedAs serviceName: String? = nil
  ) async throws -> LoopbackGateway {
    let parameters = RemoteTLS.serverParameters(credentials: credentials)
    if serviceName == nil {
      parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    }
    let listener = try NWListener(using: parameters)
    if let serviceName {
      listener.service = NWListener.Service(name: serviceName, type: testServiceType)
    }
    let keys = Dictionary(uniqueKeysWithValues: credentials.map { ($0.identity, $0.key) })
    let (outcomes, sink) = AsyncStream<Outcome>.makeStream()

    listener.newConnectionHandler = { connection in
      Task {
        do {
          let accepted = try await RemoteHandshake.accept(connection, timeout: handshakeTimeout) {
            keys[$0]
          }
          sink.yield(.accepted(identity: accepted.identity, transport: accepted.transport))
        } catch {
          sink.yield(.rejected(error))
        }
      }
    }

    let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
      let pending = OSAllocatedUnfairLock<CheckedContinuation<NWEndpoint.Port, Error>?>(
        initialState: continuation)
      let resume: @Sendable (Result<NWEndpoint.Port, Error>) -> Void = { result in
        pending.withLock { slot -> CheckedContinuation<NWEndpoint.Port, Error>? in
          defer { slot = nil }
          return slot
        }?.resume(with: result)
      }
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          if let port = listener.port { resume(.success(port)) }
        case .failed(let error):
          resume(.failure(error))
        default:
          break
        }
      }
      listener.start(queue: DispatchQueue(label: "loopback-gateway"))
    }
    return LoopbackGateway(
      listener: listener, port: port, serviceName: serviceName, outcomes: outcomes, sink: sink)
  }

  private init(
    listener: NWListener,
    port: NWEndpoint.Port,
    serviceName: String?,
    outcomes: AsyncStream<Outcome>,
    sink: AsyncStream<Outcome>.Continuation
  ) {
    self.listener = listener
    self.port = port
    self.serviceName = serviceName
    self.outcomes = outcomes
    self.outcomeSink = sink
  }

  /// The next server-side handshake outcome.
  func nextOutcome() async -> Outcome? {
    var iterator = outcomes.makeAsyncIterator()
    return await iterator.next()
  }

  func stop() {
    listener.cancel()
    outcomeSink.finish()
  }
}

enum TestKeys {
  static func credential(_ identity: String) throws -> RemoteTLS.PSKCredential {
    RemoteTLS.PSKCredential(identity: identity, key: try PairingPayload.generateKey())
  }
}
