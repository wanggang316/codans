import Foundation

/// Where a group of suggestions came from — one per parser, e.g. `package.json`
/// or `Makefile`. `id` is a stable token (menu identity, tests); `displayName`
/// is what the `+` menu shows as the submenu title.
public nonisolated struct CommandSuggestionSource: Hashable, Sendable {
  public var id: String
  public var displayName: String

  public init(id: String, displayName: String) {
    self.id = id
    self.displayName = displayName
  }
}

/// A command detected in the project's own manifests (package scripts, make
/// targets, …) that the user can adopt as a `ScriptDefinition` in one click.
/// Suggestions are derived, never persisted: adopting one copies its fields
/// into a regular script and the link to the manifest ends there.
public nonisolated struct CommandSuggestion: Hashable, Sendable, Identifiable {
  public var source: CommandSuggestionSource
  /// Entry name as written in the manifest (`dev`, `build`, `test:unit`).
  public var name: String
  /// Shell line that runs the entry (`pnpm run dev`, `make build`).
  public var command: String
  /// What the entry expands to, when the manifest says (`vite build`, a
  /// make `##` help comment). Shown as the menu item's subtitle.
  public var detail: String?
  public var kind: ScriptKind
  /// Glyph from the shared command-icon mapping; nil when nothing in the
  /// table matches and the kind's default icon should show.
  public var icon: CommandIconRef?

  public init(
    source: CommandSuggestionSource,
    name: String,
    command: String,
    detail: String? = nil,
    kind: ScriptKind? = nil,
    icon: CommandIconRef? = nil
  ) {
    self.source = source
    self.name = name
    self.command = command
    self.detail = detail.flatMap { $0.isEmpty ? nil : $0 }
    self.kind = kind ?? ScriptKindInference.kind(forEntryName: name)
    // Curated suggestions pick their glyph; detected ones go through the
    // shared mapping.
    self.icon = icon ?? CommandIconCatalog.icon(forEntryName: name, command: command, body: self.detail)
  }

  /// Icon to draw for this suggestion before it is adopted.
  public var resolvedIcon: CommandIconRef {
    icon ?? .symbol(kind.defaultSystemImage)
  }

  public var id: String { "\(source.id):\(name)" }
}

/// All suggestions one parser produced, in the parser's order.
public nonisolated struct CommandSuggestionGroup: Hashable, Sendable, Identifiable {
  public var source: CommandSuggestionSource
  public var suggestions: [CommandSuggestion]

  public init(source: CommandSuggestionSource, suggestions: [CommandSuggestion]) {
    self.source = source
    self.suggestions = suggestions
  }

  public var id: String { source.id }
}
