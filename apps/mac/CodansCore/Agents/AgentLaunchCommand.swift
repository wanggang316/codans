import Foundation

/// Renders an `AgentProfile` into the exact shell command codans types into
/// the pane it spawns. Pure and total: the Settings pane's Launch Preview and
/// the runtime launch path both call this, so what the user reads is
/// character-for-character what runs.
///
/// Shape:
///
///     [env KEY='value' … HOME='…'] <executable> [model] [effort] [mode] [extra] [prompt]
///
/// Overrides ride an `env` prefix rather than the pane's spawn environment on
/// purpose: the variables must reach the agent process and nothing else, so
/// the shell the user is left with after the agent exits keeps their normal
/// environment.
public nonisolated enum AgentLaunchCommand {
  /// Directory name under the config root that holds per-profile HOMEs.
  public static let dedicatedHomeDirectoryName = "agent-homes"

  /// `HOME` codans points a dedicated-home profile at:
  /// `<config>/agent-homes/<profile id>`.
  public static func dedicatedHomeURL(
    for profile: AgentProfile,
    configDirectory: URL = AppDirectories.configDirectory()
  ) -> URL {
    configDirectory
      .appendingPathComponent(dedicatedHomeDirectoryName, isDirectory: true)
      .appendingPathComponent(profile.id.uuidString, isDirectory: true)
  }

  /// Full command line for `profile`, optionally seeded with a kickoff
  /// `prompt` (a handoff's receiver instruction). The prompt is rendered
  /// through the descriptor's `promptStyle` and trails everything else, so it
  /// can never be mistaken for a flag value; an agent without a prompt style
  /// ignores the prompt rather than emitting an argument it cannot parse.
  ///
  /// `configDirectory` is injected so tests can render a dedicated-home
  /// command without touching the user's real config root.
  public static func render(
    profile: AgentProfile,
    prompt: String? = nil,
    configDirectory: URL = AppDirectories.configDirectory()
  ) -> String {
    let descriptor = profile.descriptor
    var tokens: [String] = []

    let prefix = envPrefix(profile: profile, configDirectory: configDirectory)
    if !prefix.isEmpty {
      tokens.append("env")
      tokens.append(contentsOf: prefix)
    }

    tokens.append(descriptor.executable)

    if let flag = descriptor.modelFlag, let model = descriptor.model(id: profile.modelID) {
      tokens.append(contentsOf: flag.arguments(for: model.id))
    }
    if let flag = descriptor.reasoningEffortFlag,
      let effort = descriptor.reasoningEffort(id: profile.reasoningEffortID)
    {
      tokens.append(contentsOf: flag.arguments(for: effort.id))
    }
    if let mode = descriptor.executionMode(id: profile.executionModeID) {
      tokens.append(contentsOf: mode.arguments)
    }

    var command = tokens.joined(separator: " ")
    // Extra arguments are a raw shell fragment, not a value: the user writes
    // them to reach flags the option catalogue does not model, so they are
    // appended verbatim rather than quoted.
    let extra = profile.extraArguments.trimmingCharacters(in: .whitespacesAndNewlines)
    if !extra.isEmpty {
      command += " " + extra
    }
    if let prompt, !prompt.isEmpty, let style = descriptor.promptStyle {
      command += " " + style.arguments(for: prompt).joined(separator: " ")
    }
    return command
  }

  /// `KEY='value'` assignments for the `env` prefix, profile variables first
  /// (sorted for a stable preview) and `HOME` last so a dedicated home always
  /// wins over a hand-set `HOME` in the profile's own variables.
  private static func envPrefix(
    profile: AgentProfile,
    configDirectory: URL
  ) -> [String] {
    var assignments = profile.envVars
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\(ShellQuoting.quoted($0.value))" }
    if profile.usesDedicatedHome {
      let home = dedicatedHomeURL(for: profile, configDirectory: configDirectory)
      assignments.append("HOME=\(ShellQuoting.quoted(home.path(percentEncoded: false)))")
    }
    return assignments
  }
}
