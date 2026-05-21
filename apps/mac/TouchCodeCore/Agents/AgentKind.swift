import Foundation

/// Coding agents recognised by the ActiveAgents feature. The raw value is
/// the stable identifier persisted in `catalog.json` (see `Pane.agentKind`)
/// and reported over the wire; the `displayName` is the user-facing label
/// rendered in the status-bar popover and any future agent-aware UI.
///
/// Adding a new case requires extending `AgentKindPatterns` so the
/// classifier can identify panes running the new agent.
public nonisolated enum AgentKind: String, Codable, Sendable, CaseIterable, Equatable {
  case claudeCode = "claude-code"
  case codex
  case pi

  public var displayName: String {
    switch self {
    case .claudeCode: return "Claude Code"
    case .codex: return "Codex"
    case .pi: return "pi"
    }
  }
}
