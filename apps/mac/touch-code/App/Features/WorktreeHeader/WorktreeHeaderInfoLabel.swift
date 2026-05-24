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
        contextRow(isMainCheckout: isMainCheckout)
      }
    }
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
      // Popover is anchored on the outer `HStack` rather than on the Button
      // itself: AppKit centres the arrow on the attachment view, and the
      // outer HStack gives a visually balanced anchor (icon + content)
      // rather than originating the arrow from the small chevron slot.
      BranchSwitcherView(store: branchSwitcherStore)
        .frame(width: 360, height: 480)
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
    .accessibilityLabel("Branch \(branchTitle), button")
  }

  private var branchRowContent: some View {
    HStack(spacing: 4) {
      Text(branchTitle)
        .font(.headline)
        .lineLimit(1)
        .underline(isBranchRowHovered, color: .primary)
        .accessibilityIdentifier("worktree_header.branch_text")
      trailingAffordance
        .frame(width: 12, alignment: .center)
    }
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private var trailingAffordance: some View {
    if branchSwitcherStore.isSwitching {
      ProgressView()
        .controlSize(.mini)
        .accessibilityIdentifier("worktree_header.switching_spinner")
        .accessibilityHidden(true)
    } else {
      Image(systemName: "chevron.down")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
  }

  // MARK: - Row 2: worktree name · project (caption)

  private func contextRow(isMainCheckout: Bool) -> some View {
    HStack(spacing: 4) {
      Text("\(worktree.name) · \(project.name)")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityIdentifier("worktree_header.context_text")
      // The pin marker follows the worktree name to row 2 (the row swap
      // moved that name down); the orange `pin.fill` still suppresses on
      // the main checkout where pinning is meaningless.
      if worktree.isPinned && !isMainCheckout {
        Image(systemName: "pin.fill")
          .font(.caption2)
          .foregroundStyle(.orange)
          .accessibilityLabel("Pinned")
      }
    }
  }

  // MARK: - Branch title

  /// Source of truth is the model field. OQ-D1 leaves the `git rev-parse`
  /// short-sha display for detached HEAD as a follow-up; until then we
  /// render explicit text so the user-test `UT-BSH-HD-003` has a stable
  /// string to assert against.
  private var branchTitle: String {
    worktree.branch ?? "(detached HEAD)"
  }
}
