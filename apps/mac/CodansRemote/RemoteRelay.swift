import CodansIPC
import CryptoKit
import Foundation
import Security

/// The relay that carries gateway connections from outside the LAN. It
/// pairs a phone's WebSocket with the Mac's and forwards bytes; the TLS-PSK
/// session runs end to end inside, so the relay sees only ciphertext and
/// these routing credentials. See the design doc's Phase 3 (D55–D60).
public enum RemoteRelay {
  /// The production relay.
  public static let defaultURL = "wss://relay.codans.dev"

  /// Under Cloudflare's 100 s idle cut-off.
  public static let pingInterval: TimeInterval = 25

  /// How long the Mac has to answer an `incoming` session.
  public static let sessionTimeout: TimeInterval = 10

  // MARK: - Credentials

  /// The phone's bearer token for the relay, derived from its pairing key
  /// so a paired phone needs no new secret: HMAC-SHA256(psk, label).
  public static func phoneToken(psk: Data) -> String {
    let code = HMAC<SHA256>.authenticationCode(
      for: Data("codans-relay-token-v1".utf8), using: SymmetricKey(data: psk))
    return Data(code).base64URLEncodedString()
  }

  /// What the relay stores and compares instead of a token or secret:
  /// base64url(SHA-256(UTF-8 bytes of the bearer string)).
  public static func hash(ofBearer bearer: String) -> String {
    Data(SHA256.hash(data: Data(bearer.utf8))).base64URLEncodedString()
  }

  /// A new Mac secret: 32 random bytes.
  public static func newMacSecret() -> Data {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
    return Data(bytes)
  }

  /// The Mac's bearer string for its secret.
  public static func bearer(forMacSecret secret: Data) -> String {
    secret.base64URLEncodedString()
  }

  /// The Mac's relay ID, derived from its secret so only the secret needs
  /// storing: the first 16 bytes of SHA-256(label ‖ secret), base64url.
  /// It reveals nothing about the secret.
  public static func macID(forMacSecret secret: Data) -> String {
    var input = Data("codans-relay-mac-id-v1".utf8)
    input.append(secret)
    return Data(SHA256.hash(data: input).prefix(16)).base64URLEncodedString()
  }

  // MARK: - Endpoints

  public static func controlURL(_ relay: RemoteRelayCoordinates) -> URL? {
    endpoint(relay, "/v1/mac/\(relay.macID)/control")
  }

  public static func sessionURL(_ relay: RemoteRelayCoordinates, session: String) -> URL? {
    guard session.allSatisfy(isURLSafe) else { return nil }
    return endpoint(relay, "/v1/mac/\(relay.macID)/session/\(session)")
  }

  public static func connectURL(_ relay: RemoteRelayCoordinates) -> URL? {
    endpoint(relay, "/v1/connect/\(relay.macID)")
  }

  /// A WebSocket upgrade request carrying `bearer`.
  public static func request(_ url: URL, bearer: String) -> URLRequest {
    var request = URLRequest(url: url, timeoutInterval: sessionTimeout + 5)
    request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
    return request
  }

  private static func endpoint(_ relay: RemoteRelayCoordinates, _ path: String) -> URL? {
    guard relay.macID.allSatisfy(isURLSafe), var components = URLComponents(string: relay.url),
      components.scheme == "wss" || components.scheme == "ws"
    else { return nil }
    let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
    components.path = base + path
    return components.url
  }

  private static func isURLSafe(_ character: Character) -> Bool {
    character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
  }
}
