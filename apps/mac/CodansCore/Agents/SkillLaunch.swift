import Foundation

/// How an agent starts, as skill completion reads it. `profile` gives the
/// agent kind, its home, and its environment; `arguments` are the words
/// after the executable, from which the launch flags that change skills
/// are read (`--settings`, `--profile`, `--no-skills`, ...). `nil`
/// arguments cannot be read, so the skills that depend on them are left
/// out (ADR 0010).
public nonisolated struct SkillLaunch: Equatable, Sendable {
  public var profile: AgentProfile
  public var arguments: [String]?

  /// A launch from `profile`. Its extra arguments are a shell fragment, so
  /// they are read only when they are plain words (`PlainShellWords`).
  public init(profile: AgentProfile) {
    self.profile = profile
    self.arguments = PlainShellWords.split(profile.extraArguments)
  }

  /// An agent of `kind` that runs now: `arguments` are its argv after the
  /// executable and `environment` its environment, as the kernel reports
  /// them. Only `HOME` and the agent's config-root variable are kept.
  /// `nil` when `HOME` is not an absolute path: the user-level skills
  /// would then depend on a directory codans cannot place.
  ///
  /// The shell has already expanded the arguments, so they need no plain
  /// word rule. A word that still starts with `~` was quoted: whether the
  /// agent expands it is not known, so such arguments cannot be read.
  public init?(kind: AgentKind, arguments: [String], environment: [String: String]) {
    var envVars: [String: String] = [:]
    if let home = environment["HOME"] {
      guard home.hasPrefix("/") else { return nil }
      envVars["HOME"] = home
    }
    if let variable = AgentCatalog.descriptor(for: kind).skillLocation.configRoot?.environmentVariable,
      let value = environment[variable]
    {
      envVars[variable] = value
    }
    // A fixed id: the profile is not stored, and two reads of the same
    // agent must compare equal.
    self.profile = AgentProfile(id: Self.runningAgentProfileID, kind: kind, envVars: envVars)
    self.arguments = arguments.contains { $0.hasPrefix("~") } ? nil : arguments
  }

  private static let runningAgentProfileID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}
