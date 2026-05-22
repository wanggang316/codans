import Foundation
import TouchCodeCore

/// Derives the status-bar badge headline from a snapshot of
/// `AgentRegistry.entries`. See spec AC-B1..B4 in
/// `docs/product-specs/active-agents-view.md`.
///
/// Four shapes:
/// - **Empty** — no entries: `headline = nil` (caller hides the badge).
/// - **Single** — one entry: `"<DisplayName> is <verb>"`.
/// - **Multi same-state** — count > 1, all same state: `"<count> agents <verb>"`.
/// - **Multi mixed-state** — top two non-empty buckets in headline-priority
///   order (`waitingForInput > loading > finished > idle`): `"<n1> <verb1> · <n2> <verb2>"`.
///
/// The badge-priority order here is *not* the popover sort order — it's the
/// "what to surface in a single line" order documented by AC-B4 ("当存在
/// 多个 Agent 且状态混合时，headline 形如 `<n1> <verb1> · <n2> <verb2>`，
/// 按优先级 `waitingForInput > loading > finished > idle`").
///
/// `pulse` is true whenever any entry is in `.loading` or `.waitingForInput`
/// — read by the badge view (T6 / T7) to decide whether to animate.
///
/// Pure value type. The badge view re-creates one on every render; entries
/// max out at ~20 in practice (one per bound agent pane) so the cost is
/// negligible.
struct ActiveAgentsBadgeViewModel: Equatable {
  let headline: String?
  let pulse: Bool

  @MainActor
  init(entries: [AgentRegistry.AgentEntry]) {
    self.pulse = entries.contains { $0.state == .loading || $0.state == .waitingForInput }

    if entries.isEmpty {
      self.headline = nil
      return
    }

    if entries.count == 1, let only = entries.first {
      self.headline = "\(only.kind.displayName) is \(Self.sentenceVerb(only.state))"
      return
    }

    // Group by state. Empty buckets are dropped; we work over the buckets
    // that actually have entries.
    var counts: [AgentRegistry.AgentRuntimeState: Int] = [:]
    for entry in entries {
      counts[entry.state, default: 0] += 1
    }

    let nonEmpty = Self.badgePriorityOrder.compactMap { state -> (AgentRegistry.AgentRuntimeState, Int)? in
      guard let count = counts[state], count > 0 else { return nil }
      return (state, count)
    }

    if nonEmpty.count == 1, let (state, count) = nonEmpty.first {
      // All entries share one state — "<count> agents <verb>".
      self.headline = "\(count) agents \(Self.shortVerb(state))"
      return
    }

    // Mixed states: top two non-empty buckets in priority order.
    let topTwo = nonEmpty.prefix(2)
    let parts = topTwo.map { state, count in "\(count) \(Self.shortVerb(state))" }
    self.headline = parts.joined(separator: " · ")
  }

  /// Headline priority — strictly `waitingForInput > loading > finished > idle`
  /// per AC-B4. This is intentionally *different* from the popover's
  /// `SortedEntriesProvider` order (which is `waitingForInput > finished >
  /// loading > idle`): the badge is a single-line summary biased toward
  /// "what's happening now", while the popover is a triage list biased
  /// toward "what just completed and what's still waiting".
  private static let badgePriorityOrder: [AgentRegistry.AgentRuntimeState] = [
    .waitingForInput, .loading, .finished, .idle,
  ]

  /// Verb used in the single-entry sentence shape — reads naturally after
  /// "<DisplayName> is …", so the `waitingForInput` case spells out the
  /// full clause ("Claude Code is waiting for input").
  private static func sentenceVerb(_ state: AgentRegistry.AgentRuntimeState) -> String {
    switch state {
    case .waitingForInput: return "waiting for input"
    case .loading: return "working"
    case .finished: return "finished"
    case .idle: return "idle"
    }
  }

  /// Verb used in the count-prefixed chip shapes — "1 waiting · 2 working".
  /// `.waitingForInput` collapses to "waiting" here because the count
  /// prefix already carries the noun; spelling out "waiting for input"
  /// would over-pack a one-line summary.
  private static func shortVerb(_ state: AgentRegistry.AgentRuntimeState) -> String {
    switch state {
    case .waitingForInput: return "waiting"
    case .loading: return "working"
    case .finished: return "finished"
    case .idle: return "idle"
    }
  }
}
