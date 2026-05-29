import Foundation
import TouchCodeCore

/// Pure helper that orders `AgentRegistry.entries` for the popover.
///
/// Sort order per spec AC-P4 (see `docs/product-specs/active-agents-view.md`
/// and `docs/user-tests/active-agents-view.md` UT-AA-P-003):
///
/// 1. Primary: state priority `blocked > finished > working > idle`.
///    Note this is the *triage* order surfaced to users — the popover answers
///    "what needs attention" first, then "what just completed", then "what's
///    still running". It is deliberately distinct from the registry's
///    internal derive priority (`blocked > working > finished > idle`),
///    which answers "what is this pane doing right now".
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
/// because `AgentRegistry.AgentEntry` is MainActor-isolated by the
/// target's default actor (the registry it lives on is `@MainActor`).
/// Tests run under `@MainActor` to satisfy this — see
/// `SortedEntriesProviderTests`.
nonisolated enum SortedEntriesProvider {
  @MainActor
  static func sorted(
    _ entries: [PaneID: AgentRegistry.AgentEntry]
  ) -> [(paneID: PaneID, entry: AgentRegistry.AgentEntry)] {
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
  private static func priority(_ state: AgentRegistry.AgentRuntimeState) -> Int {
    switch state {
    case .blocked: return 0
    case .finished: return 1
    case .working: return 2
    case .idle: return 3
    }
  }
}
