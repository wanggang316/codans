import Foundation

/// Claude Code's plugin registry: which plugins are installed where, and
/// which of them the settings enable. Both formats are not public, so a
/// file that does not match gives no plugins and leaves other skill sources
/// alone (design doc: Agent Skill Completion → Plugin Skill).
nonisolated enum ClaudePluginRegistry {
  /// Managed (enterprise) settings on macOS. They override every other
  /// settings file.
  static let managedSettings = URL(
    fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json")

  /// Managed settings on Linux, for a remote host.
  static let linuxManagedSettings = URL(fileURLWithPath: "/etc/claude-code/managed-settings.json")

  /// What the profile's extra arguments do to the settings Claude Code loads.
  enum LaunchSettings: Equatable {
    /// Plain arguments without a settings flag.
    case none
    /// `--settings <file>`: one more settings layer.
    case file(URL)
    /// Arguments whose effect codans cannot be sure of: any shell syntax,
    /// a repeated `--settings`, `--setting-sources`, or `--plugin-dir`.
    /// Then no plugin skill is offered (ADR 0010).
    case unknown
  }

  /// Reads the settings flags from a profile's extra arguments. `~`
  /// expands against `userHome` (the shell does it, before `env` sets the
  /// agent's `HOME`); a relative path against the directory the agent
  /// starts in. Arguments that are not plain words (`PlainShellWords`) are
  /// `.unknown`, so a profile with any shell syntax in its extra arguments
  /// gets no plugin skills; user and project skills stay (ADR 0010).
  static func launchSettings(
    extraArguments: String, projectStart: URL?, userHome: URL
  ) -> LaunchSettings {
    switch settingsFlag(extraArguments) {
    case .none: return .none
    case .unknown: return .unknown
    case .value(let value):
      if value.hasPrefix("/") { return .file(URL(fileURLWithPath: value).standardizedFileURL) }
      if value.hasPrefix("~/") {
        return .file(userHome.appending(path: String(value.dropFirst(2))).standardizedFileURL)
      }
      guard let projectStart else { return .unknown }
      return .file(projectStart.appending(path: value).standardizedFileURL)
    }
  }

  /// The `--settings` path when it is relative to the directory the agent
  /// starts in, else `nil`.
  static func relativeLaunchSettingsPath(extraArguments: String) -> String? {
    guard case .value(let value) = settingsFlag(extraArguments),
      !value.hasPrefix("/"), !value.hasPrefix("~/")
    else { return nil }
    return value
  }

  private enum SettingsFlag {
    case none
    case unknown
    case value(String)
  }

  private static func settingsFlag(_ extraArguments: String) -> SettingsFlag {
    guard let tokens = PlainShellWords.split(extraArguments) else { return .unknown }
    var values: [String?] = []
    for (index, token) in tokens.enumerated() {
      if token == "--setting-sources" || token.hasPrefix("--setting-sources=")
        || token == "--plugin-dir" || token.hasPrefix("--plugin-dir=")
      {
        return .unknown
      }
      if token == "--settings" {
        values.append(index + 1 < tokens.count ? tokens[index + 1] : nil)
      } else if token.hasPrefix("--settings=") {
        // Whether `~` after `=` expands depends on the shell and its options.
        let value = String(token.dropFirst("--settings=".count))
        values.append(value.hasPrefix("~") || value.hasPrefix("=") ? nil : value)
      }
    }
    guard !values.isEmpty else { return .none }
    guard values.count == 1, let value = values[0], !value.isEmpty else { return .unknown }
    return .value(value)
  }

  /// The settings files that can set `enabledPlugins`, lowest precedence
  /// first: user, project, local project, `--settings`, managed. Claude Code
  /// reads the project files in the directory it starts in.
  static func settingsFiles(
    configRoot: URL, projectStart: URL?, launchSettings: URL?, managedSettings: URL
  ) -> [URL] {
    var files = [configRoot.appending(path: "settings.json", directoryHint: .notDirectory)]
    if let projectStart {
      files.append(projectStart.appending(path: ".claude/settings.json", directoryHint: .notDirectory))
      files.append(projectStart.appending(path: ".claude/settings.local.json", directoryHint: .notDirectory))
    }
    if let launchSettings { files.append(launchSettings) }
    files.append(managedSettings)
    return files
  }

  /// The skill directories of every enabled plugin under `configRoot`, as
  /// enabled for an agent that starts in `projectStart` with the
  /// `--settings` file `launchSettings`.
  static func skillDirectories(
    configRoot: URL, home: URL, projectStart: URL?, launchSettings: URL? = nil,
    managedSettings: URL = managedSettings, fileSystem: any SkillFileSystem = LocalSkillFileSystem()
  ) -> [SkillDirectory] {
    let registry = configRoot.appending(path: "plugins/installed_plugins.json", directoryHint: .notDirectory)
    guard let registryData = fileSystem.contents(of: registry) else {
      return []
    }
    let settings = settingsFiles(
      configRoot: configRoot, projectStart: projectStart, launchSettings: launchSettings,
      managedSettings: managedSettings
    )
    .compactMap { fileSystem.contents(of: $0) }
    return enabledPlugins(registry: registryData, settings: settings, home: home).flatMap { plugin in
      skillDirectories(of: plugin, fileSystem: fileSystem).map { url, layout in
        SkillDirectory(url: url, source: .plugin, namespace: plugin.name, layout: layout)
      }
    }
  }

  /// Where one plugin keeps its skills: `skills/`, plus the paths that the
  /// `skills` field of `.claude-plugin/plugin.json` declares. Without that
  /// field, also `.claude/skills/`, which some plugins use. A plugin that
  /// declares its paths gets only those, because Claude Code then loads
  /// only the declared skills of `.claude/skills/` (ADR 0010).
  static func skillDirectories(
    of plugin: Plugin, fileSystem: any SkillFileSystem = LocalSkillFileSystem()
  ) -> [(URL, SkillDirectory.Layout)] {
    let root = plugin.installPath
    let defaults = root.appending(path: "skills", directoryHint: .isDirectory)
    guard let declared = declaredSkillPaths(installPath: root, fileSystem: fileSystem) else {
      return [
        (defaults, .skillFolders),
        (root.appending(path: ".claude/skills", directoryHint: .isDirectory), .skillFolders),
      ]
    }
    return [(defaults, .skillFolders)]
      + declared.map { url in
        let file = url.appending(path: "SKILL.md", directoryHint: .notDirectory)
        return (url, fileSystem.fileExists(at: file) ? .skill : .skillFolders)
      }
  }

  /// The `skills` paths of the plugin manifest, resolved in the install
  /// path, or `nil` when the manifest declares none or cannot be read.
  /// A path that leaves the install path is dropped.
  private static func declaredSkillPaths(installPath: URL, fileSystem: any SkillFileSystem) -> [URL]? {
    let manifest = installPath.appending(path: ".claude-plugin/plugin.json", directoryHint: .notDirectory)
    guard let data = fileSystem.contents(of: manifest),
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

  /// Installed plugins whose `<plugin>@<marketplace>` key is enabled, in
  /// key order. `settings` go from lowest to highest precedence; a later
  /// file's `true` or `false` for a key wins, and a file that is not a JSON
  /// object is skipped, as Claude Code skips an invalid settings file. A
  /// plugin installed more than once lists each distinct install path.
  static func enabledPlugins(registry: Data, settings: [Data], home: URL) -> [Plugin] {
    guard let object = try? JSONSerialization.jsonObject(with: registry) as? [String: Any],
      let installs = object["plugins"] as? [String: Any]
    else { return [] }
    let enabled = enabledKeys(settings)
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

  private static func enabledKeys(_ settings: [Data]) -> Set<String> {
    var flags: [String: Bool] = [:]
    for data in settings {
      guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let values = object["enabledPlugins"] as? [String: Any]
      else { continue }
      for (key, value) in values {
        if let flag = value as? Bool { flags[key] = flag }
      }
    }
    return Set(flags.compactMap { key, flag in flag ? key : nil })
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
