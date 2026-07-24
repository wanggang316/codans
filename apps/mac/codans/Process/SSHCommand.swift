import CodansCore
import Foundation

/// Pure, stateless builders for the `ssh` command lines codans issues against a
/// `RemoteHost`. Two shapes for two consumers:
///
///   - `invocation(...)` returns an argv for `Process` / `CommandRunner`: ssh
///     receives the remote command as a single argument, so only the *remote*
///     shell re-parses it (one quoting level, applied inside `remoteCommand`).
///     Used by the git-over-SSH path.
///   - `commandLine(...)` returns a single string for a parent `/bin/sh -c`
///     (libghostty's surface command), so the remote command is additionally
///     quoted for the *local* shell (two quoting levels). Used by the terminal.
///
/// Every call shares `controlOptions`, so N git probes plus the terminal reuse
/// one multiplexed SSH connection: one auth / prompt, and no per-call
/// TCP+handshake round-trip that would otherwise make a many-worktree sidebar
/// crawl. Authentication is delegated entirely to the user's ssh config + agent.
nonisolated enum SSHCommand {
  static let sshExecutablePath = "/usr/bin/ssh"

  /// `%C` is ssh's hash of (local host, remote host, port, user): stable per
  /// connection and short, keeping the control socket well under the
  /// `sockaddr_un.sun_path` limit. ssh expands both `~` and `%C` itself.
  static let defaultControlPath = "~/.ssh/codans-%C"

  /// SSH connection-multiplexing options. `auto` opens a master if none exists
  /// and reuses it otherwise; `ControlPersist` keeps it warm briefly after the
  /// last client so a burst of git calls shares one connection. `ServerAlive*`
  /// lives here, not per-caller: keepalives belong to whichever process is the
  /// master, so every path that can create one must carry them or a dead
  /// connection is never detected for any mux client riding it (~15s bound).
  static func controlOptions(controlPath: String = defaultControlPath) -> [String] {
    [
      "-o", "ControlMaster=auto",
      "-o", "ControlPath=\(controlPath)",
      "-o", "ControlPersist=10m",
      "-o", "ServerAliveInterval=5",
      "-o", "ServerAliveCountMax=3",
    ]
  }

  /// Options for a non-interactive background probe (resolving a remote repo,
  /// listing worktrees at reconcile). `BatchMode` so it fails fast instead of
  /// blocking on a password / host-key prompt; `ConnectTimeout` bounds the
  /// TCP+handshake. A live ControlMaster (an open terminal) bypasses auth, so
  /// the common case stays fast.
  static let backgroundProbeOptions: [String] = [
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=10",
  ]

  /// Options for an interactive terminal surface. `ConnectTimeout` bounds each
  /// reconnect attempt; 30s (vs the probe's 10s) tolerates slow ProxyJump / VPN
  /// handshakes while keeping the reconnect loop live. No `BatchMode`, so a
  /// first-connect password / 2FA prompt still works.
  static let interactiveOptions: [String] = [
    "-o", "ConnectTimeout=30",
  ]

  /// POSIX single-quote a token so a parent shell passes it through literally.
  static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// The command string the *remote* shell runs for a local
  /// `(executable, arguments, workingDirectory)` invocation. A working directory
  /// becomes `cd -- <dir> && exec ...` so the remote process starts in the
  /// worktree and replaces the shell (signals / exit status map straight
  /// through). `workingDirectory` is a remote path string — never routed through
  /// `URL(fileURLWithPath:)`, which would resolve against the local filesystem.
  static func remoteCommand(
    executable: String,
    arguments: [String],
    workingDirectory: String?
  ) -> String {
    let invocation = ([executable] + arguments).map(shellQuote).joined(separator: " ")
    guard let workingDirectory, !workingDirectory.isEmpty else {
      return invocation
    }
    return "cd -- \(shellQuote(workingDirectory)) && exec \(invocation)"
  }

  /// Wrap a remote command so it runs under a **login** shell. ssh's default
  /// `$SHELL -c <cmd>` is non-interactive *and* non-login, so on macOS hosts it
  /// only inherits `~/.zshenv`'s bare PATH — Homebrew's `/opt/homebrew/bin`
  /// (where a remote `git` may live) is not on it and the command fails with
  /// `command not found`. A login shell reads `/etc/zprofile` (path_helper) +
  /// `~/.zprofile` (`brew shellenv`), restoring the full PATH. `$SHELL` is
  /// expanded by ssh's own outer shell; `exec` replaces it so signals / exit
  /// status pass through.
  static func loginShellWrapped(_ remoteScript: String) -> String {
    "exec \"$SHELL\" -l -c " + shellQuote(remoteScript)
  }

  /// Full local `ssh` argv for `Process` / `CommandRunner`. The remote command is
  /// a single argument; ssh hands it to the remote login shell verbatim.
  static func invocation(
    host: RemoteHost,
    executable: String,
    arguments: [String],
    workingDirectory: String?,
    allocateTTY: Bool = false,
    controlPath: String = defaultControlPath,
    extraOptions: [String] = []
  ) -> (executableURL: URL, arguments: [String]) {
    var sshArguments = controlOptions(controlPath: controlPath)
    sshArguments += extraOptions
    if allocateTTY {
      sshArguments.append("-tt")
    }
    sshArguments += host.sshOptionArguments
    sshArguments.append(host.sshDestination)
    sshArguments.append(
      loginShellWrapped(
        remoteCommand(
          executable: executable, arguments: arguments, workingDirectory: workingDirectory
        )
      )
    )
    return (URL(fileURLWithPath: sshExecutablePath), sshArguments)
  }

  /// Full `ssh` line as a single string for a parent `/bin/sh -c` (libghostty's
  /// surface command). The fixed option tokens are shell-safe and stay unquoted
  /// (so ssh still expands `~` / `%C` in `ControlPath`); the login-shell-wrapped
  /// remote command is quoted for the local shell.
  static func commandLine(
    host: RemoteHost,
    remoteCommand: String,
    allocateTTY: Bool = true,
    controlPath: String = defaultControlPath
  ) -> String {
    var tokens = [sshExecutablePath]
    tokens += controlOptions(controlPath: controlPath)
    tokens += interactiveOptions
    if allocateTTY {
      tokens.append("-tt")
    }
    tokens += host.sshOptionArguments
    tokens.append(host.sshDestination)
    tokens.append(shellQuote(loginShellWrapped(remoteCommand)))
    return tokens.joined(separator: " ")
  }
}
