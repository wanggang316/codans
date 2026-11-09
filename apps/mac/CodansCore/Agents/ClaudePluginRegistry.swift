import Foundation

/// Claude Code's plugin registry: which plugins are installed where, and
/// which of them `settings.json` enables. Both formats are not public, so a
/// file that does not match gives no plugins and leaves other skill sources
/// alone (design doc: Agent Skill Completion → Plugin Skill).
nonisolated enum ClaudePluginRegistry {
  /// The skill directories of every enabled plugin under `configRoot`.
  static func skillDirectories(configRoot: URL, home: URL) -> [SkillDirectory] {
    let registry = configRoot.appending(path: "plugins/installed_plugins.json", directoryHint: .notDirectory)
    let settings = configRoot.appending(path: "settings.json", directoryHint: .notDirectory)
    let fileManager = FileManager.default
    guard let registryData = fileManager.contents(atPath: registry.path(percentEncoded: false)),
      let settingsData = fileManager.contents(atPath: settings.path(percentEncoded: false))
    else { return [] }
    return enabledPlugins(registry: registryData, settings: settingsData, home: home).flatMap { plugin in
      skillDirectories(of: plugin).map { url, layout in
        SkillDirectory(url: url, source: .plugin, namespace: plugin.name, layout: layout)
      }
    }
  }

  /// Where one plugin keeps its skills: `skills/`, plus the paths that the
  /// `skills` field of `.claude-plugin/plugin.json` declares. Without that
  /// field, also `.claude/skills/`, which some plugins use. A plugin that
  /// declares its paths gets only those, because Claude Code then loads
  /// only the declared skills of `.claude/skills/` (ADR 0010).
  static func skillDirectories(of plugin: Plugin) -> [(URL, SkillDirectory.Layout)] {
    let root = plugin.installPath
    let defaults = root.appending(path: "skills", directoryHint: .isDirectory)
    guard let declared = declaredSkillPaths(installPath: root) else {
      return [
        (defaults, .skillFolders),
        (root.appending(path: ".claude/skills", directoryHint: .isDirectory), .skillFolders),
      ]
    }
    let fileManager = FileManager.default
    return [(defaults, .skillFolders)]
      + declared.map { url in
        let file = url.appending(path: "SKILL.md", directoryHint: .notDirectory)
        return (url, fileManager.fileExists(atPath: file.path(percentEncoded: false)) ? .skill : .skillFolders)
      }
  }

  /// The `skills` paths of the plugin manifest, resolved in the install
  /// path, or `nil` when the manifest declares none or cannot be read.
  /// A path that leaves the install path is dropped.
  private static func declaredSkillPaths(installPath: URL) -> [URL]? {
    let manifest = installPath.appending(path: ".claude-plugin/plugin.json", directoryHint: .notDirectory)
    guard let data = FileManager.default.contents(atPath: manifest.path(percentEncoded: false)),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    let paths: [String]
    switch object["skills"] {
    case let path as String: paths = [path]
    case let list as [String]: paths = list
    default: return nil
    }
    let base = installPath.standardizedFileURL.path(percentEncoded: false)
    let prefix = base.hasSuffix("/") ? base : base + "/"
    return paths.compactMap { path in
      guard !path.hasPrefix("/") else { return nil }
      let url = installPath.appending(path: path, directoryHint: .isDirectory).standardizedFileURL
      return url.path(percentEncoded: false).hasPrefix(prefix) ? url : nil
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
