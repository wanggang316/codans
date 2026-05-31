import Foundation

/// A compact view of one GitHub pull request tied to a Worktree. Decoded from
/// `gh pr view --json ...` output (v1 path) or from a batched `gh api graphql` response
/// (v2 path — see docs/design-docs/github-integration-batched.md) by the app-tier parsers.
/// The DTO itself uses GitHub's string enum values verbatim so the wire JSON decodes
/// directly.
///
/// Lives in `TouchCodeCore` rather than the app-tier `touch-code/GitHub/` so a future
/// `tc` IPC surface (`github.*` methods, deferred to v2) can ship the same value type
/// without a refactor. See `docs/exec-plans/0012-github-integration.md` DEC-7.
///
/// **v2 additions (0013 M2).** Four fields let the batched fetch path deliver everything
/// the sidebar badge + popover + merge affordances need in a single GraphQL roundtrip,
/// eliminating the separate `gh pr checks` subprocess. Each is `decodeIfPresent`-tolerant
/// so v1 decoders that do not populate them continue to round-trip unchanged:
///
///   - `checkRollup` — aggregated check list, replacing the separate `state.checks[prNumber]`
///     cache. Empty when no checks exist.
///   - `mergeStateStatus` — strictly more informative than `mergeable`. `.blocked` /
///     `.behind` / `.dirty` let the popover explain why merge is disabled.
///   - `reviewDecision` — nil if no reviewers required, else the final decision.
///   - `headRepositoryOwner` — source-side repository's owner login. Used by the batched
///     fetcher's fork-PR filter: a PR whose head repo owner ≠ our project's remote owner
///     is almost certainly a fork PR that happened to match our branch name, and the
///     fetcher skips it if an upstream alternative exists.
public struct PullRequestSnapshot: Equatable, Codable, Sendable, Identifiable {
  public var id: Int { number }
  public var number: Int
  public var title: String
  public var state: PullRequestState
  public var isDraft: Bool
  public var headRefName: String
  public var author: String
  public var additions: Int
  public var deletions: Int
  public var commitCount: Int
  public var mergeable: MergeableState
  public var url: URL
  public var updatedAt: Date
  /// Aggregated check list carried inline with the snapshot. Empty when the PR has no CI
  /// checks or when the decoder path does not populate it (v1 `gh pr view` parser leaves
  /// it empty; v2 batched parser fills it from `statusCheckRollup.contexts`).
  public var checkRollup: [CheckResult]
  /// Richer merge-state classification — see `MergeStateStatus`. `.unknown` is both the
  /// "GitHub is still computing mergeability" state and the decode fallback.
  public var mergeStateStatus: MergeStateStatus
  /// Final review decision. Nil when no reviewers are required (common on personal repos).
  public var reviewDecision: ReviewDecision?
  /// `login` of the repository that owns the PR's head branch. Empty when the decoder
  /// path does not populate it (v1 parser leaves it empty).
  public var headRepositoryOwner: String

  public init(
    number: Int,
    title: String,
    state: PullRequestState,
    isDraft: Bool,
    headRefName: String,
    author: String,
    additions: Int,
    deletions: Int,
    commitCount: Int,
    mergeable: MergeableState,
    url: URL,
    updatedAt: Date,
    checkRollup: [CheckResult] = [],
    mergeStateStatus: MergeStateStatus = .unknown,
    reviewDecision: ReviewDecision? = nil,
    headRepositoryOwner: String = ""
  ) {
    self.number = number
    self.title = title
    self.state = state
    self.isDraft = isDraft
    self.headRefName = headRefName
    self.author = author
    self.additions = additions
    self.deletions = deletions
    self.commitCount = commitCount
    self.mergeable = mergeable
    self.url = url
    self.updatedAt = updatedAt
    self.checkRollup = checkRollup
    self.mergeStateStatus = mergeStateStatus
    self.reviewDecision = reviewDecision
    self.headRepositoryOwner = headRepositoryOwner
  }

  private enum CodingKeys: String, CodingKey {
    case number, title, state, isDraft, headRefName, author
    case additions, deletions, commitCount, mergeable, url, updatedAt
    case checkRollup, mergeStateStatus, reviewDecision, headRepositoryOwner
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.number = try c.decode(Int.self, forKey: .number)
    self.title = try c.decode(String.self, forKey: .title)
    self.state = try c.decode(PullRequestState.self, forKey: .state)
    self.isDraft = try c.decode(Bool.self, forKey: .isDraft)
    self.headRefName = try c.decode(String.self, forKey: .headRefName)
    self.author = try c.decode(String.self, forKey: .author)
    self.additions = try c.decode(Int.self, forKey: .additions)
    self.deletions = try c.decode(Int.self, forKey: .deletions)
    self.commitCount = try c.decode(Int.self, forKey: .commitCount)
    self.mergeable = try c.decode(MergeableState.self, forKey: .mergeable)
    self.url = try c.decode(URL.self, forKey: .url)
    self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    // v2-additive fields — decode-if-present with defaults so v1-produced snapshots
    // (which pre-date these fields) round-trip identically.
    self.checkRollup = try c.decodeIfPresent([CheckResult].self, forKey: .checkRollup) ?? []
    self.mergeStateStatus =
      try c.decodeIfPresent(
        MergeStateStatus.self, forKey: .mergeStateStatus
      ) ?? .unknown
    self.reviewDecision = try c.decodeIfPresent(ReviewDecision.self, forKey: .reviewDecision)
    self.headRepositoryOwner =
      try c.decodeIfPresent(
        String.self, forKey: .headRepositoryOwner
      ) ?? ""
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(number, forKey: .number)
    try c.encode(title, forKey: .title)
    try c.encode(state, forKey: .state)
    try c.encode(isDraft, forKey: .isDraft)
    try c.encode(headRefName, forKey: .headRefName)
    try c.encode(author, forKey: .author)
    try c.encode(additions, forKey: .additions)
    try c.encode(deletions, forKey: .deletions)
    try c.encode(commitCount, forKey: .commitCount)
    try c.encode(mergeable, forKey: .mergeable)
    try c.encode(url, forKey: .url)
    try c.encode(updatedAt, forKey: .updatedAt)
    try c.encode(checkRollup, forKey: .checkRollup)
    try c.encode(mergeStateStatus, forKey: .mergeStateStatus)
    try c.encodeIfPresent(reviewDecision, forKey: .reviewDecision)
    try c.encode(headRepositoryOwner, forKey: .headRepositoryOwner)
  }
}

extension PullRequestSnapshot {
  /// True when either signal indicates the head branch no longer merges cleanly into the
  /// base. We check both because the v1 `gh pr view` parser only populates `mergeable`,
  /// while the v2 batched GraphQL parser also populates the richer `mergeStateStatus`.
  /// Lives on the model so the sidebar pill, the titlebar pill, and the popover banner
  /// all classify "conflicted" identically instead of each rolling their own predicate.
  public var hasMergeConflict: Bool {
    mergeable == .conflicting || mergeStateStatus == .dirty
  }
}

/// Lifecycle state of a pull request. Raw values match the GraphQL enum strings that
/// `gh pr view --json state` emits, so JSON decode is a one-hop pass-through.
public enum PullRequestState: String, Codable, Sendable, CaseIterable {
  case open = "OPEN"
  case merged = "MERGED"
  case closed = "CLOSED"
}

/// Merge feasibility as reported by GitHub. `.unknown` is the transient state while
/// GitHub computes mergeability on the server — not an error.
public enum MergeableState: String, Codable, Sendable, CaseIterable {
  case mergeable = "MERGEABLE"
  case conflicting = "CONFLICTING"
  case unknown = "UNKNOWN"
}
