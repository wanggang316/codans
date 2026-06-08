import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Horizontal row of tab chips. Kept thin so feature dispatch stays out of
/// the chip views — select / close / rename / reorder callbacks come from
/// the parent.
///
/// Chips sit flush against one another (`spacing: 0`) and a thin vertical
/// separator is stamped between any two adjacent non-active chips. The
/// separator is suppressed on either side of the active chip so its
/// accent underline visually carries the boundary.
///
/// Reorder: an in-app `DragGesture` drives a live preview. While dragging,
/// a local `orderIDs` snapshot is mutated once the dragged chip overlaps a
/// neighbor by 50% (the slot boundary), so siblings reflow under a
/// `spring(response: 0.3, dampingFraction: 0.85)` (macOS Safari-style) —
/// the dragged chip leaves a transparent gap in the row while a lifted
/// copy follows the cursor in an overlay. The final permutation is
/// dispatched once via `onReorder` on drop (the catalog mutation stays a
/// single absolute-order commit, matching the exec-plan's D3).
struct TabBarRowView: View {
  let tabs: [TouchCodeCore.Tab]
  let activeTabID: TabID?
  /// Per-tab dirty lookup. Typically backed by
  /// `HierarchyManager.tabIsDirty(_:)` so SwiftUI observation re-renders
  /// the row when a pane's running state flips. Default is a no-op
  /// returning `false` for callers / previews that do not need dirty
  /// coverage.
  var isDirty: (TabID) -> Bool = { _ in false }
  let onSelect: (TabID) -> Void
  let onClose: (TabID) -> Void
  let onMiddleClick: (TabID) -> Void
  let onCloseOthers: (TabID) -> Void
  let onCloseToRight: (TabID) -> Void
  let onCloseAll: () -> Void
  let onRenameRequested: (TabID) -> Void
  let onChangeColorRequested: (TabID) -> Void
  let onChangeIconRequested: (TabID) -> Void
  let onCopyID: (TabID) -> Void
  let onReorder: @MainActor @Sendable ([TabID]) -> Void
  /// Fires whenever a chip resolves a non-empty live title (OSC tabTitle
  /// / title / pwd basename). The parent persists this onto the tab so
  /// the chip can fall back to it across app launches before the
  /// surface respawns. Default no-op keeps previews / call sites that
  /// don't care about cross-launch titles compiling without changes.
  var onCacheLiveTitle: (TabID, String) -> Void = { _, _ in }

  @Environment(CommandKeyObserver.self) private var commandKeyObserver
  @Environment(\.resolvedShortcuts) private var resolvedShortcuts

  /// Name of the row's coordinate space — drag location, chip frames, and
  /// the floating-copy position are all measured against it so they share
  /// one origin (and scroll together inside `TabBarOverflowScroll`).
  private static let rowSpace = "TabBarReorderRow"

  // MARK: Drag-reorder state

  /// Working order during a drag. Mutated locally as the dragged chip
  /// crosses neighbor midpoints so siblings reflow live; the final
  /// permutation ships once via `onReorder` on drop. Held as IDs (not
  /// `Tab` values) so chip content — title / color / dirty — always reads
  /// fresh from the `tabs` prop while only the order is owned locally.
  @State private var orderIDs: [TabID] = []
  /// The chip currently being dragged, or nil when idle.
  @State private var draggingID: TabID?
  /// Live cursor X in the row space, driving the floating chip.
  @State private var dragCursorX: CGFloat = 0
  /// Per-chip layout rects (row space) reported via `ChipFrameKey`. Read
  /// for neighbor-midpoint hit testing and to size the floating copy.
  @State private var chipFrames: [TabID: CGRect] = [:]

  /// Render order: during a drag the locally-mutated `orderIDs`; otherwise
  /// the `tabs` prop verbatim. Content is always resolved from the current
  /// `tabs`, so a title / color push mid-idle still shows through.
  private var renderedTabs: [TouchCodeCore.Tab] {
    let byID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let ordered = orderIDs.compactMap { byID[$0] }
    let known = Set(orderIDs)
    // New tabs not yet folded into `orderIDs` (added between resyncs) tail
    // the row until the next idle sync picks them up.
    return ordered + tabs.filter { !known.contains($0.id) }
  }

  var body: some View {
    let rendered = renderedTabs
    HStack(spacing: 0) {
      ForEach(Array(rendered.enumerated()), id: \.element.id) { index, tab in
        chipView(for: tab, index: index, count: rendered.count)
          .background(frameReporter(for: tab.id))
          // The dragged chip goes transparent in-flow, leaving a gap that
          // the spring reflows; a lifted copy follows the cursor (overlay).
          .opacity(draggingID == tab.id ? 0 : 1)
          .zIndex(draggingID == tab.id ? 1 : 0)
          .simultaneousGesture(reorderGesture(for: tab))
        if showsDivider(at: index, in: rendered) {
          Rectangle()
            .fill(TabBarColors.divider)
            .frame(
              width: TabBarMetrics.dividerWidth,
              height: TabBarMetrics.dividerHeight
            )
        }
      }
    }
    .coordinateSpace(name: Self.rowSpace)
    .onPreferenceChange(ChipFrameKey.self) { chipFrames = $0 }
    .overlay(alignment: .topLeading) { floatingChip(in: rendered) }
    .animation(.spring(response: 0.3, dampingFraction: 0.85), value: rendered.map(\.id))
    .onAppear { orderIDs = tabs.map(\.id) }
    .onChange(of: tabs.map(\.id)) { _, latest in
      // Resync the local order whenever the catalog changes while idle —
      // covers external add / close / reorder. Frozen during a drag so the
      // live preview owns the order until drop.
      if draggingID == nil { orderIDs = latest }
    }
  }

  /// One chip with its full callback set. Shared by the in-flow row and the
  /// floating drag copy so both stay pixel-identical.
  @ViewBuilder
  private func chipView(for tab: TouchCodeCore.Tab, index: Int, count: Int) -> some View {
    ResolvingTabChipView(
      tab: tab,
      isActive: activeTabID == tab.id,
      isDirty: isDirty(tab.id),
      isOnlyTab: count <= 1,
      isLastTab: index == count - 1,
      chordHint: chordHint(for: index + 1),
      onSelect: { onSelect(tab.id) },
      onClose: { onClose(tab.id) },
      onMiddleClick: { onMiddleClick(tab.id) },
      onCloseOthers: { onCloseOthers(tab.id) },
      onCloseToRight: { onCloseToRight(tab.id) },
      onCloseAll: onCloseAll,
      onRenameRequested: { onRenameRequested(tab.id) },
      onChangeColor: { onChangeColorRequested(tab.id) },
      onChangeIcon: { onChangeIconRequested(tab.id) },
      onCopyID: { onCopyID(tab.id) },
      tabColor: tab.color,
      icon: tab.resolvedIcon(autoFallback: nil),
      onCacheLiveTitle: { title in onCacheLiveTitle(tab.id, title) }
    )
    .id(tab.id)
  }

  /// Transparent probe stamped behind each chip; publishes the chip's
  /// row-space rect for neighbor-midpoint hit testing and floating-copy
  /// sizing.
  private func frameReporter(for id: TabID) -> some View {
    GeometryReader { proxy in
      Color.clear.preference(
        key: ChipFrameKey.self,
        value: [id: proxy.frame(in: .named(Self.rowSpace))]
      )
    }
  }

  /// The lifted chip that tracks the cursor during a drag, rendered above
  /// the row. Non-interactive — the gesture lives on the in-flow chip,
  /// which continues to receive drag events even at zero opacity.
  @ViewBuilder
  private func floatingChip(in rendered: [TouchCodeCore.Tab]) -> some View {
    if let id = draggingID,
      let index = rendered.firstIndex(where: { $0.id == id }),
      let frame = chipFrames[id]
    {
      chipView(for: rendered[index], index: index, count: rendered.count)
        .frame(width: frame.width, height: TabBarMetrics.chipHeight)
        // Opaque base so the lifted copy occludes the chips it floats
        // over — the chip's own idle fill is `.clear`, which would let
        // their titles bleed through and overlap.
        .background(TabBarColors.draggingBackground)
        .scaleEffect(1.03)
        .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
        .allowsHitTesting(false)
        .position(x: dragCursorX, y: TabBarMetrics.chipHeight / 2)
        .zIndex(10)
    }
  }

  private func reorderGesture(for tab: TouchCodeCore.Tab) -> some Gesture {
    DragGesture(
      minimumDistance: TabBarMetrics.reorderMovementThreshold,
      coordinateSpace: .named(Self.rowSpace)
    )
    .onChanged { value in
      if draggingID != tab.id {
        // First tick of a new drag — snapshot the current order as the
        // mutable baseline, then claim this chip as the dragged one.
        orderIDs = tabs.map(\.id)
        draggingID = tab.id
      }
      dragCursorX = value.location.x
      updateOrder()
    }
    .onEnded { _ in
      let final = orderIDs
      draggingID = nil
      dragCursorX = 0
      // Single absolute-order commit; skip the no-op when nothing moved.
      if final != tabs.map(\.id) {
        onReorder(final)
      }
    }
  }

  /// Steps the dragged chip past an adjacent neighbor once it overlaps that
  /// neighbor by 50%, animating the sibling reflow (macOS Safari timing).
  ///
  /// The threshold is the midpoint between the dragged chip's own slot
  /// center and the neighbor's slot center — i.e. the boundary between the
  /// two slots — not the neighbor's center. Because the dragged chip leaves
  /// a full-width gap, its center has to travel only half a chip to reach
  /// that boundary, which is exactly 50% overlap. Using the slot boundary
  /// (rather than the neighbor's near edge) keeps it oscillation-free: after
  /// a swap the two slots exchange symmetrically, so the boundary stays put
  /// even mid-animation and the cursor can't immediately trip the reverse.
  /// One step per event is enough — `onChanged` fires densely.
  private func updateOrder() {
    guard let id = draggingID,
      let current = orderIDs.firstIndex(of: id),
      let dragged = chipFrames[id]
    else { return }
    var target = current
    if current < orderIDs.count - 1,
      let next = chipFrames[orderIDs[current + 1]],
      dragCursorX > (dragged.midX + next.midX) / 2
    {
      target = current + 1
    } else if current > 0,
      let prev = chipFrames[orderIDs[current - 1]],
      dragCursorX < (dragged.midX + prev.midX) / 2
    {
      target = current - 1
    }
    guard target != current else { return }
    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
      let moved = orderIDs.remove(at: current)
      orderIDs.insert(moved, at: target)
    }
  }

  /// Suppresses the separators flanking the drag gap so the empty slot
  /// reads clean while the dragged chip floats; otherwise draws between
  /// every adjacent pair.
  private func showsDivider(at index: Int, in rendered: [TouchCodeCore.Tab]) -> Bool {
    guard index < rendered.count - 1 else { return false }
    if draggingID == rendered[index].id || draggingID == rendered[index + 1].id {
      return false
    }
    return true
  }

  /// Resolves the registry chord (`switchToTabN`) to a display string while ⌘ is held.
  /// Returned to `TabChipView.chordHint` so the chord renders inside the chip's trailing
  /// slot (replacing the close button while held). Beyond ten tabs the schema has no
  /// chord; returns nil and the chip keeps its close-button slot.
  private func chordHint(for tabIndex: Int) -> String? {
    guard commandKeyObserver.isCommandHeld,
      let id = CommandID.switchToTab(index: tabIndex),
      let resolved = resolvedShortcuts[id], resolved.isEnabled,
      let binding = resolved.binding
    else { return nil }
    return ShortcutDisplay.chord(for: binding)
  }
}

/// Per-chip wrapper that resolves the live display title and forwards
/// everything else to `TabChipView`. The view exists for one reason:
/// `SurfaceInfo` is `@Observable`, and SwiftUI registers an observer at
/// the body that reads its properties. By making each chip its own view
/// and reading `info.title` here, the observation lives on this view's
/// body — so an OSC push only invalidates the affected chip rather than
/// being dropped because the access happened inside a `ForEach` builder
/// of an upstream view that didn't establish its own tracking context.
///
/// Title priority:
/// 1. `tab.name` (manual rename — sticky, ignores OSC).
/// 2. focused pane's `info.tabTitle` (OSC 2 / set_tab_title).
/// 3. focused pane's `info.title` (OSC 0 / set_title).
/// 4. focused pane's `info.pwd` basename.
/// 5. `tab.cachedDisplayTitle` (last live value persisted to the catalog).
/// 6. focused (or first) pane's `workingDirectory` basename — always
///    present on the persisted catalog, so even cold-launched chips
///    have a meaningful label before the surface respawns.
/// 7. Empty string as a last-resort defensive default.
///
/// The cache exists because surfaces are spawned lazily — on cold launch
/// inactive tabs have no live `SurfaceInfo` yet, so without the cache
/// every previously-named tab would briefly read as the workingDirectory
/// basename until the shell re-emits an OSC title (and stay there, for
/// tabs the user does not re-open during the session).
private struct ResolvingTabChipView: View {
  let tab: TouchCodeCore.Tab
  let isActive: Bool
  let isDirty: Bool
  let isOnlyTab: Bool
  let isLastTab: Bool
  /// Forwarded to `TabChipView.chordHint`. Resolved at the row level so this view stays
  /// out of the shortcut-environment plumbing.
  let chordHint: String?
  let onSelect: () -> Void
  let onClose: () -> Void
  let onMiddleClick: () -> Void
  let onCloseOthers: () -> Void
  let onCloseToRight: () -> Void
  let onCloseAll: () -> Void
  let onRenameRequested: () -> Void
  let onChangeColor: () -> Void
  let onChangeIcon: () -> Void
  let onCopyID: () -> Void
  let tabColor: TabColor?
  let icon: String?
  let onCacheLiveTitle: (String) -> Void

  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(RollupIndexProvider.self) private var notificationRollup: RollupIndexProvider?
  @Environment(SettingsStore.self) private var settingsStore: SettingsStore?
  @Dependency(TerminalClient.self) private var terminalClient

  var body: some View {
    let live = liveResolvedTitle
    TabChipView(
      title: resolvedTitle(live: live),
      isActive: isActive,
      isDirty: isDirty,
      isOnlyTab: isOnlyTab,
      isLastTab: isLastTab,
      hasUnreadNotification: notificationRollup?.current.unreadTabs.contains(tab.id) == true
        && settingsStore?.settings.notifications.tabBellEnabled != false,
      chordHint: chordHint,
      onSelect: onSelect,
      onClose: onClose,
      onMiddleClick: onMiddleClick,
      onCloseOthers: onCloseOthers,
      onCloseToRight: onCloseToRight,
      onCloseAll: onCloseAll,
      onRenameRequested: onRenameRequested,
      onChangeColor: onChangeColor,
      onChangeIcon: onChangeIcon,
      onCopyID: onCopyID,
      tabColor: tabColor,
      icon: icon
    )
    .onChange(of: live, initial: true) { _, newLive in
      // Only persist once the surface has actually produced a live
      // title — never overwrite the cache with `nil` (e.g. surface not
      // yet spawned on cold launch), otherwise a freshly-loaded catalog
      // would clobber its own cache before the shell pushes anything.
      guard let newLive, newLive != tab.cachedDisplayTitle else { return }
      onCacheLiveTitle(newLive)
    }
  }

  /// Title sourced strictly from the live focused-pane `SurfaceInfo`.
  /// Returns `nil` when the surface hasn't been spawned yet or the shell
  /// hasn't pushed any of OSC 2 / OSC 0 / OSC 7 — letting the caller
  /// decide whether to fall back to the persisted cache or "Tab N".
  private var liveResolvedTitle: String? {
    let paneID = hierarchyManager.lastFocusedPane(in: tab.id) ?? tab.panes.first?.id
    guard let paneID, let surface = terminalClient.surface(paneID) else { return nil }
    let info = surface.info
    // Read all observable properties up-front so SwiftUI registers
    // observation on every one — `if let` short-circuits would skip
    // subsequent reads and miss future updates on those keypaths.
    let tabTitleValue = info.tabTitle
    let titleValue = info.title
    let pwdValue = info.pwd
    if let t = tabTitleValue, !t.isEmpty { return t }
    if let t = titleValue, !t.isEmpty { return t }
    if let pwd = pwdValue {
      let basename = (pwd as NSString).lastPathComponent
      if !basename.isEmpty { return basename }
    }
    return nil
  }

  private func resolvedTitle(live: String?) -> String {
    if let name = tab.name, !name.isEmpty { return name }
    if let live { return live }
    if let cached = tab.cachedDisplayTitle, !cached.isEmpty { return cached }
    let pane =
      tab.panes.first { $0.id == hierarchyManager.lastFocusedPane(in: tab.id) }
      ?? tab.panes.first
    if let pane {
      let basename = (pane.workingDirectory as NSString).lastPathComponent
      if !basename.isEmpty { return basename }
    }
    return ""
  }
}

/// Collects each chip's row-space frame keyed by `TabID`. Drives the
/// drag math: neighbor midpoints decide when the dragged chip steps past a
/// sibling, and the dragged chip's frame sizes the floating copy.
private struct ChipFrameKey: PreferenceKey {
  static let defaultValue: [TabID: CGRect] = [:]
  static func reduce(value: inout [TabID: CGRect], nextValue: () -> [TabID: CGRect]) {
    value.merge(nextValue()) { _, new in new }
  }
}
