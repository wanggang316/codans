import CodansCore
import CodansIPC
import Foundation
import os

/// The outgoing side of a handoff, resolved on the main actor from a pane id:
/// where the pane lives, the worktree root the artifact goes under, and the
/// agent codans currently sees in that pane.
nonisolated struct HandoffSource: Sendable, Equatable {
  let paneID: PaneID
  let projectID: ProjectID
  let worktreeID: WorktreeID
  let tabID: TabID
  let worktreePath: String
  /// Server projects keep their worktree on the remote host; the artifact
  /// cannot be written there from this process.
  let isRemote: Bool
  let agentKind: AgentKind?
  let sessionID: String?
  let paneTitle: String?
}

/// Server-side handler for the `handoff.*` IPC surface. Every dependency is
/// a closure so the transition logic is testable against a temporary
/// worktree with no runtime behind it:
///
/// - `resolveSource` maps the CLI's pane id to a `HandoffSource`;
/// - `readScreen` captures the pane's visible text for the session excerpt;
/// - `collectRepoState` asks git about the worktree (app tier owns
///   subprocesses, so this is injected rather than run by the store);
/// - `launch` starts the receiver through the shared agent pipeline;
/// - `typeKickoff` delivers the kickoff prompt to a receiver whose CLI takes
///   none as an argument, by typing it into the new pane once the agent is
///   up. It runs detached from the response.
///
/// The handler never focuses anything: a CLI handoff is headless and adds a
/// background tab. The in-app panel that asked for it jumps to the receiver
/// itself when the completion arrives through `registry`.
@MainActor
final class HandoffHandlers {
  typealias SourceResolver = @MainActor (PaneID) -> HandoffSource?
  typealias ScreenReader = @MainActor (PaneID) -> String?
  typealias RepoStateCollector = @Sendable (URL) async -> HandoffRepoState
  typealias Launcher = @MainActor (AgentLaunchSpec) async throws -> AgentLaunchOutcome
  typealias KickoffTyper = @MainActor (_ paneID: PaneID, _ agent: AgentKind, _ prompt: String) async -> Bool

  private let settings: SettingsStore
  private let resolveSource: SourceResolver
  private let readScreen: ScreenReader
  private let collectRepoState: RepoStateCollector
  private let launch: Launcher
  private let typeKickoff: KickoffTyper
  private let registry: HandoffRequestRegistry
  /// How this build spells its own CLI. The `--brief` guidance below is a
  /// command the agent will re-run, so it has to name the binary that
  /// answers on *this* app's socket.
  private let cli: String
  private let now: @Sendable () -> Date
  private let logger = Logger(subsystem: "com.gumpw.codans.ipc", category: "handoff")

  init(
    settings: SettingsStore,
    registry: HandoffRequestRegistry,
    resolveSource: @escaping SourceResolver,
    readScreen: @escaping ScreenReader = { _ in nil },
    collectRepoState: @escaping RepoStateCollector = { _ in .notGit },
    launch: @escaping Launcher,
    typeKickoff: @escaping KickoffTyper = { _, _, _ in false },
    cli: String = CLIInvocation.commandName,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.settings = settings
    self.registry = registry
    self.resolveSource = resolveSource
    self.readScreen = readScreen
    self.collectRepoState = collectRepoState
    self.launch = launch
    self.typeKickoff = typeKickoff
    self.cli = cli
    self.now = now
  }

  /// Human-readable receiver list for error text: every agent, since a
  /// receiver without a prompt argument gets its kickoff typed in.
  static var receiverTokens: String {
    AgentKind.allCases.map(\.rawValue).joined(separator: ", ")
  }

  // MARK: - save

  /// `handoff.save` — a checkpoint: install the briefing (archiving the one
  /// it replaces) and refresh generated context. No receiver, no launch.
  func save(_ request: IPC.HandoffRequest) async throws -> IPC.HandoffResponse {
    let source = try resolvedSource(request)
    let briefing = try preparedBriefing(request, command: "\(cli) handoff save --brief -")
    try authorize(request)

    let coordinator = HandoffCoordinator(
      store: HandoffStore(rootURL: URL(fileURLWithPath: source.worktreePath, isDirectory: true)))
    let session = sessionContext(for: source)
    // Lay the state directory out first so its ignore file is in place
    // before git status is read: a worktree from an earlier build, or one
    // that never had a hand-off, would otherwise list `.codans/` itself.
    try? coordinator.store.ensureLayout()
    let repo = await collectRepoState(coordinator.store.rootURL)
    let timestamp = now()
    let note = request.note
    let checkpoint: HandoffCoordinator.Checkpoint
    do {
      checkpoint = try await Task.detached {
        try coordinator.checkpoint(
          outgoing: source.agentKind, session: session, repo: repo,
          briefing: briefing, note: note, now: timestamp
        )
      }.value
    } catch {
      throw IPCError.internal("failed to save handoff: \(error)")
    }
    registry.publish(
      HandoffCompletion(
        action: .save, sourcePaneID: source.paneID, receiver: nil,
        briefing: checkpoint.briefing, launched: nil, requestID: request.requestID
      )
    )
    return IPC.HandoffResponse(
      action: .save,
      artifactPath: coordinator.store.currentURL.path(percentEncoded: false),
      outgoingAgent: source.agentKind?.rawValue,
      receiver: nil,
      branch: repo.branch,
      changedFileCount: repo.changedFiles.count,
      archivedPath: nil,
      sessionExcerptPath: checkpoint.session?.excerptPath,
      briefing: checkpoint.briefing.rawValue,
      hasBriefing: checkpoint.briefing.wroteBriefing,
      launchedPane: nil
    )
  }

  // MARK: - to

  /// `handoff.to` — archive the outgoing round, install the briefing (or
  /// remove the stale one), refresh context, then launch the receiver in a
  /// background tab of the same worktree. The launch never focuses anything.
  func to(_ request: IPC.HandoffRequest) async throws -> IPC.HandoffResponse {
    guard let token = request.receiver, let receiver = AgentKind(token: token) else {
      throw IPCError.invalidParams(
        message: "handoff to requires an agent; receivers: \(Self.receiverTokens)",
        path: ["receiver"])
    }
    guard let placement = HandoffPlacement(target: request.target, direction: request.direction) else {
      throw IPCError.invalidParams(
        message: "handoff cannot target the focused pane; use a new tab (default) or --split",
        path: ["target"])
    }
    let source = try resolvedSource(request)
    let briefing = try preparedBriefing(
      request, command: "\(cli) handoff to \(receiver.rawValue) --brief -")
    // Resolve the profile before any side effect so a bad `--profile` is a
    // clean error rather than an archived-but-unlaunched handoff.
    let profile = try AgentProfileSelector.resolve(
      selector: request.profile, agent: receiver, in: settings.settings.agents)
    try authorize(request)

    let coordinator = HandoffCoordinator(
      store: HandoffStore(rootURL: URL(fileURLWithPath: source.worktreePath, isDirectory: true)))
    let session = sessionContext(for: source)
    // Lay the state directory out first so its ignore file is in place
    // before git status is read: a worktree from an earlier build, or one
    // that never had a hand-off, would otherwise list `.codans/` itself.
    try? coordinator.store.ensureLayout()
    let repo = await collectRepoState(coordinator.store.rootURL)
    let timestamp = now()
    let transition: HandoffCoordinator.Transition
    do {
      transition = try await Task.detached {
        try coordinator.transition(
          outgoing: source.agentKind, to: receiver, session: session, repo: repo,
          briefing: briefing, now: timestamp
        )
      }.value
    } catch {
      throw IPCError.internal("failed to prepare handoff: \(error)")
    }

    var launched: IPC.HandoffLaunchedPane?
    if request.launch {
      launched = await launchReceiver(
        profile: profile, source: source, transition: transition, placement: placement)
      guard launched != nil else {
        // The artifact is already written and the outgoing round archived, so
        // record the failed launch before throwing — the log has to show that
        // this transition happened and where its snapshot went.
        try? await log(
          coordinator, from: source.agentKind, to: receiver, disposition: .failed,
          transition: transition, note: request.note, now: timestamp)
        throw IPCError.internal("failed to launch \(profile.displayName)")
      }
    }
    try? await log(
      coordinator, from: source.agentKind, to: receiver,
      disposition: launched.map { .pane($0.paneID.description) } ?? .skipped,
      transition: transition, note: request.note, now: timestamp)

    registry.publish(
      HandoffCompletion(
        action: .to, sourcePaneID: source.paneID, receiver: receiver,
        briefing: transition.briefing, launched: launched, requestID: request.requestID
      )
    )
    return IPC.HandoffResponse(
      action: .to,
      artifactPath: coordinator.store.currentURL.path(percentEncoded: false),
      outgoingAgent: source.agentKind?.rawValue,
      receiver: receiver.rawValue,
      branch: repo.branch,
      changedFileCount: repo.changedFiles.count,
      archivedPath: transition.archivedPath,
      sessionExcerptPath: transition.session?.excerptPath,
      briefing: transition.briefing.rawValue,
      hasBriefing: transition.hasBriefing,
      launchedPane: launched
    )
  }

  // MARK: - Steps

  private func resolvedSource(_ request: IPC.HandoffRequest) throws -> HandoffSource {
    guard let source = resolveSource(request.paneID) else {
      throw IPCError.notFound(kind: "pane", id: request.paneID.description)
    }
    guard !source.isRemote else {
      throw IPCError.unsupported(
        reason: "handoff writes .codans/handoff/ under the worktree, which lives on a remote host for Server projects"
      )
    }
    return source
  }

  /// Every caller must either provide the source-authored briefing or choose
  /// context-only explicitly. A missing choice, or an invalid briefing, is
  /// rejected here — before any filesystem side effect.
  private func preparedBriefing(
    _ request: IPC.HandoffRequest,
    command: String
  ) throws -> HandoffPreparedBriefing {
    if request.brief != nil, request.contextOnly {
      throw IPCError.invalidParams(
        message: "--brief and --no-brief are mutually exclusive", path: nil)
    }
    if let brief = request.brief {
      do {
        return try HandoffPreparedBriefing(source: .inline(brief))
      } catch {
        throw IPCError.invalidParams(message: HandoffKickoff.invalidBriefingMessage(), path: ["brief"])
      }
    }
    if request.contextOnly {
      return .contextOnly
    }
    throw IPCError.invalidParams(
      message: HandoffKickoff.briefRequiredMessage(command: command), path: ["brief"])
  }

  /// A panel-injected request may run at most once, and not after the panel
  /// gave up on it and took the context-only path itself.
  private func authorize(_ request: IPC.HandoffRequest) throws {
    guard let requestID = request.requestID else { return }
    guard registry.claim(requestID) else {
      throw IPCError.conflict(
        reason: "this handoff request was already handled or superseded; nothing was changed")
    }
  }

  private func sessionContext(for source: HandoffSource) -> HandoffSessionContext {
    HandoffSessionContext(
      agentKind: source.agentKind,
      sessionID: source.sessionID,
      paneID: source.paneID.description,
      paneTitle: source.paneTitle,
      screenExcerpt: readScreen(source.paneID)
    )
  }

  private func launchReceiver(
    profile: AgentProfile,
    source: HandoffSource,
    transition: HandoffCoordinator.Transition,
    placement: HandoffPlacement
  ) async -> IPC.HandoffLaunchedPane? {
    let prompt = HandoffKickoff.receiverPrompt(hasBriefing: transition.hasBriefing)
    let spec = AgentLaunchSpec(
      profile: profile,
      projectID: source.projectID,
      worktreeID: source.worktreeID,
      prompt: prompt,
      // The request's placement, never the profile's saved one, and never
      // `.focused`: a handoff must not type over the outgoing agent's pane.
      // A split anchors on the source pane so the receiver appears beside
      // the agent it takes over from, wherever focus happens to be.
      target: placement.target,
      direction: placement.direction,
      anchorPaneID: source.paneID,
      focus: false,
      tabName: "Hand off → \(profile.displayName)"
    )
    do {
      let outcome = try await launch(spec)
      guard let tabID = outcome.tabID, let paneID = outcome.paneID else { return nil }
      if !profile.descriptor.supportsInitialPrompt {
        // The command line carried no prompt for this agent, so type it once
        // the agent is up. Detached: the response must not wait on a TUI's
        // startup, and the CLI's request timeout is far shorter than that.
        let typeKickoff = self.typeKickoff
        let logger = self.logger
        let kind = profile.kind
        Task { @MainActor in
          if await typeKickoff(paneID, kind, prompt) { return }
          logger.error(
            "kickoff not delivered: \(kind.rawValue, privacy: .public) never appeared in pane \(paneID.description, privacy: .public), or its input box never showed the text"
          )
        }
      }
      return IPC.HandoffLaunchedPane(
        projectID: source.projectID,
        worktreeID: source.worktreeID,
        tabID: tabID,
        paneID: paneID,
        profileName: profile.displayName
      )
    } catch {
      logger.error("receiver launch failed: \(String(describing: error), privacy: .public)")
      return nil
    }
  }

  private func log(
    _ coordinator: HandoffCoordinator,
    from: AgentKind?,
    to receiver: AgentKind,
    disposition: HandoffCoordinator.LaunchDisposition,
    transition: HandoffCoordinator.Transition,
    note: String?,
    now: Date
  ) async throws {
    try await Task.detached {
      try coordinator.logTransition(
        from: from, to: receiver, disposition: disposition,
        briefing: transition.briefing, archivedPath: transition.archivedPath,
        note: note, source: "cli", now: now
      )
    }.value
  }
}
