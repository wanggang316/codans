import CodansIPC
import ComposableArchitecture
import Foundation

/// Agent-bearing panes on the Mac, grouped by what they ask of the user.
/// Fed entirely by the `events.subscribe` stream: a snapshot replaces the
/// table, deltas upsert and remove rows by pane.
@Reducer
struct AgentsFeature {
  @ObservableState
  struct State: Equatable {
    /// Keyed by pane ID.
    var entries: [String: IPC.AgentStateEntry] = [:]
    /// False until the first snapshot, so the list can tell "loading"
    /// from "no agents".
    var hasSnapshot = false

    /// Needs input first, then working, then idle; empty groups dropped.
    var groups: [AgentGroup] {
      let byKind = Dictionary(grouping: entries.values) { AgentGroup.Kind(state: $0.state) }
      return AgentGroup.Kind.allCases.compactMap { kind in
        guard let rows = byKind[kind], !rows.isEmpty else { return nil }
        return AgentGroup(kind: kind, entries: kind.sorted(rows))
      }
    }

    var needsInputCount: Int {
      entries.values.filter { AgentGroup.Kind(state: $0.state) == .needsInput }.count
    }

    /// The most urgent agent state in a worktree, with how many agents are
    /// in it, for the badge on the worktree row. Nil when no agent runs
    /// there.
    func summary(forWorktree worktreeID: String) -> AgentSummary? {
      AgentSummary(entries.values.filter { $0.worktreeID == worktreeID })
    }

    func kind(ofPane paneID: String) -> AgentGroup.Kind? {
      entries[paneID].map { AgentGroup.Kind(state: $0.state) }
    }
  }

  enum Action: Equatable {
    case eventReceived(IPC.EventFrame)
    case reset
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .eventReceived(let frame):
        switch frame.payload {
        case .snapshot(let snapshot):
          guard let agents = snapshot.agents else { return .none }
          state.entries = Dictionary(agents.map { ($0.paneID, $0) }, uniquingKeysWith: { _, last in last })
          state.hasSnapshot = true
        case .agentStatesChanged(let delta):
          for paneID in delta.removedPaneIDs {
            state.entries[paneID] = nil
          }
          for entry in delta.upserted {
            state.entries[entry.paneID] = entry
          }
        case .hierarchyChanged, .heartbeat, .unknown:
          break
        }
        return .none

      case .reset:
        state = State()
        return .none
      }
    }
  }
}

struct AgentSummary: Equatable {
  let kind: AgentGroup.Kind
  /// Agents in the most urgent kind.
  let count: Int

  init?(_ entries: some Collection<IPC.AgentStateEntry>) {
    let kinds = entries.map { AgentGroup.Kind(state: $0.state) }
    // `allCases` is ordered most urgent first.
    guard let kind = AgentGroup.Kind.allCases.first(where: kinds.contains) else { return nil }
    self.kind = kind
    self.count = kinds.count { $0 == kind }
  }
}

struct AgentGroup: Equatable, Identifiable {
  enum Kind: String, CaseIterable, Equatable {
    case needsInput
    case working
    case idle

    /// Maps the wire state (`blocked` / `working` / `idle` / `finished`,
    /// or a state newer than this build) to a group. Anything that is not
    /// asking for input or busy reads as idle.
    init(state: String) {
      switch state {
      case "blocked": self = .needsInput
      case "working": self = .working
      default: self = .idle
      }
    }

    var title: String {
      switch self {
      case .needsInput: return "Needs Input"
      case .working: return "Working"
      case .idle: return "Idle"
      }
    }

    var symbol: String {
      switch self {
      case .needsInput: return "exclamationmark.bubble.fill"
      case .working: return "circle.dotted.circle"
      case .idle: return "moon.zzz"
      }
    }

    /// Needs-input rows oldest first (waiting longest on top); the others
    /// most recent first. `since` is ISO 8601 from one clock, so string
    /// order is time order. Pane ID breaks ties for a stable list.
    func sorted(_ rows: [IPC.AgentStateEntry]) -> [IPC.AgentStateEntry] {
      rows.sorted { lhs, rhs in
        if lhs.since != rhs.since {
          return self == .needsInput ? lhs.since < rhs.since : lhs.since > rhs.since
        }
        return lhs.paneID < rhs.paneID
      }
    }
  }

  let kind: Kind
  let entries: [IPC.AgentStateEntry]

  var id: Kind { kind }
}
