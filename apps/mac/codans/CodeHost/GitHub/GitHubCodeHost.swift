import Foundation
import CodansCore
import os

/// GitHub implementation of `CodeHost`. Wraps `gh` via the shared `CommandRunner`
/// primitive and routes every domain error through `CodeHostError`. Writes address the
/// repository with `--repo HOST/OWNER/REPO`, so `gh` runs from the home directory and
/// never resolves the repository from a working directory.
///
/// Env allowlist: the subprocess inherits only `PATH` and `HOME` from the parent, plus
/// a forced `LC_ALL=en_US.UTF-8` so `gh`'s JSON output is stable. Every other variable
/// — including any `GH_*` / `GITHUB_*` that the user may have set — is stripped. `gh`
/// reads its token from its own config store (`~/.config/gh/hosts.yml`), not the env,
/// so removing `GH_*` does not break auth.
///
/// Timeout + output cap mirror `LiveGitService`: 20 s default, 2 MiB stdout cap (PR
/// check lists can be large, but they're bounded by GitHub's own limits).
nonisolated struct GitHubCodeHost: CodeHost {
  private static let logger = Logger(subsystem: "com.gumpw.codans.github", category: "service")
  private static let defaultTimeout: Duration = .seconds(20)
  private static let defaultMaxOutputBytes: Int = 2 * 1024 * 1024

  let runner: any CommandRunner
  let resolver: CLIExecutableResolver
  let timeout: Duration
  let maxOutputBytes: Int

  init(
    runner: any CommandRunner = FoundationCommandRunner(),
    resolver: CLIExecutableResolver = .gh,
    timeout: Duration = GitHubCodeHost.defaultTimeout,
    maxOutputBytes: Int = GitHubCodeHost.defaultMaxOutputBytes
  ) {
    self.runner = runner
    self.resolver = resolver
    self.timeout = timeout
    self.maxOutputBytes = maxOutputBytes
  }

  // MARK: - availability

  func availability() async -> CodeHostAvailability {
    guard let exec = await resolver.resolve() else {
      return .notInstalled
    }
    let cmd = GhCommand.authStatus()
    let outcome = await runner.run(
      executable: exec,
      arguments: cmd.arguments,
      env: Self.makeEnv(),
      // gh auth status doesn't need a real cwd — use the home dir so gh's own config
      // resolution is not affected by whatever the current directory happens to be.
      cwd: Self.homeDirectory,
      timeout: timeout,
      maxOutputBytes: maxOutputBytes
    )
    switch outcome {
    case .exited(let code, let stdout, _, _) where cmd.expectedExitCodes.contains(code):
      do {
        guard let result = try GitHubJSONParsers.parseAuthStatus(stdout) else {
          return .unavailable(reason: CodeHostError.notAuthenticated(.github, host: nil).userFacingMessage)
        }
        return .available(host: result.host, user: result.user)
      } catch let error as CodeHostError {
        return error.availability
      } catch {
        return .unavailable(reason: CodeHostError.other(String(describing: error)).userFacingMessage)
      }
    case .exited(_, _, let stderr, _):
      return .unavailable(reason: Self.translateError(stderr: stderr).userFacingMessage)
    case .timedOut:
      return .unavailable(reason: CodeHostError.timeout.userFacingMessage)
    case .spawnFailed:
      return .notInstalled
    }
  }

  func authenticatedHosts() async -> Set<String> {
    guard let exec = await resolver.resolve() else { return [] }
    let cmd = GhCommand.authStatus()
    let outcome = await runner.run(
      executable: exec,
      arguments: cmd.arguments,
      env: Self.makeEnv(),
      cwd: Self.homeDirectory,
      timeout: timeout,
      maxOutputBytes: maxOutputBytes
    )
    guard case .exited(let code, let stdout, _, _) = outcome, cmd.expectedExitCodes.contains(code)
    else { return [] }
    return GitHubJSONParsers.parseAuthenticatedHosts(stdout)
  }

  // MARK: - writes

  func merge(_ pullRequest: PullRequestReference, strategy: MergeStrategy) async throws {
    let cmd = GhCommand.pullRequestMerge(
      number: pullRequest.number, strategy: strategy, repo: GitHub.repoArgument(pullRequest.repository))
    _ = try await runExpecting(cmd, stderrOverride: Self.translateMergeError)
  }

  func close(_ pullRequest: PullRequestReference) async throws {
    let cmd = GhCommand.pullRequestClose(
      number: pullRequest.number, repo: GitHub.repoArgument(pullRequest.repository))
    _ = try await runExpecting(cmd)
  }

  func markReady(_ pullRequest: PullRequestReference) async throws {
    let cmd = GhCommand.pullRequestReady(
      number: pullRequest.number, repo: GitHub.repoArgument(pullRequest.repository))
    _ = try await runExpecting(cmd)
  }

  /// Reruns the failed jobs (`gh run rerun --failed`) of every GitHub Actions run with a
  /// failed CheckRun on the pull request's head commit — the runs that made
  /// `canRerunFailedChecks` true. Reading the rollup again here, not a branch's latest run,
  /// keeps the target on the pull request head even when a newer run of another workflow
  /// passed.
  func rerunFailedChecks(_ pullRequest: PullRequestReference) async throws {
    let repo = GitHub.repoArgument(pullRequest.repository)
    let runIDs: [Int64]
    switch try await runExpecting(GhCommand.pullRequestCheckRollup(number: pullRequest.number, repo: repo)) {
    case .success(let data): runIDs = try GitHubJSONParsers.parseFailedWorkflowRunIDs(data)
    case .noResult: throw CodeHostError.notAPullRequest
    }
    guard !runIDs.isEmpty else {
      throw CodeHostError.other("no failed workflow run on pull request #\(pullRequest.number)")
    }
    for runID in runIDs {
      _ = try await runExpecting(GhCommand.runRerunFailed(runID: runID, repo: repo))
    }
  }

  // MARK: - web URLs

  func repositoryWebURL(_ repository: CodeHostRepository) -> URL? {
    URL(string: "https://\(GitHub.repoArgument(repository))")
  }

  func pullRequestWebURL(_ pullRequest: PullRequestReference) -> URL? {
    URL(string: "https://\(GitHub.repoArgument(pullRequest.repository))/pull/\(pullRequest.number)")
  }

  // MARK: - batched PR fetch

  func batchPullRequests(
    repository: CodeHostRepository, branches: [String]
  ) async throws -> [String: PullRequestSnapshot] {
    guard !branches.isEmpty else { return [:] }
    let host = repository.host
    let (owner, repo) = GitHub.ownerAndName(repository)
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
  /// decodes the response. Translates validator / decoder errors into `CodeHostError`.
  /// Uses an 8 MiB stdout cap (vs the 2 MiB per-PR cap) because a full batched response
  /// with rollup can hit 4–6 MiB on dense-CI PRs.
  private func fetchChunk(
    host: String,
    owner: String,
    repo: String,
    branches: [String]
  ) async throws -> [String: PullRequestSnapshot] {
    guard let exec = await resolver.resolve() else {
      throw CodeHostError.cliNotInstalled(.github)
    }
    let built: (query: String, aliasMap: [String: String])
    do {
      built = try BatchedPullRequestQuery.buildQuery(branches: branches)
    } catch BatchedPullRequestQuery.ValidationError.invalidBranchName(let name) {
      throw CodeHostError.malformedBranchName(name)
    } catch {
      throw CodeHostError.other("batched query build: \(error)")
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
      cwd: Self.homeDirectory,
      timeout: timeout,
      maxOutputBytes: chunkMaxBytes
    )
    switch outcome {
    case .exited(let code, let stdout, let stderr, let overflow):
      if overflow {
        throw CodeHostError.oversizeResponse(bytes: chunkMaxBytes)
      }
      if code == 0 {
        return try GitHubJSONParsers.parseBatchedPullRequests(
          stdout, aliasMap: built.aliasMap, remoteOwner: owner
        )
      }
      let stderrString = String(data: stderr, encoding: .utf8) ?? ""
      // `gh api` propagates a non-zero exit with the error body in stderr. GraphQL
      // schema errors (unknown fields, type mismatches) look like a shell-level failure
      // here; translateError catches the common auth / network / outdated patterns.
      throw Self.translateError(stderr: stderrString, host: host)
    case .timedOut:
      throw CodeHostError.timeout
    case .spawnFailed:
      throw CodeHostError.cliNotInstalled(.github)
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
    stderrOverride: ((String) -> CodeHostError?)? = nil
  ) async throws -> RunOutcome {
    guard let exec = await resolver.resolve() else {
      throw CodeHostError.cliNotInstalled(.github)
    }
    let outcome = await runner.run(
      executable: exec,
      arguments: command.arguments,
      env: Self.makeEnv(),
      cwd: Self.homeDirectory,
      timeout: timeout,
      maxOutputBytes: maxOutputBytes
    )
    switch outcome {
    case .exited(let code, let stdout, let stderr, let overflow):
      if overflow {
        throw CodeHostError.other("gh stdout exceeded \(maxOutputBytes) bytes")
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
      throw CodeHostError.timeout
    case .spawnFailed:
      throw CodeHostError.cliNotInstalled(.github)
    }
  }

  /// Every `gh` call runs here: commands address the repository with `--hostname` or
  /// `--repo`, so no working directory may leak a different repository into them.
  static var homeDirectory: URL { URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }

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

  /// Maps gh stderr into a rich `CodeHostError`. Order matters — more specific patterns
  /// first, catch-all last. `host` is the host the command addressed; a login error names
  /// it, so a Code Host alias whose API host is not logged in gets the message for that
  /// host (ADR 0005 item 4).
  nonisolated static func translateError(stderr: Any, host: String? = nil) -> CodeHostError {
    let text: String = {
      if let s = stderr as? String { return s }
      if let d = stderr as? Data { return String(data: d, encoding: .utf8) ?? "" }
      return String(describing: stderr)
    }().lowercased()

    // gh with no token for the host prints its login prompt ("gh auth login", exit 4);
    // a host it is not logged in to answers HTTP 401.
    if text.contains("not logged") || text.contains("auth required")
      || text.contains("authentication required") || text.contains("requires authentication")
      || text.contains("gh auth login") || text.contains("http 401") || text.contains("bad credentials")
      || text.contains("token")
        && text.contains("expired")
    {
      return .notAuthenticated(.github, host: host ?? Self.parseHostHint(text))
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
  nonisolated static func translateMergeError(stderr: String) -> CodeHostError? {
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
    // A host name has a dot ("github.com"); "to get started" must not give "get".
    return host.contains(".") ? host : nil
  }

  nonisolated static func firstLine(_ text: String) -> String {
    text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
      .first
      .map(String.init) ?? text
  }
}
