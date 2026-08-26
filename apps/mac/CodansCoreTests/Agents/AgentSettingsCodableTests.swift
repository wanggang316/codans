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
}
