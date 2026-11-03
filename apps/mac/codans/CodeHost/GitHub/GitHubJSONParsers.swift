import CodansCore
import Foundation

/// Decoders that translate raw `gh` stdout bytes into the provider-neutral CodansCore
/// model. Each function is a pure mapping from `Data` → (value | `nil` | throw
/// `CodeHostError`). Wire enum values go through `GitHubWire`.
///
/// Why a dedicated translation layer rather than relying on the DTOs' built-in Codable:
///
/// - `gh pr view` returns `author` as a nested object (`{login, name, is_bot}`) — the DTO
///   carries a flat `author: String` login.
/// - `gh pr view` returns `commits` as an array of commit objects — the DTO carries a flat
///   `commitCount: Int`.
/// - `gh pr checks` returns a single `state` field that conflates status + conclusion
///   (`SUCCESS` / `FAILURE` / `PENDING` / `SKIPPING`) — the DTO carries a split
///   `status: CheckStatus` + `conclusion: CheckConclusion?` pair.
///
/// Keeping the translation here keeps the CodansCore model free of GitHub wire values.
nonisolated enum GitHubJSONParsers {
  // MARK: - gh auth status

  struct AuthStatusResult: Equatable, Sendable {
    var host: String
    var user: String
  }

  /// Parses `gh auth status --json hosts`. Returns nil when no host is logged in.
  ///
  /// Handles both wire shapes gh has used:
  ///   - **New (≥ gh 2.40)**: `hosts.<host>` is an array of account entries (multi-account).
  ///     Each entry has `login`, `active` (bool), plus metadata. We prefer the `active`
  ///     entry, falling back to the first entry with a non-empty `login`.
  ///   - **Old (< gh 2.40)**: `hosts.<host>` is a flat object with `user` / `active_user`
  ///     fields for a single account.
  /// Tries the new shape first, falls back to the old shape if that fails — lets the app
  /// keep working across a gh upgrade without a code change.
  static func parseAuthStatus(_ data: Data) throws -> AuthStatusResult? {
    if let result = try? decodeAuthStatusArrayForm(data) {
      return result
    }
    do {
      return try decodeAuthStatusDictForm(data)
    } catch {
      throw CodeHostError.other("auth status decode: \(error)")
    }
  }

  /// Every host in `gh auth status --json hosts` with a logged-in account. Handles both
  /// wire shapes `parseAuthStatus` handles. Returns `[]` on any decode failure.
  static func parseAuthenticatedHosts(_ data: Data) -> Set<String> {
    struct ArrayWire: Decodable {
      var hosts: [String: [Account]]?
    }
    struct Account: Decodable {
      var login: String?
      var user: String?
    }
    struct DictWire: Decodable {
      var hosts: [String: HostEntry]?
    }
    struct HostEntry: Decodable {
      var user: String?
      var active_user: String?
    }
    if let wire = try? JSONDecoder().decode(ArrayWire.self, from: data), let hosts = wire.hosts {
      return Set(
        hosts.filter { _, accounts in
          accounts.contains { !(($0.login ?? $0.user) ?? "").isEmpty }
        }.keys)
    }
    if let wire = try? JSONDecoder().decode(DictWire.self, from: data), let hosts = wire.hosts {
      return Set(hosts.filter { !(($0.value.user ?? $0.value.active_user) ?? "").isEmpty }.keys)
    }
    return []
  }

  /// Multi-account shape (gh 2.40+).
  private static func decodeAuthStatusArrayForm(_ data: Data) throws -> AuthStatusResult? {
    struct Wire: Decodable {
      var hosts: [String: [Account]]?
    }
    struct Account: Decodable {
      var login: String?
      var user: String?
      var active: Bool?
    }
    let wire = try JSONDecoder().decode(Wire.self, from: data)
    guard let hosts = wire.hosts else { return nil }
    for (host, accounts) in hosts {
      let active = accounts.first(where: { $0.active == true })
      let any = accounts.first(where: { !(($0.login ?? $0.user) ?? "").isEmpty })
      let pick = active ?? any
      if let user = (pick?.login ?? pick?.user), !user.isEmpty {
        return AuthStatusResult(host: host, user: user)
      }
    }
    return nil
  }

  /// Single-account shape (pre-gh 2.40). Retained for backward compatibility.
  private static func decodeAuthStatusDictForm(_ data: Data) throws -> AuthStatusResult? {
    struct Wire: Decodable {
      var hosts: [String: HostEntry]?
    }
    struct HostEntry: Decodable {
      var user: String?
      var active_user: String?
    }
    let wire = try JSONDecoder().decode(Wire.self, from: data)
    guard let hosts = wire.hosts else { return nil }
    for (host, entry) in hosts {
      if let user = (entry.user ?? entry.active_user), !user.isEmpty {
        return AuthStatusResult(host: host, user: user)
      }
    }
    return nil
  }

  /// Maps `gh pr checks`' collapsed `state` to the split status + conclusion pair. Unknown
  /// tokens fall through to `.inProgress` with no conclusion so the UI shows "pending" —
  /// better than failing the whole check list on a single unrecognised value.
  static func splitCheckState(_ state: String) -> (CheckStatus, CheckConclusion?) {
    switch state.uppercased() {
    case "SUCCESS": return (.completed, .success)
    case "FAILURE", "FAILED": return (.completed, .failure)
    case "CANCELLED", "CANCELED": return (.completed, .cancelled)
    case "SKIPPED", "SKIPPING": return (.completed, .skipped)
    case "NEUTRAL": return (.completed, .neutral)
    case "TIMED_OUT", "TIMEOUT": return (.completed, .timedOut)
    case "ACTION_REQUIRED": return (.completed, .actionRequired)
    case "PENDING", "QUEUED": return (.queued, nil)
    case "IN_PROGRESS": return (.inProgress, nil)
    case "WAITING": return (.waiting, nil)
    default: return (.inProgress, nil)
    }
  }

  // MARK: - gh pr view --json statusCheckRollup

  /// Parses `gh pr view --json statusCheckRollup` into the Actions run ids
  /// `GitHubWire.failedWorkflowRunIDs` selects.
  static func parseFailedWorkflowRunIDs(_ data: Data) throws -> [Int64] {
    struct Wire: Decodable {
      var statusCheckRollup: [Check]?
    }
    struct Check: Decodable {
      var __typename: String?
      var conclusion: String?
      var detailsUrl: String?
    }
    let wire: Wire
    do {
      wire = try JSONDecoder().decode(Wire.self, from: data)
    } catch {
      throw CodeHostError.other("pr view decode: \(error)")
    }
    return GitHubWire.failedWorkflowRunIDs(
      (wire.statusCheckRollup ?? []).map {
        GitHubWire.RollupCheck(
          isCheckRun: $0.__typename == "CheckRun", conclusion: $0.conclusion, detailsURL: $0.detailsUrl)
      })
  }

  // MARK: - gh api graphql (batched PR fetch)

  /// Parses one chunk's GraphQL response body. Input: the raw stdout from
  /// `gh api graphql ... -f query=<batched>`. Output: `[branch: snapshot]` for every
  /// branch in `aliasMap` that had a surviving PR after fork-PR filtering. Branches with
  /// no matching PR are absent.
  ///
  /// - `aliasMap`: `[alias: originalBranch]` built by `BatchedPullRequestQuery.buildQuery`.
  /// - `remoteOwner`: `login` of the repository at the project's `origin`. Used by the
  ///   fork-PR filter.
  ///
  /// Throws `.graphQLError` when the response carries a top-level `"errors": [...]`.
  /// Throws `.other` on decode failure.
  static func parseBatchedPullRequests(
    _ data: Data,
    aliasMap: [String: String],
    remoteOwner: String
  ) throws -> [String: PullRequestSnapshot] {
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
      let wire = try decoder.decode(GraphQLEnvelope.self, from: data)
      if let errors = wire.errors, let first = errors.first {
        throw CodeHostError.graphQLError(first.message ?? "unknown GraphQL error")
      }
      guard let repo = wire.data?.repository else { return [:] }
      var result: [String: PullRequestSnapshot] = [:]
      for (alias, branch) in aliasMap {
        guard let connection = repo.pullRequestsByAlias[alias] else { continue }
        let pick = selectPullRequest(
          from: connection.nodes ?? [],
          remoteOwner: remoteOwner
        )
        if let pick {
          result[branch] = convertToSnapshot(pick)
        }
      }
      return result
    } catch let error as CodeHostError {
      throw error
    } catch {
      throw CodeHostError.other("batched pr decode: \(error)")
    }
  }

  /// Fork-PR filter. Per design doc's three-rule algorithm:
  /// 1. Prefer entries where `headRepository.owner.login == remoteOwner` (upstream PRs).
  /// 2. If none, keep entries where `baseRefName != headRefName` (local branch is source).
  /// 3. Pick the first survivor (server-side sort is UPDATED_AT DESC).
  private static func selectPullRequest(
    from nodes: [GraphQLPRNode],
    remoteOwner: String
  ) -> GraphQLPRNode? {
    let upstream = nodes.filter { node in
      guard let ownerLogin = node.headRepository?.owner?.login else { return false }
      return ownerLogin == remoteOwner
    }
    if let first = upstream.first { return first }
    let forkDistinct = nodes.filter { node in
      guard let base = node.baseRefName, let head = node.headRefName else { return false }
      return base != head
    }
    return forkDistinct.first
  }

  /// Projects the GraphQL node into the neutral snapshot. Missing required fields are
  /// filled with safe defaults — one malformed PR should not fail the whole chunk.
  private static func convertToSnapshot(_ node: GraphQLPRNode) -> PullRequestSnapshot {
    let checkNodes = node.statusCheckRollup?.contexts?.nodes ?? []
    let checks = checkNodes.compactMap(convertCheckNode)
    let mergeState = GitHubWire.mergeState(
      mergeable: node.mergeable, mergeStateStatus: node.mergeStateStatus)
    // Same predicate `GitHubCodeHost.rerunFailedChecks` uses to pick its targets. A
    // CheckRun is the union member that carries `status`.
    let canRerunFailedChecks = !GitHubWire.failedWorkflowRunIDs(
      checkNodes.map {
        GitHubWire.RollupCheck(isCheckRun: $0.status != nil, conclusion: $0.conclusion, detailsURL: $0.detailsUrl)
      }
    ).isEmpty
    return PullRequestSnapshot(
      number: node.number ?? 0,
      title: node.title ?? "",
      state: GitHubWire.pullRequestState(node.state) ?? .open,
      isDraft: node.isDraft ?? false,
      headRefName: node.headRefName ?? "",
      author: node.author?.login ?? "",
      additions: node.additions ?? 0,
      deletions: node.deletions ?? 0,
      commitCount: node.commits?.totalCount ?? 0,
      url: URL(string: node.url ?? "about:blank") ?? URL(string: "about:blank")!,
      updatedAt: node.updatedAt ?? Date(timeIntervalSince1970: 0),
      checkRollup: checks,
      mergeState: mergeState,
      mergeOptions: GitHubWire.mergeOptions(mergeable: node.mergeable, mergeState: mergeState),
      canRerunFailedChecks: canRerunFailedChecks,
      reviewDecision: GitHubWire.reviewDecision(node.reviewDecision),
      headRepositoryOwner: node.headRepository?.owner?.login ?? "",
      baseRefName: node.baseRefName,
      baseRepositoryURL: node.baseRepository?.url.flatMap(URL.init(string:))
    )
  }

  /// Normalizes a `CheckRun | StatusContext` union member into a neutral `CheckResult`.
  /// CheckRun carries `name` + `status` + `conclusion` + `detailsUrl`; StatusContext
  /// carries `context` + `state` + `targetUrl` + `createdAt`. We map the intersection.
  private static func convertCheckNode(_ node: GraphQLCheckNode) -> CheckResult? {
    let normalizedName = node.name ?? node.context ?? ""
    guard !normalizedName.isEmpty else { return nil }
    let detailsURL: URL? = {
      if let s = node.detailsUrl, let u = URL(string: s) { return u }
      if let s = node.targetUrl, let u = URL(string: s) { return u }
      return nil
    }()
    let (status, conclusion): (CheckStatus, CheckConclusion?) = {
      if let statusRaw = node.status {
        // CheckRun branch: explicit status + optional conclusion enum.
        let status = GitHubWire.checkStatus(statusRaw) ?? .inProgress
        let conclusion = GitHubWire.checkConclusion(node.conclusion)
        return (status, conclusion)
      }
      // StatusContext branch: single `state` field. Reuse the v1 splitter for the
      // SUCCESS / FAILURE / PENDING / ERROR mapping.
      let state = node.state ?? ""
      return splitCheckState(state)
    }()
    let duration: Int? = {
      guard let s = node.startedAt, let c = node.completedAt else { return nil }
      let seconds = Int(c.timeIntervalSince(s))
      return seconds >= 0 ? seconds : nil
    }()
    return CheckResult(
      name: normalizedName,
      status: status,
      conclusion: conclusion,
      detailsURL: detailsURL,
      startedAt: node.startedAt,
      completedAt: node.completedAt,
      durationSeconds: duration
    )
  }

  // MARK: - GraphQL wire types

  /// Top-level `gh api graphql` envelope. `data` or `errors` may be present; tolerate both.
  private struct GraphQLEnvelope: Decodable {
    var data: GraphQLData?
    var errors: [GraphQLErrorEntry]?
  }

  private struct GraphQLErrorEntry: Decodable {
    var message: String?
  }

  private struct GraphQLData: Decodable {
    var repository: GraphQLRepository?
  }

  /// Dynamic-key container — the keys are `branch0`, `branch1`, … chosen at query-build time.
  private struct GraphQLRepository: Decodable {
    var pullRequestsByAlias: [String: GraphQLPRConnection]

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: DynamicKey.self)
      var out: [String: GraphQLPRConnection] = [:]
      for key in container.allKeys {
        out[key.stringValue] = try container.decode(
          GraphQLPRConnection.self, forKey: key
        )
      }
      self.pullRequestsByAlias = out
    }
  }

  private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.stringValue = "\(intValue)" }
  }

  private struct GraphQLPRConnection: Decodable {
    var nodes: [GraphQLPRNode]?
  }

  private struct GraphQLPRNode: Decodable {
    var number: Int?
    var title: String?
    var state: String?
    var isDraft: Bool?
    var additions: Int?
    var deletions: Int?
    var mergeable: String?
    var mergeStateStatus: String?
    var reviewDecision: String?
    var url: String?
    var updatedAt: Date?
    var headRefName: String?
    var baseRefName: String?
    var baseRepository: GraphQLRepositoryURL?
    var commits: GraphQLTotalCount?
    var author: GraphQLAuthor?
    var headRepository: GraphQLRepositoryOwnerShort?
    var statusCheckRollup: GraphQLStatusCheckRollup?
  }

  private struct GraphQLTotalCount: Decodable { var totalCount: Int? }
  private struct GraphQLRepositoryURL: Decodable { var url: String? }
  private struct GraphQLAuthor: Decodable { var login: String? }
  private struct GraphQLRepositoryOwnerShort: Decodable {
    var name: String?
    var owner: GraphQLOwnerLogin?
  }
  private struct GraphQLOwnerLogin: Decodable { var login: String? }
  private struct GraphQLStatusCheckRollup: Decodable {
    var contexts: GraphQLCheckContexts?
  }
  private struct GraphQLCheckContexts: Decodable {
    var nodes: [GraphQLCheckNode]?
  }
  /// Decodes members of the `CheckRun | StatusContext` union. Fields are optional — each
  /// concrete type contributes a subset.
  private struct GraphQLCheckNode: Decodable {
    // CheckRun fields
    var name: String?
    var status: String?
    var conclusion: String?
    var startedAt: Date?
    var completedAt: Date?
    var detailsUrl: String?
    // StatusContext fields
    var context: String?
    var state: String?
    var targetUrl: String?
    var createdAt: Date?
  }
}

extension JSONDecoder.DateDecodingStrategy {
  /// `gh` timestamps are ISO-8601 with a trailing `Z`; some commands return fractional
  /// seconds (`...123Z`), some don't. `.iso8601` alone rejects the fractional form.
  nonisolated static var iso8601WithFractionalSeconds: JSONDecoder.DateDecodingStrategy {
    .custom { decoder in
      let container = try decoder.singleValueContainer()
      let string = try container.decode(String.self)
      let formatters: [ISO8601DateFormatter] = [
        {
          let f = ISO8601DateFormatter()
          f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
          return f
        }(),
        {
          let f = ISO8601DateFormatter()
          f.formatOptions = [.withInternetDateTime]
          return f
        }(),
      ]
      for formatter in formatters {
        if let date = formatter.date(from: string) {
          return date
        }
      }
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Invalid ISO-8601 date: \(string)"
      )
    }
  }
}
