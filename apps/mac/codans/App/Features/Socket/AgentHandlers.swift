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
  /// The Agents View's per-pane runtime state. `nil` (tests, headless
  /// harness) makes `listStates` / `wait` unsupported.
  private let stateStore: @MainActor () -> AgentStateStore?
  /// Shared with `HierarchyHandlers` so `agent.listStates` prints the same
  /// `p<n>` handles `tree` does.
  private let handleRegistry: TargetHandleRegistry
  private let focusedPane: @MainActor () -> PaneID?
  /// Poll cadence of `wait`; injected so tests can shorten it.
  private let waitPollMillis: Int

  init(
    settings: SettingsStore,
    hierarchy: HierarchyClient,
    installation: AgentInstallationStore?,
    stateStore: @escaping @MainActor () -> AgentStateStore? = { nil },
    handleRegistry: TargetHandleRegistry = TargetHandleRegistry(),
    focusedPane: @escaping @MainActor () -> PaneID? = { nil },
    waitPollMillis: Int = 200
  ) {
    self.settings = settings
    self.hierarchy = hierarchy
    self.installation = installation
    self.stateStore = stateStore
    self.handleRegistry = handleRegistry
    self.focusedPane = focusedPane
    self.waitPollMillis = waitPollMillis
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
    let profile = try AgentProfileSelector.resolveLaunchable(
      selector: request.profile,
      agentToken: request.agent,
      in: settings.settings.agents
    )
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

  // MARK: - listStates

  /// `agent.listStates` — every agent-bearing pane with its derived runtime
  /// state, in hierarchy order: what the Agents View lists, for scripts.
  func listStates() throws -> IPC.AgentStateListResponse {
    guard let stateStore = stateStore() else {
      throw IPCError.unsupported(reason: "agent state is not available in this build")
    }
    let catalog = hierarchy.snapshot()
    handleRegistry.sync(with: catalog)
    let handles = handleRegistry.snapshot()
    let focused = focusedPane()
    let formatter = ISO8601DateFormatter()
    var rows: [IPC.AgentStateEntry] = []
    for project in catalog.projects {
      for worktree in project.worktrees {
        for tab in worktree.tabs {
          for pane in tab.panes {
            guard let entry = stateStore.entries[pane.id] else { continue }
            rows.append(
              IPC.AgentStateEntry(
                paneID: pane.id.description,
                handle: handles.panes[pane.id.description].map { "p\($0)" },
                agent: entry.kind.rawValue,
                agentName: entry.kind.displayName,
                state: entry.state.rawValue,
                since: formatter.string(from: entry.lastTransitionAt),
                sessionID: entry.sessionID ?? pane.agentSessionID,
                title: stateStore.title(for: pane.id),
                projectID: project.id.description,
                projectName: project.name,
                worktreeID: worktree.id.description,
                worktreeName: worktree.name,
                tabID: tab.id.description,
                tabTitle: tab.name ?? tab.cachedDisplayTitle,
                isFocused: focused == pane.id
              ))
          }
        }
      }
    }
    return IPC.AgentStateListResponse(agents: rows)
  }

  // MARK: - wait

  static let maxWaitMillis = 600_000

  /// `agent.wait` — poll the state store until the pane's agent satisfies
  /// `until` or the deadline passes. Resolves on the server so the caller
  /// needs no loop of its own; the response says whether it was satisfied.
  func wait(_ request: IPC.AgentWaitRequest) async throws -> IPC.AgentWaitResponse {
    guard let stateStore = stateStore() else {
      throw IPCError.unsupported(reason: "agent state is not available in this build")
    }
    guard hierarchy.snapshot().pane(request.paneID) != nil else {
      throw IPCError.notFound(kind: "pane", id: request.paneID.description)
    }
    let timeout = min(max(request.timeoutMillis, 1), Self.maxWaitMillis)
    let start = ContinuousClock.now
    let baseline = stateStore.entries[request.paneID]
    while true {
      let entry = stateStore.entries[request.paneID]
      let paneExists = hierarchy.snapshot().pane(request.paneID) != nil
      let satisfied: Bool
      switch request.until {
      case .idle: satisfied = entry?.state == .idle
      case .working: satisfied = entry?.state == .working
      case .error: satisfied = entry?.state == .error
      case .blocked: satisfied = entry?.state == .blocked
      case .finished: satisfied = entry?.state == .finished
      case .changed: satisfied = entry?.state != baseline?.state || entry?.kind != baseline?.kind
      case .exit: satisfied = entry == nil || !paneExists
      }
      let elapsed = ContinuousClock.now - start
      let waitedMs = Int(elapsed / .milliseconds(1))
      if satisfied || waitedMs >= timeout {
        return IPC.AgentWaitResponse(
          paneID: request.paneID.description,
          until: request.until.rawValue,
          satisfied: satisfied,
          state: entry?.state.rawValue,
          previousState: baseline?.state.rawValue,
          agent: (entry ?? baseline)?.kind.rawValue,
          waitedMs: waitedMs
        )
      }
      try? await Task.sleep(for: .milliseconds(min(waitPollMillis, timeout - waitedMs)))
    }
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
  static var agentTokens: String {
    AgentKind.allCases.map(\.rawValue).joined(separator: ", ")
  }

  /// `resolve` for a caller about to launch: parses the `--agent` token and
  /// refuses a disabled profile with `conflict` — disabling is the user's way
  /// of taking a preset out of circulation, and a CLI launch must not bypass
  /// that.
  static func resolveLaunchable(
    selector: String?,
    agentToken: String?,
    in agents: AgentSettings
  ) throws -> AgentProfile {
    let agent: AgentKind?
    if let agentToken {
      guard let kind = AgentKind(token: agentToken) else {
        throw IPCError.invalidParams(
          message: "unknown agent \"\(agentToken)\"; expected one of: \(agentTokens)",
          path: ["agent"])
      }
      agent = kind
    } else {
      agent = nil
    }
    let profile = try resolve(selector: selector, agent: agent, in: agents)
    guard profile.isEnabled else {
      throw IPCError.conflict(
        reason: "profile \"\(profile.displayName)\" is disabled; enable it in Settings > Agents")
    }
    return profile
  }

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
