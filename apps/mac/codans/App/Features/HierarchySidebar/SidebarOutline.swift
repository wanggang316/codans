import AppKit
import CodansCore
import SwiftUI

/// The sidebar tree as an AppKit outline (ADR 0002, decision 1). Row content
/// stays SwiftUI, hosted in each cell; the outline owns selection, keyboard
/// navigation, scrolling, and drag and drop.
///
/// The catalog owns every state the outline shows: the rows, which of them
/// are expanded, and the selection. The outline applies that state and
/// reports user actions; it never keeps its own copy of a decision.
struct SidebarOutline: NSViewRepresentable {
  let nodes: [SidebarOutlineNode]
  let selection: SidebarSelection?
  /// Picks the row when two rows share a selection (a worktree listed under
  /// two Projects).
  let selectedProjectID: ProjectID?
  /// A change scrolls the selected row to the center.
  let revealTrigger: UUID
  /// A new value animates the row the user opened or closed (ADR 0007, ADR 0008).
  let expansionToggle: SidebarExpansionToggle?
  /// Space the AgentState panel covers at the bottom.
  let bottomInset: CGFloat
  /// Worktrees move inside their segment only while every row of the segment
  /// shows.
  let allowsWorktreeDrag: Bool
  /// Gives a hosted row what it reads from the environment
  /// (`SidebarRowEnvironment.apply`).
  let decorateRow: (AnyView) -> AnyView
  let rowContent: (SidebarOutlineNode) -> AnyView
  let onSelect: (SidebarSelection) -> Void
  let onMoveWorktrees: (SidebarOutlineModel.WorktreeMove) -> Void
  /// A click on a Project row that cannot be selected (a git Project or a
  /// Workspace) opens or closes it.
  let onToggleProject: (ProjectID) -> Void
  let onMoveProject: (ProjectID, ProjectPlacement) -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    Self.makeScrollView(coordinator: context.coordinator)
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    context.coordinator.update(with: self)
  }

  static func makeScrollView(coordinator: Coordinator) -> NSScrollView {
    let outline = SidebarOutlineView()
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
    column.resizingMask = .autoresizingMask
    outline.addTableColumn(column)
    outline.outlineTableColumn = column
    outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    outline.headerView = nil
    outline.style = .sourceList
    // Rows size to their SwiftUI content, as the `List` rows did (see
    // `heightOfRowByItem`).
    outline.rowHeight = SidebarOutlineView.minimumRowHeight
    outline.backgroundColor = .clear
    outline.intercellSpacing = .zero
    // Every row carries its own indent in its content; the outline adds none.
    outline.indentationPerLevel = 0
    outline.allowsMultipleSelection = false
    outline.allowsEmptySelection = true
    outline.allowsTypeSelect = false
    outline.focusRingType = .none
    outline.dataSource = coordinator
    outline.delegate = coordinator
    // Fires on a click, not at the end of a drag.
    outline.target = coordinator
    outline.action = #selector(Coordinator.rowClicked(_:))
    outline.registerForDraggedTypes([Coordinator.dragType])
    outline.setDraggingSourceOperationMask(.move, forLocal: true)
    outline.draggingDestinationFeedbackStyle = .sourceList
    outline.setAccessibilityLabel("Sidebar")

    let scrollView = NSScrollView()
    scrollView.documentView = outline
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    // The bottom inset is the AgentState panel's; the window adds none.
    scrollView.automaticallyAdjustsContentInsets = false
    coordinator.outline = outline
    return scrollView
  }

  @MainActor
  final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    static let dragType = NSPasteboard.PasteboardType("com.gumpw.codans.sidebar-row")

    weak var outline: SidebarOutlineView?
    private var config: SidebarOutline?
    private(set) var roots: [SidebarOutlineItem] = []
    private var itemsByID: [String: SidebarOutlineItem] = [:]
    private var shownStructure: [String] = []
    private var shownRevealTrigger: UUID?
    /// The last toggle applied. Nil before the first update, so a toggle
    /// that is already in the store when the outline appears does not animate.
    private var shownExpansionToggle: SidebarExpansionToggle??
    /// The row the last update animated, nil when it changed rows at once.
    private(set) var animatedNodeID: String?
    /// The child rows the last animated open or close moved and faded.
    private(set) var animatedChildIDs: [String] = []
    private var heightUpdateScheduled = false
    /// Each row's measured height, by row id. Kept across updates, so a
    /// reload measures only the rows it has not seen.
    private var heights: [String: CGFloat] = [:]
    /// Measures rows that have no cell yet.
    private lazy var sizingCell = SidebarOutlineCell()
    /// True while the outline is changed from `update`, so its delegate
    /// callbacks do not echo those changes back as user actions.
    private var applying = false
    /// Rows whose children the data source reports as none for a moment:
    /// an animated open first opens the row with no children, then inserts
    /// them, so they fade in (see `animateOpen`).
    private var childlessIDs: Set<String> = []

    // Explicit, so releasing the coordinator during a SwiftUI teardown skips the isolated-deinit hop.
    deinit {}

    func update(with config: SidebarOutline) {
      self.config = config
      guard let outline else { return }
      applying = true
      defer { applying = false }

      if let scrollView = outline.enclosingScrollView, scrollView.contentInsets.bottom != config.bottomInset {
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: config.bottomInset, right: 0)
      }

      let animation = expansionAnimation(for: config.expansionToggle)
      shownExpansionToggle = .some(config.expansionToggle)
      animatedNodeID = animation?.nodeID

      let structure = rebuild(config.nodes)
      if structure != shownStructure {
        shownStructure = structure
        outline.reloadData()
        scheduleHeightUpdate()
      } else {
        refreshVisibleRows(animating: animation)
      }
      applyExpansion(animating: animation)
      syncSelection()
      if let shown = shownRevealTrigger, shown != config.revealTrigger {
        // After this update lands: the reveal may have switched worktrees and
        // opened a Project in the same tick.
        DispatchQueue.main.async { [weak self] in self?.revealSelection() }
      }
      shownRevealTrigger = config.revealTrigger
    }

    /// Reuses the item of every row that stays, so the outline keeps its
    /// views. Returns the tree's shape: one entry per row with its parent.
    private func rebuild(_ nodes: [SidebarOutlineNode]) -> [String] {
      var structure: [String] = []
      var items: [String: SidebarOutlineItem] = [:]
      func make(_ nodes: [SidebarOutlineNode], parent: String) -> [SidebarOutlineItem] {
        nodes.map { node in
          let item = itemsByID[node.id] ?? SidebarOutlineItem(node: node)
          item.node = node
          structure.append("\(parent)/\(node.id)")
          item.children = make(node.children, parent: node.id)
          items[node.id] = item
          return item
        }
      }
      roots = make(nodes, parent: "")
      itemsByID = items
      heights = heights.filter { items[$0.key] != nil }
      return structure
    }

    /// The animation for a toggle the outline has not applied yet, nil for
    /// every other update: those open and close rows at once (ADR 0007).
    private func expansionAnimation(for toggle: SidebarExpansionToggle?) -> ExpansionAnimation? {
      guard let shown = shownExpansionToggle, let toggle, toggle != shown,
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      else { return nil }
      return ExpansionAnimation(nodeID: toggle.nodeID)
    }

    /// Opens and closes rows to match the catalog, parents first, so a row
    /// that opens shows its children as they are now. Only the row of a user
    /// toggle animates (ADR 0008); a toggle during that animation starts
    /// from the outline's current rows, so it turns the animation around.
    private func applyExpansion(animating animation: ExpansionAnimation?) {
      guard let outline else { return }
      NSAnimationContext.beginGrouping()
      NSAnimationContext.current.duration = 0
      NSAnimationContext.current.allowsImplicitAnimation = false
      defer { NSAnimationContext.endGrouping() }
      func apply(_ items: [SidebarOutlineItem]) {
        for item in items where !item.children.isEmpty {
          let expanded = item.node.isExpanded
          if expanded != outline.isItemExpanded(item) {
            switch (animation?.nodeID == item.id, expanded) {
            case (true, true): animateOpen(item, in: outline)
            case (true, false): animateClose(item, in: outline)
            case (false, true): outline.expandItem(item)
            case (false, false): outline.collapseItem(item)
            }
          }
          if expanded { apply(item.children) }
        }
      }
      apply(roots)
    }

    /// Child rows slide down into place and fade in; the rows below slide
    /// down. `NSOutlineView` has no such expand animation, so the row opens
    /// with no children and then they are inserted, with the open rows under
    /// them. The table moves the rows below; the child rows get their own
    /// layer animations (ADR 0008).
    private func animateOpen(_ item: SidebarOutlineItem, in outline: NSOutlineView) {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = SidebarDisclosureTiming.rows
        context.timingFunction = SidebarDisclosureTiming.rowCurve
        outline.beginUpdates()
        childlessIDs.insert(item.id)
        outline.expandItem(item)
        insertChildren(of: item, in: outline)
        outline.endUpdates()
      }
      animateChildRows(under: item, in: outline, opening: true)
    }

    private func insertChildren(of item: SidebarOutlineItem, in outline: NSOutlineView) {
      let parents = item.children.filter { !$0.children.isEmpty }
      childlessIDs.formUnion(parents.map(\.id))
      childlessIDs.remove(item.id)
      outline.insertItems(at: IndexSet(integersIn: 0..<item.children.count), inParent: item, withAnimation: .effectFade)
      for child in parents {
        if child.node.isExpanded {
          outline.expandItem(child)
          insertChildren(of: child, in: outline)
        } else {
          // The outline can remember a row it removed as open.
          outline.collapseItem(child)
          childlessIDs.remove(child.id)
        }
      }
    }

    /// Child rows fade out fast while they move up a little; the rows below
    /// slide up over them.
    private func animateClose(_ item: SidebarOutlineItem, in outline: NSOutlineView) {
      let count = outline.numberOfChildren(ofItem: item)
      let rows = childRowViews(under: item, in: outline, make: false)
      NSAnimationContext.runAnimationGroup { context in
        context.duration = SidebarDisclosureTiming.rows
        context.timingFunction = SidebarDisclosureTiming.rowCurve
        outline.beginUpdates()
        childlessIDs.insert(item.id)
        outline.removeItems(at: IndexSet(integersIn: 0..<count), inParent: item, withAnimation: .effectFade)
        outline.endUpdates()
      }
      animate(rows, opening: false)
      outline.collapseItem(item)
      childlessIDs.remove(item.id)
    }

    /// The row views on screen under `item`, with their row ids.
    private func childRowViews(
      under item: SidebarOutlineItem, in outline: NSOutlineView, make: Bool
    ) -> [(id: String, view: NSTableRowView)] {
      let parentRow = outline.row(forItem: item)
      guard parentRow >= 0 else { return [] }
      let level = outline.level(forRow: parentRow)
      let visible = outline.rows(in: outline.visibleRect)
      var rows: [(id: String, view: NSTableRowView)] = []
      var row = parentRow + 1
      while row < outline.numberOfRows, outline.level(forRow: row) > level {
        if row >= visible.location, row < visible.location + visible.length,
          let view = outline.rowView(atRow: row, makeIfNecessary: make),
          let child = outline.item(atRow: row) as? SidebarOutlineItem
        {
          rows.append((child.id, view))
        }
        row += 1
      }
      return rows
    }

    private func animateChildRows(under item: SidebarOutlineItem, in outline: NSOutlineView, opening: Bool) {
      animate(childRowViews(under: item, in: outline, make: true), opening: opening)
    }

    /// Replaces the table's own fade of the child rows, which runs over the
    /// whole row animation, with the reference's: a short fade, and a small
    /// move. Added after the table's animations, so these win. Not kept on
    /// the layer when they end, because the table reuses row views.
    private func animate(_ rows: [(id: String, view: NSTableRowView)], opening: Bool) {
      animatedChildIDs = rows.map(\.id)
      let timing = SidebarDisclosureTiming.self
      let total = timing.rows
      for (_, view) in rows {
        view.wantsLayer = true
        guard let layer = view.layer else { continue }
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.duration = total
        fade.calculationMode = .linear
        // The outline is flipped: a negative offset is above the row's place.
        let move: CAAnimation
        if opening {
          fade.values = [0, 0, 1, 1]
          fade.keyTimes = [0, timing.openFadeDelay / total, (timing.openFadeDelay + timing.openFade) / total, 1]
            .map { NSNumber(value: $0) }
          fade.timingFunctions = [.init(name: .linear), .init(name: .easeOut), .init(name: .linear)]
          // Waits above the row's place, hidden, then follows the rows below.
          let slide = CABasicAnimation(keyPath: "transform.translation.y")
          slide.fromValue = -timing.openOffset
          slide.toValue = 0
          slide.duration = total
          slide.timingFunction = timing.rowCurve
          slide.beginTime = now + timing.openMoveDelay
          slide.fillMode = .backwards
          move = slide
        } else {
          // From where an open that is still running has got to, so a
          // quick second toggle turns it around without a jump.
          let from = layer.presentation()?.opacity ?? layer.opacity
          fade.values = [from, from * timing.closeFadeEnd, 0, 0]
          fade.keyTimes = [0, timing.closeFade / total, timing.closeGone / total, 1].map { NSNumber(value: $0) }
          let offset = (layer.presentation()?.value(forKeyPath: "transform.translation.y") as? CGFloat) ?? 0
          let lift = CABasicAnimation(keyPath: "transform.translation.y")
          lift.fromValue = offset
          lift.toValue = offset - timing.closeLift
          lift.duration = timing.closeLiftTime
          lift.timingFunction = timing.closeLiftCurve
          move = lift
        }
        layer.add(fade, forKey: "sidebar.childFade")
        layer.add(move, forKey: "sidebar.childMove")
      }
    }

    private func refreshVisibleRows(animating animation: ExpansionAnimation?) {
      guard let outline else { return }
      let rows = outline.rows(in: outline.visibleRect)
      for row in rows.location..<(rows.location + rows.length) {
        guard let item = outline.item(atRow: row) as? SidebarOutlineItem,
          let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarOutlineCell
        else { continue }
        show(
          item, in: cell,
          disclosureAnimation: animation?.nodeID == item.id ? SidebarDisclosureTiming.chevronAnimation : nil)
      }
      scheduleHeightUpdate()
    }

    private func show(_ item: SidebarOutlineItem, in cell: SidebarOutlineCell, disclosureAnimation: Animation? = nil) {
      guard let config else { return }
      let node = item.node
      cell.show(
        AnyView(
          SidebarOutlineRowHost(node: node, content: config.rowContent)
            .environment(\.sidebarDisclosureAnimation, disclosureAnimation)),
        decorate: config.decorateRow)
      cell.onSizeChange = { [weak self] in self?.scheduleHeightUpdate() }
    }

    /// Selects the row for the catalog's selection, and never scrolls.
    private func syncSelection() {
      // The store learns of a click only once the outline reports it. An update
      // before that would put the old row back.
      guard let outline, !outline.isTrackingClick else { return }
      let row = selectedItem().map { outline.row(forItem: $0) } ?? -1
      guard row >= 0 else {
        if outline.selectedRow >= 0 { outline.deselectAll(nil) }
        return
      }
      if outline.selectedRow != row { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    }

    private func selectedItem() -> SidebarOutlineItem? {
      guard let config, let selection = config.selection else { return nil }
      var match: SidebarOutlineItem?
      func find(_ items: [SidebarOutlineItem]) -> Bool {
        for item in items {
          if item.node.selection == selection {
            if match == nil { match = item }
            if item.node.projectID == config.selectedProjectID {
              match = item
              return true
            }
          }
          if find(item.children) { return true }
        }
        return false
      }
      _ = find(roots)
      return match
    }

    /// Scrolls the selected row to the center of the visible rows.
    func revealSelection() {
      guard let outline, let scrollView = outline.enclosingScrollView,
        let item = selectedItem()
      else { return }
      let row = outline.row(forItem: item)
      guard row >= 0 else { return }
      let clipView = scrollView.contentView
      let visibleHeight = clipView.bounds.height - scrollView.contentInsets.bottom
      let maxY = max(0, outline.bounds.height - visibleHeight)
      let y = min(max(0, outline.rect(ofRow: row).midY - visibleHeight / 2), maxY)
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.25
        clipView.animator().setBoundsOrigin(NSPoint(x: clipView.bounds.minX, y: y))
      }
      scrollView.reflectScrolledClipView(clipView)
    }

    /// Row content can change height (a caption shows, a phase line starts).
    /// One pass per run loop measures the rows on screen again.
    private func scheduleHeightUpdate() {
      guard !heightUpdateScheduled else { return }
      heightUpdateScheduled = true
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        heightUpdateScheduled = false
        guard let outline else { return }
        let rows = outline.rows(in: outline.visibleRect)
        var changed = IndexSet()
        for row in rows.location..<(rows.location + rows.length) {
          guard let item = outline.item(atRow: row) as? SidebarOutlineItem,
            let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarOutlineCell
          else { continue }
          let height = cell.contentHeight
          if abs(height - (heights[item.id] ?? 0)) > 0.5 {
            heights[item.id] = height
            changed.insert(row)
          }
        }
        guard !changed.isEmpty else { return }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        outline.noteHeightOfRows(withIndexesChanged: changed)
        NSAnimationContext.endGrouping()
      }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
      guard let item = item as? SidebarOutlineItem else { return roots.count }
      return childlessIDs.contains(item.id) ? 0 : item.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
      ((item as? SidebarOutlineItem)?.children ?? roots)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
      (item as? SidebarOutlineItem)?.children.isEmpty == false
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
      guard let item = item as? SidebarOutlineItem else { return nil }
      let cell =
        outlineView.makeView(withIdentifier: SidebarOutlineCell.identifier, owner: nil) as? SidebarOutlineCell
        ?? SidebarOutlineCell()
      show(item, in: cell)
      // A row that scrolls in may have changed while it was off screen.
      scheduleHeightUpdate()
      return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
      guard let item = item as? SidebarOutlineItem, let config else { return SidebarOutlineView.minimumRowHeight }
      if let height = heights[item.id] { return height }
      sizingCell.show(
        AnyView(SidebarOutlineRowHost(node: item.node, content: config.rowContent)), decorate: config.decorateRow)
      let height = sizingCell.contentHeight
      heights[item.id] = height
      return height
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
      (item as? SidebarOutlineItem)?.node.selection != nil
    }

    /// Only the catalog opens and closes rows: the row's own chevron and click
    /// go through the store. The outline's keys would otherwise do it alone.
    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool { applying }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool { applying }

    @objc func rowClicked(_ sender: NSOutlineView) {
      guard let item = sender.item(atRow: sender.clickedRow) as? SidebarOutlineItem,
        case .project(let project) = item.node.row, item.node.selection == nil
      else { return }
      if case .failed = project.loadState { return }
      config?.onToggleProject(project.id)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
      guard !applying, let outline,
        let selection = (outline.item(atRow: outline.selectedRow) as? SidebarOutlineItem)?.node.selection
      else { return }
      config?.onSelect(selection)
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
      guard let item = item as? SidebarOutlineItem, let config else { return nil }
      switch item.node.row {
      // A drag starts anywhere on a Project row, under every filter.
      case .worktree(_, _, .some) where config.allowsWorktreeDrag, .project:
        let writer = NSPasteboardItem()
        writer.setString(item.id, forType: Self.dragType)
        return writer
      default:
        return nil
      }
    }

    func outlineView(
      _ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?,
      proposedChildIndex index: Int
    ) -> NSDragOperation {
      dropAction(info, parent: item, childIndex: index) == nil ? [] : .move
    }

    func outlineView(
      _ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int
    ) -> Bool {
      guard let action = dropAction(info, parent: item, childIndex: index) else { return false }
      action()
      return true
    }

    /// What a drop at this place does, nil where it cannot land: a worktree
    /// stays in its segment of its Project, a Project under its own parent.
    private func dropAction(_ info: any NSDraggingInfo, parent: Any?, childIndex: Int) -> (() -> Void)? {
      guard let config, let id = info.draggingPasteboard.string(forType: Self.dragType),
        let dragged = itemsByID[id]
      else { return nil }
      if case .project = dragged.node.row {
        let siblings = (parent as? SidebarOutlineItem)?.children ?? roots
        guard
          let drop = SidebarOutlineModel.projectDrop(
            siblings: siblings.map(\.node), draggedID: id, childIndex: childIndex)
        else { return nil }
        guard let placement = drop.placement else { return {} }
        return { config.onMoveProject(drop.projectID, placement) }
      }
      guard let parent = parent as? SidebarOutlineItem, parent.children.contains(where: { $0 === dragged }),
        let move = SidebarOutlineModel.worktreeMove(
          siblings: parent.children.map(\.node), draggedID: id, childIndex: childIndex)
      else { return nil }
      return { config.onMoveWorktrees(move) }
    }
  }
}

/// The row a user toggle animates.
private struct ExpansionAnimation {
  let nodeID: String
}

/// The times and curves of a user toggle's animation, measured from the
/// owner's reference recording (ADR 0008).
enum SidebarDisclosureTiming {
  /// The rows move like a critically damped spring with a response of about
  /// 0.27 s: most of the way in the first 0.1 s, then a long tail. The
  /// table animates rows with a duration and a cubic curve, so this curve
  /// over `rows` is the closest fit to that spring (about 0.6 % off).
  static let rows: TimeInterval = 0.32
  static let rowCurve = CAMediaTimingFunction(controlPoints: 0.30, 0.40, 0.15, 0.98)
  /// On open, the child rows wait `openOffset` above their place, hidden,
  /// for `openMoveDelay`, then slide down on `rowCurve`. They fade in from
  /// `openFadeDelay` over `openFade` (ease-out), so they show when they are
  /// about 14 pt above their place.
  static let openOffset: CGFloat = 16
  static let openMoveDelay: TimeInterval = 0.055
  static let openFadeDelay: TimeInterval = 0.05
  static let openFade: TimeInterval = 0.11
  /// On close, the child rows fade out linearly to `closeFadeEnd` of their
  /// opacity in `closeFade`, and are gone at `closeGone`. Meanwhile they
  /// speed up as they move up (quadratic ease-in, about 1 pt after 45 ms and
  /// 7 pt after 110 ms), and the rows below slide over them.
  static let closeFade: TimeInterval = 0.11
  static let closeFadeEnd: Float = 0.3
  static let closeGone: TimeInterval = 0.12
  static let closeLift: CGFloat = 11
  static let closeLiftTime: TimeInterval = 0.14
  static let closeLiftCurve = CAMediaTimingFunction(controlPoints: 1 / 3, 0, 2 / 3, 1 / 3)
  /// The chevron turns at the start of the row animation, much faster.
  static let chevron: TimeInterval = 0.06
  static let chevronAnimation = Animation.easeOut(duration: chevron)
}

extension EnvironmentValues {
  /// How a row's chevron turns when the row opens or closes: set only for
  /// the row of a user toggle, nil (at once) for every other change
  /// (ADR 0008, decision 3). Do not send a toggle in a transaction that
  /// disables animations: that also stops this one.
  @Entry var sidebarDisclosureAnimation: Animation?
}

/// The environment the sidebar's rows read, passed into each hosted cell.
/// Named one by one: handing a cell the whole `EnvironmentValues` of the
/// sidebar left its SwiftUI content out of the accessibility tree.
struct SidebarRowEnvironment {
  let hierarchyManager: HierarchyManager
  let settingsStore: SettingsStore
  let worktreeStatusMonitor: WorktreeStatusMonitor
  let worktreeLocalDiffMonitor: WorktreeLocalDiffMonitor
  let notificationStore: NotificationStore?
  let rollup: RollupIndexProvider?
  let agentStateStore: AgentStateStore?
  let updatesModel: UpdatesModel
  let commandKeyObserver: CommandKeyObserver
  let resolvedShortcuts: ResolvedShortcutMap

  func apply(to content: AnyView) -> AnyView {
    AnyView(
      content
        .environment(hierarchyManager)
        .environment(settingsStore)
        .environment(worktreeStatusMonitor)
        .environment(worktreeLocalDiffMonitor)
        .environment(notificationStore)
        .environment(rollup)
        .environment(agentStateStore)
        .environment(updatesModel)
        .environment(commandKeyObserver)
        .environment(\.resolvedShortcuts, resolvedShortcuts))
  }
}

/// The hosted root of a row. Its own view, so the row's reads of observable
/// stores (lifecycle progress, PR snapshots, the ⌘ key) are tracked by the
/// cell and update the row on their own.
private struct SidebarOutlineRowHost: View {
  let node: SidebarOutlineNode
  let content: (SidebarOutlineNode) -> AnyView
  @Environment(\.controlActiveState) private var activeState

  var body: some View {
    content(node)
      // The sidebar `List` dimmed unstyled text while its window was not
      // active, to the secondary tone.
      .foregroundStyle(activeState == .inactive ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
  }
}

/// The sidebar's outline view.
final class SidebarOutlineView: NSOutlineView {
  /// The shortest row, as the sidebar `List` sized its rows.
  static let minimumRowHeight: CGFloat = 32
  /// Where row content starts and ends, as in the sidebar `List`.
  static let horizontalInset: CGFloat = 16

  /// True while `mouseDown` tracks a click: the clicked row shows as
  /// selected, but the selection change is not reported until it ends.
  var isTrackingClick = false

  override func mouseDown(with event: NSEvent) {
    isTrackingClick = true
    defer { isTrackingClick = false }
    super.mouseDown(with: event)
  }

  /// No disclosure triangle: rows open with their own chevron.
  override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

  /// Every level starts at the same inset: each row indents its own content.
  override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
    let frame = super.frameOfCell(atColumn: column, row: row)
    return NSRect(
      x: Self.horizontalInset, y: frame.minY, width: max(0, bounds.width - 2 * Self.horizontalInset),
      height: frame.height)
  }
}

/// One outline row. A reference type because `NSOutlineView` tracks items by identity.
final class SidebarOutlineItem: NSObject {
  let id: String
  var node: SidebarOutlineNode
  var children: [SidebarOutlineItem] = []

  init(node: SidebarOutlineNode) {
    id = node.id
    self.node = node
  }
}

/// A cell that hosts a row's SwiftUI content.
final class SidebarOutlineCell: NSTableCellView {
  static let identifier = NSUserInterfaceItemIdentifier("SidebarOutlineCell")

  private let hosting = SidebarRowHostingView(rootView: AnyView(EmptyView()))
  private var content = AnyView(EmptyView())
  private var decorate: ((AnyView) -> AnyView)?
  /// True while the cell has dropped its row (see `viewDidMoveToWindow`).
  private var isCleared = false
  /// Called when the content's size can have changed.
  var onSizeChange: (() -> Void)? {
    get { hosting.onInvalidate }
    set { hosting.onInvalidate = newValue }
  }

  init() {
    super.init(frame: .zero)
    identifier = Self.identifier
    hosting.translatesAutoresizingMaskIntoConstraints = false
    addSubview(hosting)
    // The row is as tall as the content (`contentHeight`); the content sits
    // in its middle.
    NSLayoutConstraint.activate([
      hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
      hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
      hosting.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  // Explicit, so releasing the cell during a SwiftUI teardown skips the isolated-deinit hop.
  deinit {}

  /// The height the row needs.
  var contentHeight: CGFloat {
    max(hosting.fittingSize.height, SidebarOutlineView.minimumRowHeight)
  }

  /// The row's SwiftUI elements, read as the cell's own (row → cell →
  /// content), as VoiceOver read the `List` rows.
  override func accessibilityChildren() -> [Any]? {
    [hosting]
  }

  func show(_ content: AnyView, decorate: @escaping (AnyView) -> AnyView) {
    self.content = content
    self.decorate = decorate
    render()
  }

  override var backgroundStyle: NSView.BackgroundStyle {
    didSet {
      if backgroundStyle != oldValue { render() }
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    // A cell waiting for reuse drops its row, so the row's tasks (status
    // refresh, remote polling) stop as they did when a `List` row left.
    if window == nil {
      hosting.rootView = AnyView(EmptyView())
      isCleared = true
    } else if isCleared {
      render()
    }
  }

  /// On the emphasized selection the row's styles turn light, as they did
  /// in the `List`, which set the same prominence.
  /// Renders before the cell joins the outline, so the outline measures the
  /// row's real height when it lays the row out.
  private func render() {
    guard let decorate else { return }
    isCleared = false
    hosting.rootView = decorate(
      AnyView(
        content
          .environment(\.backgroundProminence, backgroundStyle == .emphasized ? .increased : .standard)))
  }
}

/// Reports when its SwiftUI content asks for a new size.
final class SidebarRowHostingView: NSHostingView<AnyView> {
  var onInvalidate: (() -> Void)?

  /// Text and glyphs blend with the sidebar material, as they did in the
  /// `List`: dimmer in an inactive window, lighter on the selection.
  override var allowsVibrancy: Bool { true }

  override func invalidateIntrinsicContentSize() {
    super.invalidateIntrinsicContentSize()
    onInvalidate?()
  }
}
