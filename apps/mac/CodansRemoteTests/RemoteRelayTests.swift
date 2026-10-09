import CodansIPC
import Foundation
import Testing

@testable import CodansRemote

struct RemoteRelayTests {
  // Vectors computed independently (Python hmac / hashlib); the relay
  // server hashes bearers the same way.

  @Test
  func phoneTokenIsHMACOfTheLabelUnderThePairingKey() {
    let token = RemoteRelay.phoneToken(psk: Data(0..<32))
    #expect(token == "Ph_ABOhBoltMNRnZdYlsLyVjTt3w0WzQCdup11b3zR8")
    #expect(RemoteRelay.phoneToken(psk: Data(repeating: 1, count: 32)) != token)
  }

  @Test
  func bearerHashIsSHA256OfTheBearerString() {
    #expect(
      RemoteRelay.hash(ofBearer: "Ph_ABOhBoltMNRnZdYlsLyVjTt3w0WzQCdup11b3zR8")
        == "WGVdiFz53N8LN8mPE0ZDGMNl_errf8yDR9-hd0lkQZM")
  }

  @Test
  func macIdentityDerivesFromTheSecret() {
    let secret = Data(repeating: 7, count: 32)
    #expect(RemoteRelay.bearer(forMacSecret: secret) == "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc")
    #expect(RemoteRelay.macID(forMacSecret: secret) == "wIBdABfYTK7_2kk2YvL52g")
    #expect(RemoteRelay.newMacSecret().count == 32)
    #expect(RemoteRelay.newMacSecret() != RemoteRelay.newMacSecret())
  }

  @Test
  func endpointsAppendToTheBaseURL() {
    let relay = RemoteRelayCoordinates(url: "wss://relay.example.dev", macID: "wIBdABfYTK7_2kk2YvL52g")
    #expect(
      RemoteRelay.controlURL(relay)?.absoluteString
        == "wss://relay.example.dev/v1/mac/wIBdABfYTK7_2kk2YvL52g/control")
    #expect(
      RemoteRelay.sessionURL(relay, session: "s-1_x")?.absoluteString
        == "wss://relay.example.dev/v1/mac/wIBdABfYTK7_2kk2YvL52g/session/s-1_x")
    #expect(
      RemoteRelay.connectURL(relay)?.absoluteString == "wss://relay.example.dev/v1/connect/wIBdABfYTK7_2kk2YvL52g")

    let local = RemoteRelayCoordinates(url: "ws://127.0.0.1:3050/", macID: "abc")
    #expect(RemoteRelay.connectURL(local)?.absoluteString == "ws://127.0.0.1:3050/v1/connect/abc")
  }

  @Test
  func endpointsRejectUnsafeInput() {
    let relay = RemoteRelayCoordinates(url: "wss://relay.example.dev", macID: "abc")
    #expect(RemoteRelay.sessionURL(relay, session: "../control") == nil)
    #expect(RemoteRelay.connectURL(RemoteRelayCoordinates(url: "wss://relay.example.dev", macID: "a/b")) == nil)
    #expect(RemoteRelay.connectURL(RemoteRelayCoordinates(url: "https://relay.example.dev", macID: "abc")) == nil)
  }

  @Test
  func requestsCarryTheBearer() throws {
    let url = try #require(URL(string: "wss://relay.example.dev/v1/connect/abc"))
    #expect(RemoteRelay.request(url, bearer: "t0k").value(forHTTPHeaderField: "Authorization") == "Bearer t0k")
  }

  @Test
  func pairingCodesCarryTheRelayAndOlderCodesStillDecode() throws {
    let relay = RemoteRelayCoordinates(url: "wss://relay.example.dev", macID: "wIBdABfYTK7_2kk2YvL52g")
    let payload = PairingPayload(
      serviceName: "Mac", deviceID: UUID(), pskIdentity: "id", psk: Data(0..<32), channel: "codans", relay: relay)
    #expect(try PairingPayload.decode(payload.encodedString()).relay == relay)

    let withoutRelay = PairingPayload(
      serviceName: "Mac", deviceID: UUID(), pskIdentity: "id", psk: Data(0..<32), channel: "codans")
    let code = try withoutRelay.encodedString()
    #expect(!code.isEmpty)
    #expect(try PairingPayload.decode(code).relay == nil)
  }

  @Test
  func helloFromAnOlderMacHasNoRelay() throws {
    let json =
      #"{"serverVersion":"1","appBundleVersion":"1","protocolMajor":1,"protocolMinor":2,"deprecatedMethods":[]}"#
    let hello = try JSONDecoder().decode(HelloResponse.self, from: Data(json.utf8))
    #expect(hello.relay == nil)
  }
}
