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

  /// What the profile's extra arguments do to the settings Claude Code loads.
  enum LaunchSettings: Equatable {
    /// No settings flag.
    case none
    /// `--settings <file>`: one more settings layer.
    case file(URL)
    /// A flag whose effect codans cannot read: shell syntax in the fragment
    /// (inline JSON, quotes, expansions, control operators, redirections), a
    /// repeated flag, `--setting-sources`, or `--plugin-dir`. Then no plugin
    /// skill is offered (ADR 0010).
    case unknown
  }

  /// Reads the settings flags from a profile's extra arguments, a raw shell
  /// fragment that the launch command appends as it is. `~` expands against
  /// `userHome` (the shell does it, before `env` sets the agent's `HOME`);
  /// a relative path against the directory the agent starts in.
  ///
  /// The shell splits the fragment, so codans reads it only when the shell
  /// would pass each word as it is: plain words and blanks. Any other
  /// character (`;`, `&`, `|`, `<`, `>`, quotes, `$`, globs, `#`, a line
  /// break) can change which words reach Claude Code, or whether the flag
  /// reaches it at all.
  static func launchSettings(
    extraArguments: String, projectDirectory: URL?, userHome: URL
  ) -> LaunchSettings {
    guard extraArguments.contains("--setting") || extraArguments.contains("--plugin-dir") else {
      return .none
    }
    guard extraArguments.allSatisfy(isPlainShellCharacter) else { return .unknown }
    let tokens = extraArguments.split(whereSeparator: \.isWhitespace).map(String.init)
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
        values.append(value.hasPrefix("~") ? nil : value)
      }
    }
    guard !values.isEmpty else { return .none }
    guard values.count == 1, let value = values[0], !value.isEmpty else { return .unknown }
    if value.hasPrefix("/") { return .file(URL(fileURLWithPath: value).standardizedFileURL) }
    if value.hasPrefix("~/") {
      return .file(userHome.appending(path: String(value.dropFirst(2))).standardizedFileURL)
    }
    if value.hasPrefix("~") { return .unknown }
    guard let projectDirectory else { return .unknown }
    return .file(projectDirectory.appending(path: value).standardizedFileURL)
  }

  /// A character the shell keeps as it is inside a word, or a blank between
  /// words. `~` matters only at the start of a word and is handled there.
  private static func isPlainShellCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == " " || character == "\t"
      || "/._-+,@:%=~".contains(character)
  }

  /// The settings files that can set `enabledPlugins`, lowest precedence
  /// first: user, project, local project, `--settings`, managed. Claude Code
  /// reads the project files in the directory it starts in.
  static func settingsFiles(
    configRoot: URL, projectDirectory: URL?, launchSettings: URL?, managedSettings: URL
  ) -> [URL] {
    var files = [configRoot.appending(path: "settings.json", directoryHint: .notDirectory)]
    if let projectDirectory {
      files.append(projectDirectory.appending(path: ".claude/settings.json", directoryHint: .notDirectory))
      files.append(projectDirectory.appending(path: ".claude/settings.local.json", directoryHint: .notDirectory))
    }
    if let launchSettings { files.append(launchSettings) }
    files.append(managedSettings)
    return files
  }

  /// The skill directories of every enabled plugin under `configRoot`, as
  /// enabled for an agent that starts in `projectDirectory` with the
  /// `--settings` file `launchSettings`.
  static func skillDirectories(
    configRoot: URL, home: URL, projectDirectory: URL?, launchSettings: URL? = nil,
    managedSettings: URL = managedSettings
  ) -> [SkillDirectory] {
    let registry = configRoot.appending(path: "plugins/installed_plugins.json", directoryHint: .notDirectory)
    let fileManager = FileManager.default
    guard let registryData = fileManager.contents(atPath: registry.path(percentEncoded: false)) else {
      return []
    }
    let settings = settingsFiles(
      configRoot: configRoot, projectDirectory: projectDirectory, launchSettings: launchSettings,
      managedSettings: managedSettings
    ).compactMap { fileManager.contents(atPath: $0.path(percentEncoded: false)) }
    return enabledPlugins(registry: registryData, settings: settings, home: home).flatMap { plugin in
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
