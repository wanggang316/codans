import CodansCore
import ComposableArchitecture
import Foundation

/// Reads the Agent Skills a profile's launched agent can call: its Skill
/// Location resolved against the profile's home and environment and the
/// directory the agent starts in, then scanned off the main actor.
nonisolated struct AgentSkillClient: Sendable {
  /// `projectStart` is `nil` when the agent has no local project directory.
  var load: @Sendable (_ profile: AgentProfile, _ projectStart: URL?) async -> [AgentSkillEntry]
}

extension AgentSkillClient: DependencyKey {
  static let liveValue = AgentSkillClient(
    load: { profile, projectStart in
      await SkillScanner.scan(
        SkillLocationResolver.directories(for: profile, projectStart: projectStart),
        precedence: profile.descriptor.skillLocation.precedence)
    }
  )

  /// Empty rather than unimplemented: every feature that opens a composer
  /// loads skills, and most tests do not care which.
  static let testValue = AgentSkillClient(load: { _, _ in [] })
}
