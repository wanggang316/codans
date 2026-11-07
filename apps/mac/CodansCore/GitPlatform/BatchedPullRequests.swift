import Foundation

/// Aggregate result of one batched Pull Request fetch for one fetch unit. Built by the
/// Git Platform reducer around `GitPlatform.batchPullRequests(repository:branches:)`.
///
/// `byBranch` is keyed by the caller's original branch names (passed into the request),
/// not by query aliases. Branches that resolved to no PR after fork-filtering are
/// absent from the dictionary — consumers do not need to handle nil-valued entries.
///
/// `seenBranches` keeps the full set of branches queried so the reducer's cache
/// invalidator can tell when the caller's branch set has changed ("`branch X` was
/// added") vs. when PR data for the same set has plausibly shifted ("same X branches,
/// fetch again to refresh CI"). Without this, the invalidator would need a second
/// source of truth to compare against.
public nonisolated struct BatchedPullRequests: Equatable, Sendable, Codable {
  public let repository: GitPlatformRepository
  public let byBranch: [String: PullRequestSnapshot]
  public let seenBranches: Set<String>
  public let fetchedAt: Date

  public init(
    repository: GitPlatformRepository,
    byBranch: [String: PullRequestSnapshot],
    seenBranches: Set<String>,
    fetchedAt: Date
  ) {
    self.repository = repository
    self.byBranch = byBranch
    self.seenBranches = seenBranches
    self.fetchedAt = fetchedAt
  }
}
