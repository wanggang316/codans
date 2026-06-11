import Foundation

/// Aggregate result of one project-level batched PR fetch (0013 M3). Returned by
/// `GitHubService.batchPullRequests(host:owner:repo:branches:)` after one or more
/// `gh api graphql` subprocesses + response decoding.
///
/// `byBranch` is keyed by the caller's original branch names (passed into the request),
/// not by GraphQL aliases. Branches that resolved to no PR after fork-filtering are
/// absent from the dictionary — consumers do not need to handle nil-valued entries.
///
/// `seenBranches` keeps the full set of branches queried so the reducer's cache
/// invalidator can tell when the caller's branch set has changed ("`branch X` was
/// added") vs. when PR data for the same set has plausibly shifted ("same X branches,
/// fetch again to refresh CI"). Without this, the invalidator would need a second
/// source of truth to compare against.
public nonisolated struct BatchedPullRequests: Equatable, Sendable, Codable {
  public let host: String
  public let owner: String
  public let repo: String
  public let byBranch: [String: PullRequestSnapshot]
  public let seenBranches: Set<String>
  public let fetchedAt: Date

  public init(
    host: String,
    owner: String,
    repo: String,
    byBranch: [String: PullRequestSnapshot],
    seenBranches: Set<String>,
    fetchedAt: Date
  ) {
    self.host = host
    self.owner = owner
    self.repo = repo
    self.byBranch = byBranch
    self.seenBranches = seenBranches
    self.fetchedAt = fetchedAt
  }
}
