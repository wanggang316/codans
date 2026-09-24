import Foundation

/// `package.json` `scripts`, run through the project's own package manager.
///
/// The manager comes from the `packageManager` field (Corepack's source of
/// truth) when present, else from whichever lockfile exists, else npm. Every
/// manager accepts `<pm> run <name>`, so one command shape covers them all.
public nonisolated struct PackageJSONParser: CommandSuggestionParser {
  public let source = CommandSuggestionSource(id: "package-json", displayName: "package.json")

  static let manifestPath = "package.json"
  /// Lockfile → manager, in precedence order for repos that carry several.
  static let lockfiles: [(path: String, manager: String)] = [
    ("pnpm-lock.yaml", "pnpm"),
    ("bun.lock", "bun"),
    ("bun.lockb", "bun"),
    ("yarn.lock", "yarn"),
    ("package-lock.json", "npm"),
    ("npm-shrinkwrap.json", "npm"),
  ]
  static let knownManagers: Set<String> = ["npm", "pnpm", "yarn", "bun"]

  public init() {}

  public var request: ManifestRequest {
    ManifestRequest(contentPaths: [Self.manifestPath], presencePaths: Self.lockfiles.map(\.path))
  }

  public func suggestions(in snapshot: ManifestSnapshot) -> [CommandSuggestion] {
    guard
      let text = snapshot[Self.manifestPath],
      let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
      let scripts = object["scripts"] as? [String: Any]
    else { return [] }

    let manager = Self.packageManager(declared: object["packageManager"] as? String, snapshot: snapshot)
    let bodies = scripts.compactMapValues { $0 as? String }
    return bodies.keys
      .filter { !Self.isLifecycleHook($0, among: bodies) }
      .sorted()
      .map { name in
        CommandSuggestion(
          source: source,
          name: name,
          command: "\(manager) run \(CommandSuggestionToken.render(name))",
          detail: bodies[name]
        )
      }
  }

  static func packageManager(declared: String?, snapshot: ManifestSnapshot) -> String {
    // `"packageManager": "pnpm@9.1.0+sha512…"` → `pnpm`.
    if let declared,
      let name = declared.split(separator: "@", maxSplits: 1).first.map(String.init),
      knownManagers.contains(name)
    {
      return name
    }
    return lockfiles.first { snapshot.exists($0.path) }?.manager ?? "npm"
  }

  /// `prebuild` / `postbuild` run automatically around `build`; offering them
  /// on their own is noise. A `pre…` entry with no matching base stays.
  static func isLifecycleHook(_ name: String, among scripts: [String: String]) -> Bool {
    for prefix in ["pre", "post"] where name.hasPrefix(prefix) {
      let base = String(name.dropFirst(prefix.count))
      if !base.isEmpty, scripts[base] != nil { return true }
    }
    return false
  }
}
