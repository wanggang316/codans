import Foundation

/// Row density for the ActiveAgents sidebar panel. `normal` keeps the
/// two-line identity column (worktree on top, project beneath) at the
/// default vertical padding; `compact` collapses both names onto a
/// single line and tightens the row's vertical padding so more agents
/// fit before the panel needs to scroll. Persisted in
/// `GeneralSettings.agentsViewDisplayMode` — older settings files that
/// predate the field decode as `normal`.
public nonisolated enum AgentsViewDisplayMode: String, Equatable, Codable, Sendable, CaseIterable {
  case normal
  case compact
}
