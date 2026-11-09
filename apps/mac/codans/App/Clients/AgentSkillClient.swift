import CodansCore
import ComposableArchitecture
import Foundation

/// Reads the Agent Skills a profile's launched agent can call: its Skill
/// Location (user and enabled plugin skills) resolved against the profile's
/// home and environment, then
/// scanned off the main actor.
nonisolated struct AgentSkillClient: Sendable {
  var load: @Sendable (_ profile: AgentProfile) async -> [AgentSkillEntry]
}

extension AgentSkillClient: DependencyKey {
  static let liveValue = AgentSkillClient(
    load: { profile in
      await SkillScanner.scan(for: profile)
    }
  )

  /// Empty rather than unimplemented: every feature that opens a composer
  /// loads skills, and most tests do not care which.
  static let testValue = AgentSkillClient(load: { _ in [] })
}
