import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Sidebar-row GitHub badge with hover-triggered popover. Click on the badge opens the PR
/// on github.com; dwelling the cursor over the badge for 150 ms opens the rich
/// `PullRequestPopover` in place. The popover stays visible while the cursor is over
/// either the badge or the popover content — a 150 ms grace period covers the hand-off
/// between them so the popover does not flash away when the cursor transitions.
///
/// Per-row view so each instance carries its own `@State` (hover flags + debounce Task).
/// The parent `HierarchySidebarView` supplies the popover content as a `@ViewBuilder`
/// closure so the rich action surface keeps its dependency on `SettingsStore` without
/// this view needing to know.
struct WorktreeGitHubBadge<PopoverContent: View>: View {
  let store: StoreOf<GitHubFeature>
  let worktreeID: WorktreeID
  let branch: String
  let worktreePath: URL
  @ViewBuilder let popoverContent: () -> PopoverContent

  @State private var isBadgeHovered = false
  @State private var isPopoverHovered = false
  @State private var hoverTask: Task<Void, Never>?

  private static var hoverDelay: Duration { .milliseconds(150) }

  var body: some View {
    let snapshot = store.snapshots[worktreeID]
    let isLoading = store.loading.contains(worktreeID)
    let lastError = store.lastError[worktreeID]
    // True when a real pill renders; false for the 0-pt popover anchor. Drives the
    // leading gap below so the anchor adds no spacing — that's what lets a preceding
    // diff-stats chip sit flush at the row's trailing edge (see `worktreeRow`).
    let hasVisiblePill = snapshot != nil || isLoading || lastError != nil

    Group {
      if let snapshot {
        // 0013 M5: `checkRollup` now travels on the snapshot (populated by the v2
        // batched `gh api graphql` path). No longer read from the retired
        // `state.checks[prNumber]` dictionary. The `+N −M` chip used to live here
        // but moved to `HierarchySidebarView.diffStatsChip` so PR-less rows can
        // surface the same widget against `WorktreeBranchDiffMonitor`.
        let rollup = PullRequestBadge.CheckRollup.from(checks: snapshot.checkRollup)
        PullRequestBadge(
          state: .loaded(snapshot, rollup: rollup),
          onTap: { store.send(.delegate(.openURL(snapshot.url))) }
        )
      } else if isLoading {
        PullRequestBadge(state: .loading, onTap: {})
      } else if let lastError {
        PullRequestBadge(
          state: .error(lastError),
          onTap: {
            store.send(.worktreeRefreshRequested(worktreeID))
          }
        )
      } else {
        // 0-pt anchor so `.popover`/`.onHover` modifiers below have a concrete view to
        // attach to even before any PR data has loaded. `EmptyView()` is a structural
        // placeholder — SwiftUI never mounts it, which silently suppresses every modifier
        // chained after it. That's why the row stayed grey forever.
        Color.clear.frame(width: 0, height: 0)
      }
    }
    // Leading gap from a preceding diff-stats chip — but only when a pill actually shows.
    // The empty anchor pads nothing so it never nudges the chip off the trailing edge.
    .padding(.leading, hasVisiblePill ? 6 : 0)
    .onHover { hovering in
      isBadgeHovered = hovering
      reconcileHover()
    }
    // Per-row fetch dispatch is retired. `RootFeature.selectionChanged` dispatches
    // `GitHubFeature.Action.projectActivated` once per Project activation, which kicks
    // a single batched `gh api graphql` call. Restoring the `.task(id:)` here as a
    // fallback hit rate-limits: 20+ worktrees each firing `gh pr view` in parallel
    // chewed through the REST/GraphQL budget on every app relaunch.
    .popover(
      isPresented: Binding(
        get: { store.popoverTarget == worktreeID },
        set: { if !$0 { store.send(.dismissPopover) } }
      ),
      arrowEdge: .trailing
    ) {
      popoverContent()
        .onHover { hovering in
          isPopoverHovered = hovering
          reconcileHover()
        }
    }
  }

  /// Re-evaluates the "should popover be visible" state and schedules a 150 ms debounce
  /// either direction. The cached `hoverTask` is cancelled on every call so rapid hover
  /// transitions collapse into the latest intent instead of queueing a flap.
  private func reconcileHover() {
    hoverTask?.cancel()
    let isTarget = store.popoverTarget == worktreeID
    let shouldShow = isBadgeHovered || isPopoverHovered
    if shouldShow, !isTarget {
      hoverTask = Task { @MainActor in
        try? await Task.sleep(for: Self.hoverDelay)
        if Task.isCancelled { return }
        store.send(.presentPopover(worktreeID, worktreePath: worktreePath))
      }
    } else if !shouldShow, isTarget {
      hoverTask = Task { @MainActor in
        try? await Task.sleep(for: Self.hoverDelay)
        if Task.isCancelled { return }
        store.send(.dismissPopover)
      }
    }
  }
}
