import Foundation

/// The two pieces of text a handoff types into a terminal: the request that
/// asks the *live* source agent to hand itself off through the CLI, and the
/// kickoff prompt the receiving agent starts with.
public nonisolated enum HandoffKickoff {
  /// Environment variable the HUD prefixes onto the shell command it asks the
  /// source agent to run. Carries the one-shot request id so the CLI can
  /// prove the transition was the one the HUD is waiting on. Ordinary CLI
  /// use never sets it.
  public static let requestIDEnvironmentKey = CodansEnvironment.Key.handoffRequestID.rawValue

  /// Worktree-relative paths the receiver is pointed at. Derived from
  /// `HandoffLayout` so the prompt and the store can never disagree about
  /// where a file is.
  public static let currentPath = HandoffLayout.worktreeRelativePath(HandoffLayout.briefingFileName)
  public static let contextPath = HandoffLayout.worktreeRelativePath(HandoffLayout.contextFileName)
  public static let archivePath = HandoffLayout.worktreeRelativePath(HandoffLayout.archiveDirectoryName) + "/"

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
    sourcePaneID: PaneID,
    cli: String = CLIInvocation.commandName,
    placement: HandoffPlacement = .default
  ) -> String {
    let command = Self.command(
      for: request, requestID: requestID, sourcePaneID: sourcePaneID, cli: cli, placement: placement)
    let sections = HandoffBriefing.sectionSkeleton.joined(separator: ", ")
    let ask: String
    switch request {
    case .handOff(let receiver):
      ask = "Please hand this task off to \(receiver.displayName): run `\(command)`"
    case .checkpoint:
      ask = "Please checkpoint your progress for a later handoff: run `\(command)`"
    }
    return "[codans] \(ask) with your briefing on stdin as a heredoc — a markdown document "
      + "with the sections \(sections), written from your current working knowledge. "
      + "Keep Next Steps ordered and concrete. The command replies with guidance if the "
      + "briefing is incomplete."
  }

  /// The shell command the source agent runs. The injected request and the
  /// handler's retry guidance share it, so a retry keeps the explicit source
  /// pane and the request id. Without them, the CLI falls back to the pane
  /// inherited from the agent's environment, which can be stale.
  ///
  /// The placement rides on the command, so the CLI path and the panel agree
  /// without a second channel; the default adds nothing to the line.
  public static func command(
    for request: Request,
    requestID: UUID?,
    sourcePaneID: PaneID,
    cli: String = CLIInvocation.commandName,
    placement: HandoffPlacement = .default
  ) -> String {
    let env = requestID.map { "\(requestIDEnvironmentKey)=\($0.uuidString) " } ?? ""
    let pane = "--pane \(sourcePaneID.description)"
    switch request {
    case .handOff(let receiver):
      let placementFlags = placement.cliArguments.map { " \($0)" }.joined()
      return "\(env)\(cli) handoff to \(receiver.rawValue) \(pane)\(placementFlags) --brief -"
    case .checkpoint:
      return "\(env)\(cli) handoff save \(pane) --brief -"
    }
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
