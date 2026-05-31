import Foundation
import TouchCodeCore

/// Pure ordering helpers for the Agents View list. Splits the "what order"
/// question into two small, independently-testable pieces that
/// `AgentStateOrderCoordinator` drives with debounce + animation:
///
/// 1. `reconcileMembership` — keeps the *current* display order, dropping
///    panes that have departed and appending newcomers at the end. This is
///    the always-on, immediate path: adding or removing an agent never
///    re-sorts the survivors. Newcomers arriving in the same tick are
///    ordered among themselves by `SortedEntriesProvider`'s triage sort so a
///    batch (e.g. the initial set when the panel first appears, where the
///    prior order is empty) seeds in a sensible, deterministic order.
///
/// 2. `isOrderSignificant` — decides whether a single pane's state change is
///    worth a (debounced) re-sort. A decay *into* `.idle`
///    (`finished → idle`, `working → idle`, `blocked → idle`) is NOT
///    significant: the row keeps its place so a completed agent quietly
///    fading to idle doesn't yank the list around (the dominant flicker the
///    Agents View suffered — see `docs/product-specs/active-agents-view.md`).
///    Rises into an active/finished state, and lateral moves between them,
///    ARE significant and bubble the row to its triage position.
///
/// Pure logic, zero SwiftUI. `reconcileMembership` is `@MainActor` only
/// because `AgentEntry` is MainActor-isolated by the target's default actor
/// (same reason as `SortedEntriesProvider`); `isOrderSignificant` takes only
/// the `Sendable` state enum and stays nonisolated.
nonisolated enum AgentRowOrdering {
  /// Returns the next display order: survivors keep their relative order,
  /// departed panes are dropped, newcomers are appended (sorted among
  /// themselves by the triage comparator). Idempotent when membership is
  /// unchanged — returns an array equal to `order`.
  @MainActor
  static func reconcileMembership(
    order: [PaneID],
    entries: [PaneID: AgentStateStore.AgentEntry]
  ) -> [PaneID] {
    let survivors = order.filter { entries[$0] != nil }
    let known = Set(survivors)
    let newcomerKeys = Set(entries.keys).subtracting(known)
    guard !newcomerKeys.isEmpty else { return survivors }
    let sortedNewcomers = SortedEntriesProvider
      .sorted(entries.filter { newcomerKeys.contains($0.key) })
      .map(\.paneID)
    return survivors + sortedNewcomers
  }

  /// Whether a `from → to` state change should arm a re-sort. `false` for a
  /// no-op (`from == to`) and for any decay into `.idle`; `true` otherwise.
  static func isOrderSignificant(
    from: AgentStateStore.AgentRuntimeState,
    to: AgentStateStore.AgentRuntimeState
  ) -> Bool {
    guard from != to else { return false }
    if to == .idle { return false }
    return true
  }
}
