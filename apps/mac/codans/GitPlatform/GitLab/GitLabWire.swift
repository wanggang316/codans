import CodansCore
import Foundation

/// The only place that knows GitLab's wire values (GraphQL enums). Each function maps a
/// wire value into the provider-neutral model from `CodansCore`. Unknown values never
/// crash: they map to the documented fallback. See ADR 0004 items 6–9.
nonisolated enum GitLabWire {
  /// `MergeRequestState`: `opened` / `merged` / `closed` / `locked`. A locked merge
  /// request is open but cannot take new commits.
  static func pullRequestState(_ raw: String?) -> PullRequestState? {
    switch raw {
    case "opened", "locked": return .open
    case "merged": return .merged
    case "closed": return .closed
    default: return nil
    }
  }

  /// `DetailedMergeStatus` → the neutral merge state with GitLab's reason.
  ///
  /// mergeable → clean; conflict → conflicted; need rebase → behind; draft → draft;
  /// a rule that holds the merge (approvals, threads, pipeline, …) → blocked with the
  /// reason; checking / unchecked → unknown. `NOT_OPEN` (merged or closed) has nothing
  /// to explain. An unrecognised value blocks: GitLab adds statuses for new rules.
  static func mergeState(detailedMergeStatus raw: String?) -> PullRequestMergeState {
    switch raw {
    case "MERGEABLE":
      return PullRequestMergeState(status: .clean)
    case "CONFLICT":
      return PullRequestMergeState(status: .conflicted, reason: "Merge request has merge conflicts")
    case "NEED_REBASE":
      return PullRequestMergeState(
        status: .behind, reason: "Source branch is behind the target branch — rebase required")
    case "DRAFT_STATUS":
      return PullRequestMergeState(status: .draft, reason: "Merge request is a draft")
    case "NOT_OPEN":
      return PullRequestMergeState(status: .unknown)
    case "CHECKING", "UNCHECKED", "PREPARING", nil:
      return PullRequestMergeState(status: .unknown, reason: "GitLab is checking the merge status — try refresh")
    case let raw?:
      return PullRequestMergeState(status: .blocked, reason: blockedReason(raw))
    }
  }

  private static func blockedReason(_ raw: String) -> String {
    switch raw {
    case "NOT_APPROVED", "APPROVALS_SYNCING": return "Approvals are required"
    case "DISCUSSIONS_NOT_RESOLVED": return "All threads must be resolved"
    case "CI_MUST_PASS": return "The pipeline must succeed"
    case "CI_STILL_RUNNING": return "The pipeline is still running"
    case "REQUESTED_CHANGES": return "A reviewer requested changes"
    case "BLOCKED_STATUS": return "Blocked by another merge request"
    case "EXTERNAL_STATUS_CHECKS": return "External status checks must pass"
    case "COMMITS_STATUS": return "Source branch has no commits or does not exist"
    case "JIRA_ASSOCIATION": return "A Jira issue must be linked"
    case "LOCKED_PATHS", "LOCKED_LFS_FILES": return "Changed files are locked"
    case "MERGE_TIME": return "Merge is not allowed before the scheduled time"
    case "SECURITY_POLICIES_VIOLATIONS", "SECURITY_POLICY_PIPELINE_CHECK":
      return "Security policies block the merge"
    case "TITLE_NOT_MATCHING": return "The title does not match the project's required pattern"
    default: return "Merge blocked by GitLab (\(raw.lowercased().replacingOccurrences(of: "_", with: " ")))"
    }
  }

  /// One pipeline job, reduced to the fields the check mapping reads.
  struct Job: Equatable, Sendable {
    var name: String
    var status: String?
    var allowFailure: Bool
    var manualJob: Bool
  }

  /// `CiJobStatus` → check status and conclusion.
  ///
  /// A failed job with `allow_failure` is neutral, so an optional job does not turn the
  /// badge red. A manual job that did not run (`MANUAL`) is skipped, so it does not keep
  /// the badge in progress. A delayed job (`SCHEDULED`) will run, so it is waiting.
  static func check(_ job: Job) -> (CheckStatus, CheckConclusion?) {
    switch job.status {
    case "CREATED": return (.queued, nil)
    case "PENDING": return (.pending, nil)
    case "WAITING_FOR_RESOURCE", "PREPARING", "WAITING_FOR_CALLBACK", "SCHEDULED": return (.waiting, nil)
    case "RUNNING", "CANCELING": return (.inProgress, nil)
    case "SUCCESS": return (.completed, .success)
    case "FAILED": return (.completed, job.allowFailure ? .neutral : .failure)
    case "CANCELED": return (.completed, .cancelled)
    case "SKIPPED", "MANUAL": return (.completed, .skipped)
    default: return (.inProgress, nil)
    }
  }

  /// "Rerun failed" applies when the head pipeline has a job that a pipeline retry runs
  /// again and that counts against the merge request: a failed job without
  /// `allow_failure`, or a canceled job.
  static func canRetryPipeline(_ jobs: [Job]) -> Bool {
    jobs.contains { job in
      (job.status == "FAILED" && !job.allowFailure) || job.status == "CANCELED"
    }
  }

  /// Review decision from what CE and EE both report:
  /// - a reviewer requested changes → changes requested;
  /// - `NOT_APPROVED` (approval rules not met; EE) → review required;
  /// - approved with at least one approver → approved, only when the reviewer data is
  ///   complete: every reviewer page was read and every reviewer has a state. A reviewer
  ///   codans did not see could have requested changes;
  /// - otherwise none (no approval rules, nobody approved, reviewer data incomplete).
  static func reviewDecision(
    detailedMergeStatus: String?, approved: Bool, approverCount: Int, reviewerStates: [String?],
    reviewersComplete: Bool
  ) -> ReviewDecision? {
    if reviewerStates.contains("REQUESTED_CHANGES") { return .changesRequested }
    if detailedMergeStatus == "NOT_APPROVED" { return .reviewRequired }
    guard reviewersComplete, !reviewerStates.contains(nil) else { return nil }
    if approved && approverCount > 0 { return .approved }
    return nil
  }

  /// "Merge" and "Squash and merge". The project's merge method (merge commit,
  /// semi-linear, fast-forward) applies to "Merge"; codans does not override it.
  ///
  /// - Squash "never" (`squashReadOnly`, not `squashOnMerge`): squash is off, with the reason.
  /// - Squash "always" (`squashReadOnly` and `squashOnMerge`): a plain merge would squash
  ///   anyway, so "Merge" is off and "Squash and merge" is the way.
  /// - Otherwise both follow the merge state.
  static func mergeOptions(
    mergeState: PullRequestMergeState, squashReadOnly: Bool, squashOnMerge: Bool
  ) -> [PullRequestMergeOption] {
    let canMerge = mergeState.status == .clean
    let stateReason = canMerge ? nil : (mergeState.reason ?? "Merge status unknown — try refresh")
    let squashNever = squashReadOnly && !squashOnMerge
    let squashAlways = squashReadOnly && squashOnMerge
    let merge: PullRequestMergeOption =
      squashAlways
      ? PullRequestMergeOption(
        strategy: .mergeCommit, isEnabled: false,
        disabledReason: "This project squashes every merge request", label: "Merge")
      : PullRequestMergeOption(
        strategy: .mergeCommit, isEnabled: canMerge, disabledReason: stateReason, label: "Merge")
    let squash: PullRequestMergeOption =
      squashNever
      ? PullRequestMergeOption(
        strategy: .squash, isEnabled: false, disabledReason: "This project does not allow squash")
      : PullRequestMergeOption(strategy: .squash, isEnabled: canMerge, disabledReason: stateReason)
    return [merge, squash]
  }
}
