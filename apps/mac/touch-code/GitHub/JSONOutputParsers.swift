import Foundation
import TouchCodeCore

/// Decoders that translate raw `gh` stdout bytes into TouchCodeCore DTOs. Each function is
/// a pure mapping from `Data` → (DTO | `nil` | throw `GitHubError.other`).
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
/// - `gh run list` emits lowercase status + conclusion strings (`completed`, `success`) —
///   the DTO enums use uppercase GraphQL raw values.
///
/// Keeping the translation here lets the DTOs stay wire-shape-independent so a future v2
/// IPC surface can evolve the server-side JSON independently.
nonisolated enum JSONOutputParsers {
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
      throw GitHubError.other("auth status decode: \(error)")
    }
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

  // MARK: - gh run list

  /// Parses `gh run list --limit 1 --json ...`. Returns the first (and only) element,
  /// or `nil` when the branch has never run a workflow. Normalizes gh's lowercase
  /// status / conclusion strings to the DTO's uppercase raw values.
  static func parseLatestWorkflowRun(_ data: Data) throws -> WorkflowRun? {
    struct Wire: Decodable {
      var databaseId: Int64?
      var name: String?
      var status: String?
      var conclusion: String?
      var headBranch: String?
      var headSha: String?
      var number: Int?
      var updatedAt: Date?
      var url: URL?
    }
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
      let wires = try decoder.decode([Wire].self, from: data)
      guard let wire = wires.first,
        let dbid = wire.databaseId, let name = wire.name, let statusRaw = wire.status,
        let headBranch = wire.headBranch, let headSha = wire.headSha,
        let number = wire.number, let updatedAt = wire.updatedAt, let url = wire.url
      else {
        return nil
      }
      guard let status = CheckStatus(rawValue: statusRaw.uppercased()) else {
        throw GitHubError.other("run list: unknown status '\(statusRaw)'")
      }
      let conclusion: CheckConclusion? = wire.conclusion.flatMap { raw -> CheckConclusion? in
        guard !raw.isEmpty else { return nil }
        return CheckConclusion(rawValue: raw.uppercased())
      }
      return WorkflowRun(
        databaseID: dbid,
        name: name,
        status: status,
        conclusion: conclusion,
        headBranch: headBranch,
        headSHA: headSha,
        runNumber: number,
        updatedAt: updatedAt,
        url: url
      )
    } catch let error as GitHubError {
      throw error
    } catch {
      throw GitHubError.other("run list decode: \(error)")
    }
  }

  // MARK: - gh api graphql (batched PR fetch)

  /// Parses one chunk's GraphQL response body. Input: the raw stdout from
  /// `gh api graphql ... -f query=<batched>`. Output: `[branch: snapshot]` for every
  /// branch in `aliasMap` that had a surviving PR after fork-PR filtering. Branches with
  /// no matching PR are absent.
  ///
  /// - `aliasMap`: `[alias: originalBranch]` built by `BatchedPullRequestQuery.buildQuery`.
  /// - `remoteOwner`: `login` of the repository at the project's `origin`. Used by the
  ///   fork-PR filter (see design-docs/github-integration-batched.md §Fork PR Filtering).
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
        throw GitHubError.graphQLError(first.message ?? "unknown GraphQL error")
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
    } catch let error as GitHubError {
      throw error
    } catch {
      throw GitHubError.other("batched pr decode: \(error)")
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

  /// Projects the GraphQL node into the TouchCodeCore DTO. Missing required fields are
  /// filled with safe defaults — the batched fetch tolerates sparse data better than the
  /// v1 single-PR path because one malformed PR should not fail the whole chunk.
  private static func convertToSnapshot(_ node: GraphQLPRNode) -> PullRequestSnapshot {
    let checks = (node.statusCheckRollup?.contexts?.nodes ?? []).compactMap(
      convertCheckNode
    )
    return PullRequestSnapshot(
      number: node.number ?? 0,
      title: node.title ?? "",
      state: PullRequestState(rawValue: node.state ?? "") ?? .open,
      isDraft: node.isDraft ?? false,
      headRefName: node.headRefName ?? "",
      author: node.author?.login ?? "",
      additions: node.additions ?? 0,
      deletions: node.deletions ?? 0,
      commitCount: node.commits?.totalCount ?? 0,
      mergeable: MergeableState(rawValue: node.mergeable ?? "") ?? .unknown,
      url: URL(string: node.url ?? "about:blank") ?? URL(string: "about:blank")!,
      updatedAt: node.updatedAt ?? Date(timeIntervalSince1970: 0),
      checkRollup: checks,
      mergeStateStatus: MergeStateStatus.decodeOrUnknown(node.mergeStateStatus),
      reviewDecision: ReviewDecision.decodeOrNil(node.reviewDecision),
      headRepositoryOwner: node.headRepository?.owner?.login ?? ""
    )
  }

  /// Normalizes a `CheckRun | StatusContext` union member into the DTO's `CheckResult`.
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
        let status = CheckStatus(rawValue: statusRaw) ?? .inProgress
        let conclusion: CheckConclusion? = {
          guard let raw = node.conclusion, !raw.isEmpty else { return nil }
          return CheckConclusion(rawValue: raw)
        }()
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
    var commits: GraphQLTotalCount?
    var author: GraphQLAuthor?
    var headRepository: GraphQLRepositoryOwnerShort?
    var statusCheckRollup: GraphQLStatusCheckRollup?
  }

  private struct GraphQLTotalCount: Decodable { var totalCount: Int? }
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
