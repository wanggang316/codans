import Foundation

/// Where a skill comes from, shown on its completion row.
public nonisolated enum AgentSkillSource: String, Equatable, Sendable, Hashable {
  case project = "Project"
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
/// touch the real ones. The repository walk and the plugin registry read
/// files, so call `directories` off the main actor.
public nonisolated enum SkillLocationResolver {
  /// Skill directories of the plugins that `profile`'s agent, launched in
  /// `projectStart`, has enabled. The registry lives under its config
  /// root. For Claude Code the user, project, local, `--settings`, and
  /// managed settings decide which plugins are on; for Codex `config.toml`,
  /// the `--profile` layer, and the plugin flags (`CodexPluginRegistry`). A
  /// file that is missing or cannot be read gives no plugins (registry) or
  /// no say (settings). Settings flags in the
  /// profile's extra arguments that cannot be read give no plugins.
  static func pluginDirectories(
    for profile: AgentProfile,
    projectStart: URL?,
    projectStartExists: Bool = true,
    userHome: URL,
    stateDirectory: URL,
    managedSettings: URL = ClaudePluginRegistry.managedSettings,
    fileSystem: any SkillFileSystem = LocalSkillFileSystem(),
    isRepositoryRoot: ((URL) -> Bool)? = nil
  ) -> [SkillDirectory] {
    let isRepositoryRoot = isRepositoryRoot ?? fileSystem.hasGitEntry
    let location = profile.descriptor.skillLocation
    guard location.supportsCompletion, let plugins = location.plugins,
      let root = configRootDirectory(for: profile, userHome: userHome, stateDirectory: stateDirectory)
    else { return [] }
    switch plugins {
    case .claudeCode:
      // A relative `--settings` file outside a new worktree is somewhere
      // codans cannot place: the worktree's own directory is not known yet.
      if !projectStartExists,
        let relative = ClaudePluginRegistry.relativeLaunchSettingsPath(extraArguments: profile.extraArguments),
        pathInside(relative) == nil
      {
        return []
      }
      let launchSettings: URL?
      let flags = ClaudePluginRegistry.launchSettings(
        extraArguments: profile.extraArguments, projectStart: projectStart, userHome: userHome)
      switch flags {
      case .none: launchSettings = nil
      case .file(let url): launchSettings = url
      case .unknown: return []
      }
      let home = effectiveHome(for: profile, userHome: userHome, stateDirectory: stateDirectory)
      return ClaudePluginRegistry.skillDirectories(
        configRoot: root, home: home, projectStart: projectStart,
        launchSettings: launchSettings, managedSettings: managedSettings, fileSystem: fileSystem)
    case .codex:
      let searched = projectStart.map { searchedDirectories(from: $0, isRepositoryRoot: isRepositoryRoot) } ?? []
      return CodexPluginRegistry.skillDirectories(
        configRoot: root, extraArguments: profile.extraArguments, projectDirectories: searched,
        fileSystem: fileSystem)
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

  /// Project-level, user-level, and enabled plugin skill directories for
  /// `profile`, in that order. `projectStart` is the directory the agent
  /// starts in (see `projectStartDirectory(in:branch:)`), `nil` when there
  /// is none. `projectStartExists` is `false` when `projectStart` stands in
  /// for a new worktree (`NewWorktreeFiles`): the agent will start in
  /// another directory, so a decision saved for `projectStart` does not
  /// apply to it. An agent with a project trust check (Pi) gets project
  /// directories only in a project it trusts.
  public static func directories(
    for profile: AgentProfile,
    projectStart: URL?,
    projectStartExists: Bool = true,
    userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
    stateDirectory: URL = AppDirectories.stateDirectory(),
    managedSettings: URL? = nil,
    fileSystem: any SkillFileSystem = LocalSkillFileSystem(),
    isRepositoryRoot: ((URL) -> Bool)? = nil
  ) -> [SkillDirectory] {
    let isRepositoryRoot = isRepositoryRoot ?? fileSystem.hasGitEntry
    let managedSettings = managedSettings ?? ClaudePluginRegistry.managedSettings
    guard loadsSkills(profile) else { return [] }
    let project: [SkillDirectory] =
      projectStart.map { start in
        guard
          trustsProject(
            profile, start: start, startExists: projectStartExists, userHome: userHome,
            stateDirectory: stateDirectory, fileSystem: fileSystem)
        else { return [] }
        return projectDirectories(for: profile, startDirectory: start, isRepositoryRoot: isRepositoryRoot)
      } ?? []
    return project + userDirectories(for: profile, userHome: userHome, stateDirectory: stateDirectory)
      + pluginDirectories(
        for: profile, projectStart: projectStart, projectStartExists: projectStartExists, userHome: userHome,
        stateDirectory: stateDirectory, managedSettings: managedSettings, fileSystem: fileSystem,
        isRepositoryRoot: isRepositoryRoot)
  }

  /// `false` when the profile's launch flags turn skills off: Pi's
  /// `--no-skills` loads none and expands no `/skill:name` call. Pi
  /// arguments that are not plain words can hide that flag from codans
  /// (`--no-skills 2>/dev/null`), so they give no skills (ADR 0010).
  static func loadsSkills(_ profile: AgentProfile) -> Bool {
    switch profile.descriptor.skillLocation.projectTrust {
    case nil: return true
    case .pi:
      guard let launch = PiLaunchArguments(profile.extraArguments) else { return false }
      return !launch.noSkills
    }
  }

  /// `true` when the agent of `profile` reads project skills in `start`.
  /// `startExists` is `false` when `start` stands in for a new worktree.
  static func trustsProject(
    _ profile: AgentProfile, start: URL, startExists: Bool, userHome: URL, stateDirectory: URL,
    fileSystem: any SkillFileSystem = LocalSkillFileSystem()
  ) -> Bool {
    switch profile.descriptor.skillLocation.projectTrust {
    case nil: return true
    case .pi:
      guard
        let agentDirectory = configRootDirectory(
          for: profile, userHome: userHome, stateDirectory: stateDirectory)
      else { return false }
      return PiProjectTrust.trusts(
        agentDirectory: agentDirectory, extraArguments: profile.extraArguments, start: start,
        startExists: startExists, fileSystem: fileSystem)
    }
  }

  /// The directory an agent launched in `project` starts in, from which it
  /// searches project-level skills. `branch` is the branch the agent works
  /// on, `nil` for a new worktree.
  ///
  /// - An existing worktree that holds `branch`: that worktree.
  /// - A new worktree, or a branch no worktree holds: the worktree does not
  ///   exist yet, so the project's main checkout stands in for it. Its
  ///   files are not the new worktree's: read a `NewWorktreeFiles` view
  ///   built from it instead.
  /// - A folder or a workspace project: its one working directory.
  ///
  /// For a remote project the URL holds a path on its host, read over SSH;
  /// it is not standardized, which would consult this Mac's file system.
  public static func projectStartDirectory(in project: Project, branch: String?) -> URL? {
    let path: String?
    if !project.supportsWorktrees || project.isWorkspace {
      path = project.soleWorkingWorktree?.path
    } else if let branch,
      let worktree = project.worktrees.first(where: { !$0.archived && $0.branch == branch })
    {
      path = worktree.path
    } else {
      path = project.gitRoot ?? project.rootPath
    }
    return path.map {
      let url = URL(fileURLWithPath: $0, isDirectory: true)
      return project.isOnThisMac ? url.standardizedFileURL : url
    }
  }

  /// `true` when an agent launched in `project` on `branch` (`nil` for a
  /// new worktree) gets a new worktree first. Its project files are then
  /// read from a view of the new worktree (`projectFilePaths(for:)`).
  public static func createsWorktree(in project: Project, branch: String?) -> Bool {
    guard project.supportsWorktrees, !project.isWorkspace else { return false }
    guard let branch else { return true }
    return !project.worktrees.contains { !$0.archived && $0.branch == branch }
  }

  /// The project files skill completion reads for `profile`, relative to
  /// the directory the agent starts in: its project skill directories and
  /// the project settings that turn its plugins on or off. A view of a new
  /// worktree holds these paths (`NewWorktreeFiles`).
  public static func projectFilePaths(for profile: AgentProfile) -> [String] {
    let location = profile.descriptor.skillLocation
    guard location.supportsCompletion else { return [] }
    var paths = location.projectDirectories.map(\.path)
    switch location.plugins {
    case .claudeCode?:
      paths += [".claude/settings.json", ".claude/settings.local.json"]
      if let settings = ClaudePluginRegistry.relativeLaunchSettingsPath(extraArguments: profile.extraArguments)
        .flatMap(pathInside)
      {
        paths.append(settings)
      }
    case .codex?:
      paths.append(".codex/config.toml")
    case nil:
      break
    }
    var seen = Set<String>()
    return paths.filter { seen.insert($0).inserted }
  }

  /// `relative` with `.` and `..` applied, or `nil` when it is empty or
  /// leaves the directory it is relative to.
  public static func pathInside(_ relative: String) -> String? {
    guard !relative.hasPrefix("/") else { return nil }
    var components: [Substring] = []
    for component in relative.split(separator: "/") {
      switch component {
      case ".": continue
      case "..":
        guard components.popLast() != nil else { return nil }
      default: components.append(component)
      }
    }
    return components.isEmpty ? nil : components.joined(separator: "/")
  }

  /// Project-level skill directories for `profile`, searched from
  /// `startDirectory` by the search of each directory, nearest first. A walk
  /// that finds no repository root reads the start directory only.
  public static func projectDirectories(
    for profile: AgentProfile,
    startDirectory: URL,
    isRepositoryRoot: (URL) -> Bool = hasGitEntry
  ) -> [SkillDirectory] {
    projectDirectories(
      in: profile.descriptor.skillLocation, startDirectory: startDirectory,
      isRepositoryRoot: isRepositoryRoot)
  }

  static func projectDirectories(
    in location: SkillLocation, startDirectory: URL, isRepositoryRoot: (URL) -> Bool
  ) -> [SkillDirectory] {
    guard location.supportsCompletion, !location.projectDirectories.isEmpty else { return [] }
    var searched = [startDirectory.standardizedFileURL]
    if location.projectDirectories.contains(where: { $0.search == .walkUpToRepositoryRoot }) {
      searched = searchedDirectories(from: startDirectory, isRepositoryRoot: isRepositoryRoot)
    }
    return searched.enumerated().flatMap { depth, directory in
      location.projectDirectories
        .filter { depth == 0 || $0.search == .walkUpToRepositoryRoot }
        .map { relative in
          SkillDirectory(
            url: directory.appending(path: relative.path, directoryHint: .isDirectory).standardizedFileURL,
            source: .project)
        }
    }
  }

  /// `start` and its parents up to the repository root, nearest first, or
  /// `start` alone when no parent is a repository root.
  static func searchedDirectories(from start: URL, isRepositoryRoot: (URL) -> Bool) -> [URL] {
    let start = start.standardizedFileURL
    return walkUp(from: start, isRepositoryRoot: isRepositoryRoot) ?? [start]
  }

  /// Claude Code's managed settings file on a host whose kernel
  /// (`uname -s`) is `kernel`: the macOS path on `Darwin`, else the Linux
  /// path.
  public static func claudeManagedSettings(kernel: String) -> URL {
    kernel == "Darwin" ? ClaudePluginRegistry.managedSettings : ClaudePluginRegistry.linuxManagedSettings
  }

  /// `true` when `directory` holds a `.git` folder or a worktree's `.git`
  /// file.
  public static func hasGitEntry(_ directory: URL) -> Bool {
    LocalSkillFileSystem().hasGitEntry(directory)
  }

  /// `start` and its parents up to the first repository root, or `nil`
  /// when no parent is one.
  private static func walkUp(from start: URL, isRepositoryRoot: (URL) -> Bool) -> [URL]? {
    var path = start.path(percentEncoded: false)
    if path.count > 1, path.hasSuffix("/") { path.removeLast() }
    var chain: [URL] = []
    while true {
      let directory = URL(fileURLWithPath: path, isDirectory: true)
      chain.append(directory)
      if isRepositoryRoot(directory) { return chain }
      let parent = (path as NSString).deletingLastPathComponent
      if parent == path || parent.isEmpty { return nil }
      path = parent
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
