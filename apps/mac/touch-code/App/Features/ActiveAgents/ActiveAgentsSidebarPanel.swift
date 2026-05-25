import AppKit
import SwiftUI
import TouchCodeCore

/// ActiveAgents panel anchored at the sidebar's bottom safe-area inset.
///
/// Visual brief (per design pass):
/// - Rounded top corners (10pt) — system glass background drawn inside
///   the rounded shape. The background is a bridged
///   `NSVisualEffectView` (`.hudWindow` material with `.behindWindow`
///   blending) rather than a SwiftUI `Material`, so the panel actually
///   samples the desktop / window beneath it the way native macOS
///   chrome (HUD panels, popovers, sidebars) does. SwiftUI's
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
/// - Scrollable list of `ActiveAgentsRowView`s ordered by
///   `SortedEntriesProvider`.
///
/// Tapping a row dispatches focus to the corresponding pane (via the
/// controller's `onTapRow` closure). The panel intentionally stays open
/// after a row tap so the user can fan-jump between agents.
struct ActiveAgentsSidebarPanel: View {
  let registry: AgentRegistry
  let resolveSourcePath: (PaneID) -> (project: String, worktree: String)?
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
      VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
        .clipShape(shape)
    )
    .overlay(
      shape.stroke(Color.primary.opacity(0.08), lineWidth: 1)
    )
    .clipShape(shape)
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
    .accessibilityIdentifier("activeAgents.sidebarPanel.handle")
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

  @ViewBuilder
  private var content: some View {
    let rows = SortedEntriesProvider.sorted(registry.entries)
    if rows.isEmpty {
      emptyState
    } else {
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(rows, id: \.paneID) { item in
            let resolved = resolveSourcePath(item.paneID)
            ActiveAgentsRowView(
              paneID: item.paneID,
              entry: item.entry,
              projectName: resolved?.project ?? "—",
              worktreeName: resolved?.worktree ?? "—",
              isSelected: item.paneID == focusedPaneID,
              onTap: { onTapRow(item.paneID) }
            )
          }
        }
      }
      .accessibilityIdentifier("activeAgents.sidebarPanel.list")
    }
  }

  /// Empty-state placeholder when no agents are bound — minimal: a
  /// single icon stacked over a one-line invitation.
  private var emptyState: some View {
    VStack(spacing: 8) {
      Image(systemName: "sparkles")
        .font(.system(size: 14, weight: .regular))
        .foregroundStyle(.tertiary)
      Text("Run an agent and it'll show up here.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("activeAgents.sidebarPanel.emptyState")
  }
}

/// SwiftUI bridge around `NSVisualEffectView` so the panel can use the
/// real system glass materials (HUD, sidebar, popover, ...) instead of
/// SwiftUI's `Material` shim. The shim is layer-bound and cannot reach
/// past the hosting window; the real `NSVisualEffectView` with
/// `.behindWindow` blending samples the desktop / windows beneath so
/// the panel matches the native macOS chrome look.
private struct VisualEffectBackground: NSViewRepresentable {
  let material: NSVisualEffectView.Material
  let blendingMode: NSVisualEffectView.BlendingMode

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = material
    view.blendingMode = blendingMode
    // `.active` keeps the blur live even when the host window is not
    // key — without this the panel goes flat / opaque on focus loss
    // because the default `.followsWindowActiveState` would treat
    // every background window as inactive.
    view.state = .active
    view.isEmphasized = false
    view.autoresizingMask = [.width, .height]
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {
    view.material = material
    view.blendingMode = blendingMode
  }
}
