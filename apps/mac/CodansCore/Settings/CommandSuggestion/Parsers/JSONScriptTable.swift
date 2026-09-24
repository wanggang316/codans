import Foundation

/// Shared shape for manifests that keep a flat `name → command` JSON table:
/// read one object key from the first manifest found, prefix each entry name
/// with the tool's runner.
nonisolated enum JSONScriptTable {
  static func suggestions(
    source: CommandSuggestionSource,
    snapshot: ManifestSnapshot,
    manifests: [String],
    tableKey: String,
    runner: String
  ) -> [CommandSuggestion] {
    guard
      let manifest = snapshot.firstContents(of: manifests),
      let object = try? JSONSerialization.jsonObject(with: Data(manifest.text.utf8)) as? [String: Any],
      let table = object[tableKey] as? [String: Any]
    else { return [] }
    return table.keys.sorted().map { name in
      CommandSuggestion(
        source: source,
        name: name,
        command: "\(runner) \(CommandSuggestionToken.render(name))",
        detail: detail(of: table[name])
      )
    }
  }

  /// Entries are a string or, for composer, a list of steps; deno also allows
  /// `{ "command": … }` objects.
  private static func detail(of value: Any?) -> String? {
    switch value {
    case let text as String:
      return text
    case let steps as [Any]:
      return steps.compactMap { $0 as? String }.joined(separator: " && ")
    case let object as [String: Any]:
      return (object["command"] as? String) ?? (object["description"] as? String)
    default:
      return nil
    }
  }
}

/// `deno.json` `tasks` → `deno task <name>`. `deno.jsonc` is skipped: its
/// comments are not JSON and a half-parsed task list is worse than none.
public nonisolated struct DenoTaskParser: CommandSuggestionParser {
  public let source = CommandSuggestionSource(id: "deno", displayName: "deno.json")

  public init() {}

  public var request: ManifestRequest { ManifestRequest(contentPaths: ["deno.json"]) }

  public func suggestions(in snapshot: ManifestSnapshot) -> [CommandSuggestion] {
    JSONScriptTable.suggestions(
      source: source, snapshot: snapshot, manifests: ["deno.json"], tableKey: "tasks", runner: "deno task")
  }
}

/// `composer.json` `scripts` → `composer run-script <name>`.
public nonisolated struct ComposerScriptParser: CommandSuggestionParser {
  public let source = CommandSuggestionSource(id: "composer", displayName: "composer.json")

  public init() {}

  public var request: ManifestRequest { ManifestRequest(contentPaths: ["composer.json"]) }

  public func suggestions(in snapshot: ManifestSnapshot) -> [CommandSuggestion] {
    JSONScriptTable.suggestions(
      source: source, snapshot: snapshot, manifests: ["composer.json"], tableKey: "scripts",
      runner: "composer run-script")
  }
}
