import CodansCore
import ComposableArchitecture
import SwiftUI

/// Worktree-scoped wrapper around `PullRequestPopover` that wires the
/// merge / close / mark-ready / rerun / open / retry callbacks to the
/// shared `CodeHostFeature` and surfaces the per-worktree state (snapshot,
/// loading, error, mutating). Used by the sidebar badge and the
/// titlebar status-bar PR badge so both surfaces present the exact same
/// rich action surface — including the default-merge-strategy override
/// that writes through `SettingsStore`.
///
/// Reads only the provider-neutral snapshot: merge enablement comes from
/// `mergeOptions`, rerun from `canRerunFailedChecks`. The Code Host kind
/// only picks UI labels.
struct WorktreePullRequestPopover: View {
  let store: StoreOf<CodeHostFeature>
  let worktreeID: WorktreeID
  let branch: String

  @Environment(SettingsStore.self) private var settingsStore

  var body: some View {
    let snapshot = store.snapshots[worktreeID]
    let error = store.lastError[worktreeID]
    let isLoading = store.loading.contains(worktreeID)
    let pullRequest = store.state.pullRequestReference(for: worktreeID)
    let codeHostName = store.state.repository(for: worktreeID)?.kind.displayName ?? "Code Host"

    let content: PullRequestPopover.Content = {
      if let error { return .error(error) }
      if let snapshot { return .loaded(snapshot) }
      if isLoading { return .loading }
      return .noPullRequest(branch: branch)
    }()

    let defaultStrategy = settingsStore.settings.general.defaultMergeStrategy ?? .squash
    let isMutating = store.mutating.contains(worktreeID)

    PullRequestPopover(
      content: content,
      codeHostName: codeHostName,
      defaultMergeStrategy: defaultStrategy,
      canMerge: !isMutating
        && pullRequest != nil
        && snapshot?.mergeOption(for: defaultStrategy)?.isEnabled == true
        && snapshot?.state == .open
        && snapshot?.isDraft == false,
      mergeDisabledReason: isMutating
        ? "Another \(codeHostName) operation is in flight"
        : Self.mergeDisabledReason(for: snapshot, strategy: defaultStrategy),
      onMerge: { strategy in
        if let pullRequest {
          store.send(.mergeRequested(worktreeID, pullRequest, strategy: strategy))
        }
      },
      onClose: {
        if let pullRequest { store.send(.closeRequested(worktreeID, pullRequest)) }
      },
      onMarkReady: {
        if let pullRequest { store.send(.markReadyRequested(worktreeID, pullRequest)) }
      },
      onRerunFailedChecks: {
        if let pullRequest { store.send(.rerunFailedChecksRequested(worktreeID, pullRequest)) }
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

  /// Why the merge button is off: the Pull Request's lifecycle first, then the Code
  /// Host's own explanation (merge state reason, then the option's reason).
  static func mergeDisabledReason(
    for snapshot: PullRequestSnapshot?, strategy: MergeStrategy
  ) -> String? {
    guard let snapshot else { return "No pull request for this Worktree" }
    if snapshot.state == .merged { return "Pull request already merged" }
    if snapshot.state == .closed { return "Pull request closed" }
    if snapshot.isDraft { return "Pull request is a draft" }
    if let reason = snapshot.mergeState.reason { return reason }
    guard let option = snapshot.mergeOption(for: strategy) else {
      return "\(strategy.displayName) is not available"
    }
    return option.disabledReason
  }
}
