import Foundation

/// Codex plugins: `config.toml` enables a plugin with
/// `[plugins."<plugin>@<marketplace>"] enabled = true`, and its files are in
/// `plugins/cache/<marketplace>/<plugin>/<version>/`, both under the config
/// root. A config that is missing or that codans cannot read gives no
/// plugins and leaves other skill sources alone (design doc: Agent Skill
/// Completion → Plugin Skill).
nonisolated enum CodexPluginRegistry {
  /// The skill directories of every plugin that `config.toml` under
  /// `configRoot` enables, called as `<plugin>:<skill>`. Each cached
  /// version is listed, newest first, so the newest copy keeps a name.
  static func skillDirectories(configRoot: URL) -> [SkillDirectory] {
    let config = configRoot.appending(path: "config.toml", directoryHint: .notDirectory)
    guard let data = FileManager.default.contents(atPath: config.path(percentEncoded: false)),
      let text = String(data: data, encoding: .utf8)
    else { return [] }
    let cache = configRoot.appending(path: "plugins/cache", directoryHint: .isDirectory)
    return enabledPlugins(config: text).flatMap { plugin in
      let root = cache.appending(path: plugin.marketplace, directoryHint: .isDirectory)
        .appending(path: plugin.name, directoryHint: .isDirectory)
      return versions(in: root).map { version in
        SkillDirectory(
          url: version.appending(path: "skills", directoryHint: .isDirectory),
          source: .plugin, namespace: plugin.name)
      }
    }
  }

  struct Plugin: Equatable {
    var name: String
    var marketplace: String
  }

  /// Plugins whose `[plugins."<plugin>@<marketplace>"]` table sets
  /// `enabled = true`, in file order. A table without `enabled`, or with a
  /// value other than `true`, does not enable its plugin.
  static func enabledPlugins(config: String) -> [Plugin] {
    TOMLLite.tables(in: config).compactMap { table -> Plugin? in
      guard table.hasPrefix("plugins."),
        let key = TOMLLite.string(String(table.dropFirst("plugins.".count))),
        let at = key.firstIndex(of: "@")
      else { return nil }
      let name = String(key[..<at])
      let marketplace = String(key[key.index(after: at)...])
      guard isPathComponent(name), isPathComponent(marketplace) else { return nil }
      let enabled = TOMLLite.entries(in: config, table: table).last { $0.key == "enabled" }
      let value = enabled?.value.split(separator: "#", maxSplits: 1).first?
        .trimmingCharacters(in: .whitespaces)
      return value == "true" ? Plugin(name: name, marketplace: marketplace) : nil
    }
  }

  /// A name that stays one directory below the cache.
  private static func isPathComponent(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/")
  }

  private static func versions(in plugin: URL) -> [URL] {
    let children =
      (try? FileManager.default.contentsOfDirectory(
        at: plugin, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    return children.sorted {
      $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending
    }
  }
}
