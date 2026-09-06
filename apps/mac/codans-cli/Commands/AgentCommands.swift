import ArgumentParser
import CodansCore
import CodansIPC
import CodansKit
import Foundation

struct AgentCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "agent",
    abstract: "List and launch coding-agent profiles.",
    discussion: """
      Profiles are the launch presets from Settings > Agents — the same rows the
      worktree toolbar's Agents menu shows. `launch` opens a fresh tab (or split)
      in the target worktree and types the profile's command into it.

        codans agent list
        codans agent launch "Claude Code"
        codans agent launch --agent codex --prompt - <<'EOF'
        Review the diff on this branch.
        EOF
      """,
    subcommands: [
      AgentList.self,
      AgentLaunch.self,
    ]
  )
}

struct AgentList: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List agent profiles with their agent, enabled state, and launch command."
  )

  @OptionGroup var globals: GlobalOptions

  func run() async throws {
    await CommandRunner.run {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let response: IPC.AgentProfileListResponse = try await client.call(
        .agentListProfiles, params: EmptyParams())
      try Renderer.emit(AgentProfileListRenderable(profiles: response.profiles), mode: globals.renderMode)
    }
  }
}

struct AgentLaunch: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "launch",
    abstract: "Start an agent profile in a worktree.",
    discussion: """
      Pick the profile by name or id, or pass --agent to use the first enabled
      profile for that agent. --prompt seeds the session with an instruction
      (pass '-' to read it from stdin); only agents that can start with a prompt
      accept it. Placement defaults to the profile's own; --tab / --split override.
      """
  )

  enum Split: String, ExpressibleByArgument, CaseIterable {
    case right, left, up, down

    var direction: ScriptSplitDirection {
      switch self {
      case .right: return .right
      case .left: return .left
      case .up: return .up
      case .down: return .down
      }
    }
  }

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Profile name or id. Omit with --agent to use that agent's first enabled profile.")
  var profile: String?
  @Option(name: .long, help: "Agent token (claude, codex, gemini, …) when no profile is named.")
  var agent: String?
  @Option(name: .long, help: "Project id, name, or 'current'.")
  var project: String = "current"
  @Option(name: .long, help: "Worktree id or 'current'.")
  var worktree: String = "current"
  @Option(name: .long, help: "Kickoff prompt; pass '-' to read it from stdin.")
  var prompt: String?
  @Flag(name: .long, help: "Open in a new tab (overrides the profile's placement).")
  var tab: Bool = false
  @Option(name: .long, help: "Split the focused pane: right, left, up, or down.")
  var split: Split?
  @Flag(name: .long, help: "Do not select the new tab or move focus.")
  var background: Bool = false

  func run() async throws {
    await CommandRunner.run {
      if profile == nil, agent == nil {
        throw CLIError(code: .userError, message: "pass a profile name/id or --agent <agent>")
      }
      if tab, split != nil {
        throw CLIError(code: .userError, message: "--tab and --split are mutually exclusive")
      }
      let resolvedPrompt = try Self.resolvePrompt(prompt)
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let projectUUID = try await AliasResolver.resolve(project, kind: .project, client: client)
      let worktreeUUID = try await AliasResolver.resolve(worktree, kind: .worktree, client: client)
      let response: IPC.AgentLaunchResponse = try await client.call(
        .agentLaunch,
        params: IPC.AgentLaunchRequest(
          projectID: ProjectID(raw: projectUUID),
          worktreeID: WorktreeID(raw: worktreeUUID),
          profile: profile,
          agent: agent,
          prompt: resolvedPrompt,
          target: tab ? .newTab : (split == nil ? nil : .split),
          direction: split?.direction,
          focus: !background
        )
      )
      try Renderer.emitObject(
        [
          "profileID": response.profileID.uuidString,
          "profileName": response.profileName,
          "agent": response.agent,
          "command": response.command,
          "tabID": response.tabID?.description ?? "",
          "paneID": response.paneID?.description ?? "",
        ],
        mode: globals.renderMode
      ) { obj in
        let pane = (obj["paneID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return "launched \(obj["profileName"] ?? "") in \(pane.map { "pane \($0)" } ?? "the focused pane")"
      }
    }
  }

  /// `-` reads the prompt from stdin so a multi-line instruction can ride a
  /// heredoc without shell-quoting gymnastics.
  static func resolvePrompt(_ raw: String?) throws -> String? {
    guard let raw else { return nil }
    let text = raw == "-" ? try StandardInput.readString() : raw
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw CLIError(code: .userError, message: "the prompt is empty")
    }
    return trimmed
  }
}

struct AgentProfileListRenderable: Encodable, CustomStringConvertible {
  let profiles: [IPC.AgentProfileSummary]

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(["profiles": profiles])
  }

  var description: String {
    guard !profiles.isEmpty else { return "(no agent profiles)" }
    return profiles.map { profile in
      var flags: [String] = []
      if !profile.isEnabled { flags.append("disabled") }
      if profile.isInstalled == false { flags.append("not on PATH") }
      let suffix = flags.isEmpty ? "" : "  [\(flags.joined(separator: ", "))]"
      return "\(profile.id)  \(profile.name)  (\(profile.agentName))  \(profile.command)\(suffix)"
    }.joined(separator: "\n")
  }
}
