import Foundation
import CodansCore

/// Process-backed `GitService`. Builds argv via `GitCommand`, runs through the pluggable
/// `CommandRunner` seam (live implementation wraps `Foundation.Process`), applies
/// `GitProcessEnv` stripping, and enforces the 16 MiB output cap + 10 s wall-clock timeout.
///
/// Correctness notes:
/// - `gitExecutable` defaults to `/usr/bin/git` directly, not `/usr/bin/env`. This keeps the
///   env-whitelist guarantee (`PATH` exposure is then irrelevant to which git runs).
/// - `.notARepo` is detected via `rev-parse --is-inside-work-tree` at the edge, not by
///   substring-matching stderr. Stderr matching is retained only as a narrow fallback for
///   paths where the pre-check races with the Worktree being removed.
/// - Invalid commit SHAs are rejected before the subprocess spawns.
nonisolated final class LiveGitService: GitService {
  static let maxOutputBytes = 16 * 1024 * 1024  // 16 MiB
  static let defaultTimeout: Duration = .seconds(10)

  let gitExecutable: URL
  let runner: any CommandRunner

  init(
    gitExecutable: URL = URL(fileURLWithPath: "/usr/bin/git"),
    runner: any CommandRunner = FoundationCommandRunner()
  ) {
    self.gitExecutable = gitExecutable
    self.runner = runner
  }

  // MARK: - GitService

  func log(at path: URL, page: LogPage.Cursor) async throws -> LogPage {
    try await ensureIsRepo(at: path)
    let probeLimit = max(1, page.limit + 1)
    let args = GitCommand.log(limit: probeLimit, skip: page.offset)
    let out = try await run(arguments: args, cwd: path)
    var commits = try GitOutputParser.parseLog(out)
    let hasMore = commits.count > page.limit
    if hasMore { commits.removeLast() }
    return LogPage(cursor: page, commits: commits, hasMore: hasMore)
  }

  func workingTreeDiff(at path: URL, ignoreWhitespace: Bool) async throws -> UnifiedDiff {
    try await ensureIsRepo(at: path)
    let out = try await run(
      arguments: GitCommand.diff(kind: .workingTree, ignoreWhitespace: ignoreWhitespace),
      cwd: path
    )
    return try DiffParser.parse(out, scope: .working)
  }

  func stagedDiff(at path: URL, ignoreWhitespace: Bool) async throws -> UnifiedDiff {
    try await ensureIsRepo(at: path)
    let out = try await run(
      arguments: GitCommand.diff(kind: .staged, ignoreWhitespace: ignoreWhitespace),
      cwd: path
    )
    return try DiffParser.parse(out, scope: .staged)
  }

  func commitDiff(at path: URL, sha: String, ignoreWhitespace: Bool) async throws -> UnifiedDiff {
    guard GitShaValidator.isValid(sha) else {
      throw GitError.invalidInput("not a git SHA: '\(sha)'")
    }
    try await ensureIsRepo(at: path)
    let out = try await run(
      arguments: GitCommand.diff(kind: .commit(sha: sha), ignoreWhitespace: ignoreWhitespace),
      cwd: path
    )
    return try DiffParser.parse(out, scope: .commit(sha: sha))
  }

  func status(at path: URL) async throws -> WorkingTreeStatus {
    try await ensureIsRepo(at: path)
    let out = try await run(arguments: GitCommand.status(), cwd: path)
    return try GitOutputParser.parseStatus(out)
  }

  func diffNumstat(at worktreePath: URL) async throws -> [ChangedFile] {
    try await ensureIsRepo(at: worktreePath)
    // Two parallel reads — one for line counts (`numstat`) and one for status letters
    // (`name-status`). Both use `-z` so paths with embedded whitespace round-trip cleanly.
    async let numstatBytes = run(
      arguments: [
        "-c", "core.quotePath=false",
        "diff", "--no-color", "--no-ext-diff", "-M", "-C", "--numstat", "-z",
      ],
      cwd: worktreePath
    )
    async let nameStatusBytes = run(
      arguments: [
        "-c", "core.quotePath=false",
        "diff", "--no-color", "--no-ext-diff", "-M", "-C", "--name-status", "-z",
      ],
      cwd: worktreePath
    )
    let (n, s) = try await (numstatBytes, nameStatusBytes)
    let numstat = try GitOutputParser.parseDiffNumstatZ(n)
    let nameStatus = try GitOutputParser.parseDiffNameStatusZ(s)
    return GitOutputParser.joinDiffNumstatNameStatus(numstat: numstat, nameStatus: nameStatus)
  }

  func showFileAtHEAD(_ path: String, at worktreePath: URL) async throws -> String? {
    try await ensureIsRepo(at: worktreePath)
    let outcome = await runner.run(
      executable: gitExecutable,
      arguments: ["show", "HEAD:\(path)"],
      env: GitProcessEnv.build(),
      cwd: worktreePath,
      timeout: Self.defaultTimeout,
      maxOutputBytes: Self.maxOutputBytes
    )
    switch outcome {
    case .exited(let code, let stdout, let stderr, let overflow):
      if code != 0 {
        let text = String(data: stderr, encoding: .utf8) ?? ""
        // `path exists on disk, but not in 'HEAD'` / `does not exist` for newly-added files —
        // surface as nil rather than throwing so the caller treats it as an additions-only diff.
        if text.contains("exists on disk, but not in")
          || text.contains("does not exist")
          || text.contains("bad object")
        {
          return nil
        }
        throw GitError.exec(code: code, stderr: text)
      }
      if overflow { throw GitError.outputTooLarge }
      return String(data: stdout, encoding: .utf8) ?? ""
    case .timedOut:
      throw GitError.timedOut
    case .spawnFailed(let reason):
      if reason.contains("binary not found") { throw GitError.gitMissing }
      throw GitError.unparsable(context: "spawn failed: \(reason)")
    }
  }

  func localDiffStats(at worktreePath: URL) async throws -> LocalDiffStats? {
    try await ensureIsRepo(at: worktreePath)
    let out: Data
    do {
      out = try await run(arguments: ["diff", "HEAD", "--shortstat"], cwd: worktreePath)
    } catch GitError.exec {
      // Unborn HEAD / freshly cloned repo with no commits — surface as
      // "no stats available" rather than throwing onto the sidebar.
      return nil
    }
    let text = String(data: out, encoding: .utf8) ?? ""
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return LocalDiffStats(additions: 0, deletions: 0) }
    return parseShortStat(trimmed)
  }

  /// Extracts `+additions −deletions` from `git diff --shortstat` output.
  /// Sample line: ` 3 files changed, 17 insertions(+), 4 deletions(-)`.
  private func parseShortStat(_ text: String) -> LocalDiffStats {
    func firstIntBefore(_ token: String, in source: String) -> Int {
      guard let range = source.range(of: token) else { return 0 }
      let head = source[source.startIndex..<range.lowerBound]
      let digits = head.reversed().drop(while: { $0 == " " }).prefix(while: { $0.isNumber })
      let str = String(digits.reversed())
      return Int(str) ?? 0
    }
    return LocalDiffStats(
      additions: firstIntBefore("insertion", in: text),
      deletions: firstIntBefore("deletion", in: text)
    )
  }

  func remoteInfo(at path: URL) async throws -> RemoteInfo {
    try await ensureIsRepo(at: path)
    let out = try await run(arguments: GitCommand.remoteGetUrl(), cwd: path)
    let urlString =
      String(data: out, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    do {
      return try RemoteInfo.parse(urlString)
    } catch RemoteInfo.ParseError.malformed(let raw) {
      throw GitError.malformedRemoteURL(raw)
    }
  }

  func currentBranch(at path: URL) async throws -> String? {
    try await ensureIsRepo(at: path)
    // Call the runner directly (rather than the shared `run` helper) so we can
    // inspect the exit code without throwing — `git symbolic-ref --short HEAD`
    // returns exit 1 on detached HEAD and we surface that as `nil`.
    let outcome = await runner.run(
      executable: gitExecutable,
      arguments: GitCommand.symbolicRefShortHead(),
      env: GitProcessEnv.build(),
      cwd: path,
      timeout: Self.defaultTimeout,
      // `git symbolic-ref --short HEAD` returns a single ref name (≤ 255 chars);
      // mirror the 1024 cap used by `ensureIsRepo` for the same one-line shape.
      maxOutputBytes: 1024
    )
    switch outcome {
    case .exited(let code, let stdout, let stderr, let overflow):
      if code == 1 {
        // Detached HEAD — trust the exit code, do not parse stderr.
        return nil
      }
      if code != 0 {
        let stderrText = String(data: stderr, encoding: .utf8) ?? ""
        throw GitError.exec(code: code, stderr: stderrText)
      }
      if overflow { throw GitError.outputTooLarge }
      let text = String(data: stdout, encoding: .utf8) ?? ""
      return text.trimmingCharacters(in: .whitespacesAndNewlines)
    case .timedOut:
      throw GitError.timedOut
    case .spawnFailed(let reason):
      if reason.contains("binary not found") { throw GitError.gitMissing }
      throw GitError.unparsable(context: "spawn failed: \(reason)")
    }
  }

  func listAllBranches(at path: URL) async throws -> BranchInventory {
    try await ensureIsRepo(at: path)
    let out = try await run(arguments: GitCommand.forEachRefBranches(), cwd: path)
    return try GitOutputParser.parseBranchInventory(out)
  }

  func switchBranch(to target: BranchSwitchTarget, at path: URL) async throws {
    try await ensureIsRepo(at: path)
    _ = try await run(arguments: GitCommand.switchBranch(target: target), cwd: path)
  }

  func renameBranch(from oldName: String, to newName: String, at path: URL) async throws {
    try await ensureIsRepo(at: path)
    _ = try await run(arguments: GitCommand.branchRename(from: oldName, to: newName), cwd: path)
  }

  func createAndSwitchBranch(
    name newName: String,
    from baseName: String,
    at path: URL
  ) async throws {
    try await ensureIsRepo(at: path)
    _ = try await run(
      arguments: GitCommand.switchCreate(name: newName, from: baseName),
      cwd: path
    )
  }

  func commitMessage(sha: String, at path: URL) async throws -> String {
    try await ensureIsRepo(at: path)
    let stdout = try await run(arguments: GitCommand.showCommitMessage(sha: sha), cwd: path)
    let text = String(data: stdout, encoding: .utf8) ?? ""
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Edge checks

  /// Runs `git rev-parse --is-inside-work-tree` and throws `.notARepo` on failure. This is the
  /// authoritative check — no stderr substring matching. Idempotent; cheap (< 10 ms on local).
  ///
  /// `rev-parse --is-inside-work-tree` returns `"true"` (+ newline) on stdout when the cwd is
  /// inside a work tree; `"false"` when inside a bare repo or the `.git` gitdir itself. Exit
  /// code alone is insufficient for the latter cases — a bare-repo cwd exits 0 but the diff/
  /// log code paths would still fail downstream with opaque errors. Parse stdout to get a
  /// clear `.notARepo` at the edge instead.
  private func ensureIsRepo(at path: URL) async throws {
    let outcome = await runner.run(
      executable: gitExecutable,
      arguments: GitCommand.revParseIsInsideWorkTree(),
      env: GitProcessEnv.build(),
      cwd: path,
      timeout: Self.defaultTimeout,
      maxOutputBytes: 1024
    )
    switch outcome {
    case .exited(let code, let stdout, _, _):
      if code != 0 { throw GitError.notARepo }
      let reply = (String(data: stdout, encoding: .utf8) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if reply != "true" { throw GitError.notARepo }
    case .timedOut:
      throw GitError.timedOut
    case .spawnFailed(let reason):
      if reason.contains("binary not found") { throw GitError.gitMissing }
      throw GitError.unparsable(context: "rev-parse spawn failed: \(reason)")
    }
  }

  // MARK: - Runner invocation

  /// Runs `gitExecutable` with `arguments`, translating `CommandOutcome` to domain error or
  /// success. Applies env whitelist + 16 MiB cap + 10 s timeout.
  private func run(arguments: [String], cwd: URL) async throws -> Data {
    let outcome = await runner.run(
      executable: gitExecutable,
      arguments: arguments,
      env: GitProcessEnv.build(),
      cwd: cwd,
      timeout: Self.defaultTimeout,
      maxOutputBytes: Self.maxOutputBytes
    )
    switch outcome {
    case .exited(let code, let stdout, let stderr, let overflow):
      // Non-zero exit wins over overflow: when git itself rejects the invocation (bad
      // revision, missing ref) the stderr message is the actionable signal and we must
      // not mask it behind `.outputTooLarge`. The output-cap throw only fires on a
      // successful-looking run whose stdout actually exceeded the 16 MiB ceiling.
      if code != 0 {
        let stderrText = String(data: stderr, encoding: .utf8) ?? ""
        // Narrow fallback: the pre-check passed (rev-parse succeeded) but the subsequent
        // command raced with the worktree disappearing. Canonical git stderr phrases only.
        if stderrText.contains("fatal: not a git repository")
          || stderrText.contains("fatal: bad revision")
          || stderrText.contains("fatal: Not a valid object name")
        {
          throw GitError.notARepo
        }
        throw GitError.exec(code: code, stderr: stderrText)
      }
      if overflow { throw GitError.outputTooLarge }
      return stdout
    case .timedOut:
      throw GitError.timedOut
    case .spawnFailed(let reason):
      if reason.contains("binary not found") { throw GitError.gitMissing }
      throw GitError.unparsable(context: "spawn failed: \(reason)")
    }
  }
}
