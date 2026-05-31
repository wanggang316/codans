import Foundation

/// Decides whether a pane's foreground process group represents a real
/// running command — as opposed to the shell sitting at its prompt, or a
/// recognized coding agent. Drives the session-level "terminal busy" signal
/// that lights the tab-chip / sidebar worktree spinner.
///
/// Agents are deliberately excluded: a CLI agent stays the pane's foreground
/// process for its whole session, so a naive "foreground != shell" test would
/// pin an agent pane as busy forever. Agent activity is owned by the
/// render-derived agent state instead; this classifier only answers
/// "is a plain command executing right now?".
public nonisolated enum ForegroundJobClassifier {
  /// Interactive shell basenames. A foreground group made up only of these
  /// is the shell at its prompt — not a running command.
  public static let shellNames: Set<String> = [
    "zsh", "bash", "sh", "fish", "dash", "tcsh", "csh", "ksh", "nu", "xonsh", "elvish",
  ]

  /// True when `job` is a non-shell, non-agent command occupying the pane's
  /// foreground process group. `false` for an empty job (poll miss), the
  /// shell at its prompt, or any recognized agent.
  public static func indicatesRunningCommand(_ job: ForegroundJob) -> Bool {
    guard !job.isEmpty else { return false }
    guard AgentKindPatterns.classify(foregroundJob: job) == nil else { return false }
    // When a command runs, the shell hands the terminal's foreground group to
    // the command's process group and is no longer a member of it — so the
    // presence of any non-shell process means a command is executing. At the
    // prompt the foreground group is just the shell.
    return job.processes.contains { !isShell($0.processName) }
  }

  /// Shell basename check, tolerant of login-shell argv0 like `-zsh`.
  static func isShell(_ name: String) -> Bool {
    var normalized = name.lowercased()
    if normalized.hasPrefix("-") { normalized.removeFirst() }
    return shellNames.contains(normalized)
  }
}
