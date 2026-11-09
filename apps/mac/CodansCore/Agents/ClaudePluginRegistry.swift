import Foundation

/// Claude Code's plugin registry: which plugins are installed where, and
/// which of them `settings.json` enables. Both formats are not public, so a
/// file that does not match gives no plugins and leaves other skill sources
/// alone (design doc: Agent Skill Completion → Plugin Skill).
nonisolated enum ClaudePluginRegistry {
  /// Skill folders inside one install path. Some plugins keep their skills
  /// in `.claude/skills` instead of `skills`.
  static let skillDirectories = ["skills", ".claude/skills"]

  /// The skill directories of every enabled plugin under `configRoot`.
  static func skillDirectories(configRoot: URL, home: URL) -> [SkillDirectory] {
    let registry = configRoot.appending(path: "plugins/installed_plugins.json", directoryHint: .notDirectory)
    let settings = configRoot.appending(path: "settings.json", directoryHint: .notDirectory)
    let fileManager = FileManager.default
    guard let registryData = fileManager.contents(atPath: registry.path(percentEncoded: false)),
      let settingsData = fileManager.contents(atPath: settings.path(percentEncoded: false))
    else { return [] }
    return enabledPlugins(registry: registryData, settings: settingsData, home: home).flatMap { plugin in
      skillDirectories.map { relative in
        SkillDirectory(
          url: plugin.installPath.appending(path: relative, directoryHint: .isDirectory).standardizedFileURL,
          source: .plugin,
          namespace: plugin.name
        )
      }
    }
  }

  struct Plugin: Equatable {
    /// The part of the `<plugin>@<marketplace>` key before `@`.
    var name: String
    var installPath: URL
  }

  /// Installed plugins whose `<plugin>@<marketplace>` key `enabledPlugins`
  /// sets to `true`, in key order. A plugin installed more than once lists
  /// each distinct install path.
  static func enabledPlugins(registry: Data, settings: Data, home: URL) -> [Plugin] {
    guard let enabled = enabledKeys(settings),
      let object = try? JSONSerialization.jsonObject(with: registry) as? [String: Any],
      let installs = object["plugins"] as? [String: Any]
    else { return [] }
    return installs.keys.sorted().filter(enabled.contains).flatMap { key -> [Plugin] in
      guard let name = key.split(separator: "@", maxSplits: 1).first.map(String.init), !name.isEmpty,
        let records = installs[key] as? [[String: Any]]
      else { return [] }
      var seen = Set<URL>()
      return records.compactMap { record in
        guard let path = record["installPath"] as? String, let url = installURL(path, home: home),
          seen.insert(url).inserted
        else { return nil }
        return Plugin(name: name, installPath: url)
      }
    }
  }

  private static func enabledKeys(_ settings: Data) -> Set<String>? {
    guard let object = try? JSONSerialization.jsonObject(with: settings) as? [String: Any] else {
      return nil
    }
    let flags = object["enabledPlugins"] as? [String: Any] ?? [:]
    return Set(flags.compactMap { key, value in (value as? Bool) == true ? key : nil })
  }

  /// An absolute or `~`-relative install path. Claude Code writes absolute
  /// paths; anything else is not guessed.
  private static func installURL(_ path: String, home: URL) -> URL? {
    if path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL }
    if path.hasPrefix("~/") {
      return home.appending(path: String(path.dropFirst(2)), directoryHint: .isDirectory).standardizedFileURL
    }
    return nil
  }
}
