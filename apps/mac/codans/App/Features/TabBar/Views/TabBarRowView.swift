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
/// bar does. The row is not itself scrolled: it sits over the scroll view
/// (see `TabBarOverflowScroll`) and `ChipRowLayout` lays each chip out at its
/// stacked frame for the current scroll offset, clipped to its sliver.
/// Z-order rises with the index and the selected
/// chip is on top, so overlapping chips hit-test like the system bar's.
/// Clicking a sliver scrolls the stack into view; adding a tab reveals it.
/// Selecting a tab never scrolls.
///
/// Adding and closing tabs animate as in Safari (measured): a new chip grows
/// in from its trailing edge while its siblings narrow, a closed chip
/// disappears at once while its siblings widen, both in about a tenth of a
/// second (`addRemoveAnimation`). In a stacked row the new chip appears in
/// place — its slot is decided by the stack.
///
/// Reorder: an in-app `DragGesture` drives a live preview. While dragging,
/// a local `orderIDs` snapshot is mutated once the dragged chip overlaps a
/// neighbor by 50% (the slot boundary), so siblings reflow on the same
/// spring as add / close — the dragged chip leaves a transparent gap in the row while a lifted
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
  /// Title for a tab that has no pane yet — the worktree directory's name,
  /// which is where its first pane will start.
  var emptyTabTitle: String = ""
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

  /// Add / close reflow, fitted to Safari's tab bar: no overshoot, 90% of
  /// the way in under 0.1 s.
  private static let addRemoveAnimation: Animation = .spring(response: 0.15, dampingFraction: 1)

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
  /// Last selection that was present in `tabs`; see `selectedID`.
  @State private var heldSelectionID: TabID?

  /// Selection as drawn. A new tab's selection (navigation state) can land a
  /// frame or two before the catalog delivers the tab itself; until it is in
  /// `tabs` the previous selection stays drawn, so the bar never flashes with
  /// no tab selected.
  private var selectedID: TabID? {
    presentActiveID ?? (activeTabID == nil ? nil : heldSelectionID)
  }

  /// `activeTabID` when that tab is already in `tabs`.
  private var presentActiveID: TabID? {
    tabs.contains { $0.id == activeTabID } ? activeTabID : nil
  }

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
    let slots = chipSlots(widths: widths, stack: stack)
    ChipRowLayout(slots: slots) {
      ForEach(Array(rendered.enumerated()), id: \.element.id) { index, tab in
        chipView(for: tab, index: index, count: rendered.count, stack: stack)
          .frame(width: widths[index])
          // A sliver's layout frame is the sliver, so hover and hit testing
          // stop where the next chip starts; the chip draws past it.
          .frame(width: slots[index].width, alignment: .leading)
          .modifier(StackVisibility(isHidden: stack?.frames[index].isHidden ?? false))
          .onHover { hovering in
            // A narrowed chip shows no hover, so its separators stay.
            if hovering, !isNarrowed(index: index, isActive: tab.id == selectedID, stack: stack) {
              hoveredID = tab.id
            } else if hoveredID == tab.id {
              hoveredID = nil
            }
          }
          // Overlaid and pushed into the inter-chip gap rather than
          // laid out as a chip of its own, so the gap stays exactly
          // `chipSpacing` whether or not the separator shows.
          .overlay(alignment: .trailing) {
            if showsDivider(at: index, in: rendered, stack: stack) {
              Rectangle()
                .fill(TabBarColors.divider)
                .frame(
                  width: TabBarMetrics.dividerWidth,
                  height: TabBarMetrics.dividerHeight
                )
                // Just past the chip's trailing edge: inside the 1-pt gap,
                // or where the next sliver starts in a stack.
                .offset(x: TabBarMetrics.chipSpacing)
                .allowsHitTesting(false)
            }
          }
          .background(frameReporter(for: tab.id))
          // The dragged chip goes transparent in-flow, leaving a gap that
          // the spring reflows; a lifted copy follows the cursor (overlay).
          .opacity(draggingID == tab.id ? 0 : 1)
          .zIndex(
            zOrder(
              index: index, isActive: tab.id == selectedID, isDragging: draggingID == tab.id,
              stack: stack)
          )
          .simultaneousGesture(reorderGesture(for: tab))
          .transition(Self.chipTransition(isStacked: stack != nil))
      }
    }
    .coordinateSpace(name: Self.rowSpace)
    .onPreferenceChange(ChipFrameKey.self) { chipFrames = $0 }
    .overlay(alignment: .topLeading) { floatingChip(in: rendered) }
    .animation(Self.addRemoveAnimation, value: rendered.map(\.id))
    .onAppear {
      orderIDs = tabs.map(\.id)
      revealIfStacked(activeTabID)
    }
    .onChange(of: presentActiveID, initial: true) { _, id in
      if let id { heldSelectionID = id }
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

  /// A new chip grows out of its slot (`ChipGrowTransition`); a closed chip
  /// leaves at once — the siblings' reflow is the animation.
  private static func chipTransition(isStacked: Bool) -> AnyTransition {
    .asymmetric(
      insertion: AnyTransition(ChipGrowTransition(isEnabled: !isStacked)), removal: .identity)
  }

  /// One chip with its full callback set. Shared by the in-flow row and the
  /// floating drag copy so both stay pixel-identical.
  @ViewBuilder
  private func chipView(
    for tab: CodansCore.Tab, index: Int, count: Int, stack: StackState? = nil
  ) -> some View {
    let slice = stack.flatMap {
      sliceInfo(index: index, isActive: tab.id == selectedID, stack: $0)
    }
    ResolvingTabChipView(
      tab: tab,
      isActive: selectedID == tab.id,
      terminalBusy: isTerminalBusy(tab.id),
      agentWorking: isAgentWorking(tab.id),
      isOnlyTab: count <= 1,
      isLastTab: index == count - 1,
      // A narrowed chip shows only its edge, which the hint would cover.
      chordHint: slice == nil ? chordHint(for: index + 1) : nil,
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
      emptyTabTitle: emptyTabTitle,
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
  /// neighbor by 50%, animating the sibling reflow.
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
    withAnimation(Self.addRemoveAnimation) {
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

  /// Where each chip sits in the row: side by side `chipSpacing` apart, or
  /// at its stacked frame.
  private func chipSlots(widths: [CGFloat], stack: StackState?) -> [ChipRowLayout.Slot] {
    if let stack {
      return stack.frames.map { .init(x: $0.x, width: $0.isHidden ? 0 : $0.width) }
    }
    var x: CGFloat = 0
    return widths.map { width in
      defer { x += width + TabBarMetrics.chipSpacing }
      return .init(x: x, width: width)
    }
  }

  /// Draws a separator between adjacent chips, except next to the selected
  /// or hovered chip (their capsules are the boundary), next to a hidden
  /// stacked chip, and around the drag gap (so the empty slot reads clean
  /// while the dragged chip floats).
  private func showsDivider(at index: Int, in rendered: [CodansCore.Tab], stack: StackState?)
    -> Bool
  {
    guard index < rendered.count - 1 else { return false }
    if let stack, stack.frames[index].isHidden || stack.frames[index + 1].isHidden { return false }
    let pair = [rendered[index].id, rendered[index + 1].id]
    return !pair.contains { $0 == draggingID || $0 == selectedID || $0 == hoveredID }
  }

  // MARK: Overflow stacking

  /// Stacked layout for the current scroll position, or nil while every
  /// chip fits at `chipMinWidth` (plain equal-width layout).
  private func stackedFrames(for rendered: [CodansCore.Tab]) -> StackState? {
    let count = rendered.count
    guard viewport.width > 0,
      TabStackLayout.maxScrollOffset(count: count, viewportWidth: viewport.width) > 0
    else { return nil }
    let selected = rendered.firstIndex { $0.id == selectedID } ?? 0
    let placements = TabStackLayout.placements(
      count: count, selectedIndex: selected,
      scrollOffset: viewport.scrollOffset, viewportWidth: viewport.width)
    return StackState(
      layout: placements.map(\.frame),
      anchors: placements.map(\.anchor),
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
    let anchor = stack.anchors[index]
    let inset =
      anchor.squeeze == .none
      ? 0
      : TabStackLayout.contentOffset(
        frameWidth: full.width, isLeadingSide: anchor.squeeze == .leading,
        viewportWidth: stack.viewportWidth)
    // Pin the full-width content to the frame's outer edge, pushed `inset`
    // inwards, as the system bar does; a leading cut must not move it.
    let edgeAligned = anchor.alignsLeading ? inset : full.width - TabStackLayout.chipWidth - inset
    let shift = edgeAligned - stack.leadingTrim[index]
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

  /// Drawn narrower than a chip — a stack sliver or partly covered.
  private func isNarrowed(index: Int, isActive: Bool, stack: StackState?) -> Bool {
    guard let stack, !isActive else { return false }
    return stack.frames[index].width < TabStackLayout.chipWidth
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
        forTabAt: index, scrollOffset: viewport.scrollOffset, count: tabs.count,
        viewportWidth: viewport.width)
    else { return }
    // Let the scroll range grow to include the new chip before moving to it.
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
/// 7. `emptyTabTitle` (the worktree directory's name) for a tab whose first
///    pane is not open yet — a tab added from the UI opens it only after
///    its insertion animation, and must not show up untitled meanwhile.
/// 8. Empty string as a last-resort defensive default.
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
  let emptyTabTitle: String
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
    return emptyTabTitle
  }
}

/// Stacked frames for one render pass of the row.
private struct StackState {
  /// Frames as the layout computes them.
  let layout: [TabStackLayout.Frame]
  let anchors: [TabStackLayout.ContentAnchor]
  /// What is actually drawn: layout frames minus the part the selected tab
  /// covers. The selected capsule is translucent, so tabs stacked beneath
  /// it must be cut away rather than merely overlapped.
  let frames: [TabStackLayout.Frame]
  /// How much was cut from each drawn frame's leading edge.
  let leadingTrim: [CGFloat]
  let selectedIndex: Int
  let scrollOffset: CGFloat
  let viewportWidth: CGFloat

  init(
    layout: [TabStackLayout.Frame], anchors: [TabStackLayout.ContentAnchor], selectedIndex: Int,
    scrollOffset: CGFloat, viewportWidth: CGFloat
  ) {
    self.layout = layout
    self.anchors = anchors
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

/// Hides chips the stack collapses; ordering is `zOrder`'s job.
private struct StackVisibility: ViewModifier {
  let isHidden: Bool

  func body(content: Content) -> some View {
    content
      .opacity(isHidden ? 0 : 1)
      .allowsHitTesting(!isHidden)
  }
}

/// Places each chip at an explicit x. Chips are laid out where they are
/// drawn — not offset there — so hover, hit testing, the separators and the
/// drag math all follow the stacked frames.
private struct ChipRowLayout: Layout {
  struct Slot: Equatable {
    var x: CGFloat
    var width: CGFloat
  }

  var slots: [Slot]

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let extent = slots.map { $0.x + $0.width }.max() ?? 0
    return CGSize(
      width: proposal.width ?? extent, height: proposal.height ?? 0)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    for (index, subview) in subviews.enumerated() where slots.indices.contains(index) {
      let slot = slots[index]
      subview.place(
        at: CGPoint(x: bounds.minX + slot.x, y: bounds.midY), anchor: .leading,
        proposal: ProposedViewSize(width: slot.width, height: bounds.height))
    }
  }
}

/// Insertion of a newly added chip, as in Safari: the chip grows in from
/// the trailing edge of its final slot, its title centered in the part
/// already shown. Drawn as a clip plus a content shift rather than an
/// animated layout width — SwiftUI places an inserted view at its final
/// frame at once, so a width animation would grow it from the leading edge
/// instead. Disabled in a stacked row, where the stack decides the new
/// chip's slot.
private struct ChipGrowTransition: Transition {
  let isEnabled: Bool

  func body(content: Content, phase: TransitionPhase) -> some View {
    content.modifier(ChipReveal(fraction: phase.isIdentity || !isEnabled ? 1 : 0))
  }
}

/// Shows the trailing `fraction` of a chip as a capsule, with the chip's
/// content recentered in it.
private struct ChipReveal: ViewModifier, Animatable {
  var fraction: CGFloat

  var animatableData: CGFloat {
    get { fraction }
    set { fraction = newValue }
  }

  func body(content: Content) -> some View {
    let hidden = 1 - fraction
    content
      .visualEffect { effect, proxy in effect.offset(x: hidden * proxy.size.width / 2) }
      .clipShape(TrailingCapsule(fraction: fraction))
  }
}

/// A capsule over the trailing `fraction` of the rect's width; the full
/// fraction clips nothing, so the settled chip keeps its shadow and rims.
private struct TrailingCapsule: Shape {
  var fraction: CGFloat

  var animatableData: CGFloat {
    get { fraction }
    set { fraction = newValue }
  }

  func path(in rect: CGRect) -> Path {
    // Settled: clip nothing. A stacked sliver draws its chip past its own
    // (sliver-wide) frame, so a clip to the frame would cut it away.
    guard fraction < 1 else { return Path(rect.insetBy(dx: -100_000, dy: -100_000)) }
    let width = rect.width * max(fraction, 0)
    return Capsule().path(
      in: CGRect(x: rect.maxX - width, y: rect.minY, width: width, height: rect.height))
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
