import SwiftUI
import TouchCodeCore

/// The AgentState view content.
///
/// Lists every bound Agent ordered by `SortedEntriesProvider.sorted(_:)`
/// — primary by state-triage priority (`waitingForInput > finished >
/// loading > idle`), secondary by `lastTransitionAt` desc. Each row is
/// an `AgentStateRowView`; clicking dispatches `onTapRow(paneID)` so
/// the caller (T6, via `WorktreeHeaderView`) can walk the catalog and
/// call `HierarchyClient.focusPane`.
///
/// `resolveSourcePath` is the catalog-walk closure injected by the host
/// — keeps the view itself free of `HierarchyManager` /
/// catalog imports so it can be hosted from any layer. T6 wires the
/// concrete implementation.
///
/// Empty state ("No active agents") should not be reachable because
/// T6's badge hides itself when `entries.isEmpty`. Rendered anyway so a
/// programmatic open with no entries degrades gracefully instead of
/// showing an empty frame.
struct AgentStateView: View {
  let entries: [PaneID: AgentStateStore.AgentEntry]
  let resolveSourcePath: (PaneID) -> (project: String, worktree: String)?
  let onTapRow: (PaneID) -> Void

  var body: some View {
    // Sort once per redraw and pass the array down. The previous
    // `sortedEntries` computed property re-sorted twice per redraw
    // (once for the `ForEach` source, once for the `last?.paneID`
    // divider check inside the loop) — cheap at N ≤ 20, but the
    // redundant work was unnecessary.
    let rows = SortedEntriesProvider.sorted(entries)
    return VStack(alignment: .leading, spacing: 0) {
      header
      if rows.isEmpty {
        emptyState
      } else {
        list(rows: rows)
      }
    }
    .frame(width: 320)
    // Lighter material so the view reads as a quieter overlay on top of
    // the sidebar / worktree chrome rather than punching a heavy chrome
    // strip onto the screen.
    .background(.ultraThinMaterial)
    // `.contain` keeps inner row / header identifiers individually
    // addressable by the user-test probes (the contract requires
    // querying `agentState.row.<paneID>` *inside* the view).
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("agentState.view")
  }

  private var header: some View {
    Text("Active Agents (\(entries.count))")
      .font(.callout)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .accessibilityIdentifier("agentState.view.header")
  }

  /// Plain `VStack` rather than `LazyVStack` — the list tops out
  /// at ~20 rows in practice (one per bound agent pane) so eager layout
  /// is cheaper than the lazy machinery. Each row gains its own row id
  /// via `AgentStateRowView`'s `.accessibilityIdentifier`, so external
  /// probes can address them individually.
  private func list(rows: [(paneID: PaneID, entry: AgentStateStore.AgentEntry)]) -> some View {
    VStack(spacing: 0) {
      ForEach(rows, id: \.paneID) { item in
        let names = resolveSourcePath(item.paneID)
        AgentStateRowView(
          paneID: item.paneID,
          entry: item.entry,
          projectName: names?.project ?? "—",
          worktreeName: names?.worktree ?? "—",
          onTap: { onTapRow(item.paneID) }
        )
      }
    }
  }

  private var emptyState: some View {
    Text("No active agents")
      .font(.callout)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.vertical, 24)
  }
}
