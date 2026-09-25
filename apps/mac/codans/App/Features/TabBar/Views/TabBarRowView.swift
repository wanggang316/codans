import CodansCore
import ComposableArchitecture
import SwiftUI

/// Horizontal row of tab chips. Kept thin so feature dispatch stays out of
/// the chip views — select / close / rename / reorder callbacks come from
/// the parent.
///
/// Layout follows the system tab bar: chips sit 1 pt apart and split
/// the viewport width equally (the leftover points go to the leading chips),
/// bottoming out at `TabBarMetrics.chipMinWidth`, past which the enclosing
/// scroll view takes over. A separator fills the gap between two chips
/// unless either of them is selected or hovered — their capsules already
/// carry that boundary.
///
/// Overflow: once chips no longer fit at `chipMinWidth` the row scrolls and
/// is drawn by `TabStackLayout` — tabs near the edges compress into stacked
/// slivers and the selected tab slows / pins — exactly as the system tab
/// bar does. The scroll content keeps its plain linear layout (so scrolling
/// stays native); each chip is only visually offset to its stacked frame
/// and clipped to its sliver. Z-order rises with the index and the selected
/// chip is on top, so overlapping chips hit-test like the system bar's.
/// Clicking a sliver scrolls the stack into view; adding a tab reveals it.
/// Selecting a tab never scrolls.
///
/// Reorder: an in-app `DragGesture` drives a live preview. While dragging,
/// a local `orderIDs` snapshot is mutated once the dragged chip overlaps a
/// neighbor by 50% (the slot boundary), so siblings reflow under a
/// `spring(response: 0.3, dampingFraction: 0.85)` (macOS Safari-style) —
/// the dragged chip leaves a transparent gap in the row while a lifted
/// copy follows the cursor in an overlay. The final permutation is
/// dispatched once via `onReorder` on drop — the catalog mutation stays a
/// single absolute-order commit.
struct TabBarRowView: View {
  let tabs: [CodansCore.Tab]
  let activeTabID: TabID?
  /// Scroll viewport the row lives in. `.unbounded` (previews / tests)
  /// collapses every chip to `chipMinWidth` with no stacking.
  var viewport: TabBarViewport = .unbounded
  /// Per-tab terminal-busy lookup — typically `HierarchyManager.tabIsDirty(_:)`
  /// (OSC 9;4 ∪ foreground command). Drives the chip spinner unconditionally:
  /// a plain command never animates the title itself, so the spinner is the
  /// only running indicator. Default no-op for callers / previews that do not
  /// need dirty coverage.
  var isTerminalBusy: (TabID) -> Bool = { _ in false }
  /// Per-tab agent-working lookup — true when a bound agent in the tab is
  /// `.working`. Kept apart from the terminal signal because coding agents
  /// (e.g. Claude) animate their own spinner into the live OSC title;
  /// `ResolvingTabChipView` suppresses the chip spinner while that title is the
  /// one on screen so the two indicators don't stack. Default no-op.
  var isAgentWorking: (TabID) -> Bool = { _ in false }
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
  /// Chip under the pointer; its flanking separators are hidden.
  @State private var hoveredID: TabID?

  /// Render order: during a drag the locally-mutated `orderIDs`; otherwise
  /// the `tabs` prop verbatim. Content is always resolved from the current
  /// `tabs`, so a title / color push mid-idle still shows through.
  private var renderedTabs: [CodansCore.Tab] {
    let byID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let ordered = orderIDs.compactMap { byID[$0] }
    let known = Set(orderIDs)
    // New tabs not yet folded into `orderIDs` (added between resyncs) tail
    // the row until the next idle sync picks them up.
    return ordered + tabs.filter { !known.contains($0.id) }
  }

  var body: some View {
    let rendered = renderedTabs
    let widths = chipWidths(count: rendered.count)
    let stack = stackedFrames(for: rendered)
    HStack(spacing: TabBarMetrics.chipSpacing) {
      ForEach(Array(rendered.enumerated()), id: \.element.id) { index, tab in
        chipView(for: tab, index: index, count: rendered.count, stack: stack)
          .frame(width: widths[index])
          .modifier(StackPlacement(index: index, stack: stack, isActive: tab.id == activeTabID))
          .onHover { hovering in
            if hovering {
              hoveredID = tab.id
            } else if hoveredID == tab.id {
              hoveredID = nil
            }
          }
          // Overlaid and pushed into the inter-chip gap rather than
          // inserted into the HStack, so the gap stays exactly
          // `chipSpacing` whether or not the separator shows.
          .overlay(alignment: stack == nil ? .trailing : .leading) {
            if showsDivider(at: index, in: rendered, stack: stack) {
              Rectangle()
                .fill(TabBarColors.divider)
                .frame(
                  width: TabBarMetrics.dividerWidth,
                  height: TabBarMetrics.dividerHeight
                )
                // Linear layout: inside the 1-pt gap. Stacked: on the
                // sliver's trailing edge, where the next chip starts.
                .offset(x: stack?.frames[index].width ?? TabBarMetrics.chipSpacing)
                .allowsHitTesting(false)
            }
          }
          .background(frameReporter(for: tab.id))
          // The dragged chip goes transparent in-flow, leaving a gap that
          // the spring reflows; a lifted copy follows the cursor (overlay).
          .opacity(draggingID == tab.id ? 0 : 1)
          .zIndex(zOrder(index: index, isActive: tab.id == activeTabID, isDragging: draggingID == tab.id, stack: stack))
          .simultaneousGesture(reorderGesture(for: tab))
      }
    }
    .coordinateSpace(name: Self.rowSpace)
    .onPreferenceChange(ChipFrameKey.self) { chipFrames = $0 }
    .overlay(alignment: .topLeading) { floatingChip(in: rendered) }
    .animation(.spring(response: 0.3, dampingFraction: 0.85), value: rendered.map(\.id))
    .onAppear {
      orderIDs = tabs.map(\.id)
      revealIfStacked(activeTabID)
    }
    .onChange(of: tabs.map(\.id)) { previous, latest in
      // Resync the local order whenever the catalog changes while idle —
      // covers external add / close / reorder. Frozen during a drag so the
      // live preview owns the order until drop.
      if draggingID == nil { orderIDs = latest }
      // The system bar scrolls a newly added tab into view (jump, not
      // animated); plain selection changes never scroll.
      let added = Set(latest).subtracting(previous)
      if let activeTabID, added.contains(activeTabID) { revealIfStacked(activeTabID) }
    }
  }

  /// One chip with its full callback set. Shared by the in-flow row and the
  /// floating drag copy so both stay pixel-identical.
  @ViewBuilder
  private func chipView(
    for tab: CodansCore.Tab, index: Int, count: Int, stack: StackState? = nil
  ) -> some View {
    let slice = stack.flatMap { sliceInfo(index: index, isActive: tab.id == activeTabID, stack: $0) }
    ResolvingTabChipView(
      tab: tab,
      isActive: activeTabID == tab.id,
      terminalBusy: isTerminalBusy(tab.id),
      agentWorking: isAgentWorking(tab.id),
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
      sliceWidth: slice?.width,
      contentShift: slice?.shift ?? 0,
      onStackClick: slice?.onClick,
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
  private func floatingChip(in rendered: [CodansCore.Tab]) -> some View {
    if let id = draggingID,
      let index = rendered.firstIndex(where: { $0.id == id }),
      let frame = chipFrames[id]
    {
      chipView(for: rendered[index], index: index, count: rendered.count)
        .frame(width: frame.width, height: TabBarMetrics.chipHeight)
        // Opaque plate so the lifted copy occludes the chips it floats
        // over — the chip's own idle fill is `.clear`, which would let
        // their titles bleed through and overlap.
        .background(Capsule().fill(TabBarColors.draggingBackground))
        // Hard-clip the lifted copy to its own chip frame. On macOS 26 the
        // copy's opaque background otherwise paints a tall white column up to
        // the titlebar during a drag (a SwiftUI host/overlay regression — the
        // drag code itself is unchanged from when this shipped clean). Clipping
        // bounds the copy to `chipHeight` regardless of why it overflows; the
        // shadow is applied after, so it still feathers outside the clip.
        .frame(width: frame.width, height: TabBarMetrics.chipHeight)
        .clipped()
        .scaleEffect(1.03)
        .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
        .allowsHitTesting(false)
        .position(x: dragCursorX, y: TabBarMetrics.chipHeight / 2)
        .zIndex(10)
    }
  }

  private func reorderGesture(for tab: CodansCore.Tab) -> some Gesture {
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

  /// Whole-point chip widths that exactly fill the track: an equal share
  /// after the 1-pt gaps, with the remainder handed one point at a time to
  /// the leading chips (the system bar lays out 293 / 293 / 292). Floored
  /// at `chipMinWidth`, where the row overflows into the scroll view.
  private func chipWidths(count: Int) -> [CGFloat] {
    guard count > 0 else { return [] }
    let available = Int(viewport.width - TabBarMetrics.chipSpacing * CGFloat(count - 1))
    let base = available / count
    guard CGFloat(base) >= TabBarMetrics.chipMinWidth else {
      return Array(repeating: TabBarMetrics.chipMinWidth, count: count)
    }
    let remainder = available - base * count
    return (0..<count).map { CGFloat(base + ($0 < remainder ? 1 : 0)) }
  }

  /// Draws a separator between adjacent chips, except next to the selected
  /// or hovered chip (their capsules are the boundary), next to a hidden
  /// stacked chip, and around the drag gap (so the empty slot reads clean
  /// while the dragged chip floats).
  private func showsDivider(at index: Int, in rendered: [CodansCore.Tab], stack: StackState?) -> Bool {
    guard index < rendered.count - 1 else { return false }
    if let stack, stack.frames[index].isHidden || stack.frames[index + 1].isHidden { return false }
    let pair = [rendered[index].id, rendered[index + 1].id]
    return !pair.contains { $0 == draggingID || $0 == activeTabID || $0 == hoveredID }
  }

  // MARK: Overflow stacking

  /// Stacked layout for the current scroll position, or nil while every
  /// chip fits at `chipMinWidth` (plain equal-width layout).
  private func stackedFrames(for rendered: [CodansCore.Tab]) -> StackState? {
    let count = rendered.count
    guard viewport.width > 0, TabStackLayout.maxScrollOffset(count: count, viewportWidth: viewport.width) > 0
    else { return nil }
    let selected = rendered.firstIndex { $0.id == activeTabID } ?? 0
    return StackState(
      layout: TabStackLayout.frames(
        count: count, selectedIndex: selected,
        scrollOffset: viewport.scrollOffset, viewportWidth: viewport.width),
      selectedIndex: selected,
      scrollOffset: viewport.scrollOffset,
      viewportWidth: viewport.width)
  }

  /// Sliver presentation for chip `index`, or nil when it is drawn whole.
  private func sliceInfo(
    index: Int, isActive: Bool, stack: StackState
  ) -> (width: CGFloat, shift: CGFloat, onClick: () -> Void)? {
    let frame = stack.frames[index]
    let full = stack.layout[index]
    guard !isActive, frame.width < TabStackLayout.chipWidth else { return nil }
    let isLeading = full.x + full.width / 2 < stack.viewportWidth / 2
    let titleOffset = TabStackLayout.contentOffset(
      frameWidth: full.width, isLeadingSide: isLeading, viewportWidth: stack.viewportWidth)
    // Center the full-width content on the layout sliver and apply the
    // system bar's title offset; a leading cut must not move the content.
    let shift = full.width / 2 + titleOffset - TabStackLayout.chipWidth / 2 - stack.leadingTrim[index]
    let region = TabStackLayout.stackingRegion(
      atX: full.x + full.width / 2, frames: stack.layout, selectedIndex: stack.selectedIndex)
    let scroller = viewport.scroller
    let count = stack.frames.count
    return (
      frame.width, shift,
      {
        guard let region else { return }
        let target = TabStackLayout.scrollTarget(
          for: region, selectedIndex: stack.selectedIndex, scrollOffset: stack.scrollOffset,
          count: count, viewportWidth: stack.viewportWidth)
        scroller?.scroll(to: target, animated: true)
      }
    )
  }

  /// Stacked chips overlap: later tabs sit above earlier ones and the
  /// selected tab above all, as in the system bar. Without a stack only the
  /// dragged chip is raised.
  private func zOrder(index: Int, isActive: Bool, isDragging: Bool, stack: StackState?) -> Double {
    guard let stack else { return isDragging ? 1 : 0 }
    return isActive ? Double(stack.frames.count + 1) : Double(index)
  }

  /// Scrolls `id` out of a stack, as the system bar does for an added tab.
  private func revealIfStacked(_ id: TabID?) {
    guard let id, let index = tabs.firstIndex(where: { $0.id == id }), viewport.width > 0,
      let target = TabStackLayout.revealOffset(
        forTabAt: index, scrollOffset: viewport.scrollOffset, count: tabs.count, viewportWidth: viewport.width)
    else { return }
    // Let the new chip land in the scroll content before moving to it.
    let scroller = viewport.scroller
    DispatchQueue.main.async { scroller?.scroll(to: target, animated: false) }
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
  let tab: CodansCore.Tab
  let isActive: Bool
  /// Terminal-busy signal (OSC 9;4 ∪ foreground command). Drives the spinner
  /// for a plain command (which does not self-indicate inside the title), but
  /// is suppressed while the chip shows a working agent's live OSC title —
  /// there the agent's own OSC 9;4 is what set this flag (see
  /// `showsSpinner(live:)`).
  let terminalBusy: Bool
  /// A bound agent in this tab is `.working`. Drives the spinner only when the
  /// chip is NOT showing the live OSC title, because a working coding agent
  /// animates its own spinner into that title (see `showsSpinner(live:)`).
  let agentWorking: Bool
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
  var sliceWidth: CGFloat?
  var contentShift: CGFloat = 0
  var onStackClick: (() -> Void)?
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
      isDirty: showsSpinner(live: live),
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
      icon: icon,
      iconTint: runningScriptIconTint,
      sliceWidth: sliceWidth,
      contentShift: contentShift,
      onStackClick: onStackClick
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

  /// Script tint for the chip's icon while this tab's dedicated run pane is
  /// executing. Run panes are skipped by `tabIsDirty`, so a running script
  /// never swaps the chip's glyph for the spinner — the glyph picking up the
  /// script's colour is the running affordance instead. `nil` when no run
  /// pane in this tab is busy, or its script no longer exists in Settings.
  /// Reads `HierarchyManager.paneIsBusy` (@Observable) so the tint tracks
  /// start/stop automatically.
  private var runningScriptIconTint: Color? {
    guard let settings = settingsStore?.settings else { return nil }
    for pane in tab.panes {
      guard let scriptID = pane.runScriptID, hierarchyManager.paneIsBusy(pane.id) else { continue }
      let script =
        settings.general.globalScripts.first(where: { $0.id == scriptID })
        ?? settings.projects.values.lazy.flatMap(\.scripts).first(where: { $0.id == scriptID })
      guard let script else { return nil }
      return ScriptTintColorPalette.color(for: script.resolvedTintColor)
    }
    return nil
  }

  /// Whether to render the chip's running spinner. A working coding agent
  /// (e.g. Claude) both animates its own spinner into the live OSC title AND
  /// emits OSC 9;4 while running tool calls — and that OSC 9;4 also lights
  /// `terminalBusy`. So when the chip is showing the agent's live title, the
  /// activity is already covered twice over (the title animation plus the
  /// pane's own progress bar); suppress our spinner there *regardless of*
  /// `terminalBusy`, or it blinks on with every tool call and stacks on top of
  /// the title, shoving it into truncation. Otherwise any busy signal drives
  /// the spinner: a plain command (no self-indication), or a working agent on a
  /// manually renamed tab (`tab.name` — a static name with no live animation to
  /// carry the agent's own spinner).
  private func showsSpinner(live: String?) -> Bool {
    let showingAgentLiveTitle =
      agentWorking && (tab.name?.isEmpty ?? true) && live != nil
    if showingAgentLiveTitle { return false }
    return terminalBusy || agentWorking
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

/// Stacked frames for one render pass of the row.
private struct StackState {
  /// Frames as the layout computes them.
  let layout: [TabStackLayout.Frame]
  /// What is actually drawn: layout frames minus the part the selected tab
  /// covers. The selected capsule is translucent, so tabs stacked beneath
  /// it must be cut away rather than merely overlapped.
  let frames: [TabStackLayout.Frame]
  /// How much was cut from each drawn frame's leading edge.
  let leadingTrim: [CGFloat]
  let selectedIndex: Int
  let scrollOffset: CGFloat
  let viewportWidth: CGFloat

  init(layout: [TabStackLayout.Frame], selectedIndex: Int, scrollOffset: CGFloat, viewportWidth: CGFloat) {
    self.layout = layout
    self.selectedIndex = selectedIndex
    self.scrollOffset = scrollOffset
    self.viewportWidth = viewportWidth
    let selected = layout.indices.contains(selectedIndex) ? layout[selectedIndex] : nil
    var frames = layout
    var trims = Array(repeating: CGFloat(0), count: layout.count)
    if let selected {
      let covered = selected.x..<(selected.x + selected.width)
      for index in layout.indices where index != selectedIndex {
        var frame = layout[index]
        var start = frame.x
        var end = frame.x + frame.width
        if index < selectedIndex {
          end = min(end, covered.lowerBound)
        } else {
          start = max(start, covered.upperBound)
        }
        if end <= start {
          frame.width = 0
          frame.isHidden = true
        } else {
          trims[index] = start - frame.x
          frame.x = start
          frame.width = end - start
        }
        frames[index] = frame
      }
    }
    self.frames = frames
    self.leadingTrim = trims
  }
}

/// Moves a chip from its linear slot in the scroll content to its stacked
/// frame, hides chips the stack collapses, and orders them the way the
/// system bar does (later tabs above earlier ones, selected on top).
private struct StackPlacement: ViewModifier {
  let index: Int
  let stack: StackState?
  let isActive: Bool

  func body(content: Content) -> some View {
    if let stack {
      let frame = stack.frames[index]
      let linearX = CGFloat(index) * (TabStackLayout.chipWidth + TabBarMetrics.chipSpacing) - stack.scrollOffset
      content
        .offset(x: frame.x - linearX)
        .opacity(frame.isHidden ? 0 : 1)
        .allowsHitTesting(!frame.isHidden)
    } else {
      content
    }
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
