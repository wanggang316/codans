import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Leading cluster in the worktree detail toolbar. Mirrors the sidebar
/// Worktree row's identity surface so the two read as the same record:
/// the same `WorktreeRowIcon` (PR-state aware, role tint, rollup overlay,
/// unread bell override) plus a two-row content stack — row 1 is the
/// current branch (click target for the branch popover), row 2 is the
/// worktree name + project name as caption context.
///
/// The PR number badge and `+N −M` diff stats deliberately do not appear
/// here: the titlebar status bar (`StatusPullRequestView`) already owns
/// both — duplicating them in the leading toolbar item would just
/// repeat the same #NN twice across the title row.
struct WorktreeHeaderInfoLabel: View {
  let worktree: Worktree
  let project: Project
  let gitHubStore: StoreOf<GitHubFeature>
  let branchSwitcherStore: StoreOf<BranchSwitcherFeature>

  @Environment(RollupIndexProvider.self) private var notificationRollup: RollupIndexProvider?
  @State private var isBranchRowHovered = false

  var body: some View {
    let snapshot = gitHubStore.snapshots[worktree.id]
    let rollup: PullRequestBadge.CheckRollup = {
      guard let snapshot else { return .noChecks }
      return PullRequestBadge.CheckRollup.from(checks: snapshot.checkRollup)
    }()
    let isMainCheckout = worktree.path == project.rootPath
    let isSynthetic = isMainCheckout && project.gitRoot == nil
    let roleTint: Color = worktree.isPinned ? .orange : .secondary
    let hasUnread = notificationRollup?.current.unreadWorktrees.contains(worktree.id) == true

    HStack(spacing: 8) {
      WorktreeRowIcon(
        snapshot: snapshot,
        rollup: rollup,
        // Toolbar has no row-selection chrome, so the icon should keep
        // its role tint rather than swap to the selected-text colour
        // the sidebar uses on the active row.
        isSelected: false,
        roleTint: roleTint,
        isSynthetic: isSynthetic,
        hasUnreadNotification: hasUnread,
        isDefaultBranch: isMainCheckout && !isSynthetic
      )
      VStack(alignment: .leading, spacing: 0) {
        branchRowButton
          .popover(
            isPresented: Binding(
              get: { branchSwitcherStore.isPopoverOpen },
              set: { newValue in
                if !newValue {
                  branchSwitcherStore.send(.popoverDismissed)
                }
              }
            ),
            arrowEdge: .bottom
          ) {
            BranchSwitcherView(store: branchSwitcherStore)
          }
        contextRow(isMainCheckout: isMainCheckout)
      }
    }
  }

  // MARK: - Row 1: branch (click target)

  private var branchRowButton: some View {
    Button {
      branchSwitcherStore.send(.popoverTapped)
    } label: {
      branchRowContent
    }
    .buttonStyle(.plain)
    .onHover { isBranchRowHovered = $0 }
    .accessibilityIdentifier("worktree_header.branch_button")
    .accessibilityLabel("Branch \(branchTitle)")
  }

  private var branchRowContent: some View {
    HStack(spacing: 4) {
      Text(branchTitle)
        .font(.headline)
        .lineLimit(1)
        .accessibilityIdentifier("worktree_header.branch_text")
      trailingAffordance
        .frame(width: 12, alignment: .center)
    }
    .contentShape(Rectangle())
  }

  /// Trailing slot is fixed at 12pt regardless of state so the branch text
  /// doesn't shift horizontally as the user hovers in/out. Hover affordance
  /// is now chevron-only (the prior underline was dropped) — when the row
  /// is neither hovered nor switching, the slot holds an empty `Color.clear`
  /// placeholder so layout stays stable. `Color.clear` is preferred over
  /// `.opacity(0)` because the latter still consumes hit-test area and a11y.
  @ViewBuilder
  private var trailingAffordance: some View {
    if branchSwitcherStore.isSwitching {
      ProgressView()
        .controlSize(.mini)
        .accessibilityIdentifier("worktree_header.switching_spinner")
        .accessibilityLabel("Switching")
    } else if isBranchRowHovered {
      Image(systemName: "chevron.down")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    } else {
      Color.clear
        .accessibilityHidden(true)
    }
  }

  // MARK: - Row 2: worktree name · project (caption)

  private func contextRow(isMainCheckout: Bool) -> some View {
    // Pin marker sits between `worktree.name` and the `·` separator so the
    // visual "pinned" affordance attaches to the worktree (not the
    // following project name). The orange `pin.fill` still suppresses on
    // the main checkout where pinning is meaningless.
    HStack(spacing: 4) {
      Text(worktree.name)
      if worktree.isPinned && !isMainCheckout {
        Image(systemName: "pin.fill")
          .font(.caption2)
          .foregroundStyle(.orange)
          .accessibilityLabel("Pinned")
      }
      Text("· \(project.name)")
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .lineLimit(1)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("worktree_header.context_text")
  }

  // MARK: - Branch title

  /// Source of truth is the model field. OQ-D1 leaves the `git rev-parse`
  /// short-sha display for detached HEAD as a follow-up; until then we
  /// render explicit text so the user-test `UT-BSH-HD-003` has a stable
  /// string to assert against.
  private var branchTitle: String {
    worktree.branch ?? "(detached)"
  }
}
