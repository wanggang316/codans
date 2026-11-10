import Foundation
import Network
import Testing

@testable import CodansRemote

struct PairingPayloadTests {
  private func payload(key: Data? = nil, identity: String = "7C1E-identity", channel: String = "codans")
    throws -> PairingPayload
  {
    PairingPayload(
      serviceName: "Gump's MacBook Pro",
      deviceID: UUID(),
      pskIdentity: identity,
      psk: try key ?? PairingPayload.generateKey(),
      channel: channel
    )
  }

  /// Encodes arbitrary JSON the way `encodedString()` does, for payloads the
  /// type itself refuses to produce.
  private func code(json: String) -> String {
    "codans-pair:" + Data(json.utf8).base64URLEncodedString()
  }

  @Test
  func roundTripsThroughTheURLForm() throws {
    let original = try payload()
    let encoded = try original.encodedString()
    #expect(encoded.hasPrefix("codans-pair:"))
    #expect(!encoded.contains("+") && !encoded.contains("/") && !encoded.contains("="))
    #expect(try PairingPayload.decode(encoded) == original)
    #expect(try PairingPayload.decode("  \(encoded)\n", expectedChannel: "codans") == original)
  }

  @Test
  func keyIsBase64URLOnTheWire() throws {
    let key = Data((0..<32).map { UInt8(255 - $0) })
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try payload(key: key)))
    let dict = try #require(json as? [String: Any])
    #expect(dict["psk"] as? String == key.base64URLEncodedString())
    #expect(dict["v"] as? Int == 1)
  }

  @Test
  func rejectsWrongPrefix() throws {
    let body = try payload().encodedString().dropFirst("codans-pair:".count)
    #expect(throws: PairingPayload.DecodingError.wrongPrefix) {
      try PairingPayload.decode("https://example.com/\(body)")
    }
  }

  @Test
  func rejectsGarbage() {
    #expect(throws: PairingPayload.DecodingError.malformed) {
      try PairingPayload.decode("codans-pair:not*base64")
    }
    #expect(throws: PairingPayload.DecodingError.malformed) {
      try PairingPayload.decode(code(json: #"{"v": 1, "serviceName": "x"}"#))
    }
  }

  @Test
  func rejectsUnknownVersion() {
    #expect(throws: PairingPayload.DecodingError.unsupportedVersion(2)) {
      try PairingPayload.decode(code(json: #"{"v": 2, "whatever": true}"#))
    }
  }

  @Test
  func rejectsShortKey() throws {
    let short = try payload(key: Data(repeating: 1, count: 16)).encodedString()
    #expect(throws: PairingPayload.DecodingError.invalidKeyLength(16)) {
      try PairingPayload.decode(short)
    }
  }

  @Test
  func rejectsEmptyIdentity() throws {
    let encoded = try payload(identity: "").encodedString()
    #expect(throws: PairingPayload.DecodingError.emptyIdentity) {
      try PairingPayload.decode(encoded)
    }
  }

  @Test
  func rejectsChannelMismatch() throws {
    let encoded = try payload(channel: "codans-dev").encodedString()
    #expect(throws: PairingPayload.DecodingError.channelMismatch(expected: "codans", actual: "codans-dev")) {
      try PairingPayload.decode(encoded, expectedChannel: "codans")
    }
  }

  @Test
  func generatedKeysAreFullLengthAndDistinct() throws {
    let a = try PairingPayload.generateKey()
    let b = try PairingPayload.generateKey()
    #expect(a.count == 32)
    #expect(a != b)
  }

  @Test
  func base64URLRejectsStandardAlphabet() {
    #expect(Data(base64URLEncoded: "ab+/") == nil)
    #expect(Data(base64URLEncoded: "a") == nil)
    #expect(Data(base64URLEncoded: "_-8") == Data([0xFF, 0xEF]))
  }
}

struct RemoteBonjourTests {
  @Test
  func txtRecordRoundTrips() {
    let record = RemoteBonjour.txtRecord(channel: "codans-dev", protocolMajor: 1)
    #expect(RemoteBonjour.channel(in: record) == "codans-dev")
    #expect(RemoteBonjour.protocolMajor(in: record) == 1)
    #expect(RemoteBonjour.serviceType == "_codans._tcp")
  }

  @Test
  func serviceNameMarksNonReleaseChannels() {
    #expect(RemoteBonjour.serviceName(hostName: "Mac", channel: "codans") == "Mac")
    #expect(RemoteBonjour.serviceName(hostName: "Mac", channel: "codans-dev") == "Mac (codans-dev)")
  }
}
