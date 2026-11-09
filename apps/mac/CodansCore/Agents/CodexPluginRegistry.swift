import Foundation

/// Codex plugins: a config layer enables a plugin with
/// `[plugins."<plugin>@<marketplace>"] enabled = true`, and its files are in
/// `plugins/cache/<marketplace>/<plugin>/<version>/` under the config root.
/// The layers are `config.toml` under the config root, then the
/// `<name>.config.toml` of `--profile <name>`. `[features] plugins = false`
/// or `--disable plugins` turns every plugin off. Whatever codans cannot be
/// sure of (a config override, a project config about plugins, a config in a
/// form it does not read) gives no plugin skills and leaves other skill
/// sources alone (ADR 0010; design doc: Agent Skill Completion → Plugin
/// Skill).
nonisolated enum CodexPluginRegistry {
  /// What the profile's extra arguments do to the plugins Codex loads.
  enum LaunchConfig: Equatable {
    /// Plain arguments. `profile` is the name after `--profile`;
    /// `plugins` is the last `--enable plugins` (`true`) or
    /// `--disable plugins` (`false`).
    case known(profile: String?, plugins: Bool?)
    /// Arguments whose effect codans cannot be sure of: any shell syntax,
    /// `-c`/`--config`, `--remote`, `-C`/`--cd`, or a `--profile` that is
    /// repeated or has no plain name.
    case unknown
  }

  /// Reads the plugin-related flags from a profile's extra arguments.
  static func launchConfig(extraArguments: String) -> LaunchConfig {
    guard let words = PlainShellWords.split(extraArguments) else { return .unknown }
    var profiles: [String?] = []
    var plugins: Bool?
    var index = 0
    func value(after flag: String) -> String? {
      if words[index] == flag {
        index += 1
        return index < words.count ? words[index] : nil
      }
      return String(words[index].dropFirst(flag.count + 1))
    }
    while index < words.count {
      let word = words[index]
      if word.hasPrefix("-c") || word == "--config" || word.hasPrefix("--config=")
        || word.hasPrefix("-C") || word == "--cd" || word.hasPrefix("--cd=")
        || word == "--remote" || word.hasPrefix("--remote=")
      {
        return .unknown
      }
      if word.hasPrefix("-p") && !word.hasPrefix("--") {
        profiles.append(word == "-p" ? value(after: "-p") : String(word.dropFirst(2)))
      } else if word == "--profile" || word.hasPrefix("--profile=") {
        profiles.append(value(after: "--profile"))
      } else if word == "--enable" || word.hasPrefix("--enable=") {
        if value(after: "--enable") == "plugins" { plugins = true }
      } else if word == "--disable" || word.hasPrefix("--disable=") {
        if value(after: "--disable") == "plugins" { plugins = false }
      }
      index += 1
    }
    guard profiles.count <= 1 else { return .unknown }
    guard let profile = profiles.first else { return .known(profile: nil, plugins: plugins) }
    guard let profile, isPathComponent(profile) else { return .unknown }
    return .known(profile: profile, plugins: plugins)
  }

  /// The skill directories of every plugin that Codex, launched with
  /// `extraArguments` in each of `projectDirectories` (the working
  /// directory and its parents up to the repository root), has enabled,
  /// called as `<plugin>:<skill>`. Each cached version is listed, newest
  /// first, so the newest copy keeps a name.
  static func skillDirectories(
    configRoot: URL, extraArguments: String, projectDirectories: [URL]
  ) -> [SkillDirectory] {
    guard case .known(let profile, let launchPlugins) = launchConfig(extraArguments: extraArguments),
      launchPlugins != false
    else { return [] }
    // A trusted project's `.codex/config.toml` is one more layer. Whether
    // Codex trusts the project is its own state, so a project config that
    // says anything about plugins gives no plugin skills.
    for directory in projectDirectories {
      let file = directory.appending(path: ".codex/config.toml", directoryHint: .notDirectory)
      if let text = read(file), Layer(text).mentionsPlugins { return [] }
    }
    guard let base = read(configRoot.appending(path: "config.toml", directoryHint: .notDirectory))
    else { return [] }
    var layers = [base]
    if let profile {
      guard let text = read(configRoot.appending(path: "\(profile).config.toml", directoryHint: .notDirectory))
      else { return [] }
      layers.append(text)
    }
    guard let plugins = enabledPlugins(layers: layers, featureOverride: launchPlugins) else { return [] }
    let cache = configRoot.appending(path: "plugins/cache", directoryHint: .isDirectory)
    return plugins.flatMap { plugin in
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

  /// Plugins that the config `layers`, lowest precedence first, leave
  /// enabled, in the order they first appear. A later layer's `enabled`
  /// for a plugin wins; a plugin without `true` is off. `[]` when
  /// `[features] plugins = false` is the last word on the feature and
  /// `featureOverride` (from the launch flags) does not turn it back on.
  /// `nil` when a layer sets plugins in a form codans does not read.
  static func enabledPlugins(layers: [String], featureOverride: Bool? = nil) -> [Plugin]? {
    var order: [Plugin] = []
    var enabled: [Plugin: Bool] = [:]
    var feature: Bool?
    for text in layers {
      let layer = Layer(text)
      guard !layer.isUnreadable else { return nil }
      for (plugin, flag) in layer.plugins {
        if !order.contains(plugin) { order.append(plugin) }
        if let flag { enabled[plugin] = flag }
      }
      if let flag = layer.pluginsFeature { feature = flag }
    }
    if (featureOverride ?? feature) == false { return [] }
    return order.filter { enabled[$0] == true }
  }

  /// What one config file says about plugins.
  private struct Layer {
    /// `[plugins."<plugin>@<marketplace>"]` tables in file order, with
    /// their `enabled` value (`nil` when the table does not set it).
    var plugins: [(Plugin, Bool?)] = []
    /// `[features] plugins`.
    var pluginsFeature: Bool?
    /// Plugins or the plugins feature set in a form codans does not read:
    /// a `[plugins]` table, a dotted `plugins.` or `features.` key, a
    /// plugin key that is not one directory name, or a value that is not
    /// `true` or `false`.
    var isUnreadable = false

    var mentionsPlugins: Bool { !plugins.isEmpty || pluginsFeature != nil || isUnreadable }

    init(_ text: String) {
      for line in Self.topLevelLines(text) where line.hasPrefix("plugins") || line.hasPrefix("features") {
        isUnreadable = true
      }
      for table in TOMLLite.tables(in: text) {
        if table == "plugins" { isUnreadable = true }
        if table == "features" {
          let entry = TOMLLite.entries(in: text, table: table).last { $0.key == "plugins" }
          if let entry {
            guard let flag = Self.bool(entry.value) else {
              isUnreadable = true
              continue
            }
            pluginsFeature = flag
          }
        }
        guard table.hasPrefix("plugins.") else { continue }
        guard let key = TOMLLite.string(String(table.dropFirst("plugins.".count))),
          let at = key.firstIndex(of: "@")
        else {
          isUnreadable = true
          continue
        }
        let plugin = Plugin(name: String(key[..<at]), marketplace: String(key[key.index(after: at)...]))
        guard isPathComponent(plugin.name), isPathComponent(plugin.marketplace) else {
          isUnreadable = true
          continue
        }
        let entry = TOMLLite.entries(in: text, table: table).last { $0.key == "enabled" }
        if let entry, Self.bool(entry.value) == nil { isUnreadable = true }
        plugins.append((plugin, entry.flatMap { Self.bool($0.value) }))
      }
    }

    /// `true` / `false`, with an optional trailing comment.
    private static func bool(_ raw: String) -> Bool? {
      switch raw.split(separator: "#", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) {
      case "true": return true
      case "false": return false
      default: return nil
      }
    }

    /// Lines before the first table header, without comments and blanks.
    private static func topLevelLines(_ text: String) -> [String] {
      var lines: [String] = []
      for raw in text.split(whereSeparator: \.isNewline) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("[") { break }
        if !line.isEmpty, !line.hasPrefix("#") { lines.append(line) }
      }
      return lines
    }
  }

  private static func read(_ url: URL) -> String? {
    FileManager.default.contents(atPath: url.path(percentEncoded: false)).flatMap {
      String(data: $0, encoding: .utf8)
    }
  }

  /// A name that stays one directory below its parent.
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

extension CodexPluginRegistry.Plugin: Hashable {}
