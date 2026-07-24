import CodansCore
import Foundation

/// Builds the libghostty surface command for a **remote** (Server-project) pane.
///
/// Shape (outermost → innermost), mirroring how local panes gain quit-persistence
/// via `ZmxAttachCommand`, extended with an SSH reconnect loop:
///
///   local `/bin/sh -c`                            ← libghostty wraps config.command
///     → local `zmx attach <paneUUID>`             ← quit-persistence of the tunnel
///       → `/bin/sh -c "<reconnect loop>"`         ← retries the SSH line on drop
///         → `ssh <controlopts> host <remoteScript>`
///           → remote login shell                  ← restores PATH (Homebrew, etc.)
///             → `/bin/sh -c "<connect|reconnect>"` ← POSIX host-side script
///
/// The local `zmx` daemon holds the reconnect loop, so quitting/relaunching codans
/// re-attaches it and the loop re-establishes the SSH connection. When the remote
/// host has `zmx` on its login PATH and `hostPersistence` is on, the shell runs
/// inside a host-side `zmx` session too, so the remote work survives disconnects;
/// otherwise it falls back to a plain login shell in the target directory.
///
/// One shared SSH ControlMaster (see `SSHCommand.controlOptions`) multiplexes this
/// terminal with the background git probes, so there is a single auth per host.
nonisolated enum RemoteSurfaceCommand {
  /// Host-side `zmx` session name for a pane. Distinct from the local session
  /// (the bare pane UUID) by a `codans-` prefix; the two live in different `zmx`
  /// namespaces (different machines) so a shared UUID would not collide, but the
  /// prefix keeps host-side sessions self-identifying in `zmx list`.
  static func hostSessionName(for paneID: PaneID) -> String {
    "codans-\(paneID.raw.uuidString)"
  }

  /// Compose the full surface command string handed to libghostty.
  ///
  /// - `localZmxPath`: the bundled `zmx` binary path, or `nil` when unavailable —
  ///   then the surface is the bare reconnect loop with no quit-persistence
  ///   (reconnect still works).
  /// - `remotePath`: absolute directory on the host to `cd` into (the worktree).
  /// - `hostPersistence`: run the remote shell inside a host-side `zmx` session
  ///   when the host has `zmx`.
  static func build(
    host: RemoteHost,
    paneID: PaneID,
    remotePath: String,
    localZmxPath: String?,
    hostPersistence: Bool = true
  ) -> String {
    let hostSession = hostSessionName(for: paneID)
    let connectLine = SSHCommand.commandLine(
      host: host,
      remoteCommand: posixShellWrapped(
        connectScript(hostSession: hostSession, remotePath: remotePath, hostPersistence: hostPersistence)
      )
    )
    let reconnectLine = SSHCommand.commandLine(
      host: host,
      remoteCommand: posixShellWrapped(
        reconnectScript(hostSession: hostSession, remotePath: remotePath, hostPersistence: hostPersistence)
      )
    )
    let loop = SSHReconnectLoop.script(connect: connectLine, reconnect: reconnectLine)
    guard let localZmxPath else { return loop }
    // Wrap the loop in a local zmx session (name = bare pane UUID) so quit +
    // relaunch re-attaches it exactly like a local pane.
    return ZmxAttachCommand.build(
      zmxPath: localZmxPath,
      session: ZmxAttachCommand.session(for: paneID),
      userCommand: loop
    )
  }

  // MARK: - Remote scripts

  /// Re-quote a remote script behind `exec /bin/sh -c`, so the login shell (which
  /// may be fish / csh) only parses that one portable line; the POSIX `if/fi`
  /// script then runs under `/bin/sh` with the login shell's exported PATH.
  static func posixShellWrapped(_ script: String) -> String {
    "exec /bin/sh -c " + SSHCommand.shellQuote(script)
  }

  /// Run a command under a fresh login shell (so bash/zsh-isms survive on
  /// dash-as-`/bin/sh` hosts).
  private static func loginShellRun(_ command: String) -> String {
    "exec \"$SHELL\" -l -c " + SSHCommand.shellQuote(command)
  }

  /// The default shell for the worktree: cd into the remote path (best-effort)
  /// then exec a login shell. Never carries a one-shot command.
  private static func worktreeShellCommand(remotePath: String) -> String {
    "cd -- \(SSHCommand.shellQuote(remotePath)) 2>/dev/null; exec \"$SHELL\" -l"
  }

  /// First-connect script. With host persistence and a host-side `zmx`, the
  /// worktree shell runs inside `zmx attach <hostSession>` (created on first
  /// connect). A failed attach falls through to a plain login shell with a notice
  /// rather than an instant, unreadable close.
  static func connectScript(hostSession: String, remotePath: String, hostPersistence: Bool) -> String {
    let worktreeShell = worktreeShellCommand(remotePath: remotePath)
    guard hostPersistence else {
      return loginShellRun(worktreeShell)
    }
    let sessionCommand = "\"$SHELL\" -l -c " + SSHCommand.shellQuote(worktreeShell)
    return
      "if command -v zmx >/dev/null 2>&1; then "
      + "zmx attach \(hostSession) \(sessionCommand)\n"
      + "codans_rc=$?\n"
      + "[ \"$codans_rc\" -eq 0 ] && exit 0\n"
      + hostAttachFailedNotice
      + "\n"
      + "fi\n"
      + loginShellRun(worktreeShell)
  }

  /// Reconnect script, used by the loop after a dropped connection: reattach the
  /// host session if it still exists, exit 0 (closing the pane like a normal
  /// remote exit, with a notice) if it ended while disconnected, and never re-run
  /// any one-shot command. Without host `zmx` it drops into the worktree shell.
  static func reconnectScript(hostSession: String, remotePath: String, hostPersistence: Bool) -> String {
    let worktreeShell = worktreeShellCommand(remotePath: remotePath)
    guard hostPersistence else {
      return reconnectShellNotice + loginShellRun(worktreeShell)
    }
    return
      "if command -v zmx >/dev/null 2>&1; then "
      + "if zmx list --short 2>/dev/null | grep -q '\(hostSession)$'; then "
      + "exec zmx attach \(hostSession)\n"
      + "fi\n"
      + sessionEndedNotice + "exit 0\n"
      + "fi\n"
      + reconnectShellNotice
      + loginShellRun(worktreeShell)
  }

  // MARK: - Notices (rendered inside the terminal stream)

  private static let hostAttachFailedNotice =
    #"printf '\033[1;31m── Host session attach failed (status %s); continuing without host persistence. ──\033[0m\r\n' "$codans_rc"; "#

  private static let reconnectShellNotice =
    #"printf '\033[1;33m── Reconnected without a persistent session; starting a fresh shell. ──\033[0m\r\n'; "#

  private static let sessionEndedNotice =
    #"printf '\033[2m── Remote session ended while disconnected. ──\033[0m\r\n'; "#
}

/// Local `/bin/sh` retry loop around two ssh command lines: `connect` runs once
/// (create-or-attach the host session), `reconnect` runs on every retry
/// (attach-only). ssh reserves exit 255 for its own connection errors, so 255
/// retries (with capped exponential backoff, forever, so an overnight sleep still
/// resumes) and every other exit passes through, closing the surface like a local
/// shell exit. 255 also covers permanent ssh failures (auth, host key, DNS); the
/// banner names the exit and ssh's own error text stays visible above it. Ctrl-C
/// during the wait is the escape hatch (`trap` makes it deterministic; while ssh
/// is live the tty is raw and Ctrl-C goes to the remote).
nonisolated enum SSHReconnectLoop {
  static let maxDelaySeconds = 15

  static func script(connect: String, reconnect: String) -> String {
    let passExitUnless255 = "; codans_rc=$?; [ \"$codans_rc\" -ne 255 ] && exit \"$codans_rc\""
    return "trap 'exit 130' INT; "
      + connect + passExitUnless255 + "; "
      + "codans_delay=1; while :; do "
      + #"printf '\033[1;33m── Connection failed (ssh exit 255). Retrying in %ss. Press Ctrl-C to stop. ──\033[0m\r\n' "$codans_delay"; "#
      + "sleep \"$codans_delay\"; codans_delay=$((codans_delay * 2)); "
      + "[ \"$codans_delay\" -gt \(maxDelaySeconds) ] && codans_delay=\(maxDelaySeconds); "
      + reconnect + passExitUnless255 + "; done"
  }
}
