import CodansCore
import CodansIPC
import ComposableArchitecture
import Foundation

/// The Hand Off panel is a chooser and nothing more: pick a receiving profile
/// (or "only save progress"), where it opens, and how the briefing is made —
/// then hand the order to the parent and close. Hand Off with Brief asks the
/// *live* source agent to run the CLI hand-off itself with its own briefing;
/// Hand Off with Context starts the receiver right away from generated
/// context. `RootFeature` runs whichever was chosen in the background and
/// jumps to the receiver when it lands, so the panel has no waiting step and
/// no way to switch paths once the agent has been asked. codans never starts
/// a hidden model turn to author a briefing.
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

  /// One row of the grid.
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

  /// Arrow-key movement over the grid.
  enum Move: Equatable, Sendable {
    case up, down, left, right
  }

  /// What the user asked for. The parent carries it out after the panel is
  /// gone, so it names everything the work needs.
  enum Order: Equatable, Sendable {
    /// Ask the live agent to run the CLI hand-off (or a checkpoint) with its
    /// own briefing.
    case brief(HandoffKickoff.Request, targetTitle: String)
    /// Start the receiver now from generated context; the agent is not asked.
    case contextOnly(profile: AgentProfile, targetTitle: String)
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
    /// Where the receiver opens. Seeded from the last choice and remembered
    /// on every change, so the picker opens where the user left it.
    var placement: HandoffPlacement = .default

    var selectedTarget: Target? {
      guard targets.indices.contains(selectedIndex) else { return nil }
      return targets[selectedIndex]
    }

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
    /// Hand Off with Brief, or Save Progress on the checkpoint row.
    case confirmSelection
    /// Hand Off with Context, from the confirm button's menu.
    case confirmContextOnly
    case cancelTapped
    case delegate(Delegate)

    @CasePathable
    enum Delegate: Equatable {
      case dismiss
      /// The user chose. The parent closes the panel and does the work.
      case handOff(source: Source, order: Order, placement: HandoffPlacement)
    }
  }

  @Dependency(HandoffClient.self) private var handoffClient

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .moveSelection(let move):
        guard !state.targets.isEmpty else { return .none }
        state.selectedIndex = state.index(moving: move)
        return .none

      case .setSelectedIndex(let index):
        guard state.targets.indices.contains(index) else { return .none }
        state.selectedIndex = index
        return .none

      case .setPlacement(let placement):
        guard state.placement != placement else { return .none }
        state.placement = placement
        handoffClient.rememberPlacement(placement)
        return .none

      case .confirmSelection:
        guard let target = state.selectedTarget else { return .none }
        let request: HandoffKickoff.Request =
          switch target.kind {
          case .profile(let profile): .handOff(to: profile.kind)
          case .checkpoint: .checkpoint
          }
        return .send(
          .delegate(
            .handOff(
              source: state.source,
              order: .brief(request, targetTitle: target.title),
              placement: state.placement)))

      case .confirmContextOnly:
        // A checkpoint is the agent's own words or nothing; the panel offers
        // no context-only variant of it.
        guard let target = state.selectedTarget, let profile = target.profile else { return .none }
        return .send(
          .delegate(
            .handOff(
              source: state.source,
              order: .contextOnly(profile: profile, targetTitle: target.title),
              placement: state.placement)))

      case .cancelTapped:
        return .send(.delegate(.dismiss))

      case .delegate:
        return .none
      }
    }
  }
}
