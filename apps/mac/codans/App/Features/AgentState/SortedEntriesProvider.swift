import Foundation
import CodansCore

/// Pure helper that orders `AgentStateStore.entries` for the agent-state view.
///
/// Sort order:
///
/// 1. Primary: state priority `blocked > error > done > working > idle`.
///    Note this is the *triage* order surfaced to users — the view answers
///    "what needs attention" first (a prompt, then a failure), then "what
///    just completed", then "what's still running".
/// 2. Secondary: `lastTransitionAt` descending within the same state bucket
///    (most-recent transition first).
/// 3. Tie-break: `PaneID.raw.uuidString` ascending. This keeps the order
///    deterministic when two entries land on the same `lastTransitionAt`
///    instant (rare in practice but possible when an injected clock pins
///    time in tests). PaneID is a UUID, so the order is stable but
///    otherwise arbitrary — the contract is "no flicker", not "meaningful".
///
/// Pure logic: zero SwiftUI imports, trivially unit-testable. The enum
/// itself is `nonisolated`; the `sorted` static is `@MainActor` only
/// because `AgentStateStore.AgentEntry` is MainActor-isolated by the
/// target's default actor (the registry it lives on is `@MainActor`).
nonisolated enum SortedEntriesProvider {
  @MainActor
  static func sorted(
    _ entries: [PaneID: AgentStateStore.AgentEntry]
  ) -> [(paneID: PaneID, entry: AgentStateStore.AgentEntry)] {
    entries
      .map { (paneID: $0.key, entry: $0.value) }
      .sorted { lhs, rhs in
        let lp = priority(lhs.entry.state)
        let rp = priority(rhs.entry.state)
        if lp != rp { return lp < rp }
        if lhs.entry.lastTransitionAt != rhs.entry.lastTransitionAt {
          return lhs.entry.lastTransitionAt > rhs.entry.lastTransitionAt
        }
        return lhs.paneID.raw.uuidString < rhs.paneID.raw.uuidString
      }
  }

  /// Lower number = higher priority (sorts earlier in the list).
  private static func priority(_ state: AgentStateStore.AgentRuntimeState) -> Int {
    switch state {
    case .blocked: return 0
    case .error: return 1
    case .done: return 2
    case .working: return 3
    case .idle: return 4
    }
  }
}
