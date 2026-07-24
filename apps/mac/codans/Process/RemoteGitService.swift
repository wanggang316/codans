import CodansCore
import Foundation

/// Git-over-SSH for Server projects. Mirrors the local `GitWorktreeCLI` +
/// reconcile discovery surface, but every `git` invocation is wrapped by
/// `SSHCommand.invocation` and runs through the shared `CommandRunner`
/// (executable = `/usr/bin/ssh`). A Server host has no bundled `wt` script, so
/// discovery and worktree mutation use plain `git worktree` porcelain.
///
/// Path handling rule: remote paths are opaque strings — never routed through
/// `URL(fileURLWithPath:)` / `resolvingSymlinksInPath` (those resolve against
/// the *local* filesystem). `git rev-parse --show-toplevel` and `git worktree
/// list --porcelain` already emit canonical absolute paths on the host, so the
/// service returns them verbatim and the caller applies string-only
/// normalization.
///
/// All calls share one multiplexed SSH connection (`SSHCommand.controlOptions`)
/// with the interactive terminal, so a many-worktree reconcile costs one auth.
nonisolated struct RemoteGitService: Sendable {
  static let gitExecutable = "/usr/bin/git"
  static let defaultTimeout: Duration = .seconds(30)
  static let maxOutputBytes = 4 * 1024 * 1024

  let host: RemoteHost
  let runner: any CommandRunner

  init(host: RemoteHost, runner: any CommandRunner = FoundationCommandRunner()) {
    self.host = host
    self.runner = runner
  }

  /// `git -C <candidate> rev-parse --show-toplevel` over SSH. Returns the
  /// remote git root, or `nil` when the candidate is not inside a work tree
  /// (git exits non-zero) or the probe fails. Never throws — reconcile must
  /// degrade to "no git root" rather than crash.
  func discoverGitRoot(candidatePath: String) async -> String? {
    let outcome = await run(
      arguments: ["rev-parse", "--show-toplevel"],
      workingDirectory: candidatePath
    )
    guard case .exited(let code, let stdout, _, _) = outcome, code == 0 else { return nil }
    let trimmed = decode(stdout).trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// `git -C <gitRoot> worktree list --porcelain` over SSH, parsed into the
  /// same `GitWorktreeEntry` shape the local CLI produces. Throws
  /// `RemoteGitError` on a failed / unreachable probe so the reconcile caller
  /// can log and skip (append-only discovery must not wipe existing rows on a
  /// transient SSH failure).
  func listWorktrees(gitRoot: String) async throws -> [GitWorktreeEntry] {
    let outcome = await run(
      arguments: ["worktree", "list", "--porcelain"],
      workingDirectory: gitRoot
    )
    let stdout = try unwrap(outcome, command: "git worktree list --porcelain")
    return Self.parseWorktreeList(stdout)
  }

  /// `git -C <gitRoot> worktree add -b <branch> <path>` over SSH. `path` is a
  /// remote absolute path. Throws `RemoteGitError.commandFailed` carrying git's
  /// stderr so the caller can surface the reason.
  func addWorktree(gitRoot: String, branch: String, path: String) async throws {
    let outcome = await run(
      arguments: ["worktree", "add", "-b", branch, path],
      workingDirectory: gitRoot
    )
    _ = try unwrap(outcome, command: "git worktree add")
  }

  /// `git -C <gitRoot> worktree remove [--force] <path>` over SSH. A Server
  /// host has no local trash to relocate into, so removal is the plain git
  /// command; `force` maps to `--force`.
  func removeWorktree(gitRoot: String, path: String, force: Bool) async throws {
    var args = ["worktree", "remove"]
    if force { args.append("--force") }
    args.append(path)
    let outcome = await run(arguments: args, workingDirectory: gitRoot)
    _ = try unwrap(outcome, command: "git worktree remove")
  }

  // MARK: - Invocation

  private func run(
    arguments: [String],
    workingDirectory: String?
  ) async -> CommandOutcome {
    let (executable, sshArguments) = SSHCommand.invocation(
      host: host,
      executable: Self.gitExecutable,
      arguments: arguments,
      workingDirectory: workingDirectory,
      extraOptions: SSHCommand.backgroundProbeOptions
    )
    return await runner.run(
      executable: executable,
      arguments: sshArguments,
      // ssh (unlike git) needs the local session env: `SSH_AUTH_SOCK` for the
      // agent, `HOME` for `~/.ssh/config` + `known_hosts`, `PATH` for any
      // ProxyCommand helper. Hand it the full process environment rather than
      // the git-hardened allowlist.
      env: ProcessInfo.processInfo.environment,
      // ssh runs locally; its own `cd` on the remote owns the working dir, so
      // any valid local cwd works.
      cwd: URL(fileURLWithPath: NSHomeDirectory()),
      timeout: Self.defaultTimeout,
      maxOutputBytes: Self.maxOutputBytes
    )
  }

  private func decode(_ data: Data) -> String {
    String(data: data, encoding: .utf8) ?? ""
  }

  private func unwrap(_ outcome: CommandOutcome, command: String) throws -> String {
    switch outcome {
    case .exited(let code, let stdout, let stderr, _):
      guard code == 0 else {
        throw RemoteGitError.commandFailed(
          command: command,
          // ssh reserves exit 255 for its own connection errors; surface it
          // distinctly so the caller can tell "host unreachable" from "git
          // refused".
          exitCode: code,
          stderr: decode(stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        )
      }
      return decode(stdout)
    case .timedOut:
      throw RemoteGitError.commandFailed(command: command, exitCode: nil, stderr: "timed out")
    case .spawnFailed(let reason):
      throw RemoteGitError.commandFailed(command: command, exitCode: nil, stderr: reason)
    }
  }

  // MARK: - Parsing

  /// Parse `git worktree list --porcelain` into `[GitWorktreeEntry]`. The
  /// porcelain format is one record per worktree, records separated by a blank
  /// line, each a set of `key value` lines (`worktree <path>`, `HEAD <sha>`,
  /// `branch refs/heads/<name>`, or a bare `detached`). Shared with the local
  /// `GitWorktreeCLI` shape so the reconcile mapping is identical.
  static func parseWorktreeList(_ output: String) -> [GitWorktreeEntry] {
    var entries: [GitWorktreeEntry] = []
    var path: String?
    var head: String?
    var branch: String?

    func flush() {
      if let path, let head {
        entries.append(GitWorktreeEntry(path: path, branch: branch, head: head))
      }
      path = nil
      head = nil
      branch = nil
    }

    for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty {
        flush()
        continue
      }
      if line.hasPrefix("worktree ") {
        path = String(line.dropFirst("worktree ".count))
      } else if line.hasPrefix("HEAD ") {
        head = String(line.dropFirst("HEAD ".count))
      } else if line.hasPrefix("branch ") {
        let ref = String(line.dropFirst("branch ".count))
        branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
      } else if line == "detached" {
        branch = nil
      }
    }
    flush()
    return entries
  }
}

/// Typed error for `RemoteGitService`. `exitCode == 255` (or `nil` for a spawn
/// failure / timeout) signals an SSH-level failure — host unreachable, auth
/// rejected — distinct from git refusing a valid connection.
nonisolated enum RemoteGitError: Error, Equatable, Sendable {
  case commandFailed(command: String, exitCode: Int32?, stderr: String)

  /// True when the failure is at the SSH transport layer (exit 255, spawn
  /// failure, or timeout) rather than git rejecting the command.
  var isConnectionFailure: Bool {
    switch self {
    case .commandFailed(_, let exitCode, _):
      return exitCode == 255 || exitCode == nil
    }
  }
}
