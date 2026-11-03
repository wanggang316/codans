import CodansCore
import Foundation

/// Decoders that translate raw `glab` stdout into the provider-neutral CodansCore model.
/// Each function is a pure mapping from `Data` → (value | throw `CodeHostError`). Wire
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
      throw CodeHostError.other("glab auth status decode: \(error)")
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

  /// Parses one chunk's response. Returns `[branch: snapshot]` for every branch in
  /// `branches` that has a merge request after the fork filter.
  ///
  /// - `projectPath`: full path of the fetch unit's project; the fork filter prefers
  ///   merge requests whose source project is this project.
  ///
  /// Throws `.graphQLError` for an `errors` body, `.notAuthenticated` when GitLab
  /// answered anonymously (`currentUser == null`), `.other` on a decode failure. A
  /// project the user cannot see (`project == null`) has no merge requests.
  static func parseBatchedMergeRequests(
    _ data: Data, branches: [String], projectPath: String, host: String
  ) throws -> [String: PullRequestSnapshot] {
    let envelope: Envelope
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
      envelope = try decoder.decode(Envelope.self, from: data)
    } catch {
      throw CodeHostError.other("batched merge request decode: \(error)")
    }
    if let message = envelope.errors?.first?.message {
      throw CodeHostError.graphQLError(message)
    }
    guard let payload = envelope.data else { return [:] }
    guard payload.currentUser != nil else {
      throw CodeHostError.notAuthenticated(.gitlab, host: host)
    }
    let nodes = payload.project?.mergeRequests?.nodes ?? []
    var result: [String: PullRequestSnapshot] = [:]
    for branch in branches {
      let candidates = nodes.filter { $0.sourceBranch == branch }
      if let pick = selectMergeRequest(from: candidates, projectPath: projectPath) {
        result[branch] = snapshot(pick)
      }
    }
    return result
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

  private static func snapshot(_ node: MergeRequestNode) -> PullRequestSnapshot {
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
      reviewDecision: GitLabWire.reviewDecision(
        detailedMergeStatus: node.detailedMergeStatus, approved: node.approved ?? false,
        approverCount: node.approvedBy?.nodes?.count ?? 0,
        reviewerStates: (node.reviewers?.nodes ?? []).compactMap { $0.mergeRequestInteraction?.reviewState }),
      headRepositoryOwner: node.sourceProject?.fullPath ?? "",
      baseRefName: node.targetBranch,
      baseRepositoryURL: node.targetProject?.webUrl.flatMap(URL.init(string:))
    )
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
      throw CodeHostError.other("merge request decode: \(error)")
    }
  }

  /// Throws when the mark-ready mutation reports an error (top-level or in the payload).
  static func checkMarkReadyResponse(_ data: Data) throws {
    struct Mutation: Decodable { var errors: [String]? }
    struct Payload: Decodable { var mergeRequestSetDraft: Mutation? }
    struct Wire: Decodable {
      var data: Payload?
      var errors: [ErrorEntry]?
    }
    let wire: Wire
    do {
      wire = try JSONDecoder().decode(Wire.self, from: data)
    } catch {
      throw CodeHostError.other("mark ready decode: \(error)")
    }
    if let message = wire.errors?.first?.message { throw CodeHostError.graphQLError(message) }
    if let message = wire.data?.mergeRequestSetDraft?.errors?.first { throw CodeHostError.other(message) }
  }

  /// The first `errors[].message` of a GraphQL body, or `nil` when `data` is not one.
  /// `glab api graphql` exits 1 for such a body and prints it on stdout.
  static func graphQLErrorMessage(_ data: Data) -> String? {
    struct Wire: Decodable { var errors: [ErrorEntry]? }
    return (try? JSONDecoder().decode(Wire.self, from: data))?.errors?.first?.message
  }

  // MARK: - Wire types

  private struct ErrorEntry: Decodable { var message: String? }

  private struct Envelope: Decodable {
    var data: Payload?
    var errors: [ErrorEntry]?
  }

  private struct Payload: Decodable {
    var currentUser: User?
    var project: Project?
  }

  private struct User: Decodable { var username: String? }

  private struct Project: Decodable {
    var mergeRequests: Connection<MergeRequestNode>?
  }

  private struct Connection<Node: Decodable>: Decodable { var nodes: [Node]? }

  private struct MergeRequestNode: Decodable {
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

  private struct Reviewer: Decodable {
    struct Interaction: Decodable { var reviewState: String? }
    var mergeRequestInteraction: Interaction?
  }

  private struct DiffStat: Decodable {
    var additions: Int?
    var deletions: Int?
  }

  private struct ProjectPath: Decodable {
    var fullPath: String?
    var webUrl: String?
  }

  private struct Pipeline: Decodable {
    var status: String?
    var jobs: Connection<Job>?
  }

  private struct Job: Decodable {
    var name: String?
    var status: String?
    var allowFailure: Bool?
    var manualJob: Bool?
    var startedAt: Date?
    var finishedAt: Date?
    var webPath: String?
  }
}
