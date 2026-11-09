import Foundation

/// Where a skill comes from, shown on its completion row.
public nonisolated enum AgentSkillSource: String, Equatable, Sendable, Hashable {
  case user = "User"
}

/// One directory to scan for `*/SKILL.md`.
public nonisolated struct SkillDirectory: Equatable, Sendable, Hashable {
  public let url: URL
  public let source: AgentSkillSource

  public init(url: URL, source: AgentSkillSource) {
    self.url = url
    self.source = source
  }
}

/// Turns a profile's Skill Location into the directories its launched agent
/// reads. Pure: the user's home and the state root are inputs, so tests do
/// not touch the real ones.
public nonisolated enum SkillLocationResolver {
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
