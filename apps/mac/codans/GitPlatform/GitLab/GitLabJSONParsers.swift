import CodansCore
import Foundation

/// Decoders that translate raw `glab` stdout into the provider-neutral CodansCore model.
/// Each function is a pure mapping from `Data` → (value | throw `GitPlatformError`). Wire
/// enum values go through `GitLabWire`.
nonisolated enum GitLabJSONParsers {
  // MARK: - glab version

  /// The version in `glab version` output: `glab 1.128.0 (519ea19f7)` or
  /// `glab version 1.22.0 (2022-01-01)`. `nil` when no `x.y.z` token is present.
  static func parseVersion(_ data: Data) -> String? {
    let text = String(data: data, encoding: .utf8) ?? ""
    for token in text.split(whereSeparator: { $0.isWhitespace }) {
      let trimmed = token.hasPrefix("v") ? token.dropFirst() : token[...]
      let parts = trimmed.split(separator: ".")
      if parts.count >= 3, parts.prefix(3).allSatisfy({ Int($0) != nil }) {
        return String(trimmed)
      }
    }
    return nil
  }

  // MARK: - glab auth status --all --output json

  /// One host in `glab auth status --all --output json`.
  struct AuthHost: Equatable, Sendable {
    var host: String
    var user: String?
    var isLoggedIn: Bool
    /// `http` or `https`: how `glab` reaches the API, which is also how the web pages
    /// are served.
    var apiProtocol: String?
  }

  /// Every host in the auth status. A host with `state == "success"` and a user is
  /// logged in. Throws `.other` when the JSON does not decode.
  static func parseAuthStatus(_ data: Data) throws -> [AuthHost] {
    struct Wire: Decodable {
      var hosts: [Host]?
    }
    struct Host: Decodable {
      var host: String?
      var state: String?
      var user: String?
      var api_protocol: String?
    }
    let wire: Wire
    do {
      wire = try JSONDecoder().decode(Wire.self, from: data)
    } catch {
      throw GitPlatformError.other("glab auth status decode: \(error)")
    }
    return (wire.hosts ?? []).compactMap { entry in
      guard let host = entry.host, !host.isEmpty else { return nil }
      let user = entry.user.flatMap { $0.isEmpty ? nil : $0 }
      return AuthHost(
        host: host, user: user, isLoggedIn: entry.state == "success" && user != nil,
        apiProtocol: entry.api_protocol)
    }
  }

  // MARK: - glab api graphql (batched read)

  /// One page of a GraphQL connection: its nodes and where the next page starts.
  struct Page<Node: Sendable>: Sendable {
    var nodes: [Node]
    /// `endCursor` of this page when GitLab has another page; `nil` on the last page.
    var nextCursor: String?
  }

  /// Parses one page of the batched merge request read (`GitLabMergeRequestQuery.query`).
  ///
  /// Throws `.graphQLError` for an `errors` body, `.notAuthenticated` when GitLab
  /// answered anonymously (`currentUser == null`), and `.other` on a decode failure or
  /// a connection without `pageInfo` (the read could not tell whether it is complete).
  /// A project the user cannot see (`project == null`) has no merge requests.
  static func parseMergeRequestPage(_ data: Data, host: String) throws -> Page<MergeRequestNode> {
    let envelope = try decode(Envelope.self, from: data, what: "batched merge request")
    if let message = envelope.errors?.first?.message {
      throw GitPlatformError.graphQLError(message)
    }
    guard let payload = envelope.data else { throw GitPlatformError.other("batched merge request: no data") }
    guard payload.currentUser != nil else {
      throw GitPlatformError.notAuthenticated(.gitlab, host: host)
    }
    guard let connection = payload.project?.mergeRequests else { return Page(nodes: [], nextCursor: nil) }
    for node in connection.nodes ?? [] where node.headPipeline?.jobs != nil {
      _ = try nextCursor(of: node.headPipeline?.jobs, what: "pipeline jobs")
    }
    return Page(nodes: connection.nodes ?? [], nextCursor: try nextCursor(of: connection, what: "merge requests"))
  }

  /// Parses one page of `GitLabMergeRequestQuery.jobsQuery`.
  static func parseJobPage(_ data: Data) throws -> Page<Job> {
    struct Wire: Decodable {
      struct MergeRequest: Decodable { var headPipeline: Pipeline? }
      struct Project: Decodable { var mergeRequest: MergeRequest? }
      struct Payload: Decodable { var project: Project? }
      var data: Payload?
      var errors: [ErrorEntry]?
    }
    let wire = try decode(Wire.self, from: data, what: "pipeline jobs")
    if let message = wire.errors?.first?.message { throw GitPlatformError.graphQLError(message) }
    guard let jobs = wire.data?.project?.mergeRequest?.headPipeline?.jobs else {
      throw GitPlatformError.other("pipeline jobs: no job list in the response")
    }
    return Page(nodes: jobs.nodes ?? [], nextCursor: try nextCursor(of: jobs, what: "pipeline jobs"))
  }

  /// Parses one page of `GitLabMergeRequestQuery.reviewersQuery`. The connection keeps
  /// its `pageInfo` as sent: a page without it leaves the reviewer list incomplete, which
  /// withholds "approved" but does not fail the read.
  static func parseReviewerPage(_ data: Data) throws -> Connection<Reviewer> {
    struct Wire: Decodable {
      struct MergeRequest: Decodable { var reviewers: Connection<Reviewer>? }
      struct Project: Decodable { var mergeRequest: MergeRequest? }
      struct Payload: Decodable { var project: Project? }
      var data: Payload?
      var errors: [ErrorEntry]?
    }
    let wire = try decode(Wire.self, from: data, what: "reviewers")
    if let message = wire.errors?.first?.message { throw GitPlatformError.graphQLError(message) }
    guard let reviewers = wire.data?.project?.mergeRequest?.reviewers else {
      throw GitPlatformError.other("reviewers: no reviewer list in the response")
    }
    return reviewers
  }

  /// `true` when `data` is a GraphQL `errors` body and every error is an unknown field
  /// from `GitLabMergeRequestQuery.optionalFieldNames`. GitLab reports an unknown field
  /// with `extensions.code == "undefinedField"` and the message
  /// `Field 'x' doesn't exist on type 'T'`; either one identifies it.
  static func isOptionalFieldError(_ data: Data) -> Bool {
    struct Wire: Decodable { var errors: [ErrorEntry]? }
    guard let errors = (try? JSONDecoder().decode(Wire.self, from: data))?.errors, !errors.isEmpty else {
      return false
    }
    return errors.allSatisfy { error in
      guard let field = error.undefinedFieldName else { return false }
      return GitLabMergeRequestQuery.optionalFieldNames.contains(field)
    }
  }

  /// `[branch: snapshot]` for every branch in `branches` that has a merge request
  /// after the fork filter. `nodes` must be the complete list for these branches.
  ///
  /// - `projectPath`: full path of the fetch unit's project; the fork filter prefers
  ///   merge requests whose source project is this project.
  static func snapshots(
    from nodes: [MergeRequestNode], branches: [String], projectPath: String
  ) -> [String: PullRequestSnapshot] {
    selectedMergeRequests(from: nodes, branches: branches, projectPath: projectPath).mapValues(snapshot)
  }

  /// `[branch: merge request]` that `snapshots` shows, before the mapping to snapshots.
  static func selectedMergeRequests(
    from nodes: [MergeRequestNode], branches: [String], projectPath: String
  ) -> [String: MergeRequestNode] {
    var result: [String: MergeRequestNode] = [:]
    for branch in branches {
      let candidates = nodes.filter { $0.sourceBranch == branch }
      if let pick = selectMergeRequest(from: candidates, projectPath: projectPath) {
        result[branch] = pick
      }
    }
    return result
  }

  private static func nextCursor<Node>(of connection: Connection<Node>?, what: String) throws -> String? {
    guard let pageInfo = connection?.pageInfo, let hasNextPage = pageInfo.hasNextPage else {
      throw GitPlatformError.other("\(what): response has no pageInfo")
    }
    guard hasNextPage else { return nil }
    guard let cursor = pageInfo.endCursor, !cursor.isEmpty else {
      throw GitPlatformError.other("\(what): next page without endCursor")
    }
    return cursor
  }

  private static func decode<T: Decodable>(_ type: T.Type, from data: Data, what: String) throws -> T {
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
      return try decoder.decode(type, from: data)
    } catch {
      throw GitPlatformError.other("\(what) decode: \(error)")
    }
  }

  /// The GitHub fork filter with the source project path in place of the head
  /// repository owner (ADR 0004 item 9):
  /// 1. Prefer merge requests from the fetch unit's own project.
  /// 2. Otherwise keep those whose target branch differs from the source branch.
  /// Among the survivors, an open or merged merge request wins over a closed one (the
  /// GitHub read skips closed pull requests; a GitLab branch shows its closed merge
  /// request only when it has nothing newer). The input is newest first.
  private static func selectMergeRequest(from nodes: [MergeRequestNode], projectPath: String) -> MergeRequestNode? {
    let own = nodes.filter { $0.sourceProject?.fullPath?.lowercased() == projectPath.lowercased() }
    let survivors = own.isEmpty ? nodes.filter { $0.targetBranch != nil && $0.targetBranch != $0.sourceBranch } : own
    return survivors.first { $0.state != "closed" } ?? survivors.first
  }

  static func snapshot(_ node: MergeRequestNode) -> PullRequestSnapshot {
    let webURL = node.webUrl.flatMap(URL.init(string:))
    let jobs = node.headPipeline?.jobs?.nodes ?? []
    let wireJobs = jobs.map {
      GitLabWire.Job(
        name: $0.name ?? "", status: $0.status, allowFailure: $0.allowFailure ?? false,
        manualJob: $0.manualJob ?? false)
    }
    let checks = zip(jobs, wireJobs).compactMap { job, wire -> CheckResult? in
      guard !wire.name.isEmpty else { return nil }
      let (status, conclusion) = GitLabWire.check(wire)
      let duration: Int? = {
        guard let start = job.startedAt, let end = job.finishedAt else { return nil }
        let seconds = Int(end.timeIntervalSince(start))
        return seconds >= 0 ? seconds : nil
      }()
      return CheckResult(
        name: wire.name, status: status, conclusion: conclusion,
        detailsURL: job.webPath.flatMap { webPageURL(path: $0, relativeTo: webURL) },
        startedAt: job.startedAt, completedAt: job.finishedAt, durationSeconds: duration)
    }
    let mergeState = GitLabWire.mergeState(detailedMergeStatus: node.detailedMergeStatus)
    let diffStats = node.diffStats ?? []
    return PullRequestSnapshot(
      number: Int(node.iid ?? "") ?? 0,
      title: node.title ?? "",
      state: GitLabWire.pullRequestState(node.state) ?? .open,
      isDraft: node.draft ?? false,
      headRefName: node.sourceBranch ?? "",
      author: node.author?.username ?? "",
      additions: diffStats.reduce(0) { $0 + ($1.additions ?? 0) },
      deletions: diffStats.reduce(0) { $0 + ($1.deletions ?? 0) },
      commitCount: node.commitCount ?? 0,
      url: webURL ?? URL(string: "about:blank")!,
      updatedAt: node.updatedAt ?? Date(timeIntervalSince1970: 0),
      checkRollup: checks,
      mergeState: mergeState,
      mergeOptions: GitLabWire.mergeOptions(
        mergeState: mergeState, squashReadOnly: node.squashReadOnly ?? false,
        squashOnMerge: node.squashOnMerge ?? false),
      canRerunFailedChecks: GitLabWire.canRetryPipeline(wireJobs),
      reviewDecision: reviewDecision(node),
      headRepositoryOwner: node.sourceProject?.fullPath ?? "",
      baseRefName: node.targetBranch,
      baseRepositoryURL: node.targetProject?.webUrl.flatMap(URL.init(string:))
    )
  }

  /// `nil` when the read had no review fields (`GitLabMergeRequestQuery.degradedQuery`).
  /// The reviewer list is complete only when its last page was read.
  private static func reviewDecision(_ node: MergeRequestNode) -> ReviewDecision? {
    guard let reviewers = node.reviewers else { return nil }
    return GitLabWire.reviewDecision(
      detailedMergeStatus: node.detailedMergeStatus, approved: node.approved ?? false,
      approverCount: node.approvedBy?.nodes?.count ?? 0,
      reviewerStates: (reviewers.nodes ?? []).map { $0.mergeRequestInteraction?.reviewState },
      reviewersComplete: reviewers.nodes != nil && reviewers.pageInfo?.hasNextPage == false)
  }

  /// A job's `webPath` (`/group/app/-/jobs/25`) on the instance that serves the merge
  /// request, so a self-managed host keeps its scheme and port.
  private static func webPageURL(path: String, relativeTo base: URL?) -> URL? {
    guard let base, var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
      return nil
    }
    components.path = path
    components.query = nil
    components.fragment = nil
    return components.url
  }

  // MARK: - writes

  /// `head_pipeline.id` of `glab api projects/<id>/merge_requests/<iid>`. `nil` when the
  /// merge request has no pipeline.
  static func parseHeadPipelineID(_ data: Data) throws -> Int64? {
    struct Wire: Decodable {
      struct Pipeline: Decodable { var id: Int64? }
      var head_pipeline: Pipeline?
    }
    do {
      return try JSONDecoder().decode(Wire.self, from: data).head_pipeline?.id
    } catch {
      throw GitPlatformError.other("merge request decode: \(error)")
    }
  }

  /// Succeeds only when the mark-ready mutation returned its payload with no errors and
  /// the merge request is no longer a draft. Anything else (an `errors` body, a null or
  /// partial payload) throws, so the UI never reports a success GitLab did not confirm.
  static func checkMarkReadyResponse(_ data: Data) throws {
    struct MergeRequest: Decodable { var draft: Bool? }
    struct Mutation: Decodable {
      var errors: [String]?
      var mergeRequest: MergeRequest?
    }
    struct Payload: Decodable { var mergeRequestSetDraft: Mutation? }
    struct Wire: Decodable {
      var data: Payload?
      var errors: [ErrorEntry]?
    }
    let wire = try decode(Wire.self, from: data, what: "mark ready")
    if let message = wire.errors?.first?.message { throw GitPlatformError.graphQLError(message) }
    guard let mutation = wire.data?.mergeRequestSetDraft, let errors = mutation.errors else {
      throw GitPlatformError.other("mark ready: GitLab returned no mutation result")
    }
    if let message = errors.first { throw GitPlatformError.other(message) }
    guard mutation.mergeRequest?.draft == false else {
      throw GitPlatformError.other("mark ready: the merge request is still a draft")
    }
  }

  /// The first `errors[].message` of a GraphQL body, or `nil` when `data` is not one.
  /// `glab api graphql` exits 1 for such a body and prints it on stdout.
  static func graphQLErrorMessage(_ data: Data) -> String? {
    struct Wire: Decodable { var errors: [ErrorEntry]? }
    return (try? JSONDecoder().decode(Wire.self, from: data))?.errors?.first?.message
  }

  // MARK: - Wire types

  private struct ErrorEntry: Decodable {
    struct Extensions: Decodable {
      var code: String?
      var fieldName: String?
    }
    var message: String?
    var extensions: Extensions?

    /// The field name of an unknown-field error, else `nil`.
    var undefinedFieldName: String? {
      if extensions?.code == "undefinedField", let name = extensions?.fieldName { return name }
      guard let message, let match = message.firstMatch(of: #/^Field '(\w+)' doesn't exist on type/#) else {
        return nil
      }
      return String(match.1)
    }
  }

  struct PageInfo: Decodable, Sendable {
    var hasNextPage: Bool?
    var endCursor: String?
  }

  private struct Envelope: Decodable {
    var data: Payload?
    var errors: [ErrorEntry]?
  }

  private struct Payload: Decodable {
    var currentUser: User?
    var project: Project?
  }

  struct User: Decodable, Sendable { var username: String? }

  private struct Project: Decodable {
    var mergeRequests: Connection<MergeRequestNode>?
  }

  struct Connection<Node: Decodable & Sendable>: Decodable, Sendable {
    var pageInfo: PageInfo?
    var nodes: [Node]?
  }

  /// One merge request as the batched read decodes it. Only this file reads its fields.
  struct MergeRequestNode: Decodable, Sendable {
    var iid: String?
    var title: String?
    var state: String?
    var draft: Bool?
    var sourceBranch: String?
    var targetBranch: String?
    var webUrl: String?
    var updatedAt: Date?
    var detailedMergeStatus: String?
    var squashReadOnly: Bool?
    var squashOnMerge: Bool?
    var approved: Bool?
    var approvedBy: Connection<User>?
    var reviewers: Connection<Reviewer>?
    var diffStats: [DiffStat]?
    var commitCount: Int?
    var author: User?
    var sourceProject: ProjectPath?
    var targetProject: ProjectPath?
    var headPipeline: Pipeline?
  }

  struct Reviewer: Decodable, Sendable {
    struct Interaction: Decodable, Sendable { var reviewState: String? }
    var mergeRequestInteraction: Interaction?
  }

  struct DiffStat: Decodable, Sendable {
    var additions: Int?
    var deletions: Int?
  }

  struct ProjectPath: Decodable, Sendable {
    var fullPath: String?
    var webUrl: String?
  }

  struct Pipeline: Decodable, Sendable {
    var status: String?
    var jobs: Connection<Job>?
  }

  struct Job: Decodable, Sendable {
    var name: String?
    var status: String?
    var allowFailure: Bool?
    var manualJob: Bool?
    var startedAt: Date?
    var finishedAt: Date?
    var webPath: String?
  }
}
