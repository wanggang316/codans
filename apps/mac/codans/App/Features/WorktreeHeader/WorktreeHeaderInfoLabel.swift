import ComposableArchitecture
import SwiftUI
import CodansCore

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
        contextRow()
      }
    }
  }

  private var isMainCheckout: Bool { worktree.path == project.rootPath }

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
      if worktree.isPinned && !isMainCheckout {
        Image(systemName: "pin.fill")
          .font(.caption2)
          .foregroundStyle(.orange)
          .accessibilityLabel("Pinned")
      }
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

  private func contextRow() -> some View {
    // When the worktree's folder name equals the current branch (a common
    // git-wt pattern: `feat/login` worktree on `feat/login` branch), the
    // folder portion restates row 1. Suppress the folder name + leading
    // separator and keep only the project name. Mirrors the Sidebar's
    // "suppress secondary line when it restates primary" precedent.
    // Detached HEAD has `worktree.branch == nil`, so the empty-string
    // comparison won't match any real folder — detached worktrees keep
    // the full row.
    //
    // The pin marker lives on row 1 next to the branch name, not here —
    // the pinned state attaches to the worktree's overall identity, which
    // row 1 owns as the click target.
    let folderRestatesBranch = worktree.name == (worktree.branch ?? "")
    return HStack(spacing: 4) {
      if !folderRestatesBranch {
        Text(worktree.name)
        Text("· \(project.name)")
      } else {
        Text(project.name)
      }
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
