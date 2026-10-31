import AppKit
import CodansCore
import SwiftUI

/// AgentState panel anchored at the sidebar's bottom safe-area inset.
///
/// Visual brief (per design pass):
/// - A section of the sidebar, not a card: no fill, border, or corners of
///   its own, the way native sidebars group content. A card inside the
///   sidebar's glass panel has no inset that reads right against both the
///   panel edge and the pane cards next to it.
/// - It follows the sidebar list's geometry: rows and the top rule span
///   the list's selection column (`columnInset` from each side), and text
///   starts where the list's row content starts (`contentInset`).
/// - A hairline rule at the top separates it from the list. The strip
///   around the rule is the sole drag-to-resize hit region; a capsule
///   handle and the `resizeUpDown` cursor show on hover.
/// - The close button has been removed; the footer toggle is the only
///   open/close affordance.
///
/// Layout (top → bottom):
/// - Resize strip (12pt) around the hairline rule; the capsule fades in
///   on hover.
/// - Title row: "Agents View" + optional `(N)` count chip when N > 4.
/// - Scrollable list of `AgentStateRowView`s ordered by
///   `SortedEntriesProvider`.
///
/// Tapping a row dispatches focus to the corresponding pane (via the
/// controller's `onTapRow` closure). The panel intentionally stays open
/// after a row tap so the user can fan-jump between agents.
struct AgentStateSidebarPanel: View {
  let registry: AgentStateStore
  let resolveSourcePath:
    (PaneID) -> (
      project: String, worktree: String, projectColor: ProjectColor?,
      worktreePath: String, remoteHost: RemoteHost?
    )?
  /// Pane the main window is currently focused on (selection chain bottom).
  /// Drives the selected-row highlight inside the panel so the user can see
  /// at a glance which row corresponds to the pane they're already looking
  /// at. nil = no pane currently focused (sidebar focus, no selection, etc.)
  let focusedPaneID: PaneID?
  let onTapRow: (PaneID) -> Void
  /// Kept on the API even though the header no longer carries a close
  /// button — the host (sidebar) still uses this to collapse the panel
  /// from the keyboard / programmatic paths if it ever needs to.
  let onClose: () -> Void
  /// Row context-menu "Hand Off…" — routes to
  /// `RootFeature.agentState(.handOffTapped)`. Defaulted so previews and
  /// tests that don't wire it still render rows.
  var onHandOffRow: (PaneID) -> Void = { _ in }
  /// Row context-menu "Run Workflow" pick — starts `workflowID` with the
  /// row's pane as the `current` role.
  var onRunWorkflowRow: (PaneID, String) -> Void = { _, _ in }
  /// Active workflow runs, rendered as a read-only group under the agent
  /// rows. Defaulted so previews and tests without the engine render the
  /// agent list alone.
  var workflowEngine: WorkflowEngine?

  /// Current panel height in points. The view writes to this binding as
  /// the user drags the handle; the host is responsible for persisting
  /// the value (typically via `@AppStorage`).
  @Binding var height: Double
  let minHeight: Double
  let maxHeight: Double

  /// Snapshot of `height` taken at drag start. Without this anchor the
  /// drag delta would re-apply against the already-mutated height each
  /// `onChanged` tick and the resize would accelerate exponentially.
  @State private var dragAnchor: Double?
  /// Whether the cursor is currently over the resize strip. Drives the
  /// capsule's fade-in and pushes / pops the resize-up-down cursor.
  @State private var strokeHovering = false

  /// Drives per-row layout density (`normal` two-line, `compact`
  /// one-line) from `Settings → General → Agents View display`.
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(WorkflowCatalogStore.self) private var workflowCatalog

  /// Suppresses the reorder animation for users who opt out of motion.
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Owns the stable, debounced display order. View-local `@State` so it
  /// survives the host re-creating this struct on every registry mutation,
  /// and is torn down / reseeded when the panel is collapsed and reopened.
  /// Reading `order.orderedIDs` in `content` subscribes the view to its
  /// `@Observable` order changes; `.animation(_:value:)` animates the diff.
  @State private var order = AgentStateOrderCoordinator()

  /// `Settings → General → Agents View → Auto-sort`. When off the list holds
  /// insertion order and the coordinator never re-sorts.
  private var autoSort: Bool {
    settingsStore.settings.general.agentsViewAutoSort
  }

  /// Show the count chip only once the panel holds more than four
  /// agents — for the typical 1-4 entry case the title alone reads
  /// cleaner.
  private var showsCountChip: Bool {
    registry.entries.count > 4
  }

  /// Height of the resize hit region. Kept narrow so the drag affordance
  /// is purely on the top edge — the title row beneath stays inert and
  /// the user can scroll the list without accidentally resizing.
  private let resizeStripHeight: CGFloat = 12

  /// Gap between the section and the sidebar's bottom edge. The section's
  /// own height is `height` minus this gap, so the host's list inset
  /// (`height`) still clears the whole panel.
  private let edgeInset: CGFloat = PaneCardMetrics.edgeMargin
  /// Inset of the sidebar list's selection column from each side, measured
  /// from the live outline (its cells span x 10…289 in a 299pt sidebar).
  static let columnInset: CGFloat = 10
  /// Inset of row content inside the selection column, measured the same
  /// way (a project row's content starts 6pt inside its cell).
  static let contentInset: CGFloat = 6

  var body: some View {
    VStack(spacing: 0) {
      resizeStrip
      titleBar
      content
        .padding(.horizontal, Self.columnInset)
    }
    .frame(height: max(0, clampedHeight - edgeInset))
    .frame(maxWidth: .infinity)
    .padding(.bottom, edgeInset)
    // Seed + keep the display order in sync with the registry. Membership
    // (add / remove) lands immediately; status-driven reordering is
    // debounced inside the coordinator so the list doesn't flicker as
    // agents churn through states.
    .onAppear { order.reconcile(entries: registry.entries, autoSort: autoSort) }
    .onChange(of: registry.entries) { _, newEntries in
      order.reconcile(entries: newEntries, autoSort: autoSort)
    }
    .onChange(of: autoSort) { _, newValue in
      order.autoSortChanged(to: newValue, entries: registry.entries)
    }
  }

  private var clampedHeight: Double {
    min(max(height, minHeight), maxHeight)
  }

  /// Top-edge resize strip around the section's rule. The capsule fades
  /// in only on hover, so the section reads as part of the list by
  /// default; once the user hovers, the affordance + cursor signal
  /// "drag me".
  private var resizeStrip: some View {
    ZStack {
      Divider()
        .padding(.horizontal, Self.columnInset)
      Capsule()
        .fill(.tertiary)
        .frame(width: 36, height: 4)
        .opacity(strokeHovering ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: strokeHovering)
    }
    .frame(maxWidth: .infinity)
    .frame(height: resizeStripHeight)
    .contentShape(Rectangle())
    .onHover { hovering in
      strokeHovering = hovering
      if hovering {
        NSCursor.resizeUpDown.push()
      } else {
        NSCursor.pop()
      }
    }
    .gesture(
      DragGesture(coordinateSpace: .global)
        .onChanged { value in
          let base = dragAnchor ?? height
          if dragAnchor == nil { dragAnchor = height }
          let proposed = base - value.translation.height
          height = min(max(proposed, minHeight), maxHeight)
        }
        .onEnded { _ in
          dragAnchor = nil
        }
    )
    .accessibilityIdentifier("agentState.sidebarPanel.handle")
  }

  private var titleBar: some View {
    HStack(spacing: 6) {
      Text("Agents View")
        .font(.caption)
        .foregroundStyle(.secondary)
      if showsCountChip {
        Text("(\(registry.entries.count))")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
      Spacer()
    }
    .padding(.horizontal, Self.columnInset + Self.contentInset)
    .padding(.top, 2)
    .padding(.bottom, 6)
  }

  /// Rows in the coordinator's stable display order, dropping any id whose
  /// entry has already been removed from the registry (the coordinator
  /// drops departed panes on its next `reconcile`, so this only guards the
  /// brief window before that lands).
  ///
  /// Before the first `onAppear` seed lands, `orderedIDs` is empty while the
  /// registry may already hold entries (the panel opens onto agents detected
  /// while it was closed). Fall back to a triage-sorted snapshot for that one
  /// frame so the list renders populated immediately instead of flashing the
  /// empty state.
  private var orderedRows: [(paneID: PaneID, entry: AgentStateStore.AgentEntry)] {
    if order.orderedIDs.isEmpty, !registry.entries.isEmpty {
      return SortedEntriesProvider.sorted(registry.entries)
    }
    return order.orderedIDs.compactMap { id in
      registry.entries[id].map { (paneID: id, entry: $0) }
    }
  }

  /// Agent rows, then the workflow group. With no agents the empty state
  /// keeps its place above the group so a run started from a bare shell
  /// still shows up.
  @ViewBuilder
  private var content: some View {
    if let workflowEngine, !workflowEngine.activeRuns.isEmpty {
      ScrollView {
        VStack(spacing: 0) {
          if orderedRows.isEmpty {
            emptyState.frame(minHeight: 60)
          } else {
            agentRows
          }
          WorkflowRunsSection(engine: workflowEngine, onTapRun: onTapRow)
        }
      }
      .accessibilityIdentifier("agentState.sidebarPanel.list")
    } else if orderedRows.isEmpty {
      emptyState
    } else {
      ScrollView {
        agentRows
      }
      .accessibilityIdentifier("agentState.sidebarPanel.list")
    }
  }

  @ViewBuilder
  private var agentRows: some View {
    let rows = orderedRows
    if !rows.isEmpty {
      Group {
        LazyVStack(spacing: 0) {
          ForEach(rows, id: \.paneID) { item in
            let resolved = resolveSourcePath(item.paneID)
            AgentStateRowView(
              paneID: item.paneID,
              entry: item.entry,
              projectName: resolved?.project ?? "—",
              worktreeName: resolved?.worktree ?? "—",
              projectColor: resolved?.projectColor,
              projectRemoteAuthority: resolved?.remoteHost?.displayAuthority,
              isSelected: item.paneID == focusedPaneID,
              displayMode: settingsStore.settings.general.agentsViewDisplayMode,
              paneTitle: { registry.activityText(for: item.paneID) },
              worktreePath: resolved?.worktreePath,
              remoteHost: resolved?.remoteHost,
              onTap: { onTapRow(item.paneID) },
              onHandOff: { onHandOffRow(item.paneID) },
              workflows: workflowRows(worktreePath: resolved?.remoteHost == nil ? resolved?.worktreePath : nil),
              onRunWorkflow: { onRunWorkflowRow(item.paneID, $0) }
            )
          }
        }
        // Animate row insert / remove / move when the order changes.
        // Scoped to the list so panel resize (height drag) stays
        // non-animated. Reorders arrive from the coordinator's debounced
        // re-sort and from immediate membership changes alike; reduce-motion
        // users get the reorder with no animation.
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: order.orderedIDs)
      }
    }
  }

  /// The workflows a run started from a row in `worktreePath` could use —
  /// none for a remote worktree or while workflows are off.
  private func workflowRows(worktreePath: String?) -> [(id: String, name: String, isValid: Bool)] {
    let settings = settingsStore.settings.workflows
    guard settings.isEnabled, let worktreePath else { return [] }
    return workflowCatalog.catalog(forWorktreePath: worktreePath)
      .filter { !settings.isDisabled($0.id) }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
      .map { (id: $0.id, name: $0.name, isValid: $0.isValid) }
  }

  /// Empty-state invitation when no agents are bound.
  private var emptyState: some View {
    Text("Run an agent and it'll show up here.")
      .font(.callout)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityIdentifier("agentState.sidebarPanel.emptyState")
  }
}
