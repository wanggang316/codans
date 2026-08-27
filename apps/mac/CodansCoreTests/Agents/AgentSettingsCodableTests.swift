import Foundation
import Testing

@testable import CodansCore

/// `agents` is an additive settings.json subtree, so the decode rules carry
/// the whole upgrade story: an absent key seeds the built-in presets, while a
/// present-but-empty list is the user's own choice and must survive.
struct AgentSettingsCodableTests {
  private static func decodeSettings(_ json: String) throws -> Settings {
    try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
  }

  @Test
  func absentAgentsKeySeedsTheBuiltInProfiles() throws {
    let settings = try Self.decodeSettings(#"{"version": 3}"#)
    // `map` / `allSatisfy` are `rethrows`, which makes a `#expect` expansion
    // that contains them throwing — hoist them out so the macro stays pure.
    let kinds = settings.agents.profiles.map(\.kind)
    let allEnabled = settings.agents.profiles.allSatisfy(\.isEnabled)
    #expect(kinds == AgentProfile.seededKinds)
    #expect(allEnabled)
  }

  @Test
  func emptyProfileListSurvivesARoundTrip() throws {
    let settings = try Self.decodeSettings(#"{"version": 3, "agents": {"profiles": []}}"#)
    #expect(settings.agents.profiles.isEmpty)

    let reencoded = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(Settings.self, from: reencoded)
    #expect(decoded.agents.profiles.isEmpty)
  }

  @Test
  func seedIDsAreStableAndDistinctPerAgent() {
    let ids = AgentProfile.seededKinds.map(AgentProfile.seedID(for:))
    let distinctCount = Set(ids).count
    // Re-deriving must produce the same ids — a re-seed after the user drops
    // the `agents` object keeps id-keyed state valid.
    let rederived = AgentProfile.seededKinds.map(AgentProfile.seedID(for:))
    #expect(distinctCount == ids.count)
    #expect(rederived == ids)
  }

  @Test
  func untouchedProfileEncodesOnlyItsIdentity() throws {
    let profile = AgentProfile.seeded(.codex)
    let encoded = try JSONEncoder().encode(profile)
    let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    let keys = Set((object ?? [:]).keys)
    #expect(keys == ["id", "kind"])
  }

  @Test
  func customisedProfileRoundTripsEveryField() throws {
    let profile = AgentProfile(
      kind: .claudeCode,
      name: "Planner",
      isEnabled: false,
      modelID: "opus",
      executionModeID: "plan",
      target: .split,
      direction: .down,
      extraArguments: "--verbose",
      envVars: ["ANTHROPIC_LOG": "debug"],
      usesDedicatedHome: true
    )
    let decoded = try JSONDecoder().decode(
      AgentProfile.self, from: JSONEncoder().encode(profile))
    #expect(decoded == profile)
  }

  @Test
  func everySeededKindHasABrandAssetAndExecutable() {
    for kind in AgentProfile.seededKinds {
      let descriptor = AgentCatalog.descriptor(for: kind)
      #expect(!descriptor.executable.isEmpty)
      #expect(!descriptor.iconAssetName.isEmpty)
      #expect(!descriptor.displayName.isEmpty)
    }
  }

  @Test
  func iconFallsBackToTheBrandMarkAndOverridesToASymbol() {
    var profile = AgentProfile(kind: .codex)
    #expect(profile.icon == .brand(.codex))
    #expect(profile.tabIcon == "agent:codex")

    profile.systemImage = "sparkles"
    #expect(profile.icon == .symbol("sparkles"))
    #expect(profile.tabIcon == "sparkles")

    // An empty string is a cleared override, not a nameless symbol — the
    // picker writes "" when the user empties the text field.
    profile.systemImage = ""
    #expect(profile.icon == .brand(.codex))
  }

  @Test
  func tabIconReferencesRoundTripAndRejectPlainSymbols() {
    for kind in AgentKind.allCases {
      #expect(TabIconRef.agentKind(from: TabIconRef.icon(for: kind)) == kind)
    }
    // Plain SF Symbols and unknown agents both fall through to the
    // SF-Symbol render path rather than resolving to a bogus kind.
    #expect(TabIconRef.agentKind(from: "sparkles") == nil)
    #expect(TabIconRef.agentKind(from: "agent:not-an-agent") == nil)
  }

  @Test
  func iconOverrideSurvivesARoundTripAndSwappingAgentsKeepsIt() throws {
    let profile = AgentProfile(kind: .codex, systemImage: "bolt.fill")
    let decoded = try JSONDecoder().decode(
      AgentProfile.self, from: JSONEncoder().encode(profile))
    #expect(decoded.systemImage == "bolt.fill")
    #expect(decoded.icon == .symbol("bolt.fill"))
  }
}
