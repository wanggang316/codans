import SwiftUI
import TouchCodeCore

/// Status-bar entry that surfaces the ActiveAgents headline next to the
/// inbox bell. Wires the `AgentRegistry` snapshot into a
/// `ActiveAgentsBadgeViewModel` for the one-line summary, hosts the
/// `ActiveAgentsPopoverView` via SwiftUI `.popover(isPresented:)`, and
/// drives the open/close hover bridge through a pure `HoverIntent`
/// value type.
///
/// Hidden entirely when `viewModel.headline == nil` (no bound agents)
/// — the bell + worktree label collapse together without a placeholder
/// frame.
///
/// Accessibility identifiers per `docs/user-tests/active-agents-view.md`:
/// - `activeAgents.badge` on the badge itself.
/// - `activeAgents.badge.pulse` trait — present only when
///   `viewModel.pulse == true` AND `accessibilityReduceMotion` is off.
///
/// Pulse animation is a simple opacity 1.0 ↔ 0.6 ease-in-out 1.2s
/// repeating-forever cycle on the leading icon, matching the busy
/// glyph cadence in `HierarchySidebarView`. Suppressed when
/// `accessibilityReduceMotion` is true (and the pulse a11y trait is
/// suppressed in lockstep).
struct ActiveAgentsBadgeView: View {
  /// Read-only handle on the registry. SwiftUI re-renders on every
  /// `entries` mutation via `@Observable` change tracking.
  let registry: AgentRegistry
  /// Catalog walker injected by the host — resolves a `PaneID` to its
  /// `(projectName, worktreeName)` for the popover rows. Threaded
  /// through so the view itself stays free of `HierarchyManager` /
  /// catalog imports.
  let resolveSourcePath: (PaneID) -> (project: String, worktree: String)?
  /// Click handler for popover rows. The host (RootFeature) walks the
  /// catalog and dispatches `HierarchyClient.focusPane` plus the
  /// selection chain.
  let onTapRow: (PaneID) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var intent = HoverIntent()
  @State private var pulseAnimating = false
  /// Schedules `intent.tick(at:)` calls. Re-created whenever
  /// `intent.pendingDeadline` changes so a fresh deadline always
  /// supersedes a stale one. `@State` so SwiftUI keeps the handle
  /// across re-renders; the modifier below cancels + replaces it on
  /// each `.onChange`.
  @State private var pendingTask: Task<Void, Never>?

  var body: some View {
    let viewModel = ActiveAgentsBadgeViewModel(entries: registry.entries)
    if let headline = viewModel.headline {
      badge(headline: headline, pulse: viewModel.pulse)
    } else {
      EmptyView()
    }
  }

  @ViewBuilder
  private func badge(headline: String, pulse: Bool) -> some View {
    let pulseActive = pulse && !reduceMotion
    Button(action: handleClick) {
      HStack(spacing: 6) {
        leadingIcon
          // Drive opacity off `pulseAnimating`, which is toggled from
          // `.onAppear` / `.onChange(of: pulseActive)` so the
          // `.repeatForever` animation actually runs both ways. Without
          // the toggle the value stays put and the animation never
          // visibly cycles.
          .opacity(pulseActive ? (pulseAnimating ? 0.6 : 1.0) : 1.0)
          .animation(
            pulseActive
              ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
              : .default,
            value: pulseAnimating
          )
        Text(headline)
          .font(.callout)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover(perform: handleBadgeHover(_:))
    .accessibilityIdentifier("activeAgents.badge")
    .accessibilityLabel(headline)
    .accessibilityHint("Open active agents popover")
    // Pulse trait identifier — exposed as a *sibling* accessibility
    // element via `.overlay`, NOT a `.combine` child. SwiftUI's
    // `.accessibilityElement(children: .combine)` collapses descendant
    // identifiers into the parent's, so a `.background` child holding
    // `activeAgents.badge.pulse` becomes unreachable to XCUI probes
    // (UT-AA-B-008). An overlay sibling with its own
    // `.accessibilityElement()` registers as a discrete queryable
    // element, leaving the badge's primary `activeAgents.badge`
    // identifier intact. The overlay is gated on `pulseActive`
    // (`pulse && !reduceMotion`) so the pulse identifier appears in
    // lockstep with the animation per spec.
    .overlay(alignment: .topLeading) {
      if pulseActive {
        Color.clear
          .frame(width: 1, height: 1)
          .accessibilityElement()
          .accessibilityIdentifier("activeAgents.badge.pulse")
          .accessibilityHidden(false)
      }
    }
    .popover(isPresented: popoverBinding, arrowEdge: .top) {
      ActiveAgentsPopoverView(
        entries: registry.entries,
        resolveSourcePath: resolveSourcePath,
        onTapRow: { paneID in
          intent.dismiss()
          schedulePendingTick()
          onTapRow(paneID)
        }
      )
      .onHover(perform: handlePopoverHover(_:))
    }
    .onAppear {
      // Kick the toggle once on appear so the `.repeatForever`
      // animation has a value change to chain from. `pulseActive` is
      // re-evaluated by the framework on every redraw, so a
      // subsequent `pulse` flip naturally takes effect without an
      // explicit `.onChange` trampoline.
      if pulseActive { pulseAnimating = true }
    }
    .onChange(of: pulseActive) { _, newValue in
      pulseAnimating = newValue
    }
    .onChange(of: intent.pendingDeadline) { _, _ in
      schedulePendingTick()
    }
    .onDisappear {
      pendingTask?.cancel()
      pendingTask = nil
    }
  }

  /// Binding bridges `intent.desiredOpen` into SwiftUI's popover
  /// presentation API. Writes route through `intent.dismiss()` so the
  /// hover bridge stays consistent when the system closes the popover
  /// (e.g. outside-click).
  private var popoverBinding: Binding<Bool> {
    Binding(
      get: { intent.desiredOpen },
      set: { newValue in
        if !newValue && intent.desiredOpen {
          intent.dismiss()
          schedulePendingTick()
        }
      }
    )
  }

  private var leadingIcon: some View {
    Image(systemName: "brain.head.profile")
      .resizable()
      .scaledToFit()
      .frame(width: 14, height: 14)
      .foregroundStyle(.secondary)
      .accessibilityHidden(true)
  }

  private func handleClick() {
    intent.clickBadge()
    schedulePendingTick()
  }

  private func handleBadgeHover(_ entered: Bool) {
    if entered {
      intent.enterBadge(at: Date())
    } else {
      intent.leaveBadge(at: Date())
    }
    schedulePendingTick()
  }

  private func handlePopoverHover(_ entered: Bool) {
    if entered {
      intent.enterPopover(at: Date())
    } else {
      intent.leavePopover(at: Date())
    }
    schedulePendingTick()
  }

  /// Cancels any in-flight tick Task and arms a new one at the current
  /// pending deadline (if any). `Task.sleep` resolution on macOS is
  /// well under 50 ms so the 150 / 250 ms windows are comfortable.
  private func schedulePendingTick() {
    pendingTask?.cancel()
    guard let deadline = intent.pendingDeadline else {
      pendingTask = nil
      return
    }
    let interval = max(0, deadline.timeIntervalSinceNow)
    pendingTask = Task { @MainActor in
      let nanos = UInt64(interval * 1_000_000_000)
      try? await Task.sleep(nanoseconds: nanos)
      if Task.isCancelled { return }
      intent.tick(at: Date())
      // A tick may not have committed yet (debounced by the deadline
      // calculation), so re-arm if a fresh pending is still present.
      if intent.pendingDeadline != nil {
        schedulePendingTick()
      }
    }
  }
}
