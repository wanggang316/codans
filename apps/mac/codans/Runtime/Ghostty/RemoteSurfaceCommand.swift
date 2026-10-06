import CodansCore
import Foundation

/// Builds the libghostty surface command for a **remote** (Remote Project) pane.
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
    let paneUUID = paneID.raw.uuidString
    let connectLine = SSHCommand.commandLine(
      host: host,
      remoteCommand: posixShellWrapped(
        connectScript(
          hostSession: hostSession, paneUUID: paneUUID, remotePath: remotePath,
          hostPersistence: hostPersistence
        )
      )
    )
    let reconnectLine = SSHCommand.commandLine(
      host: host,
      remoteCommand: posixShellWrapped(
        reconnectScript(
          hostSession: hostSession, paneUUID: paneUUID, remotePath: remotePath,
          hostPersistence: hostPersistence
        )
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

  /// ssh forwards the pane's `TERM=xterm-ghostty`, which few hosts have a
  /// terminfo entry for; without one the host's line editors fall back to a
  /// dumb terminal (zsh stops erasing on Backspace) and `tput` / full-screen
  /// programs fail. Only that one name is replaced — a TERM the user set on
  /// purpose, or none at all, passes through — and only when the host lacks
  /// its entry, before anything (the host-side `zmx` session included)
  /// inherits it. A missing `infocmp` counts as a missing entry. The probe
  /// also looks in `toolDirectories`, inside a subshell, so an `infocmp`
  /// that only a login profile puts on PATH still resolves without that PATH
  /// leaking into the session.
  static let terminfoFallback =
    #"if [ "${TERM:-}" = xterm-ghostty ] && ! ( PATH="$PATH:"#
    + toolDirectories.joined(separator: ":")
    + #""; infocmp "$TERM" >/dev/null 2>&1 ); then export TERM=xterm-256color; fi; "#

  /// Package-manager bin directories a non-login remote shell's PATH misses.
  static let toolDirectories = [
    "/opt/homebrew/bin",  // macOS Apple Silicon Homebrew
    "/usr/local/bin",  // macOS Intel Homebrew, common install prefix
    "/opt/local/bin",  // MacPorts
    "/home/linuxbrew/.linuxbrew/bin",  // Linuxbrew
  ]

  /// Printed before the shell when the host is macOS and its default keychain
  /// is locked for this SSH session (SSH sessions never inherit the GUI
  /// console's unlock). Keychain-backed CLIs — Claude Code's OAuth token
  /// lives there — would otherwise report "Not logged in" with no context.
  /// The check is a single local `security` call on the host; non-Darwin
  /// hosts skip it entirely. A shell that `guiSessionSpawn` started in the
  /// GUI session sees the unlocked keychain, so the notice only shows when
  /// that path was not available. No apostrophes in the text — it crosses
  /// several single-quoting layers.
  static let lockedKeychainNotice =
    #"if [ "$(uname)" = Darwin ] && ! security show-keychain-info >/dev/null 2>&1; then "#
    + #"printf '\033[2m── Keychain is locked in this SSH session; keychain-backed CLIs (e.g. claude) may ask to log in. Fix: security unlock-keychain, or install zmx on the host ──\033[0m\r\n'; fi; "#

  /// The default shell for the worktree: cd into the remote path (best-effort),
  /// record this pane's controlling tty for the host-side foreground probe
  /// (agent detection — see `RemoteForegroundProbe`), then exec an
  /// **interactive** login shell. `-i` is load-bearing: without it a shell
  /// whose stdin isn't perfectly a TTY (some SSH PTY / multiplexing paths)
  /// treats the connection as a script, reads EOF immediately, and exits —
  /// which the SSH line surfaces as a fast non-255 exit and the pane closes
  /// on the spot. Forcing interactive keeps the shell alive for the terminal.
  /// Never carries a one-shot command.
  private static func worktreeShellCommand(paneUUID: String, remotePath: String) -> String {
    "cd -- \(SSHCommand.shellQuote(remotePath)) 2>/dev/null; "
      + RemoteForegroundProbe.recordTTYFragment(paneUUID: paneUUID)
      + lockedKeychainNotice
      + "exec \"$SHELL\" -il"
  }

  /// First-connect script. With host persistence and a host-side `zmx`, the
  /// worktree shell runs inside `zmx attach <hostSession>` (created on first
  /// connect). A failed attach falls through to a plain login shell with a notice
  /// rather than an instant, unreadable close.
  static func connectScript(
    hostSession: String, paneUUID: String, remotePath: String, hostPersistence: Bool
  ) -> String {
    let worktreeShell = worktreeShellCommand(paneUUID: paneUUID, remotePath: remotePath)
    guard hostPersistence else {
      return terminfoFallback + loginShellRun(worktreeShell)
    }
    let sessionCommand = "\"$SHELL\" -l -c " + SSHCommand.shellQuote(worktreeShell)
    return
      terminfoFallback
      + "if command -v zmx >/dev/null 2>&1; then "
      + guiSessionSpawn(hostSession: hostSession, sessionCommand: sessionCommand)
      + "zmx attach \(hostSession) \(sessionCommand)\n"
      + "codans_rc=$?\n"
      + "[ \"$codans_rc\" -eq 0 ] && exit 0\n"
      + hostAttachFailedNotice
      + "\n"
      + "fi\n"
      + loginShellRun(worktreeShell)
  }

  /// On a macOS host whose keychain is locked for this SSH session, start the
  /// host-side `zmx` daemon in the user's GUI login session instead of under
  /// sshd. A process inherits its login session from its parent, and only the
  /// GUI session sees the unlocked login keychain, so a daemon spawned by the
  /// `zmx attach` below would give the shell no keychain access: git's
  /// `osxkeychain` helper fails with -25308 and `gh` / `claude` lose their
  /// tokens. `launchctl submit` from an SSH session runs the job in the GUI
  /// session when the user is logged in at the console; `zmx serve` forks the
  /// daemon and exits, so the job is removed once the session is listed. The
  /// `attach` that follows then joins that daemon. With no console login, a
  /// failed submit, or a timeout, the `attach` creates the daemon as before.
  /// `TMPDIR` / `XDG_RUNTIME_DIR` / `ZMX_DIR` are forwarded only when set,
  /// because they select the socket directory both sides must agree on.
  static func guiSessionSpawn(hostSession: String, sessionCommand: String) -> String {
    let listed = "zmx list --short 2>/dev/null | grep -qx \(hostSession)"
    let label = "com.codans.zmx-serve.\(hostSession)"
    let forwardedEnvironment = ["TMPDIR", "XDG_RUNTIME_DIR", "ZMX_DIR", "LANG", "TERM"]
      .map { "${\($0)+\"\($0)=$\($0)\"}" }
      .joined(separator: " ")
    return
      #"if [ "$(uname)" = Darwin ] && ! security show-keychain-info >/dev/null 2>&1 && ! "#
      + listed + "; then\n"
      + "launchctl remove \(label) 2>/dev/null\n"
      + "if launchctl submit -l \(label) -- /usr/bin/env \(forwardedEnvironment) PATH=\"$PATH\" "
      + "\"$(command -v zmx)\" serve \(hostSession) --command \(sessionCommand) 2>/dev/null; then\n"
      + "codans_n=0\n"
      + "while [ \"$codans_n\" -lt 30 ] && ! \(listed); do sleep 0.1; codans_n=$((codans_n + 1)); done\n"
      + "launchctl remove \(label) 2>/dev/null\n"
      + "fi\n"
      + "fi\n"
  }

  /// Reconnect script, used by the loop after a dropped connection: reattach the
  /// host session if it still exists, exit 0 (closing the pane like a normal
  /// remote exit, with a notice) if it ended while disconnected, and never re-run
  /// any one-shot command. Without host `zmx` it drops into the worktree shell.
  static func reconnectScript(
    hostSession: String, paneUUID: String, remotePath: String, hostPersistence: Bool
  ) -> String {
    let worktreeShell = worktreeShellCommand(paneUUID: paneUUID, remotePath: remotePath)
    guard hostPersistence else {
      return terminfoFallback + reconnectShellNotice + loginShellRun(worktreeShell)
    }
    return
      terminfoFallback
      + "if command -v zmx >/dev/null 2>&1; then "
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

/// Local `/bin/sh` supervisor around two ssh command lines: `connect` runs
/// first (create-or-attach the host session), `reconnect` runs after a real
/// session drops (attach-only).
///
/// The loop distinguishes a **real interactive session that ended** from a
/// **failed launch** by how long the ssh line lived (`minSessionSeconds`):
///
///   - Ran ≥ threshold, exit ≠ 255 → the user's shell exited → close the pane
///     (propagate the code), exactly like a local pane's `exit`.
///   - Ran ≥ threshold, exit 255 → the connection dropped mid-session → switch
///     to `reconnect` and re-attach.
///   - Ran < threshold → the ssh line died before an interactive session could
///     start (auth/host-key 255, a non-interactive remote shell that read EOF,
///     a missing `$SHELL`, …). Instead of silently closing the pane — which
///     reads as "the tab flashes and vanishes" — the loop prints the exit code
///     and retries with capped backoff, so the failure is always visible and
///     Ctrl-C is the escape hatch. The one exception is `reconnect` mode: a
///     fast non-255 exit there means the host session ended while away, which
///     is a legitimate close.
///
/// `$SECONDS` (a shell builtin on the local macOS `/bin/sh`) times each attempt
/// without spawning `date`.
nonisolated enum SSHReconnectLoop {
  static let maxDelaySeconds = 15
  static let minSessionSeconds = 3

  /// Turns off the terminal modes a remote program can leave on when its
  /// connection drops before it can clean up. Without this, a mouse mode
  /// (e.g. Claude Code's any-event tracking with SGR encoding) stays on, and
  /// the fresh shell after the reconnect echoes each report as typed input.
  /// This is a targeted reset, not RIS (`ESC c`): the screen, the scrollback,
  /// and the notices stay visible. A surviving host `zmx` session replays the
  /// modes its program still holds when it re-attaches.
  static let terminalModeResetSequence =
    [
      // Mouse tracking and encodings.
      "\u{1B}[?9l", "\u{1B}[?1000l", "\u{1B}[?1001l", "\u{1B}[?1002l", "\u{1B}[?1003l",
      "\u{1B}[?1005l", "\u{1B}[?1006l", "\u{1B}[?1015l", "\u{1B}[?1016l",
      // Focus reporting, bracketed paste, synchronized output.
      "\u{1B}[?1004l", "\u{1B}[?2004l", "\u{1B}[?2026l",
      // Ghostty keeps one kitty keyboard stack per screen, and the alternate
      // screen keeps its stack after 1049l, so the next program to enter it
      // would inherit the flags. Pop the stack of the current screen before
      // leaving it; the primary screen's stack is popped below.
      "\u{1B}[<99u",
      // Primary screen, visible cursor, normal cursor keys (DECCKM), normal keypad.
      // Leaving 1049 restores the primary screen's saved cursor, which is the
      // top-left corner when none was saved, so the output would be written
      // over. Save the cursor first: on the primary screen the restore then
      // keeps it in place; on the alternate screen the save goes to that
      // screen and the primary one gets its own cursor back.
      "\u{1B}7", "\u{1B}[?1049l", "\u{1B}[?25h", "\u{1B}[?1l", "\u{1B}>",
      // Pop the primary screen's kitty keyboard stack; modifyOtherKeys off.
      "\u{1B}[<99u", "\u{1B}[>4;0m",
      // SGR reset.
      "\u{1B}[0m",
    ].joined()

  /// `printf` line that writes `terminalModeResetSequence`. The format holds
  /// no `%` and no `'`, so it crosses the outer single-quoting layers as is.
  static let terminalModeResetCommand =
    "printf '" + terminalModeResetSequence.replacingOccurrences(of: "\u{1B}", with: "\\033") + "'"

  static func script(connect: String, reconnect: String) -> String {
    let retryNotice =
      #"printf '\033[1;33m── Connection ended (exit %s). Retrying in %ss. Press Ctrl-C to stop. ──\033[0m\r\n' "$codans_rc" "$codans_delay""#
    let dropNotice =
      #"printf '\033[1;33m── Disconnected. Reconnecting… Press Ctrl-C to stop. ──\033[0m\r\n'"#
    return """
      trap 'exit 130' INT
      codans_delay=1
      codans_mode=connect
      while :; do
      codans_t0=$SECONDS
      if [ "$codans_mode" = connect ]; then
      \(connect)
      else
      \(reconnect)
      fi
      codans_rc=$?
      codans_dur=$((SECONDS - codans_t0))
      \(terminalModeResetCommand)
      if [ "$codans_dur" -ge \(minSessionSeconds) ]; then
      [ "$codans_rc" -ne 255 ] && exit "$codans_rc"
      codans_mode=reconnect
      codans_delay=1
      \(dropNotice)
      continue
      fi
      if [ "$codans_mode" = reconnect ] && [ "$codans_rc" -ne 255 ]; then
      exit "$codans_rc"
      fi
      \(retryNotice)
      sleep "$codans_delay"
      codans_delay=$((codans_delay * 2))
      [ "$codans_delay" -gt \(maxDelaySeconds) ] && codans_delay=\(maxDelaySeconds)
      done
      """
  }
}
