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
  /// Bare name, resolved by the host's *login* shell PATH (the invocation is
  /// login-shell wrapped) — so a Homebrew-only git on a macOS host still works.
  static let gitExecutable = "git"
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

  /// `git -C <gitRoot> worktree add -b <branch> <path> [<baseRef>]` over SSH.
  /// `path` is a remote absolute path; `baseRef` (when non-empty) is the
  /// committish the new branch starts from — same argv the local flow builds.
  /// Throws `RemoteGitError.commandFailed` carrying git's stderr so the caller
  /// can surface the reason.
  func addWorktree(gitRoot: String, branch: String, path: String, baseRef: String? = nil) async throws {
    var args = ["worktree", "add", "-b", branch, path]
    if let baseRef, !baseRef.isEmpty {
      args.append(baseRef)
    }
    let outcome = await run(arguments: args, workingDirectory: gitRoot)
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

  /// POSIX script behind `resolveAbsolutePath`: expand an intended leading `~`
  /// (double-quoted `$1` never tilde-expands, so the expansion is explicit and
  /// nothing else in the path is interpreted), then `cd && pwd -P`. Exposed for
  /// the command-shape tests.
  static let resolvePathScript = """
    case "$1" in
      "~") target=$HOME ;;
      "~/"*) target=$HOME/${1#"~/"} ;;
      *) target=$1 ;;
    esac
    cd -- "$target" 2>/dev/null && pwd -P
    """

  /// Resolve a typed remote path to an absolute, canonical (`pwd -P`) path on
  /// the host in a single round trip — expanding a leading `~`, verifying the
  /// directory exists, and normalizing symlinks, all at once. The path travels
  /// as a positional argument (never interpolated into the script), so spaces
  /// and shell metacharacters are inert. Returns `nil` when the host is
  /// unreachable or the path does not exist, so the caller can reject the add.
  /// A login shell may print banners before the probe; the result is the last
  /// non-empty stdout line.
  func resolveAbsolutePath(_ path: String) async -> String? {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let outcome = await run(
      executable: "/bin/sh",
      arguments: ["-c", Self.resolvePathScript, "sh", trimmed],
      workingDirectory: nil
    )
    guard case .exited(let code, let stdout, _, _) = outcome, code == 0 else { return nil }
    let resolved = Self.lastNonEmptyLine(of: decode(stdout))
    return resolved.isEmpty ? nil : resolved
  }

  /// The last non-empty line of `output`, trimmed. A login shell sources
  /// dotfiles before running a probe, so any banner they print precedes the
  /// command's own output; the real result is the final line.
  static func lastNonEmptyLine(of output: String) -> String {
    output
      .split(whereSeparator: \.isNewline)
      .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
  }

  // MARK: - Branch surface (create-worktree options)

  /// `git for-each-ref --format=%(refname:short) refs/heads refs/remotes` over
  /// SSH, with `<remote>/HEAD` filtered — the base-ref options for the create
  /// sheet, same shape as the local client.
  func branchRefs(gitRoot: String) async throws -> [String] {
    let stdout = try unwrap(
      await run(
        arguments: ["for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes"],
        workingDirectory: gitRoot
      ),
      command: "git for-each-ref refs/heads refs/remotes"
    )
    return
      stdout
      .components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.hasSuffix("/HEAD") }
  }

  /// Local branch names on the host (original casing), for the create sheet's
  /// collision classification.
  func localBranchNames(gitRoot: String) async throws -> Set<String> {
    let stdout = try unwrap(
      await run(
        arguments: ["for-each-ref", "--format=%(refname:short)", "refs/heads"],
        workingDirectory: gitRoot
      ),
      command: "git for-each-ref refs/heads"
    )
    return Set(
      stdout
        .components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    )
  }

  /// The host repo's default remote branch (`origin/HEAD` symbolic-ref, with a
  /// `git remote show origin` fallback for clones where the local symref was
  /// never set). `nil` when neither resolves.
  func defaultRemoteBranchRef(gitRoot: String) async -> String? {
    let symbolic = await run(
      arguments: ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
      workingDirectory: gitRoot
    )
    if case .exited(let code, let stdout, _, _) = symbolic, code == 0 {
      let trimmed = Self.lastNonEmptyLine(of: decode(stdout))
      if !trimmed.isEmpty { return trimmed }
    }
    let show = await run(
      arguments: ["remote", "show", "origin"],
      workingDirectory: gitRoot
    )
    guard case .exited(let code, let stdout, _, _) = show, code == 0 else { return nil }
    for line in decode(stdout).components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("HEAD branch:") else { continue }
      let branch = trimmed.dropFirst("HEAD branch:".count).trimmingCharacters(in: .whitespaces)
      if !branch.isEmpty, branch != "(unknown)" {
        return "origin/\(branch)"
      }
    }
    return nil
  }

  /// `git check-ref-format --branch <name>` on the host.
  func isValidBranchName(gitRoot: String, name: String) async -> Bool {
    let outcome = await run(
      arguments: ["check-ref-format", "--branch", name],
      workingDirectory: gitRoot
    )
    if case .exited(let code, _, _, _) = outcome, code == 0 { return true }
    return false
  }

  /// When `baseRef` starts with one of the repo's remote names (`origin/…`),
  /// `git fetch <remote>` on the host so the new worktree branches from
  /// up-to-date refs — mirroring the local fetch-before-create behavior.
  /// Best-effort and non-fatal: a fetch failure must not block creation, and a
  /// base ref with no remote prefix (a local branch, `HEAD`) skips the fetch.
  func fetchIfBaseRefTracksRemote(baseRef: String, gitRoot: String) async {
    let remotesOutcome = await run(arguments: ["remote"], workingDirectory: gitRoot)
    guard case .exited(let code, let stdout, _, _) = remotesOutcome, code == 0 else { return }
    let remotes = decode(stdout)
      .components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    guard let matched = remotes.first(where: { baseRef.hasPrefix($0 + "/") }) else { return }
    _ = await run(arguments: ["fetch", matched], workingDirectory: gitRoot)
  }

  /// `git fetch <remote>` on the host. Throws on failure so callers that need
  /// the result (explicit fetch actions) can surface it; best-effort callers
  /// wrap in `try?`.
  func fetchRemote(gitRoot: String, remote: String) async throws {
    _ = try unwrap(
      await run(arguments: ["fetch", remote], workingDirectory: gitRoot),
      command: "git fetch \(remote)"
    )
  }

  /// `git worktree prune` on the host. Returns the number of entries pruned,
  /// measured as the before/after difference of the worktree listing (prune
  /// itself prints nothing on success).
  func pruneWorktrees(gitRoot: String) async throws -> Int {
    let before = (try? await listWorktrees(gitRoot: gitRoot).count) ?? 0
    _ = try unwrap(
      await run(arguments: ["worktree", "prune"], workingDirectory: gitRoot),
      command: "git worktree prune"
    )
    let after = (try? await listWorktrees(gitRoot: gitRoot).count) ?? before
    return max(0, before - after)
  }

  /// `git status --porcelain` on the host, parsed into file paths (same
  /// prefix-stripping as the local client). Feeds the remove-confirmation
  /// dialog's uncommitted-files list.
  func changedFiles(worktreeRoot: String) async throws -> [String] {
    let stdout = try unwrap(
      await run(arguments: ["status", "--porcelain"], workingDirectory: worktreeRoot),
      command: "git status --porcelain"
    )
    return GitWorktreeClient.parsePorcelainPaths(stdout)
  }

  /// Best-effort deletion of the branch's remote-tracking counterpart, run on
  /// the host (`git push <remote> --delete <branch>`, remote resolved from the
  /// branch's configured upstream, falling back to `origin`). The push uses
  /// the HOST's own credentials/agent; failures (no upstream, offline, auth)
  /// are swallowed — they must never fail the worktree removal.
  func deleteRemoteBranchIfExists(gitRoot: String, branch: String) async {
    var remote = "origin"
    let upstream = await run(
      arguments: ["for-each-ref", "--format=%(upstream:remotename)", "refs/heads/\(branch)"],
      workingDirectory: gitRoot
    )
    if case .exited(let code, let stdout, _, _) = upstream, code == 0 {
      let trimmed = Self.lastNonEmptyLine(of: decode(stdout))
      if !trimmed.isEmpty { remote = trimmed }
    }
    _ = await run(arguments: ["push", remote, "--delete", branch], workingDirectory: gitRoot)
  }

  /// Best-effort `git branch -D <branch>` on the host after a worktree
  /// removal. Mirrors the local outcome mapping: `.kept` when git refuses
  /// (branch checked out elsewhere — exactly when it must survive), `.absent`
  /// when the branch is already gone, `.deleted` on success. Never throws.
  func deleteBranchIfExists(gitRoot: String, branch: String) async -> BranchDeleteOutcome {
    let outcome = await run(arguments: ["branch", "-D", branch], workingDirectory: gitRoot)
    guard case .exited(let code, _, let stderr, _) = outcome else {
      return .kept(reason: "git branch -D did not complete")
    }
    if code == 0 { return .deleted }
    let message = decode(stderr).trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = message.lowercased()
    if lower.contains("not found") || lower.contains("no branch named")
      || lower.contains("couldn't look up")
    {
      return .absent
    }
    return .kept(reason: message.isEmpty ? "git refused to delete the branch" : message)
  }

  // MARK: - Invocation

  private func run(
    executable: String = Self.gitExecutable,
    arguments: [String],
    workingDirectory: String?
  ) async -> CommandOutcome {
    let (sshExecutable, sshArguments) = SSHCommand.invocation(
      host: host,
      executable: executable,
      arguments: arguments,
      workingDirectory: workingDirectory,
      extraOptions: SSHCommand.backgroundProbeOptions
    )
    return await runner.run(
      executable: sshExecutable,
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
