import ComposableArchitecture
import SwiftUI
import CodansCore

/// Worktree-scoped wrapper around `PullRequestPopover` that wires the
/// merge / close / mark-ready / rerun / open / retry callbacks to the
/// shared `GitHubFeature` and surfaces the per-worktree state (snapshot,
/// loading, error, mutating). Used by the sidebar badge and the
/// titlebar status-bar PR badge so both surfaces present the exact same
/// rich action surface — including the default-merge-strategy override
/// that writes through `SettingsStore`.
struct WorktreePullRequestPopover: View {
  let store: StoreOf<GitHubFeature>
  let worktreeID: WorktreeID
  let branch: String
  let worktreePath: URL

  @Environment(SettingsStore.self) private var settingsStore

  var body: some View {
    let snapshot = store.snapshots[worktreeID]
    let error = store.lastError[worktreeID]
    let isLoading = store.loading.contains(worktreeID)

    let content: PullRequestPopover.Content = {
      if let error { return .error(error) }
      if let snapshot {
        // 0013 M5: checks now travel inside the snapshot. `latestWorkflowRuns`
        // remains a separately-fetched lazy load on popover-open — the
        // batched query does not yet include workflow-run IDs.
        let run = store.latestWorkflowRuns[snapshot.number]
        return .loaded(snapshot, checks: snapshot.checkRollup, workflowRun: run)
      }
      if isLoading { return .loading }
      return .noPullRequest(branch: branch)
    }()

    let defaultStrategy = settingsStore.settings.general.defaultMergeStrategy ?? .squash
    let isMutating = store.mutating.contains(worktreeID)

    PullRequestPopover(
      content: content,
      defaultMergeStrategy: defaultStrategy,
      canMerge: !isMutating
        && snapshot?.mergeable == .mergeable
        && snapshot?.state == .open
        && snapshot?.isDraft == false,
      mergeDisabledReason: isMutating
        ? "Another GitHub operation is in flight"
        : Self.mergeDisabledReason(for: snapshot),
      onMerge: { strategy in
        if let pr = snapshot {
          store.send(
            .mergeRequested(
              worktreeID, prNumber: pr.number, strategy: strategy, worktreePath: worktreePath
            )
          )
        }
      },
      onClose: {
        if let pr = snapshot {
          store.send(.closeRequested(worktreeID, prNumber: pr.number, worktreePath: worktreePath))
        }
      },
      onMarkReady: {
        if let pr = snapshot {
          store.send(.markReadyRequested(worktreeID, prNumber: pr.number, worktreePath: worktreePath))
        }
      },
      onRerunFailedJobs: {
        if let pr = snapshot, let run = store.latestWorkflowRuns[pr.number] {
          store.send(
            .rerunFailedJobsRequested(worktreeID, runID: run.databaseID, worktreePath: worktreePath)
          )
        }
      },
      onOpenOnWeb: {
        if let url = snapshot?.url {
          store.send(.delegate(.openURL(url)))
        }
      },
      onOpenCheckLog: { url in store.send(.delegate(.openURL(url))) },
      onSetProjectDefaultStrategy: { [settingsStore] strategy in
        // Per-Project override UI is deferred — writing to the *global* default is a
        // useful intermediate behavior. When per-Project lands, this callback splits
        // into two.
        settingsStore.mutateGeneral { $0.defaultMergeStrategy = strategy }
      },
      onRetry: {
        store.send(.worktreeRefreshRequested(worktreeID))
      }
    )
  }

  static func mergeDisabledReason(for snapshot: PullRequestSnapshot?) -> String? {
    guard let snapshot else { return "No pull request for this Worktree" }
    if snapshot.state == .merged { return "Pull request already merged" }
    if snapshot.state == .closed { return "Pull request closed" }
    if snapshot.isDraft { return "Pull request is a draft" }
    // Prefer the richer `mergeStateStatus` reason when GitHub computed it; the legacy
    // `mergeable` only distinguishes mergeable/conflicting/unknown.
    switch snapshot.mergeStateStatus {
    case .dirty: return "Pull request has merge conflicts"
    case .blocked: return "Merge blocked by required checks or reviews"
    case .behind: return "Behind base branch — update required before merge"
    case .clean, .hasHooks, .unstable, .draft, .unknown: break
    }
    if snapshot.mergeable == .conflicting { return "Pull request has merge conflicts" }
    if snapshot.mergeable == .unknown { return "Merge status unknown — try refresh" }
    return nil
  }
}
