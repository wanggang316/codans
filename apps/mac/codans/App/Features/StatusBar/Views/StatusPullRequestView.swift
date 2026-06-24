import ComposableArchitecture
import SwiftUI
import CodansCore

/// Titlebar-center PR form: `#N` badge + `+N −M` diff stats +
/// ChecksRollupRing + one-line summary.
///
/// Interactions:
///   * plain click → opens the PR on github.com (same dispatch the sidebar
///     badge uses)
///   * ⌘-hold → summary text swaps to `Open on GitHub <chord>`, hinting the
///     keyboard binding registered for `.openCurrentPR` (registry default
///     ⌘⇧G; respects user override).
///   * hover dwell (150 ms) → shows the rich `WorktreePullRequestPopover`,
///     same view the sidebar badge uses. Independent of the sidebar's
///     `GitHubFeature.popoverTarget` so the two surfaces don't mount a
///     popover at each other's anchor.
struct StatusPullRequestView: View {
  let snapshot: PullRequestSnapshot
  let store: StoreOf<GitHubFeature>
  /// Active Worktree, needed by the hover popover for dispatch CWDs.
  /// When nil (e.g. a hypothetical preview path with no real selection)
  /// the popover is suppressed but click-to-open still works.
  var worktreeID: WorktreeID? = nil
  var worktreePath: URL? = nil
  var branch: String? = nil
  /// Collapses the trailing detail text when true. Ring + badge stay so
  /// the slot still carries the CI health signal at a glance.
  var compact: Bool = false
  @Environment(CommandKeyObserver.self) private var commandKeyObserver
  @Environment(\.resolvedShortcuts) private var resolvedShortcuts

  @State private var isBadgeHovered = false
  @State private var isPopoverHovered = false
  @State private var isPopoverPresented = false
  @State private var hoverTask: Task<Void, Never>?

  private static var hoverDelay: Duration { .milliseconds(150) }

  var body: some View {
    Button {
      store.send(.delegate(.openURL(snapshot.url)))
    } label: {
      HStack(spacing: 6) {
        badge
        diffStats
        ChecksRollupRing(checks: snapshot.checkRollup)
        if !compact {
          detailText
            .foregroundStyle(.secondary)
        }
      }
      .font(.footnote)
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Pull request #\(snapshot.number)")
    .accessibilityValue(Self.summaryText(snapshot: snapshot))
    .accessibilityAddTraits(.isButton)
    .accessibilityHint("Opens on GitHub")
    .onHover { hovering in
      isBadgeHovered = hovering
      reconcileHover()
    }
    .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
      if let worktreeID, let worktreePath {
        WorktreePullRequestPopover(
          store: store,
          worktreeID: worktreeID,
          branch: branch ?? "",
          worktreePath: worktreePath
        )
        .onHover { hovering in
          isPopoverHovered = hovering
          reconcileHover()
        }
      }
    }
  }

  /// Shared with the sidebar via `PullRequestNumberPill` so the titlebar `#N` chip is
  /// pixel-identical to the sidebar row badge — same bordered capsule, same state tint,
  /// same red merge-conflict treatment — and the two can't drift apart.
  private var badge: some View {
    PullRequestNumberPill(snapshot: snapshot)
  }

  /// `+N −M` patch-size indicator next to the `#NN` badge. Gated on
  /// `.open` PRs only — closed / merged PRs hide the counts since the
  /// diff is already in base or discarded. Same suppression rule
  /// `WorktreeGitHubBadge` uses for the sidebar.
  @ViewBuilder
  private var diffStats: some View {
    if snapshot.state == .open, snapshot.additions > 0 || snapshot.deletions > 0 {
      HStack(spacing: 4) {
        if snapshot.additions > 0 {
          Text("+\(snapshot.additions)").foregroundStyle(DiffStatColor.additions)
        }
        if snapshot.deletions > 0 {
          Text("−\(snapshot.deletions)").foregroundStyle(DiffStatColor.deletions)
        }
      }
      .font(.caption2.monospacedDigit())
      .accessibilityLabel(
        "\(snapshot.additions) additions, \(snapshot.deletions) deletions"
      )
    }
  }

  @ViewBuilder
  private var detailText: some View {
    if commandKeyObserver.isCommandHeld {
      Text("Open on GitHub \(openPRHintChord)")
        .lineLimit(1)
    } else {
      Text(Self.summaryText(snapshot: snapshot))
        .lineLimit(1)
    }
  }

  /// Live chord display for the `.openCurrentPR` registry entry — falls back to the schema
  /// default when no resolved entry is injected (previews / tests). Without this, the hint
  /// would silently lie when the user rebinds the chord or disables it.
  private var openPRHintChord: String {
    if let resolved = resolvedShortcuts[.openCurrentPR],
      resolved.isEnabled,
      let binding = resolved.binding
    {
      return ShortcutDisplay.chord(for: binding)
    }
    if let fallback = ShortcutSchema.app.entry(for: .openCurrentPR)?.defaultBinding {
      return ShortcutDisplay.chord(for: fallback)
    }
    return ""
  }

  /// Simple-line summary, in priority order:
  ///   1. Merged / closed state labels
  ///   2. Merge-state blockers (`blocked` / `dirty` / `behind`)
  ///   3. Checks breakdown (failing > pending > all passing)
  ///   4. `(Draft)` marker
  ///   5. PR title (truncated to fit)
  static func summaryText(snapshot: PullRequestSnapshot) -> String {
    if snapshot.state == .merged { return "Merged" }
    if snapshot.state == .closed { return "Closed" }
    switch snapshot.mergeStateStatus {
    case .blocked: return "Blocked"
    case .dirty: return "Merge conflicts"
    case .behind: return "Behind base"
    case .clean, .hasHooks, .unstable, .draft, .unknown: break
    }
    let breakdown = ChecksRollupRing.Breakdown(checks: snapshot.checkRollup)
    if breakdown.failing > 0 { return "\(breakdown.failing) checks failing" }
    if breakdown.pending > 0 { return "\(breakdown.pending) checks pending" }
    if breakdown.passing > 0, breakdown.failing == 0, breakdown.pending == 0 {
      return "All checks passing"
    }
    if snapshot.isDraft { return "(Draft)" }
    return snapshot.title
  }

  /// Re-evaluates the "should popover be visible" state and schedules a 150 ms debounce
  /// either direction. The cached `hoverTask` is cancelled on every call so rapid hover
  /// transitions collapse into the latest intent instead of queueing a flap. Mirrors the
  /// pattern in `WorktreeGitHubBadge` so the two surfaces dwell-trigger identically.
  private func reconcileHover() {
    hoverTask?.cancel()
    let shouldShow = (isBadgeHovered || isPopoverHovered) && worktreeID != nil && worktreePath != nil
    if shouldShow, !isPopoverPresented {
      hoverTask = Task { @MainActor in
        try? await Task.sleep(for: Self.hoverDelay)
        if Task.isCancelled { return }
        isPopoverPresented = true
      }
    } else if !shouldShow, isPopoverPresented {
      hoverTask = Task { @MainActor in
        try? await Task.sleep(for: Self.hoverDelay)
        if Task.isCancelled { return }
        isPopoverPresented = false
      }
    }
  }
}
