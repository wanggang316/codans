import Foundation
import Testing

@testable import TouchCode

/// Pins the contract between the vendored web bundle's `manifest.json` and
/// the Swift bridge's `DiffBridgeProtocol.version`. Drift here means the JS
/// renderer expects a different envelope shape than the host emits — every
/// outbound message would surface as `protocol_mismatch` at runtime.
@MainActor
struct DiffWebAssetsManifestTests {

  private struct Manifest: Decodable {
    let protocolVersion: Int
  }

  @Test
  func manifestProtocolVersionMatchesBridgeExpectation() throws {
    let url = try #require(
      Bundle.main.url(forResource: "manifest", withExtension: "json"),
      "manifest.json must ship in the app bundle's Resources"
    )
    let data = try Data(contentsOf: url)
    let manifest = try JSONDecoder().decode(Manifest.self, from: data)
    #expect(manifest.protocolVersion == DiffBridgeProtocol.version)
  }
}
