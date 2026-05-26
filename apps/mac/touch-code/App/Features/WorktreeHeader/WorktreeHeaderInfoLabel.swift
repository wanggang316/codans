import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Leading cluster in the worktree detail toolbar. Mirrors the sidebar
/// Worktree row's identity surface so the two read as the same record:
/// the same `WorktreeRowIcon` (PR-state aware, role tint, rollup overlay,
/// unread bell override), the worktree name + pin marker, and the
/// branch subtitle (only when it differs from the name — same
/// suppression rule the sidebar uses).
///
/// The PR number badge and `+N −M` diff stats deliberately do not appear
/// here: the titlebar status bar (`StatusPullRequestView`) already owns
/// both — duplicating them in the leading toolbar item would just
/// repeat the same #NN twice across the title row.
struct WorktreeHeaderInfoLabel: View {
  let worktree: Worktree
  let project: Project
  let gitHubStore: StoreOf<GitHubFeature>

  @Environment(RollupIndexProvider.self) private var notificationRollup: RollupIndexProvider?

  var body: some View {
    let snapshot = gitHubStore.snapshots[worktree.id]
    let rollup: PullRequestBadge.CheckRollup = {
      guard let snapshot else { return .noChecks }
      return PullRequestBadge.CheckRollup.from(checks: snapshot.checkRollup)
    }()
    let isMainCheckout = worktree.path == project.rootPath
    let isSynthetic = isMainCheckout && project.gitRoot == nil
    let hasUnread = notificationRollup?.current.unreadWorktrees.contains(worktree.id) == true

    HStack(spacing: 8) {
      WorktreeRowIcon(
        snapshot: snapshot,
        rollup: rollup,
        // Toolbar has no row-selection chrome, so the icon should keep
        // its role tint rather than swap to the selected-text colour
        // the sidebar uses on the active row.
        isSelected: false,
        isSynthetic: isSynthetic,
        hasUnreadNotification: hasUnread,
        isDefaultBranch: isMainCheckout && !isSynthetic
      )
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 4) {
          Text(worktree.name)
            .font(.headline)
            .lineLimit(1)
          // Default-branch marker now lives in WorktreeRowIcon's leading
          // slot (star.fill); the toolbar identity surface no longer
          // duplicates it inline next to the name.
          if worktree.isPinned && !isMainCheckout {
            Image(systemName: "pin.fill")
              .font(.caption2)
              .foregroundStyle(.orange)
              .accessibilityLabel("Pinned")
          }
        }
        if let branch = worktree.branch, branch != worktree.name {
          Text(branch)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
  }

  private var accessibilityLabel: Text {
    var parts: [String] = [worktree.name]
    if let branch = worktree.branch, branch != worktree.name {
      parts.append("branch \(branch)")
    }
    return Text(parts.joined(separator: ", "))
  }
}
