import Foundation

/// The two pieces of text a handoff types into a terminal: the request that
/// asks the *live* source agent to hand itself off through the CLI, and the
/// kickoff prompt the receiving agent starts with.
public nonisolated enum HandoffKickoff {
  /// Environment variable the HUD prefixes onto the shell command it asks the
  /// source agent to run. Carries the one-shot request id so the CLI can
  /// prove the transition was the one the HUD is waiting on. Ordinary CLI
  /// use never sets it.
  public static let requestIDEnvironmentKey = "CODANS_HANDOFF_REQUEST_ID"

  /// Relative paths the receiver is pointed at, spelled once.
  public static let currentPath = ".codans/handoff/current.md"
  public static let contextPath = ".codans/handoff/context.md"
  public static let archivePath = ".codans/handoff/archive/"

  public enum Request: Equatable, Sendable {
    case handOff(to: AgentKind)
    case checkpoint
  }

  /// One self-contained line typed into the source agent's input. The agent
  /// composes the heredoc itself — nothing multi-line is ever injected, so
  /// any TUI input box can take it.
  ///
  /// `cli` is how this build spells its own CLI (see `CLIInvocation`). It is
  /// a parameter rather than a literal because a Debug app writing plain
  /// `codans` would be answered by the installed Release app instead of
  /// itself.
  public static func sourceInstruction(
    for request: Request,
    requestID: UUID,
    cli: String = CLIInvocation.commandName
  ) -> String {
    let env = "\(requestIDEnvironmentKey)=\(requestID.uuidString) "
    let sections = HandoffBriefing.sectionSkeleton.joined(separator: ", ")
    let ask: String
    switch request {
    case .handOff(let receiver):
      ask =
        "Please hand this task off to \(receiver.displayName): run "
        + "`\(env)\(cli) handoff to \(receiver.rawValue) --brief -`"
    case .checkpoint:
      ask =
        "Please checkpoint your progress for a later handoff: run "
        + "`\(env)\(cli) handoff save --brief -`"
    }
    return "[codans] \(ask) with your briefing on stdin as a heredoc — a markdown document "
      + "with the sections \(sections), written from your current working knowledge. "
      + "Keep Next Steps ordered and concrete. The command replies with guidance if the "
      + "briefing is incomplete."
  }

  /// What the receiving agent is started with. Adapts to whether a fresh
  /// briefing exists: with one it continues from Next Steps, without one it
  /// orients from generated context and the archive.
  public static func receiverPrompt(hasBriefing: Bool) -> String {
    if hasBriefing {
      return "Take over this task from the previous agent. Read \(currentPath) (its briefing) "
        + "and \(contextPath) (generated repository and session state), then continue from "
        + "Next Steps. Do not redo work listed under What Has Been Done. If context.md names a "
        + "session excerpt, read it before changing code. Earlier handoff snapshots are under "
        + "\(archivePath) if you need deeper history. Ask before any commit, push, or "
        + "destructive git operation."
    }
    return "Take over this task from the previous agent. There is no briefing from it: orient "
      + "from \(contextPath) (generated repository and session state). If context.md names a "
      + "session excerpt, read it before changing code. Earlier handoff snapshots are under "
      + "\(archivePath) if you need history. Ask before any commit, push, or destructive git "
      + "operation."
  }

  // MARK: - Guidance for the CLI

  /// Error text when neither `--brief` nor `--no-brief` was given. Carries a
  /// copy-pasteable heredoc so an agent can fix its call in one step.
  public static func briefRequiredMessage(command: String) -> String {
    let skeleton = HandoffBriefing.sectionSkeleton.map { "  \($0)\n  …" }.joined(separator: "\n")
    return """
      Handoff requires an inline briefing from the source agent. Rerun with the briefing on stdin:
        \(command) <<'EOF'
      \(skeleton)
        EOF
      Write it from your current working knowledge. Use --no-brief only for an intentional \
      context-only handoff.
      """
  }

  public static func invalidBriefingMessage() -> String {
    "The briefing is missing required sections. Include at least "
      + HandoffBriefing.requiredSections.map { "\"\($0)\"" }.joined(separator: ", ")
      + " (recommended: the full skeleton "
      + HandoffBriefing.sectionSkeleton.joined(separator: " / ")
      + "). Nothing was written — fix the briefing and rerun."
  }
}
