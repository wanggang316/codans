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
    // `registry.entries` is keyed by `PaneID`; the badge ViewModel and
    // the leading-kind helper both operate on a value-only sequence, so
    // the dictionary is flattened once per redraw. Entry count is
    // bounded by the number of bound agent panes (~tens), so the
    // allocation is negligible.
    let entries = Array(registry.entries.values)
    let viewModel = ActiveAgentsBadgeViewModel(entries: entries)
    if let headline = viewModel.headline {
      badge(
        headline: headline,
        pulse: viewModel.pulse,
        leadingKind: Self.leadingKind(in: entries)
      )
    } else {
      EmptyView()
    }
  }

  @ViewBuilder
  private func badge(headline: String, pulse: Bool, leadingKind: AgentKind?) -> some View {
    let pulseActive = pulse && !reduceMotion
    Button(action: handleClick) {
      HStack(spacing: 6) {
        leadingIcon(for: leadingKind)
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

  /// Leading 14pt logo — drives the badge's visual identity.
  ///
  /// When the badge represents a single kind (every entry shares one
  /// `AgentKind`), we show that kind's logo via `AgentLogoView` so the
  /// status-bar mark matches the popover rows. When multiple kinds are
  /// active (e.g. Claude Code + Codex both running), no single logo
  /// would be honest, so we fall back to a kind-agnostic SF Symbol
  /// (`brain.head.profile`) — the popover is the place to disambiguate.
  ///
  /// Always `accessibilityHidden(true)`: the badge a11y label already
  /// spells out the headline.
  @ViewBuilder
  private func leadingIcon(for kind: AgentKind?) -> some View {
    if let kind {
      AgentLogoView(kind: kind, size: 14)
    } else {
      Image(systemName: "brain.head.profile")
        .resizable()
        .scaledToFit()
        .frame(width: 14, height: 14)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
  }

  /// Returns the single `AgentKind` shared by every entry, or `nil`
  /// when the snapshot is empty or mixes kinds. The badge uses this to
  /// decide whether to show a kind-specific logo or a kind-agnostic
  /// fallback — see `leadingIcon(for:)`.
  private static func leadingKind(in entries: [AgentRegistry.AgentEntry]) -> AgentKind? {
    guard let first = entries.first else { return nil }
    return entries.allSatisfy { $0.kind == first.kind } ? first.kind : nil
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
