import CodansCore
import ComposableArchitecture
import Foundation

/// Where a new worktree's files come from: the tracked files of `ref`, and
/// the ignored and untracked files of the main checkout that the copy
/// options copy.
nonisolated struct NewWorktreeSource: Equatable, Sendable {
  /// The ref `wt` creates the worktree from, `nil` while the dialog has not
  /// resolved it.
  var ref: String?
  var copyIgnored: Bool
  var copyUntracked: Bool
}

/// The agent that runs in a pane now, as skill completion reads it.
nonisolated struct RunningAgent: Equatable, Sendable {
  var pid: Int32
  /// How it started: its argv (after the executable, or after the agent
  /// script of a wrapper such as `node`) and the environment that places
  /// its skills. `nil` when the kernel does not give its environment.
  var launch: SkillLaunch?
  /// Its current directory, `nil` when it cannot be read.
  var workingDirectory: URL?
}

/// Reads the Agent Skills a profile's launched agent can call: its Skill
/// Location resolved against the profile's home and environment and the
/// directory the agent starts in, then scanned off the main actor.
nonisolated struct AgentSkillClient: Sendable {
  /// `launch` is a profile (`SkillLaunch(profile:)`) or an agent that runs
  /// now. `projectStart` is `nil` when the agent has no local project directory.
  /// `newWorktree` is set when the agent starts in a worktree that does not
  /// exist yet: `projectStart` is then the main checkout, and the project
  /// files are read from a view of the new worktree (`NewWorktreeFiles`).
  var load:
    @Sendable (_ launch: SkillLaunch, _ projectStart: URL?, _ newWorktree: NewWorktreeSource?)
      async -> [AgentSkillEntry]
}

extension AgentSkillClient: DependencyKey {
  static let liveValue = AgentSkillClient(
    load: { launch, projectStart, newWorktree in
      let profile = launch.profile
      let precedence = profile.descriptor.skillLocation.precedence
      guard let projectStart, let newWorktree else {
        return await SkillScanner.scan(
          SkillLocationResolver.directories(for: launch, projectStart: projectStart),
          precedence: precedence)
      }
      // Without the new worktree's files, its project skills and the
      // project settings that turn plugins on or off are unknown: offer
      // the user skills only (ADR 0010).
      guard let ref = newWorktree.ref,
        let view = await NewWorktreeFiles.makeView(
          repoRoot: projectStart, ref: ref, copyIgnored: newWorktree.copyIgnored,
          copyUntracked: newWorktree.copyUntracked,
          paths: SkillLocationResolver.projectFilePaths(for: profile))
      else {
        return await SkillScanner.scan(
          SkillLocationResolver.userDirectories(for: profile), precedence: precedence)
      }
      defer { try? FileManager.default.removeItem(at: view) }
      return await SkillScanner.scan(
        SkillLocationResolver.directories(for: launch, projectStart: view, projectStartExists: false),
        precedence: precedence)
    }
  )

  /// Empty rather than unimplemented: every feature that opens a composer
  /// loads skills, and most tests do not care which.
  static let testValue = AgentSkillClient(load: { _, _, _ in [] })
}
