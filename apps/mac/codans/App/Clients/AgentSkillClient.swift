import CodansCore
import ComposableArchitecture
import Foundation

/// What a new worktree copies from the main checkout besides the tracked
/// files.
nonisolated struct WorktreeCopyOptions: Equatable, Sendable {
  var copyIgnored: Bool
  var copyUntracked: Bool
}

/// Reads the Agent Skills a profile's launched agent can call: its Skill
/// Location resolved against the profile's home and environment and the
/// directory the agent starts in, then scanned off the main actor.
nonisolated struct AgentSkillClient: Sendable {
  /// `projectStart` is `nil` when the agent has no local project directory.
  /// `newWorktree` is set when the agent starts in a worktree that does not
  /// exist yet: `projectStart` is then the main checkout, and only the
  /// project files the copy options copy are read.
  var load:
    @Sendable (_ profile: AgentProfile, _ projectStart: URL?, _ newWorktree: WorktreeCopyOptions?)
      async -> [AgentSkillEntry]
}

extension AgentSkillClient: DependencyKey {
  static let liveValue = AgentSkillClient(
    load: { profile, projectStart, newWorktree in
      var exclusion: ProjectFileExclusion?
      if let projectStart, let newWorktree {
        exclusion = await NewWorktreeFiles.exclusion(
          repoRoot: projectStart, copyIgnored: newWorktree.copyIgnored,
          copyUntracked: newWorktree.copyUntracked)
      }
      return await SkillScanner.scan(
        SkillLocationResolver.directories(for: profile, projectStart: projectStart, excluding: exclusion),
        precedence: profile.descriptor.skillLocation.precedence, excluding: exclusion)
    }
  )

  /// Empty rather than unimplemented: every feature that opens a composer
  /// loads skills, and most tests do not care which.
  static let testValue = AgentSkillClient(load: { _, _, _ in [] })
}
