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
      AgentStatus.self,
      AgentWait.self,
      AgentLaunch.self,
    ]
  )
}

struct AgentStatus: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "List every pane running an agent with its runtime state.",
    discussion: """
      What the sidebar's Agents View shows: for each pane the app recognises
      as running an agent, the agent, its derived state (idle, working,
      blocked, finished), when it last changed, and where the pane lives.
      The state is derived from the pane's screen and foreground process, so
      it can lag a moment behind the agent; `agent wait` blocks on it.
      """
  )

  @OptionGroup var globals: GlobalOptions

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let response: IPC.AgentStateListResponse = try await client.call(
        .agentListStates, params: EmptyParams())
      try Renderer.emit(AgentStatusRenderable(response: response), mode: globals.renderMode)
    }
  }
}

struct AgentStatusRenderable: Encodable, CustomStringConvertible {
  let response: IPC.AgentStateListResponse

  func encode(to encoder: Encoder) throws {
    try response.encode(to: encoder)
  }

  var description: String {
    guard !response.agents.isEmpty else { return "(no agents running)" }
    let now = Date()
    let formatter = ISO8601DateFormatter()
    return response.agents.map { row in
      let since = formatter.date(from: row.since).map { Self.age(from: $0, to: now) } ?? "-"
      let focus = row.isFocused ? "*" : " "
      let tab = row.tabTitle.map { "  \"\($0)\"" } ?? ""
      return
        "\(focus) \(row.handle ?? row.paneID)  \(row.agent)  \(row.state)  \(since)  \(row.projectName)/\(row.worktreeName)\(tab)"
    }.joined(separator: "\n")
  }

  static func age(from: Date, to: Date) -> String {
    let seconds = max(Int(to.timeIntervalSince(from)), 0)
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m\(seconds % 60)s" }
    return "\(seconds / 3600)h\(seconds % 3600 / 60)m"
  }
}

struct AgentWait: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "wait",
    abstract: "Block until a pane's agent reaches a state.",
    discussion: """
      Waits server-side, so no polling loop is needed. Conditions: unknown,
      idle, working, blocked, error, finished (the states `agent status` reports),
      changed (any transition from the state seen when the wait started,
      including the agent appearing or leaving), and exit (no agent bound to
      the pane any more). A wait that does not resolve before --wait-timeout
      fails with WAIT_TIMEOUT (exit 11); the JSON error carries the last
      observed state. --wait-timeout bounds the wait; the global --timeout
      is the RPC client's own limit and is raised to cover it.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Pane id, p<n> handle, @label, or 'current'.")
  var pane: String = "current"
  @Option(name: .long, help: "Condition: unknown, idle, working, blocked, error, finished, changed, or exit.")
  var until: IPC.AgentWaitCondition
  @Option(name: .long, help: "Seconds to wait before giving up (1 through 600, default 60).")
  var waitTimeout: Double = 60

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      guard waitTimeout >= 1, waitTimeout <= 600 else {
        throw CLIError(code: .userError, message: "--wait-timeout must be between 1 and 600 seconds")
      }
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let uuid = try await AliasResolver.resolve(pane, kind: .pane, client: client)
      let response: IPC.AgentWaitResponse = try await client.call(
        .agentWait,
        params: IPC.AgentWaitRequest(
          paneID: PaneID(raw: uuid), until: until, timeoutMillis: Int(waitTimeout * 1000)),
        // The server holds the request for the whole wait; give the client
        // side headroom beyond it.
        timeout: .seconds(waitTimeout + 5)
      )
      guard response.satisfied else {
        throw CLIError(
          code: .requestTimeout,
          message: "pane \(response.paneID) did not reach \(response.until) within \(Int(waitTimeout))s"
            + (response.state.map { " (last state: \($0))" } ?? " (no agent bound)"),
          errorCode: .waitTimeout,
          details: [
            "paneID": response.paneID, "until": response.until, "state": response.state ?? "",
            "waitedMs": String(response.waitedMs),
          ])
      }
      try Renderer.emit(AgentWaitRenderable(response: response), mode: globals.renderMode)
    }
  }
}

struct AgentWaitRenderable: Encodable, CustomStringConvertible {
  let response: IPC.AgentWaitResponse

  func encode(to encoder: Encoder) throws {
    try response.encode(to: encoder)
  }

  var description: String {
    "pane \(response.paneID) reached \(response.until) after \(response.waitedMs)ms"
      + (response.state.map { " (state: \($0))" } ?? "")
  }
}

extension IPC.AgentWaitCondition: @retroactive ExpressibleByArgument {}

struct AgentList: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List agent profiles with their agent, enabled state, and launch command."
  )

  @OptionGroup var globals: GlobalOptions

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
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
  @Option(name: .long, help: "Worktree id, name, branch, or 'current'.")
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
    await CommandRunner.run(self, globals: globals) {
      if profile == nil, agent == nil {
        throw CLIError(code: .userError, message: "pass a profile name/id or --agent <agent>")
      }
      if tab, split != nil {
        throw CLIError(code: .userError, message: "--tab and --split are mutually exclusive")
      }
      let resolvedPrompt = try Self.resolvePrompt(prompt)
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let scope = try await ScopeResolver.worktree(project: project, worktree: worktree, client: client)
      let response: IPC.AgentLaunchResponse = try await client.call(
        .agentLaunch,
        params: IPC.AgentLaunchRequest(
          projectID: scope.projectID,
          worktreeID: scope.worktreeID,
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
