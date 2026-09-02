import ArgumentParser
import CodansCore
import CodansIPC
import CodansKit
import Foundation

struct HandoffCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "handoff",
    abstract: "Hand a task off between coding agents: archive, brief, and launch the receiver.",
    discussion: """
      The source is the calling pane — an agent running `codans handoff` inside its
      pane hands off itself. Pass --pane to target another pane.

      A handoff needs a briefing from the source agent (--brief -, read from stdin
      as a heredoc) or an explicit --no-brief. Artifacts live under the worktree's
      .codans/handoff/ directory; the receiver starts in a new background tab.

        codans handoff to codex --brief - <<'EOF'
        # Handoff
        ## Objective
        …
        ## Current State
        …
        ## Next Steps
        …
        EOF
        codans handoff save --brief - < notes.md
      """,
    subcommands: [
      HandoffTo.self,
      HandoffSave.self,
    ]
  )
}

/// Briefing options shared by `to` and `save`. `--brief <text|->` supplies
/// the agent-authored document (`-` reads stdin); `--no-brief` is the
/// explicit context-only escape. The server rejects a call with neither.
struct HandoffBriefOptions: ParsableArguments {
  @Option(name: .long, help: "Inline briefing; pass '-' to read it from stdin (heredoc).")
  var brief: String?
  @Flag(name: .customLong("no-brief"), help: "Context-only: skip the briefing entirely.")
  var noBrief: Bool = false

  func resolve() throws -> (brief: String?, contextOnly: Bool) {
    if noBrief, brief != nil {
      throw CLIError(code: .userError, message: "--brief and --no-brief are mutually exclusive")
    }
    guard var text = brief else { return (nil, noBrief) }
    if text == "-" {
      text = try StandardInput.readString()
    }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CLIError(code: .userError, message: "the briefing is empty")
    }
    return (text, false)
  }
}

/// The app prefixes an injected shell command with a one-shot request id so
/// the handler can prove the transition is the one a panel is waiting on.
/// Interactive use never sets it.
enum HandoffRequestContext {
  static func requestID(in environment: [String: String] = ProcessInfo.processInfo.environment) -> UUID? {
    environment[HandoffKickoff.requestIDEnvironmentKey].flatMap(UUID.init(uuidString:))
  }
}

struct HandoffTo: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "to",
    abstract: "Archive the outgoing state, install the briefing, and launch the receiving agent."
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Receiving agent: claude, codex, gemini, or any agent token with --no-launch.")
  var agent: String
  @Option(name: .long, help: "Source pane id, p<n> handle, @label, or 'current' (the calling pane).")
  var pane: String = "current"
  @Option(name: .long, help: "Profile (name or id) to launch the receiver with.")
  var profile: String?
  @OptionGroup var briefOptions: HandoffBriefOptions
  @Option(name: .long, help: "Note appended to the handoff log.")
  var note: String?
  @Flag(name: .customLong("no-launch"), help: "Archive and save only; do not start the receiver.")
  var noLaunch: Bool = false

  func run() async throws {
    await CommandRunner.run {
      guard AgentKind(token: agent) != nil else {
        throw CLIError(
          code: .userError,
          message: "unknown agent \"\(agent)\"; expected one of: "
            + AgentKind.allCases.map(\.rawValue).joined(separator: ", "))
      }
      let resolvedBrief = try briefOptions.resolve()
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let paneUUID = try await AliasResolver.resolve(pane, kind: .pane, client: client)
      let response: IPC.HandoffResponse = try await client.call(
        .handoffTo,
        params: IPC.HandoffRequest(
          action: .to,
          paneID: PaneID(raw: paneUUID),
          receiver: agent,
          profile: profile,
          brief: resolvedBrief.brief,
          contextOnly: resolvedBrief.contextOnly,
          note: note,
          launch: !noLaunch,
          requestID: HandoffRequestContext.requestID()
        )
      )
      try Renderer.emit(HandoffRenderable(response: response), mode: globals.renderMode)
    }
  }
}

struct HandoffSave: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "save",
    abstract: "Checkpoint: install a fresh briefing and refresh generated context, without launching."
  )

  @OptionGroup var globals: GlobalOptions
  @Option(name: .long, help: "Source pane id, p<n> handle, @label, or 'current' (the calling pane).")
  var pane: String = "current"
  @OptionGroup var briefOptions: HandoffBriefOptions
  @Option(name: .long, help: "Note appended to the handoff log.")
  var note: String?

  func run() async throws {
    await CommandRunner.run {
      let resolvedBrief = try briefOptions.resolve()
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let paneUUID = try await AliasResolver.resolve(pane, kind: .pane, client: client)
      let response: IPC.HandoffResponse = try await client.call(
        .handoffSave,
        params: IPC.HandoffRequest(
          action: .save,
          paneID: PaneID(raw: paneUUID),
          brief: resolvedBrief.brief,
          contextOnly: resolvedBrief.contextOnly,
          note: note,
          requestID: HandoffRequestContext.requestID()
        )
      )
      try Renderer.emit(HandoffRenderable(response: response), mode: globals.renderMode)
    }
  }
}

struct HandoffRenderable: Encodable, CustomStringConvertible {
  let response: IPC.HandoffResponse

  func encode(to encoder: Encoder) throws {
    try response.encode(to: encoder)
  }

  var description: String {
    var lines: [String] = []
    switch response.action {
    case .save:
      lines.append(
        response.hasBriefing
          ? "saved briefing to \(response.artifactPath)"
          : "refreshed handoff context (no briefing written)")
    case .to:
      let from = response.outgoingAgent ?? "agent"
      let to = response.receiver ?? "agent"
      lines.append("handed off \(from) -> \(to)")
      lines.append(
        response.hasBriefing
          ? "  briefing: \(response.artifactPath)"
          : "  briefing: none (receiver reads context.md and the archive)")
      if let archived = response.archivedPath {
        lines.append("  archived: \(archived)")
      }
      if let pane = response.launchedPane {
        lines.append("  launched \(pane.profileName) in pane \(pane.paneID) (tab \(pane.tabID))")
      } else {
        lines.append("  receiver not launched")
      }
    }
    if let branch = response.branch {
      lines.append("  branch: \(branch), changed files: \(response.changedFileCount)")
    }
    return lines.joined(separator: "\n")
  }
}
