import Foundation

/// How a profile's glyph is sourced: the agent's bundled brand mark, or an
/// SF Symbol the user picked instead. Every surface that draws an agent —
/// settings row, toolbar button, menu item, tab chip — switches on this so
/// an override applies everywhere at once.
public nonisolated enum AgentIconRef: Equatable, Sendable, Hashable {
  case brand(AgentKind)
  case symbol(String)
}

/// A stored icon string is an SF Symbol name or `agent:<AgentKind.rawValue>`,
/// which glyph views resolve to the agent's bundled brand mark — the same
/// mark the Agents settings pane and the toolbar menu show, so one agent
/// reads the same everywhere.
///
/// Parsing lives here rather than at the render site because the string is
/// persisted (a script's `systemImage`): the prefix is a wire format, and
/// anything that reads a stored icon has to agree on it.
public nonisolated enum TabIconRef {
  static let agentPrefix = "agent:"

  /// Icon string that names `kind`'s brand mark.
  public static func icon(for kind: AgentKind) -> String {
    agentPrefix + kind.rawValue
  }

  /// The agent an icon string names, or `nil` when it is a plain SF Symbol.
  /// An unknown kind behind the prefix (catalog written by a newer build,
  /// hand-edited file) also returns `nil`, which degrades to the
  /// SF-Symbol path and renders nothing rather than crashing.
  public static func agentKind(from icon: String) -> AgentKind? {
    guard icon.hasPrefix(agentPrefix) else { return nil }
    return AgentKind(rawValue: String(icon.dropFirst(agentPrefix.count)))
  }
}
