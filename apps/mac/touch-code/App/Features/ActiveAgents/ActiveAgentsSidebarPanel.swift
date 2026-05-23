import SwiftUI
import TouchCodeCore

/// ActiveAgents panel anchored at the sidebar's bottom safe-area inset.
///
/// Layout (top → bottom):
/// - Capsule drag handle. Pulling it upward grows the panel; downward
///   shrinks it. The host clamps the resulting height to a sensible
///   range; this view only proposes a new value via the `height`
///   binding.
/// - Header row: `Active Agents (N)` title + close button.
/// - Divider.
/// - Scrollable list of `ActiveAgentsRowView`s ordered by
///   `SortedEntriesProvider` (`waitingForInput > finished > loading >
///   idle`, then `lastTransitionAt` desc).
///
/// The panel is the sole entry point for the ActiveAgents UI as of the
/// sidebar-relocation change — the worktree-toolbar badge that used to
/// host the popover has been removed. Tapping a row dispatches focus
/// to the corresponding pane (via the controller's `onTapRow` closure)
/// and the host normally collapses the panel afterwards.
struct ActiveAgentsSidebarPanel: View {
  let registry: AgentRegistry
  let resolveSourcePath: (PaneID) -> (project: String, worktree: String)?
  let onTapRow: (PaneID) -> Void
  let onClose: () -> Void

  /// Current panel height in points. The view writes to this binding as
  /// the user drags the handle; the host is responsible for persisting
  /// the value (typically via `@AppStorage`).
  @Binding var height: Double
  /// Lower bound below which the panel snaps closed visually but keeps
  /// the binding clamped; useful so the user can't drag it to zero.
  let minHeight: Double
  /// Upper bound — usually `0.5 * sidebarHeight`.
  let maxHeight: Double

  /// Snapshot of `height` taken at drag start. Without this anchor the
  /// drag delta would re-apply against the already-mutated height each
  /// `onChanged` tick and the resize would accelerate exponentially.
  @State private var dragAnchor: Double?

  var body: some View {
    VStack(spacing: 0) {
      handleAndHeader
      Divider()
      content
    }
    .frame(height: clampedHeight)
    .frame(maxWidth: .infinity)
    .background(Color(nsColor: .underPageBackgroundColor))
    .overlay(alignment: .top) { Divider() }
  }

  /// Effective height that respects the host-supplied bounds. Drag
  /// callbacks already clamp into `height`, but consumers may set
  /// `height` outside the range when the host's geometry changes
  /// (e.g. window resize shrinks the sidebar). This clamp ensures the
  /// rendered panel never exceeds the new bounds even before the next
  /// drag corrects the binding.
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
      HStack(spacing: 8) {
        Text("Active Agents (\(registry.entries.count))")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Button(action: onClose) {
          Image(systemName: "xmark")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Close active agents panel")
        .accessibilityLabel("Close active agents panel")
      }
      .padding(.horizontal, 10)
      .padding(.bottom, 6)
    }
    .contentShape(Rectangle())
    .gesture(
      DragGesture(coordinateSpace: .global)
        .onChanged { value in
          let base = dragAnchor ?? height
          if dragAnchor == nil { dragAnchor = height }
          // Drag UP = negative y translation = panel grows.
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
