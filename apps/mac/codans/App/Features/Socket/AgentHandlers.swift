import CodansCore
import CodansIPC
import Foundation

/// Server-side handler for the `agent.*` IPC surface — the launch presets
/// in `Settings.agents`, exposed so a script or an agent can list and start
/// profiles the same way the toolbar Agents menu does.
///
/// Holds the `SettingsStore` (persisted truth), the `HierarchyClient` (to
/// validate the target Project and to run the launch), and the app-scoped
/// `AgentInstallationStore` (advisory "is this CLI on PATH" bit).
@MainActor
final class AgentHandlers {
  private let settings: SettingsStore
  private let hierarchy: HierarchyClient
  private let installation: AgentInstallationStore?

  init(settings: SettingsStore, hierarchy: HierarchyClient, installation: AgentInstallationStore?) {
    self.settings = settings
    self.hierarchy = hierarchy
    self.installation = installation
  }

  // MARK: - listProfiles

  /// `agent.listProfiles` — every profile in list order, enabled or not. The
  /// caller filters; the CLI text renderer dims disabled rows.
  func listProfiles() -> IPC.AgentProfileListResponse {
    let profiles = settings.settings.agents.profiles.map { profile in
      IPC.AgentProfileSummary(
        id: profile.id,
        name: profile.displayName,
        agent: profile.kind.rawValue,
        agentName: profile.kind.displayName,
        isEnabled: profile.isEnabled,
        isInstalled: installation.flatMap { $0.hasScanned ? $0.isInstalled(profile.kind) : nil },
        supportsPrompt: profile.descriptor.supportsInitialPrompt,
        command: AgentLaunchCommand.render(profile: profile)
      )
    }
    return IPC.AgentProfileListResponse(profiles: profiles)
  }

  // MARK: - launch

  /// `agent.launch` — resolve the profile, then run it through the same
  /// pipeline the toolbar uses. A disabled profile is refused with
  /// `conflict`: disabling is the user's way of taking a preset out of
  /// circulation, and a CLI launch must not bypass that.
  func launch(_ request: IPC.AgentLaunchRequest) async throws -> IPC.AgentLaunchResponse {
    guard hierarchy.kind(request.projectID) != nil else {
      throw IPCError.notFound(kind: "project", id: request.projectID.description)
    }
    let agent: AgentKind?
    if let token = request.agent {
      guard let kind = AgentKind(token: token) else {
        throw IPCError.invalidParams(
          message: "unknown agent \"\(token)\"; expected one of: \(Self.agentTokens)",
          path: ["agent"])
      }
      agent = kind
    } else {
      agent = nil
    }
    let profile = try AgentProfileSelector.resolve(
      selector: request.profile,
      agent: agent,
      in: settings.settings.agents
    )
    guard profile.isEnabled else {
      throw IPCError.conflict(
        reason: "profile \"\(profile.displayName)\" is disabled; enable it in Settings > Agents")
    }
    if let prompt = request.prompt, !prompt.isEmpty, !profile.descriptor.supportsInitialPrompt {
      throw IPCError.unsupported(
        reason: "\(profile.kind.displayName) cannot start with a prompt; launch it without --prompt")
    }
    let outcome: AgentLaunchOutcome
    do {
      outcome = try await hierarchy.launchAgent(
        AgentLaunchSpec(
          profile: profile,
          projectID: request.projectID,
          worktreeID: request.worktreeID,
          prompt: request.prompt,
          target: request.target,
          direction: request.direction,
          focus: request.focus
        )
      )
    } catch let error as RunScriptError {
      throw Self.map(error)
    }
    return IPC.AgentLaunchResponse(
      profileID: outcome.profile.id,
      profileName: outcome.profile.displayName,
      agent: outcome.profile.kind.rawValue,
      command: outcome.command,
      tabID: outcome.tabID,
      paneID: outcome.paneID
    )
  }

  static var agentTokens: String {
    AgentKind.allCases.map(\.rawValue).joined(separator: ", ")
  }

  static func map(_ error: RunScriptError) -> IPCError {
    switch error {
    case .unknownScript(let id):
      return .notFound(kind: "profile", id: id.uuidString)
    case .missingWorktree(let id):
      return .notFound(kind: "worktree", id: id.description)
    case .missingProject(let id):
      return .notFound(kind: "project", id: id.description)
    }
  }
}

/// Picks the `AgentProfile` a CLI selector names. Shared by `agent.launch`
/// and the handoff receiver launch so both spell "which profile" the same
/// way:
///
/// 1. `selector` is a UUID → that profile (any agent).
/// 2. `selector` matches a display name, case-insensitively → that profile;
///    ambiguous names are an error rather than a silent first-match.
/// 3. No selector, `agent` given → the first *enabled* profile for that
///    agent, else the agent's bare preset (transient, never persisted).
/// 4. Nothing given → the first enabled profile in list order.
nonisolated enum AgentProfileSelector {
  static func resolve(
    selector: String?,
    agent: AgentKind?,
    in agents: AgentSettings
  ) throws -> AgentProfile {
    if let selector, !selector.trimmingCharacters(in: .whitespaces).isEmpty {
      let wanted = selector.trimmingCharacters(in: .whitespaces)
      if let id = UUID(uuidString: wanted) {
        guard let profile = agents.profile(id: id) else {
          throw IPCError.notFound(kind: "profile", id: wanted)
        }
        try checkAgent(profile, agent: agent)
        return profile
      }
      let matches = agents.profiles.filter {
        $0.displayName.caseInsensitiveCompare(wanted) == .orderedSame
          && (agent == nil || $0.kind == agent)
      }
      switch matches.count {
      case 0:
        throw IPCError.notFound(kind: "profile", id: wanted)
      case 1:
        return matches[0]
      default:
        throw IPCError.conflict(
          reason: "profile name \"\(wanted)\" matches \(matches.count) profiles; pass its id")
      }
    }
    if let agent {
      return agents.enabledProfiles.first { $0.kind == agent } ?? AgentProfile(kind: agent)
    }
    guard let first = agents.enabledProfiles.first else {
      throw IPCError.notFound(kind: "profile", id: "(no enabled profiles)")
    }
    return first
  }

  private static func checkAgent(_ profile: AgentProfile, agent: AgentKind?) throws {
    guard let agent, profile.kind != agent else { return }
    throw IPCError.conflict(
      reason:
        "profile \"\(profile.displayName)\" launches \(profile.kind.displayName), not \(agent.displayName)"
    )
  }
}
