import Network
import Testing

@testable import CodansMobile

/// Which advertisements the phone tries, and in what order. The paired
/// gateway is "Studio (codans-dev)" on the `codans-dev` channel.
struct GatewayDiscoveryTests {
  @Test
  func pairedNameComesFirstThenItsConflictRenames() {
    // After a crash mDNS keeps the old record; the relaunched app is renamed.
    let offers = [
      Self.offer("Studio (codans-dev) (2)"),
      Self.offer("Studio (codans-dev)"),
      Self.offer("Other Mac (codans-dev)"),
    ]
    #expect(Self.names(offers) == ["Studio (codans-dev)", "Studio (codans-dev) (2)"])
  }

  @Test
  func renamedMacFallsBackToEveryGatewayOnTheChannel() {
    let offers = [Self.offer("Laptop (codans-dev)"), Self.offer("Desk (codans-dev)")]
    #expect(Self.names(offers) == ["Desk (codans-dev)", "Laptop (codans-dev)"])
  }

  @Test
  func otherChannelsAreNeverCandidates() {
    let offers = [
      Self.offer("Studio", channel: "codans"),
      Self.offer("Studio (codans-dev)", channel: nil),
    ]
    #expect(Self.names(offers).isEmpty)
  }

  private static func offer(_ name: String, channel: String? = "codans-dev") -> GatewayDiscovery.Offer {
    GatewayDiscovery.Offer(
      name: name, channel: channel, endpoint: .service(name: name, type: "_codans._tcp", domain: "local.", interface: nil))
  }

  private static func names(_ offers: [GatewayDiscovery.Offer]) -> [String] {
    GatewayDiscovery.candidates(for: Fixtures.gateway, in: offers).compactMap { endpoint in
      if case .service(let name, _, _, _) = endpoint { return name }
      return nil
    }
  }
}
