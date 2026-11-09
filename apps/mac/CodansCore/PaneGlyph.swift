import Foundation

/// Glyph of one pane. A pane card header draws it, and a tab chip draws the
/// glyph of its tab's selected pane, so the two never disagree.
public nonisolated struct PaneGlyph: Equatable, Sendable {
  /// Glyph of a pane with no agent and no run script.
  public static let terminalIcon = "terminal"

  /// Stored icon string: an SF Symbol name, a `mark:<tool>` reference
  /// (`CommandIconRef`) or an `agent:<kind>` reference (`TabIconRef`).
  public var icon: String
  /// The run script's tint while it executes; `nil` otherwise.
  public var tint: ScriptTintColor?

  public init(icon: String, tint: ScriptTintColor?) {
    self.icon = icon
    self.tint = tint
  }

  /// Picks the glyph for `pane`, in this order:
  /// 1. an agent runs in it → the agent's mark. An agent started in a run
  ///    pane wins, because it is what the pane shows now;
  /// 2. it is a run pane of a script in `settings` → the script's icon,
  ///    tinted while `isBusy`;
  /// 3. otherwise → a terminal.
  public static func resolve(pane: Pane?, settings: Settings, isBusy: Bool) -> PaneGlyph {
    if let kind = pane?.agentKind {
      return PaneGlyph(icon: TabIconRef.icon(for: kind), tint: nil)
    }
    if let scriptID = pane?.runScriptID, let script = settings.script(id: scriptID) {
      return PaneGlyph(
        icon: script.resolvedSystemImage, tint: isBusy ? script.resolvedTintColor : nil)
    }
    return PaneGlyph(icon: terminalIcon, tint: nil)
  }
}

extension Settings {
  /// The global or project script with `id`, or `nil` when none exists.
  public nonisolated func script(id: UUID) -> ScriptDefinition? {
    general.globalScripts.first { $0.id == id }
      ?? projects.values.lazy.flatMap(\.scripts).first { $0.id == id }
  }
}
