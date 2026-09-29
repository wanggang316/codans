import ComposableArchitecture
import SwiftUI
import CodansCore

/// Root SwiftUI view for the Worktree Status Bar's center slot. Picks a
/// form by priority: toast → activity (both reducer-owned) → PR (derived from
/// GitHubFeature.snapshots) → motivational.
struct StatusBarView: View {
  @Bindable var store: StoreOf<StatusBarFeature>
  let gitHubStore: StoreOf<GitHubFeature>
  /// Active Worktree identifier, nil when selection doesn't resolve one
  /// (sidebar placeholder state). Drives the PR form's snapshot lookup.
  let worktreeID: WorktreeID?
  /// Active Worktree's filesystem path — needed by the hover popover so
  /// it can dispatch merge / close / refresh actions that take a CWD.
  /// Nil when `worktreeID` is nil; the PR form is gated on `worktreeID`
  /// so the popover anchor never mounts without this.
  var worktreePath: URL? = nil
  /// Branch name for the popover's `.noPullRequest` fallback and the
  /// retry-refresh dispatch. The PR form is only selected when a
  /// snapshot exists, so this is mostly carried for the retry path.
  var branch: String? = nil

  var body: some View {
    HStack(spacing: 10) {
      ViewThatFits(in: .horizontal) {
        formContent(compact: false)
        formContent(compact: true)
        Color.clear.frame(width: 0, height: 0)
      }
      .animation(.easeInOut(duration: 0.2), value: formIdentity)
    }
    .padding(.horizontal, 12)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("status.bar")
  }

  /// Each form's two width budgets — full (preferred) and compact (when the
  /// titlebar is narrower than the full rendering). `ViewThatFits` picks the
  /// first subview that fits horizontally; if neither fits, the slot
  /// collapses to `Color.clear` so left / right toolbar groups stay anchored.
  @ViewBuilder
  private func formContent(compact: Bool) -> some View {
    switch form {
    case .toast(let toast):
      StatusToastView(toast: toast, compact: compact)
        .transition(.opacity)
    case .activity:
      StatusActivityView(activities: Array(store.activities), compact: compact) { id in
        store.send(.cancelTapped(id))
      }
      .transition(.opacity)
    case .pullRequest(let snapshot):
      StatusPullRequestView(
        snapshot: snapshot,
        store: gitHubStore,
        worktreeID: worktreeID,
        worktreePath: worktreePath,
        branch: branch,
        compact: compact
      )
      .transition(.opacity)
    case .motivational:
      StatusMotivationalView(compact: compact)
        .transition(.opacity)
    }
  }

  /// Priority resolution. A just-landed outcome wins for its few seconds;
  /// then running work; then a non-closed `PullRequestSnapshot` for the
  /// active Worktree; else the motivational line.
  enum Form: Equatable {
    case toast(StatusToast)
    case activity(StatusActivity)
    case pullRequest(PullRequestSnapshot)
    case motivational
  }

  private var form: Form {
    if let toast = store.toast { return .toast(toast) }
    if let activity = store.primaryActivity { return .activity(activity) }
    if let wt = worktreeID,
      let snapshot = gitHubStore.snapshots[wt],
      snapshot.state != .closed
    {
      return .pullRequest(snapshot)
    }
    return .motivational
  }

  /// Cheap equality-stable token for the form animation. The SwiftUI
  /// `.animation(_:value:)` trigger compares this, so we don't compare
  /// the whole `PullRequestSnapshot` (it carries a `Date` that ticks on
  /// every refresh without changing rendered content).
  ///
  /// Includes every field that visibly affects the rendered PR row —
  /// number, state, draft, mergeStateStatus, and the breakdown signature
  /// — so transitions like "checks failing → all passing" or
  /// "blocked → clean" do animate instead of snapping.
  private var formIdentity: String {
    switch form {
    case .toast(let t):
      return "toast-\(t.message)"
    case .activity:
      // One identity for the whole form: activities replacing each other
      // update the text in place instead of cross-fading the slot.
      return "activity"
    case .pullRequest(let pr):
      let breakdown = ChecksRollupRing.Breakdown(checks: pr.checkRollup)
      return [
        "pr",
        "\(pr.number)",
        pr.state.rawValue,
        pr.isDraft ? "draft" : "ready",
        pr.mergeStateStatus.rawValue,
        "\(breakdown.passing)/\(breakdown.failing)/\(breakdown.pending)/\(breakdown.neutral)",
      ].joined(separator: "-")
    case .motivational:
      return "motivational"
    }
  }
}
