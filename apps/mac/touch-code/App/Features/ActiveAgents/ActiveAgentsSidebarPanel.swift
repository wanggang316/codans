import AppKit
import SwiftUI
import TouchCodeCore

/// ActiveAgents panel anchored at the sidebar's bottom safe-area inset.
///
/// Visual brief (per design pass):
/// - Rounded top corners (8pt) — the panel reads as a card pinned to
///   the sidebar floor.
/// - Background uses `controlBackgroundColor` so it adapts naturally
///   to the active appearance (a light grey in light mode and a soft
///   dark grey in dark mode — the inverse-of-content fill macOS uses
///   for "tray over chrome" surfaces).
/// - Capsule drag handle at the top. Hovering it swaps the cursor to
///   `resizeUpDown` so the affordance is discoverable without label.
///
/// Layout (top → bottom):
/// - Header bar — drag handle, "Agents View" title, optional count chip
///   (only shown when there are more than four entries; the panel is
///   primarily a focus pivot, not a count display), and a close button.
/// - Divider.
/// - Scrollable list of `ActiveAgentsRowView`s ordered by
///   `SortedEntriesProvider` (`waitingForInput > finished > loading >
///   idle`, then `lastTransitionAt` desc).
///
/// Tapping a row dispatches focus to the corresponding pane (via the
/// controller's `onTapRow` closure). The panel intentionally stays open
/// after a row tap so the user can fan-jump between agents.
struct ActiveAgentsSidebarPanel: View {
  let registry: AgentRegistry
  let resolveSourcePath: (PaneID) -> (project: String, worktree: String)?
  let onTapRow: (PaneID) -> Void
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
  /// Whether the cursor is currently over the drag handle. Used to push
  /// / pop a resize-up-down cursor without spamming the cursor stack.
  @State private var handleHovering = false

  /// Show the count chip only once the panel holds more than four
  /// agents — for the typical 1-4 entry case the title alone reads
  /// cleaner.
  private var showsCountChip: Bool {
    registry.entries.count > 4
  }

  var body: some View {
    VStack(spacing: 0) {
      handleAndHeader
      Divider()
      content
    }
    .frame(height: clampedHeight)
    .frame(maxWidth: .infinity)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(
      UnevenRoundedRectangle(
        topLeadingRadius: 8,
        bottomLeadingRadius: 0,
        bottomTrailingRadius: 0,
        topTrailingRadius: 8,
        style: .continuous
      )
    )
    .overlay(alignment: .top) { Divider() }
  }

  private var clampedHeight: Double {
    min(max(height, minHeight), maxHeight)
  }

  private var handleAndHeader: some View {
    VStack(spacing: 0) {
      Capsule()
        .fill(.tertiary)
        .frame(width: 36, height: 4)
        .padding(.top, 6)
        .padding(.bottom, 4)
      HStack(spacing: 6) {
        Text("Agents View")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        if showsCountChip {
          Text("(\(registry.entries.count))")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
        Spacer()
        Button(action: onClose) {
          Image(systemName: "xmark")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Close agents view")
        .accessibilityLabel("Close agents view")
      }
      .padding(.horizontal, 10)
      .padding(.bottom, 6)
    }
    .contentShape(Rectangle())
    .onHover { hovering in
      handleHovering = hovering
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
    .accessibilityIdentifier("activeAgents.sidebarPanel.handle")
  }

  private var content: some View {
    let rows = SortedEntriesProvider.sorted(registry.entries)
    return ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(Array(rows.enumerated()), id: \.element.paneID) { idx, item in
          let resolved = resolveSourcePath(item.paneID)
          ActiveAgentsRowView(
            paneID: item.paneID,
            entry: item.entry,
            projectName: resolved?.project ?? "—",
            worktreeName: resolved?.worktree ?? "—",
            onTap: { onTapRow(item.paneID) }
          )
          if idx < rows.count - 1 {
            Divider().padding(.leading, 44)
          }
        }
      }
    }
    .accessibilityIdentifier("activeAgents.sidebarPanel.list")
  }
}
