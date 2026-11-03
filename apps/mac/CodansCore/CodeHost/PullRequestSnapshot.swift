import Foundation

/// A compact, provider-neutral view of one Pull Request tied to a Worktree. Each Code
/// Host's decoding layer builds it from its own wire format; nothing here knows GitHub or
/// GitLab wire values. See ADR 0004 item 14.
///
/// Lives in `CodansCore` rather than the app tier so a future `codans` IPC surface can
/// ship the same value type without a refactor.
///
/// Capability differences between Code Hosts are data on the snapshot, not optional
/// protocol methods:
///
///   - `mergeOptions` — each merge strategy with whether the Code Host allows it now and,
///     when not, why.
///   - `canRerunFailedChecks` — whether "Rerun failed" applies.
///
/// The type is the snapshot-cache format too. A cached value that does not decode with
/// the current shape is discarded; the next fetch replaces it.
public struct PullRequestSnapshot: Equatable, Codable, Sendable, Identifiable {
  public var id: Int { number }
  public var number: Int
  public var title: String
  public var state: PullRequestState
  public var isDraft: Bool
  public var headRefName: String
  /// Pull Request destination. Both values are needed before mapping a base branch to a
  /// local remote-tracking ref, especially when the Pull Request comes from a fork.
  public var baseRefName: String?
  public var baseRepositoryURL: URL?
  public var author: String
  public var additions: Int
  public var deletions: Int
  public var commitCount: Int
  public var url: URL
  public var updatedAt: Date
  /// Aggregated check list carried inline with the snapshot. Empty when the Pull Request
  /// has no CI checks.
  public var checkRollup: [CheckResult]
  /// Provider-neutral merge state — see `PullRequestMergeState`.
  public var mergeState: PullRequestMergeState
  /// Merge strategies the popover offers, with their enabled state and reason.
  public var mergeOptions: [PullRequestMergeOption]
  /// `true` when the Code Host can rerun the failed checks of this Pull Request.
  public var canRerunFailedChecks: Bool
  /// Final review decision. Nil when no reviewers are required (common on personal repos).
  public var reviewDecision: ReviewDecision?
  /// Owner of the repository that holds the source branch. The decoding layer's fork
  /// filter compares it with the fetch unit's repository. Empty when unknown.
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
    url: URL,
    updatedAt: Date,
    checkRollup: [CheckResult] = [],
    mergeState: PullRequestMergeState = .unknown,
    mergeOptions: [PullRequestMergeOption] = [],
    canRerunFailedChecks: Bool = false,
    reviewDecision: ReviewDecision? = nil,
    headRepositoryOwner: String = "",
    baseRefName: String? = nil,
    baseRepositoryURL: URL? = nil
  ) {
    self.number = number
    self.title = title
    self.state = state
    self.isDraft = isDraft
    self.headRefName = headRefName
    self.baseRefName = baseRefName
    self.baseRepositoryURL = baseRepositoryURL
    self.author = author
    self.additions = additions
    self.deletions = deletions
    self.commitCount = commitCount
    self.url = url
    self.updatedAt = updatedAt
    self.checkRollup = checkRollup
    self.mergeState = mergeState
    self.mergeOptions = mergeOptions
    self.canRerunFailedChecks = canRerunFailedChecks
    self.reviewDecision = reviewDecision
    self.headRepositoryOwner = headRepositoryOwner
  }
}

extension PullRequestSnapshot {
  /// True when the source branch no longer merges cleanly into the target. Lives on the
  /// model so the sidebar pill, the titlebar pill, and the popover banner all classify
  /// "conflicted" identically instead of each rolling their own predicate.
  public var hasMergeConflict: Bool {
    mergeState.status == .conflicted
  }

  /// The merge option for `strategy`, or `nil` when the Code Host does not offer it.
  public func mergeOption(for strategy: MergeStrategy) -> PullRequestMergeOption? {
    mergeOptions.first { $0.strategy == strategy }
  }

  /// The strategy a merge uses when the user prefers `preferred`. A Code Host that does
  /// not offer `preferred` merges with its plain merge instead (GitLab has no `rebase`
  /// option: the project's merge method applies to "Merge"). See ADR 0004 item 6.
  public func mergeStrategy(preferring preferred: MergeStrategy) -> MergeStrategy {
    if mergeOptions.isEmpty || mergeOption(for: preferred) != nil { return preferred }
    if mergeOption(for: .mergeCommit) != nil { return .mergeCommit }
    return mergeOptions[0].strategy
  }
}

/// Lifecycle state of a Pull Request. Provider-neutral; raw values are the
/// snapshot-cache form.
public enum PullRequestState: String, Codable, Sendable, CaseIterable {
  case open
  case merged
  case closed
}
