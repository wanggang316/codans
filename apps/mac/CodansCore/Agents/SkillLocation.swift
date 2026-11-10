import Foundation

/// How a prompt calls one Agent Skill explicitly. An agent gets skill
/// completion only after a probe on its real CLI shows that this spelling
/// runs in the first prompt (ADR 0010); until then it is `none`.
public nonisolated enum SkillInvocationStyle: Equatable, Sendable, Hashable {
  /// No verified spelling. The composer offers no completion.
  case none
  /// `/name`, the Claude Code spelling.
  case slash
  /// `/skill:name`, the Pi spelling.
  case slashSkill
  /// `$name`, the Codex spelling.
  case dollar

  /// Character that opens the completion list, or `nil` for `none`.
  public var prefix: Character? {
    switch self {
    case .none: return nil
    case .slash, .slashSkill: return "/"
    case .dollar: return "$"
    }
  }

  /// Text between the prefix and the skill name in a call (`skill:` in
  /// `/skill:name`). The completion query ignores it when typed.
  public var marker: String {
    self == .slashSkill ? "skill:" : ""
  }

  /// The token that calls the skill named `name`, or `nil` for `none`.
  public func token(for name: String) -> String? {
    prefix.map { "\($0)\(marker)\(name)" }
  }
}

/// Where in the first prompt a skill call runs.
public nonisolated enum SkillInvocationPosition: Equatable, Sendable, Hashable {
  /// Only as the first token of the prompt.
  case leading
  /// At the start of any token.
  case anywhere
}

/// The config root of an agent that an environment variable can move, for
/// example `CLAUDE_CONFIG_DIR` in place of `~/.claude`.
public nonisolated struct SkillConfigRoot: Equatable, Sendable, Hashable {
  /// Variable read from the profile's environment.
  public let environmentVariable: String
  /// Default root, relative to the effective home.
  public let defaultDirectory: String

  public init(environmentVariable: String, defaultDirectory: String) {
    self.environmentVariable = environmentVariable
    self.defaultDirectory = defaultDirectory
  }
}

/// The plugin system whose enabled plugins add skills, called as
/// `<plugin>:<skill>`.
public nonisolated enum SkillPluginSource: Equatable, Sendable, Hashable {
  /// Claude Code: `plugins/installed_plugins.json` and the `enabledPlugins`
  /// of `settings.json`, both under the config root.
  case claudeCode
  /// Codex: `plugins/cache/<marketplace>/<plugin>/<version>/skills`, for
  /// each plugin that `config.toml` enables, both under the config root.
  case codex
}

/// A trust check that gates an agent's project-level skills.
public nonisolated enum SkillProjectTrust: Equatable, Sendable, Hashable {
  /// Pi: `--approve`, extensions, `trust.json`, `defaultProjectTrust`
  /// (`PiProjectTrust`).
  case pi
}

/// How far an agent searches for project-level skill directories.
public nonisolated enum SkillProjectSearch: Equatable, Sendable, Hashable {
  /// The working directory and each parent up to the repository root.
  case walkUpToRepositoryRoot
  /// The working directory only.
  case workingDirectoryOnly
}

/// One project-level skill directory and how far the agent searches for it.
public nonisolated struct SkillProjectDirectory: Equatable, Sendable, Hashable {
  /// Relative to each searched project directory (`.claude/skills`).
  public let path: String
  public let search: SkillProjectSearch

  public init(_ path: String, search: SkillProjectSearch) {
    self.path = path
    self.search = search
  }
}

/// The rule by which one `AgentKind` finds its Agent Skills and calls them.
/// See GLOSSARY → Agent Skills and the Agent Skill Completion design doc.
public nonisolated struct SkillLocation: Equatable, Sendable, Hashable {
  /// User-level skill directories, relative to the effective home
  /// (`.claude/skills`). A directory under `configRoot.defaultDirectory`
  /// moves with the config root.
  public let userDirectories: [String]
  public let configRoot: SkillConfigRoot?
  /// Project-level skill directories. The resolver lists every directory
  /// of one searched project directory before the next one up.
  public let projectDirectories: [SkillProjectDirectory]
  /// The agent reads `projectDirectories` only in a project it trusts.
  /// `nil` when it reads them in every project.
  public let projectTrust: SkillProjectTrust?
  /// Which source keeps a name that more than one source has, first wins.
  public let precedence: [AgentSkillSource]
  /// Plugins resolve under `configRoot`, so a source needs one.
  public let plugins: SkillPluginSource?
  public let invocationStyle: SkillInvocationStyle
  public let invocationPosition: SkillInvocationPosition

  public init(
    userDirectories: [String] = [],
    configRoot: SkillConfigRoot? = nil,
    projectDirectories: [SkillProjectDirectory] = [],
    projectTrust: SkillProjectTrust? = nil,
    precedence: [AgentSkillSource] = [.project, .user],
    plugins: SkillPluginSource? = nil,
    invocationStyle: SkillInvocationStyle = .none,
    invocationPosition: SkillInvocationPosition = .leading
  ) {
    self.userDirectories = userDirectories
    self.configRoot = configRoot
    self.projectDirectories = projectDirectories
    self.projectTrust = projectTrust
    self.precedence = precedence
    self.plugins = plugins
    self.invocationStyle = invocationStyle
    self.invocationPosition = invocationPosition
  }

  /// An agent without verified skill calls.
  public static let none = SkillLocation()

  public var supportsCompletion: Bool { invocationStyle != .none }

  /// The user directory under the config root (`.claude/skills`): the
  /// folder only this agent reads. `nil` without a config root.
  public var configRootUserDirectory: String? {
    guard let root = configRoot else { return nil }
    return userDirectories.first { Self.isDirectory($0, under: root) }
  }

  /// User directories outside the config root (`.agents/skills`), which
  /// other agents can read too.
  public var sharedUserDirectories: [String] {
    guard let root = configRoot else { return userDirectories }
    return userDirectories.filter { !Self.isDirectory($0, under: root) }
  }

  private static func isDirectory(_ path: String, under root: SkillConfigRoot) -> Bool {
    path.hasPrefix(root.defaultDirectory + "/")
  }
}

extension SkillLocation {
  /// Claude Code reads `~/.claude/skills`; `CLAUDE_CONFIG_DIR` replaces
  /// `~/.claude`. In a project it reads `.claude/skills` from the working
  /// directory up to the repository root. A personal skill wins over a
  /// project skill with the same name. Enabled plugins add
  /// `/<plugin>:<skill>`. The probe in the design doc showed that `/name` runs at
  /// the prompt start and in the middle of the first prompt.
  public static let claudeCode = SkillLocation(
    userDirectories: [".claude/skills"],
    configRoot: SkillConfigRoot(environmentVariable: "CLAUDE_CONFIG_DIR", defaultDirectory: ".claude"),
    projectDirectories: [SkillProjectDirectory(".claude/skills", search: .walkUpToRepositoryRoot)],
    precedence: [.user, .project, .plugin],
    plugins: .claudeCode,
    invocationStyle: .slash,
    invocationPosition: .anywhere
  )

  /// Codex reads `~/.agents/skills` and `$CODEX_HOME/skills` (`CODEX_HOME`
  /// defaults to `~/.codex`), and `.agents/skills` from the working
  /// directory up to the repository root. Enabled plugins add
  /// `$<plugin>:<skill>`. The probe showed that `$name` runs at the prompt
  /// start and in the middle.
  public static let codex = SkillLocation(
    userDirectories: [".agents/skills", ".codex/skills"],
    configRoot: SkillConfigRoot(environmentVariable: "CODEX_HOME", defaultDirectory: ".codex"),
    projectDirectories: [SkillProjectDirectory(".agents/skills", search: .walkUpToRepositoryRoot)],
    precedence: [.project, .user, .plugin],
    plugins: .codex,
    invocationStyle: .dollar,
    invocationPosition: .anywhere
  )

  /// Pi reads `~/.pi/agent/skills` (`PI_CODING_AGENT_DIR` replaces
  /// `~/.pi/agent`) and `~/.agents/skills`; in a trusted project
  /// `.pi/skills` in the working directory and `.agents/skills` from there
  /// up to the repository root. The first skill found keeps a name:
  /// project before user. The probe showed that `/skill:name` runs at the
  /// prompt start (Pi expands it) and in the middle (the model loads it);
  /// project skills only when Pi trusts the project.
  public static let pi = SkillLocation(
    userDirectories: [".pi/agent/skills", ".agents/skills"],
    configRoot: SkillConfigRoot(environmentVariable: "PI_CODING_AGENT_DIR", defaultDirectory: ".pi/agent"),
    projectDirectories: [
      SkillProjectDirectory(".pi/skills", search: .workingDirectoryOnly),
      SkillProjectDirectory(".agents/skills", search: .walkUpToRepositoryRoot),
    ],
    projectTrust: .pi,
    precedence: [.project, .user],
    invocationStyle: .slashSkill,
    invocationPosition: .anywhere
  )
}
