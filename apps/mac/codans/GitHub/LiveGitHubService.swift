import Foundation
import CodansCore
import os

/// Production implementation of `GitHubService`. Wraps `gh` via the shared
/// `CommandRunner` primitive and routes every domain error through `GitHubError`.
///
/// Env allowlist: the subprocess inherits only `PATH` and `HOME` from the parent, plus
/// a forced `LC_ALL=en_US.UTF-8` so `gh`'s JSON output is stable. Every other variable
/// — including any `GH_*` / `GITHUB_*` that the user may have set — is stripped. `gh`
/// reads its token from its own config store (`~/.config/gh/hosts.yml`), not the env,
/// so removing `GH_*` does not break auth.
///
/// Timeout + output cap mirror `LiveGitService`: 20 s default, 2 MiB stdout cap (PR
/// check lists can be large, but they're bounded by GitHub's own limits).
nonisolated struct LiveGitHubService: GitHubService {
  private static let logger = Logger(subsystem: "com.gumpw.codans.github", category: "service")
  private static let defaultTimeout: Duration = .seconds(20)
  private static let defaultMaxOutputBytes: Int = 2 * 1024 * 1024

  let runner: any CommandRunner
  let resolver: GhExecutableResolver
  let timeout: Duration
  let maxOutputBytes: Int

  init(
    runner: any CommandRunner = FoundationCommandRunner(),
    resolver: GhExecutableResolver = .shared,
    timeout: Duration = LiveGitHubService.defaultTimeout,
    maxOutputBytes: Int = LiveGitHubService.defaultMaxOutputBytes
  ) {
    self.runner = runner
    self.resolver = resolver
    self.timeout = timeout
    self.maxOutputBytes = maxOutputBytes
  }

  // MARK: - availability

  func availability() async -> GitHubAvailability {
    guard let exec = await resolver.resolve() else {
      return .unavailable(reason: GitHubError.notInstalled.userFacingMessage)
    }
    let cmd = GhCommand.authStatus()
    let outcome = await runner.run(
      executable: exec,
      arguments: cmd.arguments,
      env: Self.makeEnv(),
      // gh auth status doesn't need a real cwd — use the home dir so gh's own config
      // resolution is not affected by whatever the current directory happens to be.
      cwd: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
      timeout: timeout,
      maxOutputBytes: maxOutputBytes
    )
    switch outcome {
    case .exited(let code, let stdout, _, _) where cmd.expectedExitCodes.contains(code):
      do {
        guard let result = try JSONOutputParsers.parseAuthStatus(stdout) else {
          return .unavailable(reason: GitHubError.notAuthenticated(host: nil).userFacingMessage)
        }
        return .available(host: result.host, user: result.user)
      } catch let error as GitHubError {
        return .unavailable(reason: error.userFacingMessage)
      } catch {
        return .unavailable(reason: GitHubError.other(String(describing: error)).userFacingMessage)
      }
    case .exited(_, _, let stderr, _):
      return .unavailable(reason: Self.translateError(stderr: stderr).userFacingMessage)
    case .timedOut:
      return .unavailable(reason: GitHubError.timeout.userFacingMessage)
    case .spawnFailed:
      return .unavailable(reason: GitHubError.notInstalled.userFacingMessage)
    }
  }

  // MARK: - reads

  func latestWorkflowRun(branch: String, worktreePath: URL) async throws -> WorkflowRun? {
    let cmd = GhCommand.runListLatest(branch: branch)
    let outcome = try await runExpecting(cmd, cwd: worktreePath)
    switch outcome {
    case .success(let data):
      return try JSONOutputParsers.parseLatestWorkflowRun(data)
    case .noResult:
      return nil
    }
  }

  // MARK: - writes

  func merge(number: Int, strategy: MergeStrategy, worktreePath: URL) async throws {
    let cmd = GhCommand.pullRequestMerge(number: number, strategy: strategy)
    _ = try await runExpecting(cmd, cwd: worktreePath, stderrOverride: Self.translateMergeError)
  }

  func close(number: Int, worktreePath: URL) async throws {
    let cmd = GhCommand.pullRequestClose(number: number)
    _ = try await runExpecting(cmd, cwd: worktreePath)
  }

  func markReady(number: Int, worktreePath: URL) async throws {
    let cmd = GhCommand.pullRequestReady(number: number)
    _ = try await runExpecting(cmd, cwd: worktreePath)
  }

  func rerunFailedJobs(runID: Int64, worktreePath: URL) async throws {
    let cmd = GhCommand.runRerunFailed(runID: runID)
    _ = try await runExpecting(cmd, cwd: worktreePath)
  }

  // MARK: - v2 batched PR fetch

  func batchPullRequests(
    host: String,
    owner: String,
    repo: String,
    branches: [String]
  ) async throws -> [String: PullRequestSnapshot] {
    guard !branches.isEmpty else { return [:] }
    let chunks = BatchedPullRequestQuery.chunk(branches)
    let maxConcurrent = BatchedPullRequestQuery.maxConcurrentChunks

    // Work-stealing TaskGroup: keep `maxConcurrent` children in flight at once. On each
    // child completion, enqueue the next waiting chunk until all are scheduled. If any
    // child throws, the TaskGroup propagates — cancelling siblings — and the error
    // reaches the outer await.
    return try await withThrowingTaskGroup(
      of: [String: PullRequestSnapshot].self
    ) { group in
      var nextChunkIndex = 0
      let primeCount = min(maxConcurrent, chunks.count)
      while nextChunkIndex < primeCount {
        let chunk = chunks[nextChunkIndex]
        group.addTask { [self] in
          try await fetchChunk(host: host, owner: owner, repo: repo, branches: chunk)
        }
        nextChunkIndex += 1
      }

      var merged: [String: PullRequestSnapshot] = [:]
      while let chunkResult = try await group.next() {
        for (branch, snap) in chunkResult {
          merged[branch] = snap
        }
        if nextChunkIndex < chunks.count {
          let chunk = chunks[nextChunkIndex]
          group.addTask { [self] in
            try await fetchChunk(host: host, owner: owner, repo: repo, branches: chunk)
          }
          nextChunkIndex += 1
        }
      }
      return merged
    }
  }

  /// Runs one GraphQL query for up to `BatchedPullRequestQuery.chunkSize` branches and
  /// decodes the response. Translates validator / decoder errors into `GitHubError`.
  /// Uses an 8 MiB stdout cap (vs the 2 MiB per-PR cap) because a full batched response
  /// with rollup can hit 4–6 MiB on dense-CI PRs.
  private func fetchChunk(
    host: String,
    owner: String,
    repo: String,
    branches: [String]
  ) async throws -> [String: PullRequestSnapshot] {
    guard let exec = await resolver.resolve() else {
      throw GitHubError.notInstalled
    }
    let built: (query: String, aliasMap: [String: String])
    do {
      built = try BatchedPullRequestQuery.buildQuery(branches: branches)
    } catch BatchedPullRequestQuery.ValidationError.invalidBranchName(let name) {
      throw GitHubError.malformedBranchName(name)
    } catch {
      throw GitHubError.other("batched query build: \(error)")
    }

    let cmd = GhCommand.apiGraphQL(
      query: built.query,
      hostname: host,
      variables: ["owner": owner, "repo": repo]
    )
    let chunkMaxBytes = 8 * 1024 * 1024
    let outcome = await runner.run(
      executable: exec,
      arguments: cmd.arguments,
      env: Self.makeEnv(),
      cwd: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
      timeout: timeout,
      maxOutputBytes: chunkMaxBytes
    )
    switch outcome {
    case .exited(let code, let stdout, let stderr, let overflow):
      if overflow {
        throw GitHubError.oversizeResponse(bytes: chunkMaxBytes)
      }
      if code == 0 {
        return try JSONOutputParsers.parseBatchedPullRequests(
          stdout, aliasMap: built.aliasMap, remoteOwner: owner
        )
      }
      let stderrString = String(data: stderr, encoding: .utf8) ?? ""
      // `gh api` propagates a non-zero exit with the error body in stderr. GraphQL
      // schema errors (unknown fields, type mismatches) look like a shell-level failure
      // here; translateError catches the common auth / network / outdated patterns.
      throw Self.translateError(stderr: stderrString)
    case .timedOut:
      throw GitHubError.timeout
    case .spawnFailed:
      throw GitHubError.notInstalled
    }
  }

  // MARK: - Private

  /// Outcome discriminates "gh exited 0 with payload" from "gh exited 1 with a recognised
  /// 'nothing to report' stderr" (e.g., "no pull requests found"). Callers of read methods
  /// return `nil` / `[]` for `.noResult`; callers of write methods treat it as an error
  /// because a write path never expects "nothing to report".
  private enum RunOutcome {
    case success(Data)
    case noResult
  }

  private func runExpecting(
    _ command: (arguments: [String], expectedExitCodes: Set<Int32>),
    cwd: URL,
    stderrOverride: ((String) -> GitHubError?)? = nil
  ) async throws -> RunOutcome {
    guard let exec = await resolver.resolve() else {
      throw GitHubError.notInstalled
    }
    let outcome = await runner.run(
      executable: exec,
      arguments: command.arguments,
      env: Self.makeEnv(),
      cwd: cwd,
      timeout: timeout,
      maxOutputBytes: maxOutputBytes
    )
    switch outcome {
    case .exited(let code, let stdout, let stderr, let overflow):
      if overflow {
        throw GitHubError.other("gh stdout exceeded \(maxOutputBytes) bytes")
      }
      if code == 0 {
        return .success(stdout)
      }
      if command.expectedExitCodes.contains(code) {
        // Exit 1 on pr view / auth status is how gh reports "no PR" / "not authed".
        let stderrString = String(data: stderr, encoding: .utf8) ?? ""
        if Self.stderrIndicatesNoResult(stderrString) {
          return .noResult
        }
        // Fall through to error translation.
        if let override = stderrOverride, let translated = override(stderrString) {
          throw translated
        }
        throw Self.translateError(stderr: stderrString)
      }
      let stderrString = String(data: stderr, encoding: .utf8) ?? ""
      if let override = stderrOverride, let translated = override(stderrString) {
        throw translated
      }
      throw Self.translateError(stderr: stderrString)
    case .timedOut:
      throw GitHubError.timeout
    case .spawnFailed:
      throw GitHubError.notInstalled
    }
  }

  /// Minimum env for a gh subprocess. `PATH` + `HOME` come from the parent when available;
  /// `LC_ALL` is forced so gh's JSON output is stable. `GH_CONFIG_DIR` + `XDG_CONFIG_HOME`
  /// are forwarded so `gh` finds its own config store (`hosts.yml` / tokens) — this is the
  /// config-location family, *not* the credential family (`GH_TOKEN`, `GITHUB_TOKEN`, etc.
  /// remain stripped so the user's tokens stay in gh's keyring, not the subprocess env).
  /// See `gh help environment` for the full list.
  nonisolated static func makeEnv() -> [String: String] {
    var env: [String: String] = ["LC_ALL": "en_US.UTF-8"]
    let parent = ProcessInfo.processInfo.environment
    for key in ["PATH", "HOME", "GH_CONFIG_DIR", "XDG_CONFIG_HOME"] {
      if let value = parent[key] { env[key] = value }
    }
    return env
  }

  /// Returns true when gh's stderr indicates a "nothing to report" (rather than a real
  /// error). The patterns are lenient — gh's exact wording drifts across versions.
  nonisolated static func stderrIndicatesNoResult(_ stderr: String) -> Bool {
    let lowered = stderr.lowercased()
    return lowered.contains("no pull request")
      || lowered.contains("no pull requests")
      || lowered.contains("could not find any pull request")
      || lowered.contains("no open pull request")
  }

  /// Maps gh stderr into a rich `GitHubError`. Order matters — more specific patterns
  /// first, catch-all last.
  nonisolated static func translateError(stderr: Any) -> GitHubError {
    let text: String = {
      if let s = stderr as? String { return s }
      if let d = stderr as? Data { return String(data: d, encoding: .utf8) ?? "" }
      return String(describing: stderr)
    }().lowercased()

    if text.contains("not logged") || text.contains("auth required")
      || text.contains("authentication required")
      || text.contains("token")
        && text.contains("expired")
    {
      return .notAuthenticated(host: Self.parseHostHint(text))
    }
    if text.contains("rate limit") {
      return .rateLimited(retryAfter: nil)
    }
    if text.contains("could not resolve") || text.contains("network")
      || text.contains("no such host") || text.contains("timeout while")
      || text.contains("connection refused") || text.contains("unreachable")
    {
      return .network(Self.firstLine(text))
    }
    if text.contains("not mergeable") || text.contains("cannot be merged")
      || text.contains("merge conflict")
    {
      return .mergeConflict
    }
    if text.isEmpty { return .other("gh exited non-zero with empty stderr") }
    return .other(Self.firstLine(text))
  }

  /// `gh pr merge` has a narrower error surface than the generic translator assumes.
  /// This override fires first for merge calls so "not mergeable" reports cleanly.
  nonisolated static func translateMergeError(stderr: String) -> GitHubError? {
    let lowered = stderr.lowercased()
    if lowered.contains("not mergeable") || lowered.contains("cannot be merged")
      || lowered.contains("merge conflict")
    {
      return .mergeConflict
    }
    return nil
  }

  nonisolated static func parseHostHint(_ text: String) -> String? {
    // gh messages often include "to github.com" or "to github.my-company.com". Split on
    // whitespace / closing punctuation only — '.' is part of the hostname and must not
    // terminate the token (a prior version truncated "github.com" to "github"). Trim any
    // trailing sentence punctuation that may have followed the hostname.
    guard let range = text.range(of: "to ") else { return nil }
    let tail = text[range.upperBound...]
    let token = tail.prefix { !$0.isWhitespace && $0 != "," && $0 != ")" && $0 != "\"" }
    let host = String(token).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
    return host.isEmpty ? nil : host
  }

  nonisolated static func firstLine(_ text: String) -> String {
    text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
      .first
      .map(String.init) ?? text
  }
}
