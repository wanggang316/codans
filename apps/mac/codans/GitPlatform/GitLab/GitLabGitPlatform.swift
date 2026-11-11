import CodansCore
import Foundation
import os

/// GitLab implementation of `GitPlatform`. Wraps `glab` via the shared `CommandRunner` and
/// routes every domain error through `GitPlatformError`, with the same subprocess contract
/// as `GitHubGitPlatform`: argv only, an env allowlist, a timeout, and an output cap.
///
/// Every call runs from the home directory and names its host explicitly
/// (`GlabCommand`), so `glab` never resolves a repository from a working directory.
///
/// Reads use `glab api graphql`; writes use `glab api` REST calls (merge, close, pipeline
/// retry) and one GraphQL mutation (mark ready). See ADR 0004 items 3 and 6–9.
nonisolated struct GitLabGitPlatform: GitPlatform {
  private static let logger = Logger(subsystem: "com.gumpw.codans.gitlab", category: "service")
  private static let defaultTimeout: Duration = .seconds(20)
  private static let defaultMaxOutputBytes: Int = 2 * 1024 * 1024
  /// Cap for one batched read: up to 100 merge requests with their jobs and diff stats.
  static let readMaxOutputBytes: Int = 8 * 1024 * 1024

  let runner: any CommandRunner
  let resolver: CLIExecutableResolver
  let timeout: Duration
  let maxOutputBytes: Int
  private let now: @Sendable () -> Date
  private let configHosts: @Sendable () -> [GlabConfig.Host]
  private let state: SharedState
  private let recheck: GitLabMergeStatusRecheck

  init(
    runner: any CommandRunner = FoundationCommandRunner(),
    resolver: CLIExecutableResolver = .glab,
    timeout: Duration = GitLabGitPlatform.defaultTimeout,
    maxOutputBytes: Int = GitLabGitPlatform.defaultMaxOutputBytes,
    now: @escaping @Sendable () -> Date = { Date() },
    configHosts: @escaping @Sendable () -> [GlabConfig.Host] = { GlabConfig.loggedInHosts() }
  ) {
    self.runner = runner
    self.resolver = resolver
    self.timeout = timeout
    self.maxOutputBytes = maxOutputBytes
    self.now = now
    self.configHosts = configHosts
    self.state = SharedState()
    self.recheck = GitLabMergeStatusRecheck()
  }

  // MARK: - availability

  /// Missing → not installed; older than `GitLab.minimumVersion` → outdated; no host
  /// logged in → not authenticated; otherwise the first logged-in host and its user.
  func availability() async -> GitPlatformAvailability {
    do {
      let exec = try await checkedExecutable()
      let hosts = try await authStatus(exec)
      guard let host = hosts.first(where: \.isLoggedIn) else {
        return .notLoggedIn(host: nil)
      }
      return .available(host: host.host, user: host.user ?? "")
    } catch {
      return Self.gitPlatformError(error).availability
    }
  }

  /// Hosts `glab` is logged in to, from its config file (`GlabConfig`): no network and no
  /// version gate, so an old or missing `glab` still lets a self-managed host resolve and
  /// show the actionable error. Also remembers each host's API protocol, so the web URLs
  /// of a self-managed `http` instance keep their scheme.
  func authenticatedHosts() async -> Set<String> {  // swiftlint:disable:this async_without_await
    let hosts = configHosts()
    for host in hosts {
      state.setAPIProtocol(host.apiProtocol, for: host.host)
    }
    return Set(hosts.map(\.host))
  }

  func invalidateExecutable() async {
    await resolver.invalidate()
  }

  // MARK: - batched read

  func batchPullRequests(
    repository: GitPlatformRepository, branches: [String]
  ) async throws -> [String: PullRequestSnapshot] {
    guard !branches.isEmpty else { return [:] }
    let exec = try await checkedExecutable()
    let chunks = GitLabMergeRequestQuery.chunk(branches)
    let maxConcurrent = GitLabMergeRequestQuery.maxConcurrentChunks
    let selected = try await withThrowingTaskGroup(of: [String: GitLabJSONParsers.MergeRequestNode].self) { group in
      var next = 0
      while next < min(maxConcurrent, chunks.count) {
        let chunk = chunks[next]
        group.addTask { [self] in try await fetchChunk(exec: exec, repository: repository, branches: chunk) }
        next += 1
      }
      var merged: [String: GitLabJSONParsers.MergeRequestNode] = [:]
      while let result = try await group.next() {
        merged.merge(result) { _, new in new }
        if next < chunks.count {
          let chunk = chunks[next]
          group.addTask { [self] in try await fetchChunk(exec: exec, repository: repository, branches: chunk) }
          next += 1
        }
      }
      return merged
    }
    recheckUnsettledMergeStatus(of: Array(selected.values), exec: exec, repository: repository)
    return selected.mapValues(GitLabJSONParsers.snapshot)
  }

  /// Asks GitLab to recheck open merge requests it left `UNCHECKED` (or `CHECKING` that
  /// does not settle), within the limits of `GitLabMergeStatusRecheck`.
  ///
  /// The read does not wait for the rechecks: its snapshots are already complete, and
  /// the next poll reads the result. The rechecks run concurrently in a task that each
  /// call's `timeout` bounds. Best effort: a failed recheck is logged only.
  private func recheckUnsettledMergeStatus(
    of nodes: [GitLabJSONParsers.MergeRequestNode], exec: URL, repository: GitPlatformRepository
  ) {
    // An iid is unique within the merge request's target project.
    let candidates = nodes.compactMap { node -> GitLabMergeStatusRecheck.Candidate? in
      guard node.state == "opened", let iid = node.iid.flatMap(Int.init) else { return nil }
      return .init(
        host: repository.host, projectPath: node.targetProject?.fullPath ?? repository.path, iid: iid,
        detailedMergeStatus: node.detailedMergeStatus)
    }
    .sorted { ($0.projectPath, $0.iid) < ($1.projectPath, $1.iid) }
    let claimed = recheck.claim(candidates, now: now())
    guard !claimed.isEmpty else { return }
    let task = Task { [self] in
      await withTaskGroup(of: Void.self) { group in
        for candidate in claimed {
          group.addTask { [self] in await recheckMergeStatus(candidate, exec: exec, kind: repository.kind) }
        }
      }
    }
    state.setPendingRecheck(task)
  }

  private func recheckMergeStatus(
    _ candidate: GitLabMergeStatusRecheck.Candidate, exec: URL, kind: GitPlatformKind
  ) async {
    let target = GitPlatformRepository(kind: kind, host: candidate.host, path: candidate.projectPath)
    do {
      _ = try await run(GlabCommand.mergeRequestRecheck(repository: target, iid: candidate.iid), exec: exec, host: target.host)
      Self.logger.info(
        "asked GitLab to recheck the merge status of \(target.path, privacy: .public)!\(candidate.iid, privacy: .public) (\(candidate.detailedMergeStatus ?? "nil", privacy: .public))"
      )
    } catch {
      Self.logger.error(
        "merge status recheck of \(target.path, privacy: .public)!\(candidate.iid, privacy: .public) failed: \(String(describing: error), privacy: .public)"
      )
    }
  }

  /// Waits for the rechecks the last batched read started. Tests use it to observe them.
  func waitForPendingRechecks() async {
    await state.pendingRecheck()?.value
  }

  private func fetchChunk(
    exec: URL, repository: GitPlatformRepository, branches: [String]
  ) async throws -> [String: GitLabJSONParsers.MergeRequestNode] {
    if let bad = branches.first(where: { $0.unicodeScalars.contains { $0.value < 0x20 } }) {
      throw GitPlatformError.malformedBranchName(bad)
    }
    var nodes: [GitLabJSONParsers.MergeRequestNode]
    do {
      nodes = try await readMergeRequests(
        query: GitLabMergeRequestQuery.query, degradable: true, exec: exec, repository: repository,
        branches: branches)
    } catch is OptionalFieldUnknown {
      if state.markDegraded(host: repository.host) {
        Self.logger.notice(
          "\(repository.host, privacy: .public) does not know a review or squash field; reading merge requests without them"
        )
      }
      nodes = try await readMergeRequests(
        query: GitLabMergeRequestQuery.degradedQuery, degradable: false, exec: exec, repository: repository,
        branches: branches)
    }
    for index in nodes.indices {
      nodes[index] = try await completingJobs(of: nodes[index], exec: exec, repository: repository)
      nodes[index] = try await completingReviewers(of: nodes[index], exec: exec, repository: repository)
    }
    return GitLabJSONParsers.selectedMergeRequests(from: nodes, branches: branches, projectPath: repository.path)
  }

  /// The batched query failed only because the instance does not know one of
  /// `GitLabMergeRequestQuery.optionalFieldNames`.
  private struct OptionalFieldUnknown: Error {}

  /// Every page of the merge requests for `branches`. Every page is read before any
  /// snapshot is built: a merge request on a later page can be the newest one of its
  /// branch, and a partial list must not drop a badge.
  ///
  /// With `degradable`, an `errors` body that only names unknown optional fields throws
  /// `OptionalFieldUnknown`, so the caller can read again with `degradedQuery`.
  private func readMergeRequests(
    query: String, degradable: Bool, exec: URL, repository: GitPlatformRepository, branches: [String]
  ) async throws -> [GitLabJSONParsers.MergeRequestNode] {
    var nodes: [GitLabJSONParsers.MergeRequestNode] = []
    var cursor: String?
    var pages = 0
    repeat {
      pages += 1
      guard pages <= GitLabMergeRequestQuery.maxPages else {
        throw GitPlatformError.other(
          "more than \(GitLabMergeRequestQuery.maxPages * GitLabMergeRequestQuery.pageSize) merge requests for \(branches.count) branches"
        )
      }
      var variables = ["fullPath": repository.path]
      if let cursor { variables["after"] = cursor }
      let cmd = GlabCommand.apiGraphQL(
        query: query,
        host: repository.host,
        stringVariables: variables,
        jsonVariables: ["branches": GitLabMergeRequestQuery.branchesVariable(branches)]
      )
      let data = try await run(
        cmd, exec: exec, host: repository.host, maxOutputBytes: Self.readMaxOutputBytes, returnsGraphQLErrors: true)
      if degradable, GitLabJSONParsers.isOptionalFieldError(data) { throw OptionalFieldUnknown() }
      let page = try GitLabJSONParsers.parseMergeRequestPage(data, host: repository.host)
      nodes += page.nodes
      cursor = page.nextCursor
    } while cursor != nil
    return nodes
  }

  /// The merge request with every job of its head pipeline. The batched read returns the
  /// first page of jobs; a pipeline with more reads the rest here, so a failed job on a
  /// later page still reaches the check rollup and "Rerun failed".
  private func completingJobs(
    of node: GitLabJSONParsers.MergeRequestNode, exec: URL, repository: GitPlatformRepository
  ) async throws -> GitLabJSONParsers.MergeRequestNode {
    guard var jobs = node.headPipeline?.jobs, var cursor = jobs.pageInfo?.hasNextPage == true ? jobs.pageInfo?.endCursor : nil,
      let iid = node.iid
    else { return node }
    var pages = 1
    while true {
      pages += 1
      guard pages <= GitLabMergeRequestQuery.maxPages else {
        throw GitPlatformError.other(
          "merge request !\(iid): more than \(GitLabMergeRequestQuery.maxPages * GitLabMergeRequestQuery.pageSize) pipeline jobs"
        )
      }
      let cmd = GlabCommand.apiGraphQL(
        query: GitLabMergeRequestQuery.jobsQuery,
        host: repository.host,
        stringVariables: ["fullPath": repository.path, "iid": iid, "after": cursor]
      )
      let data = try await run(cmd, exec: exec, host: repository.host, maxOutputBytes: Self.readMaxOutputBytes)
      let page = try GitLabJSONParsers.parseJobPage(data)
      jobs.nodes = (jobs.nodes ?? []) + page.nodes
      guard let next = page.nextCursor else { break }
      cursor = next
    }
    jobs.pageInfo = GitLabJSONParsers.PageInfo(hasNextPage: false, endCursor: nil)
    var completed = node
    completed.headPipeline?.jobs = jobs
    return completed
  }

  /// The merge request with every reviewer, read like `completingJobs`, so a requested
  /// change on a later page reaches the review decision. A list longer than `maxPages`
  /// pages, or a page without `nodes` or usable `pageInfo`, stays incomplete: it only
  /// withholds "approved", so it does not fail the read.
  private func completingReviewers(
    of node: GitLabJSONParsers.MergeRequestNode, exec: URL, repository: GitPlatformRepository
  ) async throws -> GitLabJSONParsers.MergeRequestNode {
    // A first page without `nodes` is unknown: later pages cannot make the list
    // complete, so it stays as decoded (incomplete).
    guard var reviewers = node.reviewers, var known = reviewers.nodes,
      var cursor = reviewers.pageInfo?.hasNextPage == true ? reviewers.pageInfo?.endCursor : nil,
      let iid = node.iid
    else { return node }
    var pages = 1
    while pages < GitLabMergeRequestQuery.maxPages {
      pages += 1
      let cmd = GlabCommand.apiGraphQL(
        query: GitLabMergeRequestQuery.reviewersQuery,
        host: repository.host,
        stringVariables: ["fullPath": repository.path, "iid": iid, "after": cursor]
      )
      let data = try await run(cmd, exec: exec, host: repository.host, maxOutputBytes: Self.readMaxOutputBytes)
      let page = try GitLabJSONParsers.parseReviewerPage(data)
      guard let pageNodes = page.nodes else {
        // The reviewers of this page are unknown: without `pageInfo` the list is incomplete.
        reviewers.pageInfo = nil
        break
      }
      known += pageNodes
      reviewers.nodes = known
      // `nil`, or a next page without a cursor, keeps the list incomplete.
      reviewers.pageInfo = page.pageInfo
      guard page.pageInfo?.hasNextPage == true, let next = page.pageInfo?.endCursor, !next.isEmpty else { break }
      cursor = next
    }
    var completed = node
    completed.reviewers = reviewers
    return completed
  }

  // MARK: - writes

  /// `mergeCommit` and `rebase` merge with the project's merge method; `squash` squashes.
  func merge(_ pullRequest: PullRequestReference, strategy: MergeStrategy, headSHA: String) async throws {
    let exec = try await checkedExecutable()
    let cmd = GlabCommand.mergeRequestMerge(
      repository: pullRequest.repository, iid: pullRequest.number, squash: strategy == .squash, sha: headSHA)
    _ = try await run(cmd, exec: exec, host: pullRequest.repository.host, isMerge: true)
  }

  func close(_ pullRequest: PullRequestReference) async throws {
    let exec = try await checkedExecutable()
    let cmd = GlabCommand.mergeRequestClose(repository: pullRequest.repository, iid: pullRequest.number)
    _ = try await run(cmd, exec: exec, host: pullRequest.repository.host)
  }

  func markReady(_ pullRequest: PullRequestReference) async throws {
    let exec = try await checkedExecutable()
    let cmd = GlabCommand.apiGraphQL(
      query: GlabCommand.markReadyMutation,
      host: pullRequest.repository.host,
      stringVariables: ["projectPath": pullRequest.repository.path, "iid": String(pullRequest.number)]
    )
    let data = try await run(cmd, exec: exec, host: pullRequest.repository.host)
    try GitLabJSONParsers.checkMarkReadyResponse(data)
  }

  /// Retries the merge request's head pipeline. GitLab reruns only its failed and
  /// canceled jobs (ADR 0004 item 7). The pipeline is read again here so the target is
  /// the current head pipeline, not the one the last fetch saw.
  func rerunFailedChecks(_ pullRequest: PullRequestReference) async throws {
    let exec = try await checkedExecutable()
    let repository = pullRequest.repository
    let view = try await run(
      GlabCommand.mergeRequestView(repository: repository, iid: pullRequest.number), exec: exec,
      host: repository.host)
    guard let pipelineID = try GitLabJSONParsers.parseHeadPipelineID(view) else {
      throw GitPlatformError.other("merge request !\(pullRequest.number) has no pipeline")
    }
    _ = try await run(
      GlabCommand.pipelineRetry(repository: repository, pipelineID: pipelineID), exec: exec,
      host: repository.host)
  }

  // MARK: - web URLs

  func repositoryWebURL(_ repository: GitPlatformRepository) -> URL? {
    URL(string: "\(webOrigin(repository.host))/\(repository.path)")
  }

  func pullRequestWebURL(_ pullRequest: PullRequestReference) -> URL? {
    URL(string: "\(webOrigin(pullRequest.repository.host))/\(pullRequest.repository.path)/-/merge_requests/\(pullRequest.number)")
  }

  /// `scheme://host` of the instance. The scheme is the API protocol `glab` reported for
  /// the host (a self-managed instance can serve plain `http`); `https` when unknown.
  private func webOrigin(_ host: String) -> String {
    "\(state.apiProtocol(for: host) ?? "https")://\(host)"
  }

  // MARK: - Private

  /// The `glab` executable, after the version gate. Throws `.cliNotInstalled` or
  /// `.cliOutdated`.
  private func checkedExecutable() async throws -> URL {
    guard let exec = await resolver.resolve() else { throw GitPlatformError.cliNotInstalled(.gitlab) }
    if let cached = state.version(for: exec) {
      return try gate(cached, exec: exec)
    }
    let data = try await run(GlabCommand.version(), exec: exec, host: nil)
    let version = GitLabJSONParsers.parseVersion(data)
    state.setVersion(version, for: exec)
    return try gate(version, exec: exec)
  }

  private func gate(_ version: String?, exec: URL) throws -> URL {
    guard let version, GitLab.isVersion(version, atLeast: GitLab.minimumVersion) else {
      throw GitPlatformError.cliOutdated(.gitlab, minVersion: GitLab.minimumVersion)
    }
    return exec
  }

  private func authStatus(_ exec: URL) async throws -> [GitLabJSONParsers.AuthHost] {
    let cmd = GlabCommand.authStatus()
    let outcome = await runner.run(
      executable: exec, arguments: cmd.arguments, env: Self.makeEnv(host: nil),
      cwd: Self.homeDirectory, timeout: timeout, maxOutputBytes: maxOutputBytes,
      launch: .loginShell)
    switch outcome {
    case .exited(let code, let stdout, let stderr, _) where cmd.expectedExitCodes.contains(code):
      let hosts: [GitLabJSONParsers.AuthHost]
      do {
        hosts = try GitLabJSONParsers.parseAuthStatus(stdout)
      } catch {
        throw Self.translateError(stderr: String(data: stderr, encoding: .utf8) ?? "")
      }
      for host in hosts {
        state.setAPIProtocol(host.apiProtocol, for: host.host)
      }
      return hosts
    case .exited(_, _, let stderr, _):
      throw Self.translateError(stderr: String(data: stderr, encoding: .utf8) ?? "")
    case .timedOut:
      throw GitPlatformError.timeout
    case .spawnFailed:
      throw GitPlatformError.cliNotInstalled(.gitlab)
    }
  }

  /// Runs one `glab` command and returns its stdout on exit 0. `host` names the
  /// instance for `GITLAB_HOST`; `nil` for host-independent commands. With
  /// `returnsGraphQLErrors`, a GraphQL `errors` body on a failed exit is also returned,
  /// so the caller can read every error in it.
  private func run(
    _ command: GlabCommand.Command,
    exec: URL,
    host: String?,
    maxOutputBytes: Int? = nil,
    isMerge: Bool = false,
    returnsGraphQLErrors: Bool = false
  ) async throws -> Data {
    let cap = maxOutputBytes ?? self.maxOutputBytes
    let outcome = await runner.run(
      executable: exec, arguments: command.arguments, env: Self.makeEnv(host: host),
      cwd: Self.homeDirectory, timeout: timeout, maxOutputBytes: cap,
      launch: .loginShell)
    switch outcome {
    case .exited(let code, let stdout, let stderr, let overflow):
      if overflow { throw GitPlatformError.oversizeResponse(bytes: cap) }
      if command.expectedExitCodes.contains(code) { return stdout }
      // `glab api` prints a GraphQL `errors` body or a REST error body on stdout and a
      // summary on stderr.
      if let message = GitLabJSONParsers.graphQLErrorMessage(stdout) {
        if returnsGraphQLErrors { return stdout }
        throw GitPlatformError.graphQLError(message)
      }
      let text = [String(data: stderr, encoding: .utf8), String(data: stdout, encoding: .utf8)]
        .compactMap { $0 }.joined(separator: "\n")
      if isMerge, let mergeError = Self.translateMergeError(stderr: text) { throw mergeError }
      Self.logger.error("glab exited \(code, privacy: .public): \(Self.firstLine(text), privacy: .public)")
      throw Self.translateError(stderr: text, host: host)
    case .timedOut:
      throw GitPlatformError.timeout
    case .spawnFailed:
      throw GitPlatformError.cliNotInstalled(.gitlab)
    }
  }

  private static func gitPlatformError(_ error: any Error) -> GitPlatformError {
    (error as? GitPlatformError) ?? .other(String(describing: error))
  }

  static var homeDirectory: URL { URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }

  /// Minimum env for a `glab` subprocess. `PATH` and `HOME` come from the parent, with
  /// the config-location variables (`GLAB_CONFIG_DIR`, `XDG_CONFIG_HOME`) so `glab`
  /// finds its own config and token store. Every other variable is stripped, including
  /// the token family (`GITLAB_TOKEN`, `GITLAB_ACCESS_TOKEN`, `OAUTH_TOKEN`) and any
  /// `GITLAB_HOST` / `GITLAB_REPO` the user set: codans sets `GITLAB_HOST` itself from
  /// the repository, because `glab --hostname` rejects `host:port`. Prompts, update
  /// checks, telemetry, and color are off so the output is stable.
  nonisolated static func makeEnv(
    host: String?, parent: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    var env: [String: String] = [
      "LC_ALL": "en_US.UTF-8",
      "NO_COLOR": "1",
      "GLAB_NO_PROMPT": "true",
      "GLAB_CHECK_UPDATE": "false",
      "GLAB_SEND_TELEMETRY": "false",
      "GLAB_SHOW_WHATS_NEW": "false",
    ]
    for key in ["PATH", "HOME", "GLAB_CONFIG_DIR", "XDG_CONFIG_HOME"] {
      if let value = parent[key] { env[key] = value }
    }
    if let host { env["GITLAB_HOST"] = host }
    return env
  }

  /// Maps `glab` output into a `GitPlatformError`. Specific patterns first.
  nonisolated static func translateError(stderr: String, host: String? = nil) -> GitPlatformError {
    let text = stderr.lowercased()
    if text.contains("401") || text.contains("unauthorized") || text.contains("not logged in")
      || text.contains("no token") || text.contains("authentication")
    {
      return .notAuthenticated(.gitlab, host: host)
    }
    if text.contains("429") || text.contains("rate limit") || text.contains("too many requests") {
      return .rateLimited(retryAfter: nil)
    }
    if text.contains("dial tcp") || text.contains("no such host") || text.contains("connection refused")
      || text.contains("i/o timeout") || text.contains("network is unreachable")
      || text.contains("tls:") || text.contains("could not resolve")
    {
      return .network(firstLine(text))
    }
    if text.isEmpty { return .other("glab exited non-zero with empty output") }
    return .other(firstLine(text))
  }

  /// A merge GitLab refuses (`405 Method Not Allowed`, `406`, `409`, "cannot be merged")
  /// is a merge conflict in the neutral model: the merge request cannot merge now. The
  /// `409` for a `sha` that is not the source branch head is checked first: it is
  /// `.headMoved`, not a conflict.
  nonisolated static func translateMergeError(stderr: String) -> GitPlatformError? {
    let text = stderr.lowercased()
    if text.contains("sha does not match head") { return .headMoved }
    if text.contains("405") || text.contains("406") || text.contains("409")
      || text.contains("cannot be merged") || text.contains("not mergeable") || text.contains("conflict")
    {
      return .mergeConflict
    }
    return nil
  }

  /// The first line with text, without `glab`'s padded `ERROR` banner.
  nonisolated static func firstLine(_ text: String) -> String {
    text.split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty && $0.lowercased() != "error" } ?? text
  }

  /// State the value-type implementation shares across copies: the `glab` version per
  /// executable (keyed by path and modification date, so an upgrade is seen), the API
  /// protocol per host, the merge status rechecks the last read started, and the hosts
  /// whose degraded read was already logged.
  private final class SharedState: @unchecked Sendable {
    private let lock = NSLock()
    private var versions: [String: String?] = [:]
    private var protocols: [String: String] = [:]
    private var recheckTask: Task<Void, Never>?
    private var degradedHosts: Set<String> = []

    /// `true` the first time `host` is marked.
    func markDegraded(host: String) -> Bool {
      lock.withLock { degradedHosts.insert(host.lowercased()).inserted }
    }

    func pendingRecheck() -> Task<Void, Never>? {
      lock.withLock { recheckTask }
    }

    func setPendingRecheck(_ task: Task<Void, Never>) {
      lock.withLock { recheckTask = task }
    }

    func version(for exec: URL) -> String?? {
      lock.withLock { versions[Self.key(exec)] }
    }

    func setVersion(_ version: String?, for exec: URL) {
      lock.withLock { versions[Self.key(exec)] = .some(version) }
    }

    func apiProtocol(for host: String) -> String? {
      lock.withLock { protocols[host.lowercased()] }
    }

    func setAPIProtocol(_ value: String?, for host: String) {
      guard let value, value == "http" || value == "https" else { return }
      lock.withLock { protocols[host.lowercased()] = value }
    }

    private static func key(_ exec: URL) -> String {
      let modified = (try? FileManager.default.attributesOfItem(atPath: exec.path)[.modificationDate] as? Date)
        .map { "\($0.timeIntervalSince1970)" } ?? ""
      return "\(exec.path)@\(modified)"
    }
  }
}
