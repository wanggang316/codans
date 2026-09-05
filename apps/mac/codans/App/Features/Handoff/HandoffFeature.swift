import CodansCore
import CodansIPC
import ComposableArchitecture
import Foundation

/// The staged Hand Off panel: choose a receiving profile (or "only save
/// progress"), then either ask the *live* source agent to run the CLI
/// handoff itself by typing a one-line request into its pane (Hand Off with
/// Brief: the agent writes its own briefing and the shared CLI transition
/// completes headlessly; the panel observes the completion through the
/// request registry and jumps to the receiver), or run the transition in
/// process right away with generated context only (Hand Off with Context).
/// The two paths part at the confirm button and never meet again: once the
/// agent has been asked there is no switching to context-only, so the agent
/// is never asked for a briefing that will be refused. codans never starts a
/// hidden model turn to author a briefing.
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
    /// Tooltip only. The rows are a compact grid of names; how the kickoff
    /// reaches this agent is one hover away rather than a line under each.
    let help: String
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
    /// The in-process, context-only transition is running; not cancellable.
    case finishing
  }

  struct Run: Equatable, Sendable {
    let target: Target
    /// The one-shot id of the injected request; nil for a context-only
    /// hand-off, which never asks the agent.
    let requestID: UUID?
    let stage: Stage
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

  /// Arrow-key movement over the choose step's grid.
  enum Move: Equatable, Sendable {
    case up, down, left, right
  }

  @ObservableState
  struct State: Equatable {
    /// Profile rows fill a grid this many across; the checkpoint row spans
    /// the full width beneath them.
    static let columns = 2

    let source: Source
    /// Profiles first, the checkpoint row last — `index(moving:)` relies on
    /// that order.
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

    /// Receivers are the enabled profiles the machine can run, in Settings
    /// order, followed by the checkpoint row. "Can run" is the same advisory
    /// filter as the toolbar Agents menu (`AgentInstallationStore
    /// .offeredProfiles`), fail-open included. An agent whose CLI takes no
    /// kickoff argument is still a receiver: the prompt is typed into its
    /// pane once it is up, without Enter, and the row's tooltip says so.
    static func make(
      source: Source,
      profiles: [AgentProfile],
      isInstalled: (AgentKind) -> Bool = { _ in true },
      placement: HandoffPlacement = .default
    ) -> State {
      var targets = AgentInstallationStore.offeredProfiles(
        enabled: profiles.filter(\.isEnabled), isInstalled: isInstalled
      )
      .map { profile in
        // Where the session opens is the picker's business, not the row's.
        var help = profile.name.isEmpty ? "New session" : "\(profile.kind.displayName) · new session"
        if !profile.descriptor.supportsInitialPrompt {
          help += " · kickoff typed in once it starts, you press Enter"
        }
        return Target(
          kind: .profile(profile),
          title: profile.displayName,
          help: help,
          isSameAgent: profile.kind == source.agent
        )
      }
      targets.append(
        Target(
          kind: .checkpoint,
          title: "Only save progress, don't hand off",
          help: "Writes a briefing checkpoint for a later hand-off",
          isSameAgent: false
        )
      )
      return State(source: source, targets: targets, placement: placement)
    }

    /// Where an arrow key lands. Left/right walk the whole list and wrap.
    /// Up/down move by a grid row: below the last profile row sits the
    /// checkpoint, below the checkpoint the list wraps to the top, and above
    /// the first row it wraps to the checkpoint.
    func index(moving move: Move) -> Int {
      let count = targets.count
      guard count > 0 else { return 0 }
      let checkpoint = count - 1
      switch move {
      case .left:
        return (selectedIndex - 1 + count) % count
      case .right:
        return (selectedIndex + 1) % count
      case .down:
        guard selectedIndex != checkpoint else { return 0 }
        let below = selectedIndex + Self.columns
        return below < checkpoint ? below : checkpoint
      case .up:
        guard selectedIndex != checkpoint else { return max(checkpoint - 1, 0) }
        let above = selectedIndex - Self.columns
        return above >= 0 ? above : checkpoint
      }
    }
  }

  enum Action: Equatable {
    case moveSelection(Move)
    case setSelectedIndex(Int)
    case setPlacement(HandoffPlacement)
    /// Hand Off with Brief (or Save Progress): ask the live agent to run the
    /// CLI hand-off with its own briefing.
    case confirmSelection
    /// Hand Off with Context: run the transition now, without a briefing and
    /// without involving the agent.
    case confirmContextOnly
    /// The pane could not take the injected request.
    case deliveryFailed
    /// A handoff completed somewhere in the app; ignored unless it is the
    /// one this panel asked for.
    case completionReceived(HandoffCompletion)
    case contextOnlyFinished(HandoffCompletion)
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
      case .moveSelection(let move):
        guard state.isChoosing, !state.targets.isEmpty else { return .none }
        state.selectedIndex = state.index(moving: move)
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

      case .confirmContextOnly:
        guard state.isChoosing, state.targets.indices.contains(state.selectedIndex) else {
          return .none
        }
        let target = state.targets[state.selectedIndex]
        // A checkpoint is the agent's own words or nothing; the panel offers
        // no context-only variant of it.
        guard let profile = target.profile else { return .none }
        state.phase = .running(Run(target: target, requestID: nil, stage: .finishing))
        let request = IPC.HandoffRequest(
          action: .to,
          paneID: state.source.paneID,
          receiver: profile.kind.rawValue,
          profile: profile.id.uuidString,
          contextOnly: true,
          target: state.placement.target,
          direction: state.placement.direction
        )
        let client = handoffClient
        return .run { send in
          let completion = try await client.run(request)
          await send(.contextOnlyFinished(completion))
        } catch: { error, send in
          let message = (error as? IPCError)?.displayMessage ?? error.localizedDescription
          await send(.failed(message: message))
        }

      case .deliveryFailed:
        // The pane is gone or wedged. Retire the request the agent will never
        // see and stop: starting the receiver without a briefing is the
        // user's call (Hand Off with Context), not a silent downgrade.
        guard let run = state.run, run.stage == .requesting else { return .none }
        if let requestID = run.requestID {
          _ = handoffClient.supersede(requestID)
        }
        let agent = state.source.agentName
        let message =
          switch run.target.kind {
          case .profile:
            "\(agent)'s pane could not take the request. Nothing was launched; "
              + "Hand Off with Context starts \(run.target.title) without a briefing."
          case .checkpoint:
            "\(agent)'s pane could not take the request. Nothing was saved."
          }
        state.phase = .finished(.failed(message: message))
        return .cancel(id: CancelID.completions)

      case .completionReceived(let completion):
        guard let run = state.run, run.stage == .requesting,
          completion.requestID == run.requestID,
          completion.sourcePaneID == state.source.paneID
        else { return .none }
        return .merge(.cancel(id: CancelID.completions), finish(&state, with: completion))

      case .contextOnlyFinished(let completion):
        guard let run = state.run, run.stage == .finishing else { return .none }
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
