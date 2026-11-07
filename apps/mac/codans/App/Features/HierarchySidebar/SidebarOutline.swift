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
    /// The fade and move of each child row of the last animated toggles,
    /// by row id (see `animate`).
    private var childPlans: [String: ChildRowPlan] = [:]
    /// The views of the rows the last animated close is fading out.
    private var closingViews: [String: NSTableRowView] = [:]
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
      animate(childRowViews(under: item, in: outline, make: true), opening: true)
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

    /// Starts the reference's fade and move on each child row (ADR 0008).
    /// The table fades the row view with the row curve and keeps that fade
    /// on top; the plan shapes what shows from the row's cell and moves the
    /// row view (`ChildRowPlan`). A row's animation is a plan in time, not a
    /// property of a view: the table can show a row in another view part
    /// way through, and `didAdd` gives that view the same animation, at the
    /// same point. A second toggle during a plan starts from where the plan
    /// has got to, so the opacity and the offset stay continuous.
    private func animate(_ rows: [(id: String, view: NSTableRowView)], opening: Bool) {
      animatedChildIDs = rows.map(\.id)
      let now = CACurrentMediaTime()
      for (id, view) in rows {
        let running = childPlans[id].flatMap { $0.isRunning(at: now) ? $0 : nil }
        let plan: ChildRowPlan
        switch (opening, running) {
        case (true, nil): plan = .open(at: now)
        case (true, let running?): plan = .reopen(from: running.state(at: now), at: now)
        case (false, nil): plan = .close(from: ChildRowState(opacity: 1, offset: 0), at: now, fresh: true)
        case (false, let running?): plan = .close(from: running.state(at: now), at: now)
        }
        childPlans[id] = plan
        // When the row comes back in another view, the view that showed it
        // while it closed keeps fading out: the two fades overlap, so what
        // shows has no step.
        plan.apply(to: view)
      }
      closingViews = opening ? [:] : Dictionary(rows.map { ($0.id, $0.view) }, uniquingKeysWith: { first, _ in first })
      // The table can show a row in another view after this, as it lays
      // the rows out: apply the plans again once it has. They are dated
      // from their start, so this does not change what shows.
      DispatchQueue.main.async { [weak self] in
        self?.reapplyChildPlans(alignToTable: false)
        DispatchQueue.main.async { [weak self] in self?.reapplyChildPlans(alignToTable: false) }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.reapplyChildPlans(alignToTable: true) }
    }

    /// When the table's own fade of `view` started, in `CACurrentMediaTime`,
    /// worked out from how far that fade has got: the table does not report
    /// it, and starts it only when it next draws.
    private static func tableFadeStart(of view: NSTableRowView, opening: Bool, now: CFTimeInterval) -> CFTimeInterval? {
      guard let shown = view.layer?.presentation()?.opacity, view.layer?.animation(forKey: "opacity") != nil
      else { return nil }
      let progress = opening ? Double(shown) : 1 - Double(shown)
      guard progress > 0.02, progress < 0.98 else { return nil }
      let timing = SidebarDisclosureTiming.self
      var low = 0.0
      var high = 1.0
      for _ in 0..<30 {
        let mid = (low + high) / 2
        if timing.rowCurve.progress(at: mid) < progress { low = mid } else { high = mid }
      }
      return now - (low + high) / 2 * timing.rows
    }

    private func reapplyChildPlans(alignToTable: Bool) {
      guard let outline else { return }
      let now = CACurrentMediaTime()
      for (id, running) in childPlans where running.isRunning(at: now) {
        guard let item = itemsByID[id] else { continue }
        let row = outline.row(forItem: item)
        guard row >= 0, let view = outline.rowView(atRow: row, makeIfNecessary: false) else { continue }
        // The table starts its fade of the row view when it next draws, a
        // little after the plan started; the plan divides by that fade, so a
        // plan from rest moves onto the table's clock.
        var plan = running
        if alignToTable, let fresh = plan.freshOpening,
          let tableStart = Self.tableFadeStart(of: view, opening: fresh, now: now),
          tableStart > plan.start, tableStart - plan.start < 0.05
        {
          plan = plan.starting(at: tableStart)
          childPlans[id] = plan
        }
        plan.apply(to: view)
      }
      for (id, view) in closingViews where childPlans[id]?.isRunning(at: now) == true {
        childPlans[id]?.apply(to: view)
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

    /// A view that starts to show a row takes the row's running fade and
    /// move, at the point they have got to; a reused view drops any other.
    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
      guard let item = outlineView.item(atRow: row) as? SidebarOutlineItem else { return }
      if let plan = childPlans[item.id], plan.isRunning(at: CACurrentMediaTime()) {
        plan.apply(to: rowView)
      } else {
        ChildRowPlan.clear(rowView)
      }
    }

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

/// The opacity and offset a child row shows. The outline is flipped: a
/// negative offset is above the row's place.
struct ChildRowState: Equatable {
  let opacity: Double
  let offset: Double
}

/// One value of a child row over time: pieces of curves, end to end, from
/// the plan's start.
struct ChildRowTrack {
  struct Piece {
    let end: TimeInterval
    let to: Double
    let curve: CAMediaTimingFunction
  }

  let from: Double
  let pieces: [Piece]

  var duration: TimeInterval { pieces.last?.end ?? 0 }

  func value(at time: TimeInterval) -> Double {
    var start: TimeInterval = 0
    var value = from
    for piece in pieces {
      if time < piece.end {
        let length = piece.end - start
        let progress = length > 0 ? piece.curve.progress(at: (time - start) / length) : 1
        return value + (piece.to - value) * progress
      }
      start = piece.end
      value = piece.to
    }
    return value
  }

  func animation(_ keyPath: String) -> CAKeyframeAnimation {
    let animation = CAKeyframeAnimation(keyPath: keyPath)
    animation.duration = duration
    animation.values = [from] + pieces.map(\.to)
    animation.keyTimes = ([0] + pieces.map { $0.end / duration }).map { NSNumber(value: $0) }
    animation.timingFunctions = pieces.map(\.curve)
    return animation
  }
}

/// The fade and move of one child row for one toggle, from `start`
/// (`CACurrentMediaTime`).
struct ChildRowPlan {
  let start: CFTimeInterval
  /// For a plan from rest, whether it opens; nil for a plan that took over
  /// from another one, whose table fade does not follow the row curve.
  var freshOpening: Bool?
  /// The opacity of the row's cell. The table fades the row view itself
  /// with the row curve; the two multiply.
  let opacity: ChildRowTrack
  /// Where the row shows, against its place.
  let offset: ChildRowTrack

  private static let linear = CAMediaTimingFunction(name: .linear)
  private static let easeInOut = CAMediaTimingFunction(name: .easeInEaseOut)
  private static let fadeKey = "sidebar.childFade"
  private static let moveKey = "sidebar.childMove"

  var duration: TimeInterval { max(opacity.duration, offset.duration) }

  func isRunning(at time: CFTimeInterval) -> Bool { time - start < duration }

  /// The same plan from `start`.
  func starting(at start: CFTimeInterval) -> Self {
    Self(start: start, freshOpening: nil, opacity: opacity, offset: offset)
  }

  func state(at time: CFTimeInterval) -> ChildRowState {
    ChildRowState(opacity: opacity.value(at: time - start), offset: offset.value(at: time - start))
  }

  /// What shows of a row: the table's fade of the row view times the
  /// plan's fade of its cell.
  static func shown(cell: Double, at time: TimeInterval, opening: Bool) -> Double {
    let table = SidebarDisclosureTiming.rowCurve.progress(at: time / SidebarDisclosureTiming.rows)
    return cell * (opening ? table : 1 - table)
  }

  /// The cell's fade, sampled, that makes the table's fade times it follow
  /// `target`: the cell holds back where the table is ahead of the target,
  /// and stays at `start` where the table is behind.
  private static func cellFade(
    from start: Double, opening: Bool, _ target: (TimeInterval) -> Double
  ) -> ChildRowTrack {
    let timing = SidebarDisclosureTiming.self
    let step = 0.01
    let count = Int((timing.rows / step).rounded())
    let pieces = (1...count).map { index -> ChildRowTrack.Piece in
      let time = Double(index) * step
      let table = timing.rowCurve.progress(at: time / timing.rows)
      let fade = opening ? table : 1 - table
      let value = fade > 0.001 ? min(start, target(time) / fade) : (opening ? start : 0)
      return .init(end: time, to: max(value, 0), curve: linear)
    }
    return ChildRowTrack(from: opening ? 0 : start, pieces: pieces)
  }

  /// Fades in from nothing, slowly at first; waits above the row's place,
  /// then follows the rows below.
  static func open(at start: CFTimeInterval) -> Self {
    let timing = SidebarDisclosureTiming.self
    let offset = -Double(timing.openOffset)
    return Self(
      start: start, freshOpening: true,
      opacity: cellFade(from: 1, opening: true) {
        timing.value(of: timing.openFadeCurve, at: $0 - timing.openFadeDelay)
      },
      offset: ChildRowTrack(
        from: offset,
        pieces: [
          .init(end: timing.openMoveDelay, to: offset, curve: linear),
          .init(end: timing.openMoveDelay + timing.rows, to: 0, curve: timing.rowCurve),
        ]))
  }

  /// From where a close has got to, back in and down to the row's place.
  static func reopen(from state: ChildRowState, at start: CFTimeInterval) -> Self {
    let timing = SidebarDisclosureTiming.self
    return Self(
      start: start, freshOpening: nil,
      opacity: ChildRowTrack(
        from: state.opacity,
        pieces: [
          .init(end: max(timing.openFade * (1 - state.opacity), 0.05), to: 1, curve: easeInOut),
          .init(end: timing.rows, to: 1, curve: linear),
        ]),
      offset: ChildRowTrack(from: state.offset, pieces: [.init(end: timing.rows, to: 0, curve: timing.rowCurve)]))
  }

  /// Out to nothing from where the row is, while it speeds up as it moves
  /// up; hidden until the table drops the row.
  static func close(from state: ChildRowState, at start: CFTimeInterval, fresh: Bool = false) -> Self {
    let timing = SidebarDisclosureTiming.self
    let top = state.offset - Double(timing.closeLift)
    return Self(
      start: start, freshOpening: fresh ? false : nil,
      opacity: cellFade(from: state.opacity, opening: false) {
        timing.value(of: timing.closeFadeCurve, at: $0 - timing.closeFadeDelay)
      },
      offset: ChildRowTrack(
        from: state.offset,
        pieces: [
          .init(end: timing.closeLiftTime, to: top, curve: timing.closeLiftCurve),
          .init(end: timing.rows, to: top, curve: linear),
        ]))
  }

  /// Runs the plan on `view` from its start, so a view added late joins it
  /// part way through: the fade on the row's cell, the move on the row
  /// view. Not kept on the layers when it ends, because the table reuses
  /// row views.
  func apply(to view: NSTableRowView) {
    view.wantsLayer = true
    guard let rowLayer = view.layer, let cellLayer = Self.cellLayer(of: view) else { return }
    let begin = rowLayer.convertTime(start, from: nil)
    let fade = opacity.animation("opacity")
    let move = offset.animation("transform.translation.y")
    for animation in [fade, move] {
      animation.beginTime = begin
      animation.fillMode = .backwards
    }
    cellLayer.add(fade, forKey: Self.fadeKey)
    rowLayer.add(move, forKey: Self.moveKey)
  }

  /// The layer of the row's cell: the table animates the row view's
  /// opacity, not the cell's.
  private static func cellLayer(of view: NSTableRowView) -> CALayer? {
    guard let cell = view.subviews.first else { return nil }
    cell.wantsLayer = true
    return cell.layer
  }

  static func clear(_ view: NSTableRowView) {
    cellLayer(of: view)?.removeAnimation(forKey: fadeKey)
    view.layer?.removeAnimation(forKey: moveKey)
  }
}

extension CAMediaTimingFunction {
  /// The curve's value at `time`, both from 0 to 1.
  func progress(at time: Double) -> Double {
    let x = min(max(time, 0), 1)
    var first: [Float] = [0, 0]
    var second: [Float] = [0, 0]
    getControlPoint(at: 1, values: &first)
    getControlPoint(at: 2, values: &second)
    func bezier(_ s: Double, _ p1: Float, _ p2: Float) -> Double {
      let u = 1 - s
      return 3 * u * u * s * Double(p1) + 3 * u * s * s * Double(p2) + s * s * s
    }
    var low = 0.0
    var high = 1.0
    for _ in 0..<30 {
      let mid = (low + high) / 2
      if bezier(mid, first[0], second[0]) < x { low = mid } else { high = mid }
    }
    return bezier((low + high) / 2, first[1], second[1])
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
  /// On open, the child rows wait `openOffset` above their place for
  /// `openMoveDelay`, then slide down on `rowCurve`.
  static let openOffset: CGFloat = 16
  static let openMoveDelay: TimeInterval = 0.055
  /// On open, the child rows' opacity from `openFadeDelay`, one value per
  /// 1/60 s. The first four frames stay faint (at most 0.25), where the eye
  /// sees most; no frame changes by more than 0.18.
  static let openFadeDelay: TimeInterval = 0.05
  static let openFadeCurve: [Double] = [0, 0.03, 0.08, 0.15, 0.25, 0.40, 0.58, 0.74, 0.86, 0.94, 0.98, 1]
  /// A fade back in after a close was cut short takes up to this long.
  static let openFade: TimeInterval = 0.15
  /// On close, the child rows' opacity from `closeFadeDelay`, one value per
  /// 1/60 s: the last four frames stay faint (under 0.25) before they are
  /// gone.
  /// Meanwhile they speed up as they move up `closeLift` over
  /// `closeLiftTime` (quadratic ease-in, about 1 pt after 45 ms and 7 pt
  /// after 110 ms), and the rows below slide over them.
  static let closeFadeDelay: TimeInterval = 0.02
  static let closeFadeCurve: [Double] = [1, 0.92, 0.80, 0.64, 0.46, 0.32, 0.20, 0.12, 0.06, 0.02, 0]
  static let closeLift: CGFloat = 11
  static let closeLiftTime: TimeInterval = 0.14
  static let closeLiftCurve = CAMediaTimingFunction(controlPoints: 1 / 3, 0, 2 / 3, 1 / 3)
  /// `curve` (one value per 1/60 s) at `time`, between its ends.
  static func value(of curve: [Double], at time: TimeInterval) -> Double {
    let position = time * 60
    guard position > 0 else { return curve[0] }
    let index = Int(position)
    guard index + 1 < curve.count else { return curve[curve.count - 1] }
    let fraction = position - Double(index)
    return curve[index] + (curve[index + 1] - curve[index]) * fraction
  }

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
