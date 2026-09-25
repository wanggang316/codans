import CryptoKit
import Foundation

/// The first frame a client sends after the TLS handshake, before any IPC
/// traffic. It names the device and proves possession of that device's key
/// for *this* session: `HMAC-SHA256(key, channelBinding)`.
///
/// Needed because the TLS-PSK server holds every paired key and
/// Network.framework does not say which identity a peer used. Without the
/// proof, a device paired read-only could handshake with its own key and
/// then claim to be an interactive device. The channel binding is the TLS
/// exporter, so a proof cannot be replayed on another connection.
public struct RemotePeerProof: Codable, Equatable, Sendable {
  public static let currentVersion = 1

  public let version: Int
  public let identity: String
  public let mac: Data

  private enum CodingKeys: String, CodingKey {
    case version = "v"
    case identity, mac
  }

  public init(identity: String, mac: Data, version: Int = RemotePeerProof.currentVersion) {
    self.version = version
    self.identity = identity
    self.mac = mac
  }

  /// Proof for `credential` over the session's channel binding.
  public static func make(credential: RemoteTLS.PSKCredential, channelBinding: Data) -> RemotePeerProof {
    let code = HMAC<SHA256>.authenticationCode(
      for: channelBinding, using: SymmetricKey(data: credential.key))
    return RemotePeerProof(identity: credential.identity, mac: Data(code))
  }

  /// Constant-time check against the key the server holds for `identity`.
  public func isValid(key: Data, channelBinding: Data) -> Bool {
    version == Self.currentVersion
      && HMAC<SHA256>.isValidAuthenticationCode(
        mac, authenticating: channelBinding, using: SymmetricKey(data: key))
  }
}
