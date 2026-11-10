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

/// Reads the Agent Skills a profile's launched agent can call: its Skill
/// Location resolved against the profile's home and environment and the
/// directory the agent starts in, then scanned off the main actor.
nonisolated struct AgentSkillClient: Sendable {
  /// `projectStart` is `nil` when the agent has no local project directory.
  /// `newWorktree` is set when the agent starts in a worktree that does not
  /// exist yet: `projectStart` is then the main checkout, and the project
  /// files are read from a view of the new worktree (`NewWorktreeFiles`).
  var load:
    @Sendable (_ profile: AgentProfile, _ projectStart: URL?, _ newWorktree: NewWorktreeSource?)
      async -> [AgentSkillEntry]
  /// The skills in a remote project on `host`: `projectStart` is a path on
  /// the host, `createsWorktree` is `true` when the agent starts in a
  /// worktree that does not exist yet. Fails when the host cannot be read.
  var loadRemote:
    @Sendable (_ profile: AgentProfile, _ host: RemoteHost, _ projectStart: String?, _ createsWorktree: Bool)
      async -> Result<[AgentSkillEntry], RemoteSkillReadError>
}

extension AgentSkillClient: DependencyKey {
  static let liveValue = AgentSkillClient(
    load: { profile, projectStart, newWorktree in
      let precedence = profile.descriptor.skillLocation.precedence
      guard let projectStart, let newWorktree else {
        return await SkillScanner.scan(
          SkillLocationResolver.directories(for: profile, projectStart: projectStart),
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
        SkillLocationResolver.directories(for: profile, projectStart: view, projectStartExists: false),
        precedence: precedence)
    },
    loadRemote: { profile, host, projectStart, createsWorktree in
      do throws(RemoteSkillReadError) {
        return .success(
          try await RemoteSkillReader(host: host).load(
            profile: profile, projectStart: projectStart, createsWorktree: createsWorktree))
      } catch {
        return .failure(error)
      }
    }
  )

  /// Empty rather than unimplemented: every feature that opens a composer
  /// loads skills, and most tests do not care which.
  static let testValue = AgentSkillClient(load: { _, _, _ in [] }, loadRemote: { _, _, _, _ in .success([]) })
}
