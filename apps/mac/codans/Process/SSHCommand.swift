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
/// Every call runs through `sharedMasterLine`, so N git probes plus the
/// terminals reuse one multiplexed SSH connection that exactly one of them
/// creates (a few more when sshd `MaxSessions` fills one): one auth / prompt
/// per shared connection, and no per-call
/// TCP+handshake round-trip that would otherwise make a many-worktree sidebar
/// crawl. Authentication is delegated entirely to the user's ssh config + agent.
nonisolated enum SSHCommand {
  static let sshExecutablePath = "/usr/bin/ssh"
  /// `invocation` runs ssh through this shell so `sharedMasterGuard` runs first.
  static let guardShellPath = "/bin/sh"
  /// `$0` of that shell; the ssh argv follows it as `$@`.
  static let guardShellName = "codans-ssh"

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

  /// How long an ssh line waits for another codans line that is creating the
  /// shared master. Past it the line runs anyway and ssh's own `auto` fallback
  /// applies, so a stuck creator never blocks a pane or a probe for good.
  /// A probe's `CommandRunner` timeout can be shorter. That is safe: `Process`
  /// makes the shell a process-group leader and `terminate()` signals the
  /// whole group, so `lockf` and the creating `ssh` stop with the probe.
  static let masterLockTimeoutSeconds = 30

  /// Number of shared masters one host can have. sshd caps the sessions on
  /// one connection (`MaxSessions`, default 10). A line that the full master
  /// refuses moves to the next master, so each master costs one
  /// authentication. Past the last one, the line opens its own connection.
  static let masterSlotCount = 4

  /// ControlPath of each shared master, primary first. `-<n>` follows `%C`,
  /// so every path stays short and per connection.
  static func masterControlPaths(controlPath: String = defaultControlPath) -> [String] {
    (0..<masterSlotCount).map { $0 == 0 ? controlPath : "\(controlPath)-\($0)" }
  }

  /// Notice a terminal prints when every shared master refused it. No
  /// apostrophes: it crosses several single-quoting layers.
  static let mastersFullNotice =
    #"printf '\033[2m── All shared SSH connections to this host are full (sshd MaxSessions). "#
    + #"This line uses its own connection and can ask you to sign in again. ──\033[0m\r\n' >&2; "#

  /// POSIX `sh` statement that runs one ssh line over a shared ControlMaster
  /// of the host. `sshArguments` is the shell text that follows the control
  /// options (extra options, host options, destination, remote command).
  ///
  /// For each master in `masterControlPaths`, in order:
  ///
  ///   1. `sharedMasterGuard` makes sure the master is live.
  ///   2. The line runs with `ControlMaster=no` and a sentinel `ProxyCommand`.
  ///      ssh runs `ProxyCommand` only when it cannot use the master, which is
  ///      before anything runs on the host, so the line can safely run again.
  ///      Without this, a master that refuses the session (sshd
  ///      `MaxSessions`) makes ssh connect and authenticate on its own and
  ///      print "ControlSocket … already exists, disabling multiplexing".
  ///      `LogLevel=FATAL` hides ssh's "session request failed" error.
  ///   3. No sentinel: the line ran, and its status is the statement's status.
  ///      Sentinel and a live master: the master is full; go to the next one.
  ///      Sentinel and no live master (the guard could not create one): run
  ///      the line as before, with `ControlMaster=auto`, so auth prompts and
  ///      errors stay visible.
  ///
  /// When every master refused, the line runs on its own connection
  /// (`ControlPath=none`): no warning, and a terminal prints
  /// `mastersFullNotice`. No master is ever removed or replaced.
  ///
  /// The statement is a subshell, so it composes in a terminal's reconnect
  /// loop and `$?` is the status of ssh.
  static func sharedMasterLine(
    host: RemoteHost,
    extraOptions: [String],
    quiet: Bool,
    sshArguments: String,
    controlPath: String = defaultControlPath,
    sshPath: String = sshExecutablePath
  ) -> String {
    let ssh = shellQuote(sshPath)
    let target = (host.sshOptionArguments + [host.sshDestination]).map(shellQuote)
      .joined(separator: " ")
    let paths = masterControlPaths(controlPath: controlPath).map(shellQuote)
      .joined(separator: " ")
    let mux =
      "\(ssh) -o ControlMaster=no -o \"ControlPath=$codans_cpath\" -o LogLevel=FATAL "
      + "-o \"ProxyCommand=/usr/bin/touch '$codans_refused'\" \(sshArguments)"
    let shared = "\(ssh) \(controlArguments) \(sshArguments)"
    let own = "\(ssh) -o ControlMaster=no -o ControlPath=none \(sshArguments)"
    return "( codans_refused=\"${TMPDIR:-/tmp}/codans-ssh-refused.$$\"; "
      + "for codans_cpath in \(paths); do "
      + sharedMasterGuard(host: host, extraOptions: extraOptions, quiet: quiet, sshPath: sshPath)
      + "/bin/rm -f \"$codans_refused\"; \(mux); codans_rc=$?; "
      + "[ -e \"$codans_refused\" ] || exit \"$codans_rc\"; /bin/rm -f \"$codans_refused\"; "
      + "\(ssh) -o \"ControlPath=$codans_cpath\" -O check \(target) >/dev/null 2>&1 "
      + "|| exec \(shared); done; "
      + (quiet ? "" : mastersFullNotice)
      + "exec \(own) )"
  }

  /// Control options of `controlOptions`, with the ControlPath of the master
  /// that `sharedMasterLine` tries now (`$codans_cpath`).
  private static let controlArguments =
    controlOptions(controlPath: "$codans_cpath").map { "\"\($0)\"" }.joined(separator: " ")

  /// POSIX `sh` fragment that makes sure the master at `$codans_cpath` is live
  /// before an ssh line uses it. `ControlMaster=auto` alone cannot do this:
  /// when no master listens (it ended, or a killed one left a socket that ssh
  /// unlinks as stale), every line that starts in that window connects and
  /// authenticates on its own, the first to finish takes the ControlPath, and
  /// each other one prints "ControlSocket … already exists, disabling
  /// multiplexing" and keeps a private connection — for a terminal, for the
  /// whole session. This happens on every reconnect, when panes and probes
  /// start together.
  ///
  /// The fragment checks the master (`-O check`, local only). If none answers,
  /// it creates one with a no-op `true` while it holds an exclusive `lockf`
  /// lock next to the ControlPath (`ssh -G` gives the expanded path, so the
  /// lock is exactly per master). A line that waited on the lock finds the new
  /// master and only multiplexes `true` through it. The fragment never removes
  /// a socket: a live master is never touched, and ssh itself unlinks a socket
  /// whose master is gone.
  ///
  /// `quiet` sends the creator's output to `/dev/null` (background probes);
  /// a terminal keeps it, so auth prompts and errors stay visible.
  static func sharedMasterGuard(
    host: RemoteHost,
    extraOptions: [String],
    quiet: Bool,
    sshPath: String = sshExecutablePath
  ) -> String {
    let ssh = shellQuote(sshPath)
    let control = controlArguments
    let target = (host.sshOptionArguments + [host.sshDestination]).map(shellQuote)
      .joined(separator: " ")
    var create =
      "/usr/bin/lockf -k -t \(masterLockTimeoutSeconds) \"$codans_cp.lock\" \(ssh) \(control)"
    for option in extraOptions {
      create += " " + shellQuote(option)
    }
    create += " -n \(target) true"
    if quiet {
      create += " >/dev/null 2>&1"
    }
    return "if ! \(ssh) \(control) -O check \(target) >/dev/null 2>&1; then "
      + "codans_cp=$(\(ssh) -G \(control) \(target) 2>/dev/null | /usr/bin/sed -n 's/^controlpath //p'); "
      + "[ -n \"$codans_cp\" ] && \(create); fi; "
  }

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

  /// Local argv for `Process` / `CommandRunner`. `/bin/sh` runs
  /// `sharedMasterLine` with the ssh arguments after the control options as
  /// `$@`, so the ssh argv stays one token per element: the remote command is
  /// the last argument, and ssh hands it to the remote login shell verbatim.
  static func invocation(
    host: RemoteHost,
    executable: String,
    arguments: [String],
    workingDirectory: String?,
    allocateTTY: Bool = false,
    controlPath: String = defaultControlPath,
    extraOptions: [String] = []
  ) -> (executableURL: URL, arguments: [String]) {
    var sshArguments = extraOptions
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
    let script = sharedMasterLine(
      host: host, extraOptions: extraOptions, quiet: true, sshArguments: "\"$@\"",
      controlPath: controlPath
    )
    return (
      URL(fileURLWithPath: guardShellPath),
      ["-c", script, guardShellName] + sshArguments
    )
  }

  /// Full `ssh` line as a single string for a parent `/bin/sh -c` (libghostty's
  /// surface command), built by `sharedMasterLine`, so a reconnect waits for
  /// (or creates) a shared master instead of racing the probes for it, and
  /// moves to the next master when one is full. The fixed option tokens are
  /// shell-safe and stay unquoted; the login-shell-wrapped remote command is
  /// quoted for the local shell.
  static func commandLine(
    host: RemoteHost,
    remoteCommand: String,
    allocateTTY: Bool = true,
    controlPath: String = defaultControlPath
  ) -> String {
    var tokens = interactiveOptions
    if allocateTTY {
      tokens.append("-tt")
    }
    tokens += host.sshOptionArguments
    tokens.append(host.sshDestination)
    tokens.append(shellQuote(loginShellWrapped(remoteCommand)))
    return sharedMasterLine(
      host: host, extraOptions: interactiveOptions, quiet: false,
      sshArguments: tokens.joined(separator: " "), controlPath: controlPath
    )
  }
}
