import Foundation

/// Where a skill comes from, shown on its completion row.
public nonisolated enum AgentSkillSource: String, Equatable, Sendable, Hashable {
  case user = "User"
  case plugin = "Plugin"
}

/// One directory to scan for `*/SKILL.md`.
public nonisolated struct SkillDirectory: Equatable, Sendable, Hashable {
  public let url: URL
  public let source: AgentSkillSource
  /// Plugin name the agent puts before each skill name here, as in
  /// `<plugin>:<skill>`. `nil` for skills called by their bare name.
  public let namespace: String?
  public let layout: Layout

  /// What `url` holds.
  public enum Layout: Equatable, Sendable, Hashable {
    /// Skill folders, each with a `SKILL.md`.
    case skillFolders
    /// One skill: `url` is the skill folder.
    case skill
  }

  public init(
    url: URL, source: AgentSkillSource, namespace: String? = nil, layout: Layout = .skillFolders
  ) {
    self.url = url
    self.source = source
    self.namespace = namespace
    self.layout = layout
  }
}

/// Turns a profile's Skill Location into the directories its launched agent
/// reads. The user's home and the state root are inputs, so tests do not
/// touch the real ones. Only `pluginDirectories` reads files.
public nonisolated enum SkillLocationResolver {
  /// Every directory to scan for `profile` launched in `projectDirectory`:
  /// user skills, then plugin skills. Reads plugin registry and settings
  /// files, so call it off the main actor.
  public static func directories(
    for profile: AgentProfile,
    projectDirectory: URL?,
    userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
    stateDirectory: URL = AppDirectories.stateDirectory()
  ) -> [SkillDirectory] {
    userDirectories(for: profile, userHome: userHome, stateDirectory: stateDirectory)
      + pluginDirectories(
        for: profile, projectDirectory: projectDirectory, userHome: userHome,
        stateDirectory: stateDirectory)
  }

  /// Skill directories of the plugins that `profile`'s agent, launched in
  /// `projectDirectory`, has enabled. The registry lives under its config
  /// root; the user, project, local, `--settings`, and managed settings
  /// decide which plugins are on. A file that is missing or cannot be read
  /// gives no plugins (registry) or no say (settings). Settings flags in the
  /// profile's extra arguments that cannot be read give no plugins.
  static func pluginDirectories(
    for profile: AgentProfile,
    projectDirectory: URL?,
    userHome: URL,
    stateDirectory: URL,
    managedSettings: URL = ClaudePluginRegistry.managedSettings
  ) -> [SkillDirectory] {
    let location = profile.descriptor.skillLocation
    guard location.supportsCompletion, let plugins = location.plugins,
      let root = configRootDirectory(for: profile, userHome: userHome, stateDirectory: stateDirectory)
    else { return [] }
    switch plugins {
    case .claudeCode:
      let launchSettings: URL?
      let flags = ClaudePluginRegistry.launchSettings(
        extraArguments: profile.extraArguments, projectDirectory: projectDirectory, userHome: userHome)
      switch flags {
      case .none: launchSettings = nil
      case .file(let url): launchSettings = url
      case .unknown: return []
      }
      let home = effectiveHome(for: profile, userHome: userHome, stateDirectory: stateDirectory)
      return ClaudePluginRegistry.skillDirectories(
        configRoot: root, home: home, projectDirectory: projectDirectory,
        launchSettings: launchSettings, managedSettings: managedSettings)
    }
  }

  /// The directory the agent's config root resolves to, or `nil` when the
  /// agent has none or its variable holds a relative path.
  static func configRootDirectory(
    for profile: AgentProfile, userHome: URL, stateDirectory: URL
  ) -> URL? {
    guard let root = profile.descriptor.skillLocation.configRoot else { return nil }
    let home = effectiveHome(for: profile, userHome: userHome, stateDirectory: stateDirectory)
    switch configRoot(root, envVars: profile.envVars, home: home) {
    case .unset: return home.appending(path: root.defaultDirectory, directoryHint: .isDirectory)
    case .moved(let url): return url
    case .unplaceable: return nil
    }
  }

  /// User-level skill directories for `profile`, resolved against the home
  /// the agent runs with and the config root its environment sets.
  public static func userDirectories(
    for profile: AgentProfile,
    userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
    stateDirectory: URL = AppDirectories.stateDirectory()
  ) -> [SkillDirectory] {
    let location = profile.descriptor.skillLocation
    guard location.supportsCompletion else { return [] }
    let home = effectiveHome(for: profile, userHome: userHome, stateDirectory: stateDirectory)
    return location.userDirectories.compactMap { relative in
      var base = home
      var path = relative
      if let root = location.configRoot, let rest = relativePath(relative, under: root.defaultDirectory) {
        switch configRoot(root, envVars: profile.envVars, home: home) {
        case .unset: break
        case .moved(let url): (base, path) = (url, rest)
        case .unplaceable: return nil
        }
      }
      let url = path.isEmpty ? base : base.appending(path: path, directoryHint: .isDirectory)
      return SkillDirectory(url: url.standardizedFileURL, source: .user)
    }
  }

  /// `HOME` of the launched agent, by the same rule as the `env` prefix of
  /// `AgentLaunchCommand`: a dedicated home wins over a `HOME` in the
  /// profile's variables, which wins over the user's home.
  static func effectiveHome(
    for profile: AgentProfile, userHome: URL, stateDirectory: URL
  ) -> URL {
    if profile.usesDedicatedHome {
      return AgentLaunchCommand.dedicatedHomeURL(for: profile, stateDirectory: stateDirectory)
    }
    if let home = profile.envVars["HOME"], home.hasPrefix("/") {
      return URL(fileURLWithPath: home, isDirectory: true)
    }
    return userHome
  }

  private enum ConfigRootValue {
    case unset
    case moved(URL)
    /// A relative path depends on the agent's working directory. The
    /// directories under the root are left out rather than guessed.
    case unplaceable
  }

  private static func configRoot(
    _ root: SkillConfigRoot, envVars: [String: String], home: URL
  ) -> ConfigRootValue {
    guard let value = envVars[root.environmentVariable], !value.isEmpty else { return .unset }
    if value == "~" { return .moved(home) }
    if value.hasPrefix("~/") {
      return .moved(home.appending(path: String(value.dropFirst(2)), directoryHint: .isDirectory))
    }
    if value.hasPrefix("/") { return .moved(URL(fileURLWithPath: value, isDirectory: true)) }
    return .unplaceable
  }

  /// The rest of `path` below `root`, or `nil` when `path` is not under it.
  private static func relativePath(_ path: String, under root: String) -> String? {
    if path == root { return "" }
    guard path.hasPrefix(root + "/") else { return nil }
    return String(path.dropFirst(root.count + 1))
  }
}
