import Foundation
import Security

/// Everything a phone needs to reach and authenticate to one Mac gateway,
/// shown on the Mac as a QR code and as copyable text:
/// `codans-pair:` + base64url(JSON). The payload *is* a credential — it
/// carries the device's pre-shared key.
///
/// `deviceID` and `pskIdentity` are separate so the TLS identity format can
/// change without renaming devices.
public struct PairingPayload: Codable, Equatable, Sendable {
  public static let currentVersion = 1
  public static let urlScheme = "codans-pair"
  public static let keyLength = 32

  public let version: Int
  /// Bonjour service name of the gateway at pairing time.
  public let serviceName: String
  public let deviceID: UUID
  public let pskIdentity: String
  public let psk: Data
  /// `BuildChannel.slug` of the Mac build that issued the payload.
  public let channel: String

  public init(
    serviceName: String,
    deviceID: UUID,
    pskIdentity: String,
    psk: Data,
    channel: String,
    version: Int = PairingPayload.currentVersion
  ) {
    self.version = version
    self.serviceName = serviceName
    self.deviceID = deviceID
    self.pskIdentity = pskIdentity
    self.psk = psk
    self.channel = channel
  }

  public var credential: RemoteTLS.PSKCredential {
    RemoteTLS.PSKCredential(identity: pskIdentity, key: psk)
  }

  public enum DecodingError: Error, Equatable, Sendable {
    case wrongPrefix
    case malformed
    /// Issued by a newer (or unknown) codans; the user should update.
    case unsupportedVersion(Int)
    case invalidKeyLength(Int)
    case emptyIdentity
    case channelMismatch(expected: String, actual: String)
  }

  private enum CodingKeys: String, CodingKey {
    case version = "v"
    case serviceName, deviceID, pskIdentity, psk, channel
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    version = try c.decode(Int.self, forKey: .version)
    serviceName = try c.decode(String.self, forKey: .serviceName)
    deviceID = try c.decode(UUID.self, forKey: .deviceID)
    pskIdentity = try c.decode(String.self, forKey: .pskIdentity)
    let keyString = try c.decode(String.self, forKey: .psk)
    guard let key = Data(base64URLEncoded: keyString) else {
      throw Swift.DecodingError.dataCorruptedError(
        forKey: .psk, in: c, debugDescription: "psk is not base64url")
    }
    psk = key
    channel = try c.decode(String.self, forKey: .channel)
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(version, forKey: .version)
    try c.encode(serviceName, forKey: .serviceName)
    try c.encode(deviceID, forKey: .deviceID)
    try c.encode(pskIdentity, forKey: .pskIdentity)
    try c.encode(psk.base64URLEncodedString(), forKey: .psk)
    try c.encode(channel, forKey: .channel)
  }

  /// `codans-pair:<base64url(JSON)>`.
  public func encodedString() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return "\(Self.urlScheme):" + (try encoder.encode(self)).base64URLEncodedString()
  }

  /// Parses and validates a pairing code as scanned or pasted. Surrounding
  /// whitespace is ignored. `expectedChannel`, when given, must match the
  /// payload's channel.
  public static func decode(_ string: String, expectedChannel: String? = nil) throws -> PairingPayload {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = "\(urlScheme):"
    guard trimmed.lowercased().hasPrefix(prefix) else { throw DecodingError.wrongPrefix }
    let body = String(trimmed.dropFirst(prefix.count))
    guard let json = Data(base64URLEncoded: body) else { throw DecodingError.malformed }

    // Check the version before decoding the rest so a future payload shape
    // reports "update the app" instead of a generic parse failure.
    struct VersionProbe: Decodable {
      let v: Int
    }
    guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: json) else {
      throw DecodingError.malformed
    }
    guard probe.v == currentVersion else { throw DecodingError.unsupportedVersion(probe.v) }

    let payload: PairingPayload
    do {
      payload = try JSONDecoder().decode(PairingPayload.self, from: json)
    } catch {
      throw DecodingError.malformed
    }
    guard payload.psk.count == keyLength else {
      throw DecodingError.invalidKeyLength(payload.psk.count)
    }
    guard !payload.pskIdentity.isEmpty else { throw DecodingError.emptyIdentity }
    if let expectedChannel, payload.channel != expectedChannel {
      throw DecodingError.channelMismatch(expected: expectedChannel, actual: payload.channel)
    }
    return payload
  }

  /// A fresh random pre-shared key. Keys are never derived from anything a
  /// human types.
  public static func generateKey() throws -> Data {
    var bytes = [UInt8](repeating: 0, count: keyLength)
    let status = SecRandomCopyBytes(kSecRandomDefault, keyLength, &bytes)
    guard status == errSecSuccess else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    return Data(bytes)
  }
}
