import CodansIPC
import CodansRemote
import Foundation
import Network

/// Why a remote session could not start or ended, reduced to what the UI
/// shows and what the reconnect policy needs. Equatable so reducers can keep
/// it in state and tests can assert on it.
nonisolated struct RemoteFailure: Error, Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    /// No gateway with the paired channel is advertising on this network:
    /// the Mac is asleep, Remote Access is off, or the phone is on another
    /// network.
    case macNotFound
    /// iOS denied local-network access. Retrying cannot help until the
    /// user allows it in Settings.
    case localNetworkDenied
    /// One TLS handshake refusal from a resolved gateway. Retried, but
    /// counted: repeated refusals become `rejected`.
    case refused
    /// The Mac keeps refusing this device's key: it was removed there, or
    /// its pairing expired. Only pairing again helps.
    case rejected
    /// The Mac and this app speak incompatible protocol or app versions.
    case incompatible
    /// A phase, the whole attempt or a call ran past its deadline.
    case timeout
    /// The Mac refused the call for this device's permission.
    case forbidden
    /// The Mac cannot do this right now, e.g. type into a pane that is not
    /// open in its window.
    case unsupported
    /// The Keychain no longer holds this pairing's key.
    case missingKey
    /// The events stream ended (gateway turned off, device revoked, Mac
    /// quit, Wi-Fi hand-off).
    case streamEnded
    case other
  }

  let kind: Kind
  let message: String

  init(_ kind: Kind, _ message: String) {
    self.kind = kind
    self.message = message
  }

  /// Whether reconnecting with backoff can plausibly succeed. The others
  /// wait for the user: an update, a Settings change or pairing again.
  var isRetryable: Bool {
    switch kind {
    case .incompatible, .missingKey, .rejected, .localNetworkDenied: return false
    case .macNotFound, .refused, .timeout, .forbidden, .unsupported, .streamEnded, .other: return true
    }
  }

  static let streamEnded = RemoteFailure(.streamEnded, "The connection to your Mac ended.")
  /// The events stream went silent past the heartbeat deadline: the
  /// connection is presumed half-open.
  static let stalled = RemoteFailure(.streamEnded, "Your Mac stopped responding.")
  static let missingKey = RemoteFailure(
    .missingKey, "This pairing's key is missing on this device. Pair with your Mac again.")
  static let refused = RemoteFailure(.refused, "Your Mac refused this device.")
  static let rejected = RemoteFailure(
    .rejected, "Your Mac no longer accepts this device. It was removed or its pairing expired.")
  static let handshakeTimeout = RemoteFailure(.timeout, "Your Mac did not answer in time.")
  static let syncTimeout = RemoteFailure(.timeout, "Your Mac connected but sent nothing.")
  static let deadlinePassed = RemoteFailure(.timeout, "Connecting to your Mac took too long.")

  static func macNotFound(_ name: String) -> RemoteFailure {
    RemoteFailure(.macNotFound, "Couldn't find \(name) on this network.")
  }

  /// What a relay refusal means, from the HTTP status it answered with;
  /// nil when the relay refused nothing (the failure lies elsewhere).
  static func relayRefusal(_ status: Int?, gateway: PairedGateway) -> RemoteFailure? {
    switch status {
    case nil:
      return nil
    case 404:
      return RemoteFailure(
        .macNotFound,
        "\(gateway.displayName) is offline, or it doesn't allow access from outside its network.")
    case 403:
      // The relay no longer lists this device's token: removed on the Mac,
      // or outside access was turned off and on before it re-registered.
      // Counted like a TLS refusal.
      return .refused
    case 429:
      return RemoteFailure(.other, "The relay is busy. Trying again shortly.")
    default:
      return RemoteFailure(.other, "The relay could not connect to \(gateway.displayName).")
    }
  }

  /// Classifies any error thrown by the remote stack.
  init(_ error: Error) {
    switch error {
    case let failure as RemoteFailure:
      self = failure
    case let client as RemoteRPCClient.ClientError:
      self = Self.classify(client)
    case RemoteHandshake.HandshakeError.timedOut:
      self = .handshakeTimeout
    case RemoteHandshake.HandshakeError.refused:
      self = .refused
    case is RemoteHandshake.HandshakeError:
      self.init(.other, "Your Mac refused the connection. If it keeps failing, pair again.")
    default:
      self.init(.other, error.localizedDescription)
    }
  }

  private static func classify(_ error: RemoteRPCClient.ClientError) -> RemoteFailure {
    switch error {
    case .protocolMismatch(let server, let client):
      return RemoteFailure(
        .incompatible,
        server > client
          ? "Your Mac runs a newer Codans. Update this app."
          : "Your Mac runs an older Codans. Update Codans on your Mac.")
    case .ipc(.versionMismatch(let client, let server)):
      return RemoteFailure(
        .incompatible, "Codans \(client) on this device cannot talk to Codans \(server) on your Mac.")
    case .ipc(.forbidden(let reason)):
      return RemoteFailure(.forbidden, reason)
    case .ipc(.unsupported(let reason)):
      return RemoteFailure(.unsupported, reason)
    case .ipc(let ipc):
      return RemoteFailure(.other, ipc.displayMessage)
    case .timeout:
      return .handshakeTimeout
    case .connectionClosed:
      return .streamEnded
    case .noResult, .decodeFailed:
      return RemoteFailure(.other, "Your Mac sent a reply this app does not understand.")
    case .writeFailed:
      return RemoteFailure(.other, "The connection to your Mac was interrupted.")
    }
  }
}
