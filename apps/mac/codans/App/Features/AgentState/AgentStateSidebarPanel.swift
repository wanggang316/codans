import AppKit
import CodansCore
import SwiftUI

/// AgentState panel anchored at the sidebar's bottom safe-area inset.
///
/// Visual brief (per design pass):
/// - Rounded top corners (10pt) — system glass background drawn inside
///   the rounded shape. The background is a bridged
///   `NSVisualEffectView` (`.popover` material with `.behindWindow`
///   blending) rather than a SwiftUI `Material`, so the panel actually
///   samples the desktop / window beneath it the way native macOS
///   chrome (popovers, HUD panels, sidebars) does. SwiftUI's
///   `Material` is a layer-based blur that cannot reach past the
///   hosting window.
/// - Header carries no chrome by default: the title sits on top of the
///   panel directly. A capsule resize handle fades in only when the
///   cursor enters a narrow strip at the very top (16pt tall) — that
///   strip is also the sole drag-to-resize hit region. Cursor swaps to
///   `resizeUpDown` on hover.
/// - The close button has been removed; the footer toggle is the only
///   open/close affordance.
///
/// Layout (top → bottom):
/// - Resize strip (16pt; capsule fades in on hover).
/// - Title row: "Agents View" + optional `(N)` count chip when N > 4.
/// - Divider.
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
      project: String, worktree: String, projectColor: ProjectColor?, remoteAuthority: String?
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
  private let resizeStripHeight: CGFloat = 8

  var body: some View {
    let shape = UnevenRoundedRectangle(
      topLeadingRadius: 10,
      bottomLeadingRadius: 0,
      bottomTrailingRadius: 0,
      topTrailingRadius: 10,
      style: .continuous
    )
    return VStack(spacing: 0) {
      resizeStrip
      titleBar
      content
    }
    .frame(height: clampedHeight)
    .frame(maxWidth: .infinity)
    .background(
      VisualEffectBackground(material: .popover, blendingMode: .behindWindow)
        .clipShape(shape)
    )
    .overlay(
      shape.stroke(Color.primary.opacity(0.08), lineWidth: 1)
    )
    .clipShape(shape)
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

  /// Top-edge resize strip. The capsule fades in only on hover so the
  /// panel reads as a clean card by default; once the user hovers, the
  /// affordance + cursor signal "drag me".
  private var resizeStrip: some View {
    ZStack {
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
    .padding(.horizontal, 10)
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

  @ViewBuilder
  private var content: some View {
    let rows = orderedRows
    if rows.isEmpty {
      emptyState
    } else {
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(rows, id: \.paneID) { item in
            let resolved = resolveSourcePath(item.paneID)
            AgentStateRowView(
              paneID: item.paneID,
              entry: item.entry,
              projectName: resolved?.project ?? "—",
              worktreeName: resolved?.worktree ?? "—",
              projectColor: resolved?.projectColor,
              projectRemoteAuthority: resolved?.remoteAuthority,
              isSelected: item.paneID == focusedPaneID,
              displayMode: settingsStore.settings.general.agentsViewDisplayMode,
              paneTitle: { registry.title(for: item.paneID) },
              onTap: { onTapRow(item.paneID) }
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
      .accessibilityIdentifier("agentState.sidebarPanel.list")
    }
  }

  /// Empty-state placeholder when no agents are bound — minimal: a
  /// single icon stacked over a one-line invitation.
  private var emptyState: some View {
    VStack(spacing: 8) {
      Image(systemName: "sparkles")
        .font(.system(size: 14, weight: .regular))
        .foregroundStyle(.tertiary)
        // Decorative icon — the adjacent Text carries the meaning, so hide
        // it from assistive tech (and satisfy `accessibility_label_for_image`).
        .accessibilityHidden(true)
      Text("Run an agent and it'll show up here.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("agentState.sidebarPanel.emptyState")
  }
}
