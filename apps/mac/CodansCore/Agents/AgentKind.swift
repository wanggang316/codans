import Foundation

/// Coding agents recognised by the AgentState feature. The raw value is
/// the stable identifier persisted in `catalog.json` (see `Pane.agentKind`)
/// and reported over the wire; everything else agent-specific (display
/// name, classifier patterns, resume invocation) lives on the agent's
/// `AgentRuntimeAdapter`.
///
/// Adding a new case requires registering an adapter in
/// `AgentRuntimeAdapters.adapter(for:)`; the exhaustive switch there makes
/// a missing adapter a compile error.
public nonisolated enum AgentKind: String, Codable, Sendable, CaseIterable, Equatable {
  case claudeCode = "claude-code"
  case codex
  case pi
  case opencode
  case gemini
  case cursorAgent = "cursor-agent"
  case cline
  case copilot
  case kimi
  case droid
  case amp
  case grok
  case omp

  public var displayName: String {
    AgentRuntimeAdapters.adapter(for: self).displayName
  }

  /// Resolves a user-typed agent name: the persisted raw value
  /// (`claude-code`), the executable (`claude`), or the display name
  /// (`Claude Code`), case-insensitively. This is what `codans handoff to
  /// <agent>` accepts, so a human and an agent can both spell the receiver
  /// the way they already think of it.
  public init?(token: String) {
    let wanted = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !wanted.isEmpty else { return nil }
    let match = AgentKind.allCases.first { kind in
      kind.rawValue == wanted
        || AgentCatalog.descriptor(for: kind).executable.lowercased() == wanted
        || kind.displayName.lowercased() == wanted
    }
    guard let match else { return nil }
    self = match
  }
}
