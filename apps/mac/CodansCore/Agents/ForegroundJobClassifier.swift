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

  /// True when `job` should light the pane's busy spinner: a running
  /// command (see `indicatesRunningCommand`) that is not an interactive
  /// remote session. A session like `ssh host` holds the foreground until
  /// the user logs out, so a spinner over it carries no information; it is
  /// still a running command for the worktree's process list.
  public static func indicatesBusyCommand(_ job: ForegroundJob) -> Bool {
    indicatesRunningCommand(job) && !indicatesInteractiveSession(job)
  }

  /// Remote-session clients that are interactive whatever their arguments.
  static let sessionClientNames: Set<String> = ["mosh", "mosh-client", "et"]

  /// True when the foreground job is an interactive remote session: an
  /// `ssh` login (no remote command, or a forced tty), `mosh`, or `et`.
  /// Any other non-shell process must descend from one of those — ssh's
  /// own ProxyCommand / ProxyJump helpers run in its process group.
  static func indicatesInteractiveSession(_ job: ForegroundJob) -> Bool {
    let sessions = Set(job.processes.filter(isInteractiveSessionClient).map(\.pid))
    guard !sessions.isEmpty else { return false }
    let parentByPID = Dictionary(
      job.processes.map { ($0.pid, $0.parentPID) }, uniquingKeysWith: { first, _ in first })
    return job.processes.allSatisfy { process in
      if isShell(process.processName) || sessions.contains(process.pid) { return true }
      // Walk ancestors inside the job; the hop cap guards a pid cycle.
      var pid = process.parentPID
      for _ in 0..<job.processes.count {
        if sessions.contains(pid) { return true }
        guard let parent = parentByPID[pid] else { return false }
        pid = parent
      }
      return false
    }
  }

  static func isInteractiveSessionClient(_ process: ForegroundProcess) -> Bool {
    let name = process.processName.lowercased()
    if sessionClientNames.contains(name) { return true }
    guard name == "ssh" else { return false }
    return sshIsInteractive(arguments: Array(process.argumentsOrTokens.dropFirst()))
  }

  /// ssh options that consume the next argument (OpenSSH `ssh(1)`).
  private static let sshOptionsWithValue = Set("BbcDEeFIiJLlmOoPpQRSWw")

  /// An `ssh` invocation is interactive when it requests a tty (`-t`) or
  /// names no remote command after the destination. Needs real argv to be
  /// exact — an option value with spaces (Ghostty's own `ssh` wrapper passes
  /// `-o "SetEnv COLORTERM=truecolor"`) would otherwise read as positionals.
  static func sshIsInteractive(arguments: [String]) -> Bool {
    var positionals = 0
    var forcesTTY = false
    var index = 0
    while index < arguments.count {
      let token = arguments[index]
      index += 1
      if token == "--" {
        positionals += arguments.count - index
        break
      }
      // ssh re-reads options right after the destination too (`ssh host -t`),
      // so a dash token counts as an option until the command starts.
      guard token.hasPrefix("-"), token.count > 1 else {
        positionals += 1
        // Everything after the destination is the remote command.
        if positionals > 1 { break }
        continue
      }
      for (offset, flag) in token.dropFirst().enumerated() {
        if flag == "t" { forcesTTY = true }
        if sshOptionsWithValue.contains(flag) {
          // `-p2222` carries its value inline; `-p 2222` takes the next token.
          if offset == token.count - 2 { index += 1 }
          break
        }
      }
    }
    return forcesTTY || positionals <= 1
  }

  /// Shell basename check, tolerant of login-shell argv0 like `-zsh`.
  static func isShell(_ name: String) -> Bool {
    var normalized = name.lowercased()
    if normalized.hasPrefix("-") { normalized.removeFirst() }
    return shellNames.contains(normalized)
  }

  /// VCS / forge CLIs whose completion at the shell prompt should kick an
  /// immediate git + PR status refresh. A finishing `git push` / `git commit`
  /// moves the diff and ahead/behind counts; a finishing `gh pr create` /
  /// `gh pr merge` changes server-side PR state — both of which the liveness
  /// poll would otherwise surface up to a minute later.
  public static let gitCommandNames: Set<String> = ["git", "gh"]

  /// True when the foreground group is a shell-launched `git` / `gh` command.
  /// Agent jobs are excluded for the same reason as `indicatesRunningCommand`:
  /// an agent stays foreground for its whole session and its own git
  /// subprocesses are render-derived, not a discrete prompt command — so this
  /// only fires for direct human-in-pane VCS usage.
  public static func indicatesGitCommand(_ job: ForegroundJob) -> Bool {
    guard !job.isEmpty else { return false }
    guard AgentKindPatterns.classify(foregroundJob: job) == nil else { return false }
    return job.processes.contains { gitCommandNames.contains($0.processName) }
  }
}
