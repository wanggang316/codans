import CodansCore
import ComposableArchitecture
import SwiftUI

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
    let glyph: WorktreeRowIcon.LeadingGlyph = isSynthetic ? .folder : .gitAnchor
    let hasUnread = notificationRollup?.current.unreadWorktrees.contains(worktree.id) == true

    HStack(spacing: 8) {
      if isFolderRoot {
        // The row this header names is the Project itself, so it wears the
        // Project's icon — the same one the sidebar row draws, including a
        // user-picked one and the workspace default. `WorktreeRowIcon` knows
        // only the fixed folder glyph and would contradict the sidebar.
        folderRootIcon(hasUnread: hasUnread)
      } else {
        WorktreeRowIcon(
          snapshot: snapshot,
          rollup: rollup,
          // Toolbar has no row-selection chrome, so the icon should keep
          // its role tint rather than swap to the selected-text colour
          // the sidebar uses on the active row.
          isSelected: false,
          glyph: glyph,
          hasUnreadNotification: hasUnread,
          isDefaultBranch: isMainCheckout && !isSynthetic
        )
      }
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

  /// The folder a Project row stands for (`Project.rowWorktree`): a plain
  /// folder, a remote folder, or a workspace root. No branch to show and no
  /// repository to list branches from, so the headline names the Project, as
  /// its sidebar row does, and is not a popover target.
  private var isFolderRoot: Bool { project.rowWorktree?.id == worktree.id }

  /// Leading icon for such a folder: the Project's own icon, sized to the
  /// slot `WorktreeRowIcon` uses so the headline sits at the same offset
  /// either way. Unread still takes the slot, as it does on every row.
  @ViewBuilder
  private func folderRootIcon(hasUnread: Bool) -> some View {
    if hasUnread {
      Image(systemName: "bell.fill")
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 12, height: 12)
        .foregroundStyle(Color.orange)
        .frame(width: 14, height: 14)
        .accessibilityLabel("Has unread notifications")
    } else {
      ProjectIconView(
        icon: project.icon, color: project.color, size: 13,
        defaultSymbol: ProjectIconView.defaultSymbol(for: project.kind)
      )
      // Decorative, like the sidebar row's copy of it: the context row
      // under the headline already says "Workspace" or "Folder" in words.
      .frame(width: 14, height: 14)
    }
  }

  /// Project name tint in the caption row. Uses the project's configured
  /// color when set; otherwise keeps the caption `.secondary` hue so a
  /// No-Color project reads exactly as before.
  private var projectNameColor: Color {
    project.color?.swiftUIColor ?? .secondary
  }

  // MARK: - Row 1: branch (click target)

  @ViewBuilder
  private var branchRowButton: some View {
    if isFolderRoot {
      branchRowContent
        .accessibilityIdentifier("worktree_header.branch_text")
        .accessibilityLabel(branchTitle)
    } else {
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
      if isFolderRoot {
        // The headline already names the Project; say what kind of folder it
        // is. A path would be wider than the toolbar item can give it.
        Text(project.isWorkspace ? "Workspace" : "Folder")
      } else if !folderRestatesBranch {
        Text(worktree.name)
        Text("· \(project.name)")
          .foregroundStyle(projectNameColor)
      } else {
        Text(project.name)
          .foregroundStyle(projectNameColor)
      }
      // Server-project marker — same glyph + tooltip as the sidebar
      // project row, so the header names the host the worktree lives on.
      // `.small` image scale keeps the wide glyph proportionate to the
      // caption-sized neighbor text.
      if let host = project.remoteHost {
        Image(systemName: "tv.badge.wifi")
          .font(.caption2)
          .imageScale(.small)
          .foregroundStyle(.secondary)
          .help(host.displayAuthority)
          .accessibilityLabel("Remote server \(host.displayAuthority)")
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .lineLimit(1)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("worktree_header.context_text")
  }

  // MARK: - Branch title

  /// Source of truth is the model field. Detached HEAD renders the commit
  /// ("Detached HEAD @<short>") via the same helper the sidebar row uses;
  /// the bare "(detached)" fallback only shows when even the SHA is
  /// unknown (synthetic non-git worktree).
  private var branchTitle: String {
    if isFolderRoot { return project.name }
    return worktree.branch ?? worktree.detachedHeadTitle ?? "(detached)"
  }
}
