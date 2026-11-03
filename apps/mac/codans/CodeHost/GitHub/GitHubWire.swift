import CodansCore
import Foundation

/// The only place that knows GitHub's wire values (GraphQL enums and `gh` JSON strings).
/// Each function maps a wire value into the provider-neutral model from `CodansCore`.
/// Unknown values never crash: they map to the documented fallback.
nonisolated enum GitHubWire {
  /// `PullRequestState`: `OPEN` / `MERGED` / `CLOSED`.
  static func pullRequestState(_ raw: String?) -> PullRequestState? {
    switch raw {
    case "OPEN": return .open
    case "MERGED": return .merged
    case "CLOSED": return .closed
    default: return nil
    }
  }

  /// `CheckStatusState`. Callers upper-case `gh run list`'s lowercase form first.
  static func checkStatus(_ raw: String?) -> CheckStatus? {
    switch raw {
    case "QUEUED": return .queued
    case "IN_PROGRESS": return .inProgress
    case "COMPLETED": return .completed
    case "WAITING": return .waiting
    case "PENDING": return .pending
    default: return nil
    }
  }

  /// `CheckConclusionState`. Callers upper-case `gh run list`'s lowercase form first.
  static func checkConclusion(_ raw: String?) -> CheckConclusion? {
    switch raw {
    case "SUCCESS": return .success
    case "FAILURE": return .failure
    case "CANCELLED": return .cancelled
    case "SKIPPED": return .skipped
    case "NEUTRAL": return .neutral
    case "TIMED_OUT": return .timedOut
    case "ACTION_REQUIRED": return .actionRequired
    case "STALE": return .stale
    case "STARTUP_FAILURE": return .startupFailure
    default: return nil
    }
  }

  /// `PullRequestReviewDecision`. Missing, empty, and unknown values map to nil.
  static func reviewDecision(_ raw: String?) -> ReviewDecision? {
    switch raw {
    case "APPROVED": return .approved
    case "CHANGES_REQUESTED": return .changesRequested
    case "REVIEW_REQUIRED": return .reviewRequired
    default: return nil
    }
  }

  /// Folds GitHub's two merge signals into the neutral merge state.
  ///
  /// - `mergeStateStatus` (`CLEAN`, `DIRTY`, `BLOCKED`, `BEHIND`, `HAS_HOOKS`, `UNSTABLE`,
  ///   `DRAFT`, `UNKNOWN`) gives the status. `HAS_HOOKS` and `UNSTABLE` still merge, so
  ///   they are clean. A missing or unrecognised value is unknown.
  /// - `mergeable` (`MERGEABLE`, `CONFLICTING`, `UNKNOWN`) marks conflicts the richer
  ///   field has not caught up with yet.
  ///
  /// The reason explains why merge is off, in the order the popover always used: the
  /// richer blockers first, then the legacy conflict and still-computing signals.
  static func mergeState(mergeable: String?, mergeStateStatus: String?) -> PullRequestMergeState {
    let status: PullRequestMergeState.Status = {
      if mergeStateStatus == "DIRTY" || mergeable == "CONFLICTING" { return .conflicted }
      switch mergeStateStatus {
      case "BLOCKED": return .blocked
      case "BEHIND": return .behind
      case "DRAFT": return .draft
      case "CLEAN", "HAS_HOOKS", "UNSTABLE": return .clean
      default: return .unknown
      }
    }()
    let reason: String? = {
      switch mergeStateStatus {
      case "DIRTY": return "Pull request has merge conflicts"
      case "BLOCKED": return "Merge blocked by required checks or reviews"
      case "BEHIND": return "Behind base branch — update required before merge"
      default: break
      }
      switch mergeable {
      case "MERGEABLE": return nil
      case "CONFLICTING": return "Pull request has merge conflicts"
      default: return "Merge status unknown — try refresh"
      }
    }()
    return PullRequestMergeState(status: status, reason: reason)
  }

  /// GitHub offers every strategy; `mergeable == MERGEABLE` decides whether merge is
  /// possible now. The repository's allowed merge methods are not fetched, so a
  /// strategy the repository forbids fails at `gh pr merge` time.
  static func mergeOptions(
    mergeable: String?, mergeState: PullRequestMergeState
  ) -> [PullRequestMergeOption] {
    let isEnabled = mergeable == "MERGEABLE"
    return MergeStrategy.allCases.map { strategy in
      PullRequestMergeOption(
        strategy: strategy,
        isEnabled: isEnabled,
        disabledReason: isEnabled ? nil : (mergeState.reason ?? "Merge status unknown — try refresh")
      )
    }
  }
}
