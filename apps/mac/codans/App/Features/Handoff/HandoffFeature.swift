import CodansCore
import CodansIPC
import ComposableArchitecture
import Foundation

/// The staged Hand Off panel: choose a receiving profile (or "only save
/// progress"), then ask the *live* source agent to run the CLI handoff
/// itself by typing a one-line request into its pane. The agent writes its
/// own briefing and the shared CLI transition completes headlessly; the
/// panel observes the completion through the request registry and jumps to
/// the receiver. Context-only is the explicit fallback while waiting.
/// codans never starts a hidden model turn to author a briefing.
@Reducer
struct HandoffFeature {
  /// The outgoing side, captured once when the panel opens.
  struct Source: Equatable, Sendable {
    let paneID: PaneID
    let projectID: ProjectID
    let worktreeID: WorktreeID
    let agent: AgentKind

    var agentName: String { agent.displayName }
  }

  /// One row of the choose step.
  struct Target: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
      case profile(AgentProfile)
      case checkpoint
    }

    let kind: Kind
    let title: String
    let subtitle: String
    /// Receiver is the same agent as the source — a fresh-session restart.
    let isSameAgent: Bool

    var id: String {
      switch kind {
      case .profile(let profile): return "profile.\(profile.id.uuidString)"
      case .checkpoint: return "checkpoint"
      }
    }

    var profile: AgentProfile? {
      guard case .profile(let profile) = kind else { return nil }
      return profile
    }

    var icon: AgentIconRef? { profile?.icon }
  }

  enum Stage: Equatable, Sendable {
    /// Request typed into the source agent; waiting for its CLI call.
    case requesting
    /// The fallback transition is running; it is not cancellable.
    case finishing
  }

  struct Run: Equatable, Sendable {
    let target: Target
    let requestID: UUID
    var stage: Stage
  }

  enum Outcome: Equatable, Sendable {
    case handedOff(profileName: String)
    case saved
    case failed(message: String)
  }

  enum Phase: Equatable, Sendable {
    case choosing
    case running(Run)
    case finished(Outcome)
  }

  @ObservableState
  struct State: Equatable {
    let source: Source
    let targets: [Target]
    var selectedIndex = 0
    var phase: Phase = .choosing
    /// Where the receiver opens. Seeded from the last choice and remembered
    /// on every change, so the picker opens where the user left it.
    var placement: HandoffPlacement = .default

    var run: Run? {
      guard case .running(let run) = phase else { return nil }
      return run
    }

    var isChoosing: Bool { phase == .choosing }

    /// Receivers are the enabled profiles in Settings order, followed by the
    /// checkpoint row. An agent whose CLI takes no kickoff argument is still a
    /// receiver: the prompt is typed into its pane once it is up, and the row
    /// says so.
    static func make(
      source: Source,
      profiles: [AgentProfile],
      placement: HandoffPlacement = .default
    ) -> State {
      var targets =
        profiles
        .filter(\.isEnabled)
        .map { profile in
          // Where the session opens is the picker's business, not the row's.
          var subtitle = profile.name.isEmpty ? "New session" : "\(profile.kind.displayName) · new session"
          if !profile.descriptor.supportsInitialPrompt {
            subtitle += " · kickoff typed in once it starts"
          }
          return Target(
            kind: .profile(profile),
            title: profile.displayName,
            subtitle: subtitle,
            isSameAgent: profile.kind == source.agent
          )
        }
      targets.append(
        Target(
          kind: .checkpoint,
          title: "Only save progress, don't hand off",
          subtitle: "Writes a briefing checkpoint for a later hand-off",
          isSameAgent: false
        )
      )
      return State(source: source, targets: targets, placement: placement)
    }
  }

  enum Action: Equatable {
    case moveSelection(delta: Int)
    case setSelectedIndex(Int)
    case setPlacement(HandoffPlacement)
    case confirmSelection
    /// The pane could not take the injected request.
    case deliveryFailed
    case contextOnlyTapped
    /// A handoff completed somewhere in the app; ignored unless it is the
    /// one this panel asked for.
    case completionReceived(HandoffCompletion)
    case fallbackFinished(HandoffCompletion)
    case failed(message: String)
    case cancelTapped
    case closeTapped
    case delegate(Delegate)

    @CasePathable
    enum Delegate: Equatable {
      case dismiss
      /// The receiver is up; the parent lands focus on its pane.
      case focusPane(PaneID)
    }
  }

  nonisolated enum CancelID: Hashable, Sendable {
    case completions
  }

  @Dependency(HandoffClient.self) private var handoffClient
  @Dependency(\.uuid) private var uuid

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .moveSelection(let delta):
        guard state.isChoosing, !state.targets.isEmpty else { return .none }
        let count = state.targets.count
        state.selectedIndex = (state.selectedIndex + delta + count) % count
        return .none

      case .setSelectedIndex(let index):
        guard state.isChoosing, state.targets.indices.contains(index) else { return .none }
        state.selectedIndex = index
        return .none

      case .setPlacement(let placement):
        guard state.isChoosing, state.placement != placement else { return .none }
        state.placement = placement
        handoffClient.rememberPlacement(placement)
        return .none

      case .confirmSelection:
        guard state.isChoosing, state.targets.indices.contains(state.selectedIndex) else {
          return .none
        }
        let target = state.targets[state.selectedIndex]
        let request: HandoffKickoff.Request =
          switch target.kind {
          case .profile(let profile): .handOff(to: profile.kind)
          case .checkpoint: .checkpoint
          }
        let requestID = uuid()
        handoffClient.register(requestID)
        let instruction = HandoffKickoff.sourceInstruction(
          for: request, requestID: requestID, cli: handoffClient.cli, placement: state.placement)
        state.phase = .running(Run(target: target, requestID: requestID, stage: .requesting))
        let paneID = state.source.paneID
        let client = handoffClient
        return .run { send in
          // Subscribe before typing: the stream does not replay, and a fast
          // agent could answer before a later subscription lands.
          let stream = await client.completions()
          guard await client.sendInstruction(paneID, instruction) else {
            await send(.deliveryFailed)
            return
          }
          for await completion in stream {
            await send(.completionReceived(completion))
          }
        }
        .cancellable(id: CancelID.completions, cancelInFlight: true)

      case .deliveryFailed:
        // The pane is gone or wedged — retire the request the agent will
        // never see and take the context-only path ourselves.
        guard let run = state.run, run.stage == .requesting else { return .none }
        _ = handoffClient.supersede(run.requestID)
        return .merge(.cancel(id: CancelID.completions), startFallback(&state))

      case .contextOnlyTapped:
        guard let run = state.run, run.stage == .requesting,
          handoffClient.supersede(run.requestID)
        else { return .none }
        return .merge(.cancel(id: CancelID.completions), startFallback(&state))

      case .completionReceived(let completion):
        guard let run = state.run, run.stage == .requesting,
          completion.requestID == run.requestID,
          completion.sourcePaneID == state.source.paneID
        else { return .none }
        return .merge(.cancel(id: CancelID.completions), finish(&state, with: completion))

      case .fallbackFinished(let completion):
        guard state.run != nil else { return .none }
        return finish(&state, with: completion)

      case .failed(let message):
        guard state.run != nil else { return .none }
        state.phase = .finished(.failed(message: message))
        return .none

      case .cancelTapped:
        switch state.phase {
        case .choosing:
          return .send(.delegate(.dismiss))
        case .running(let run) where run.stage == .requesting:
          // The typed request cannot be unsent; if the agent still hands
          // off, the CLI path completes headlessly and the tab appears.
          return .merge(.cancel(id: CancelID.completions), .send(.delegate(.dismiss)))
        case .running, .finished:
          return .none
        }

      case .closeTapped:
        guard case .finished = state.phase else { return .none }
        return .send(.delegate(.dismiss))

      case .delegate:
        return .none
      }
    }
  }

  /// Crosses the fallback's commit boundary: from here the transition runs
  /// to one consistent outcome and the panel offers no cancel.
  private func startFallback(_ state: inout State) -> Effect<Action> {
    guard var run = state.run else { return .none }
    run.stage = .finishing
    state.phase = .running(run)
    let request: IPC.HandoffRequest =
      switch run.target.kind {
      case .profile(let profile):
        IPC.HandoffRequest(
          action: .to,
          paneID: state.source.paneID,
          receiver: profile.kind.rawValue,
          profile: profile.id.uuidString,
          contextOnly: true,
          target: state.placement.target,
          direction: state.placement.direction
        )
      case .checkpoint:
        IPC.HandoffRequest(action: .save, paneID: state.source.paneID, contextOnly: true)
      }
    let client = handoffClient
    return .run { send in
      let completion = try await client.run(request)
      await send(.fallbackFinished(completion))
    } catch: { error, send in
      let message = (error as? IPCError)?.displayMessage ?? error.localizedDescription
      await send(.failed(message: message))
    }
  }

  private func finish(_ state: inout State, with completion: HandoffCompletion) -> Effect<Action> {
    guard let run = state.run else { return .none }
    switch run.target.kind {
    case .checkpoint:
      state.phase = .finished(.saved)
      return .none
    case .profile(let profile):
      state.phase = .finished(.handedOff(profileName: profile.displayName))
      // The user is present and asked for this hand-off — jump to the
      // receiver. The transition itself never focuses anything.
      guard let launched = completion.launched else { return .none }
      return .send(.delegate(.focusPane(launched.paneID)))
    }
  }
}
