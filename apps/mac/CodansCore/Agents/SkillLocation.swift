import Foundation

/// How a prompt calls one Agent Skill explicitly. An agent gets skill
/// completion only after a probe on its real CLI shows that this spelling
/// runs in the first prompt (ADR 0010); until then it is `none`.
public nonisolated enum SkillInvocationStyle: Equatable, Sendable, Hashable {
  /// No verified spelling. The composer offers no completion.
  case none
  /// `/name`, the Claude Code spelling.
  case slash

  /// Character that opens the completion list, or `nil` for `none`.
  public var prefix: Character? {
    switch self {
    case .none: return nil
    case .slash: return "/"
    }
  }

  /// The token that calls the skill named `name`, or `nil` for `none`.
  public func token(for name: String) -> String? {
    prefix.map { "\($0)\(name)" }
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

/// The rule by which one `AgentKind` finds its Agent Skills and calls them.
/// See GLOSSARY → Agent Skills and the Agent Skill Completion design doc.
public nonisolated struct SkillLocation: Equatable, Sendable, Hashable {
  /// User-level skill directories, relative to the effective home
  /// (`.claude/skills`). A directory under `configRoot.defaultDirectory`
  /// moves with the config root.
  public let userDirectories: [String]
  public let configRoot: SkillConfigRoot?
  public let invocationStyle: SkillInvocationStyle
  public let invocationPosition: SkillInvocationPosition

  public init(
    userDirectories: [String] = [],
    configRoot: SkillConfigRoot? = nil,
    invocationStyle: SkillInvocationStyle = .none,
    invocationPosition: SkillInvocationPosition = .leading
  ) {
    self.userDirectories = userDirectories
    self.configRoot = configRoot
    self.invocationStyle = invocationStyle
    self.invocationPosition = invocationPosition
  }

  /// An agent without verified skill calls.
  public static let none = SkillLocation()

  public var supportsCompletion: Bool { invocationStyle != .none }
}

extension SkillLocation {
  /// Claude Code reads `~/.claude/skills`; `CLAUDE_CONFIG_DIR` replaces
  /// `~/.claude`. The probe in the design doc showed that `/name` runs at
  /// the prompt start and in the middle of the first prompt.
  public static let claudeCode = SkillLocation(
    userDirectories: [".claude/skills"],
    configRoot: SkillConfigRoot(environmentVariable: "CLAUDE_CONFIG_DIR", defaultDirectory: ".claude"),
    invocationStyle: .slash,
    invocationPosition: .anywhere
  )
}
