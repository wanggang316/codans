import CodansIPC
import CodansRemote
import Foundation
import Network

/// Why a remote session could not start or ended, reduced to what the UI
/// shows and what the reconnect policy needs. Equatable so reducers can keep
/// it in state and tests can assert on it.
nonisolated struct RemoteFailure: Error, Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    /// No gateway with the paired channel is advertising on this network.
    case notFound
    /// iOS denied local-network access; retrying cannot help until the user
    /// allows it in Settings, but it is cheap, so the policy still retries.
    case localNetworkDenied
    /// The Mac and this app speak incompatible protocol or app versions.
    case incompatible
    /// The Mac refused the call for this device's permission.
    case forbidden
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

  /// Whether reconnecting with backoff can plausibly succeed. A version
  /// mismatch needs an update and a missing key needs re-pairing.
  var isRetryable: Bool {
    switch kind {
    case .incompatible, .missingKey: return false
    case .notFound, .localNetworkDenied, .forbidden, .streamEnded, .other: return true
    }
  }

  static let streamEnded = RemoteFailure(.streamEnded, "The connection to your Mac ended.")
  static let missingKey = RemoteFailure(
    .missingKey, "This pairing's key is missing on this device. Pair with your Mac again.")

  /// Classifies any error thrown by the remote stack.
  init(_ error: Error) {
    switch error {
    case let failure as RemoteFailure:
      self = failure
    case let client as RemoteRPCClient.ClientError:
      self = Self.classify(client)
    case RemoteHandshake.HandshakeError.timedOut:
      self.init(.other, "Your Mac did not answer in time.")
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
    case .ipc(let ipc):
      return RemoteFailure(.other, ipc.displayMessage)
    case .timeout:
      return RemoteFailure(.other, "Your Mac did not answer in time.")
    case .connectionClosed:
      return .streamEnded
    case .noResult, .decodeFailed:
      return RemoteFailure(.other, "Your Mac sent a reply this app does not understand.")
    case .writeFailed:
      return RemoteFailure(.other, "The connection to your Mac was interrupted.")
    }
  }
}
