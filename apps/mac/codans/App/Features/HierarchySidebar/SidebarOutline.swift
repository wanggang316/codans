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
    private var heightUpdateScheduled = false
    /// Each row's measured height, by row id. Kept across updates, so a
    /// reload measures only the rows it has not seen.
    private var heights: [String: CGFloat] = [:]
    /// Measures rows that have no cell yet.
    private lazy var sizingCell = SidebarOutlineCell()
    /// True while the outline is changed from `update`, so its delegate
    /// callbacks do not echo those changes back as user actions.
    private var applying = false

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

      let structure = rebuild(config.nodes)
      if structure != shownStructure {
        shownStructure = structure
        outline.reloadData()
        scheduleHeightUpdate()
      } else {
        refreshVisibleRows()
      }
      applyExpansion()
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

    /// Opens and closes rows to match the catalog, parents first, so a row
    /// that opens shows its children as they are now. No animation: the
    /// sidebar has always opened at once.
    private func applyExpansion() {
      guard let outline else { return }
      NSAnimationContext.beginGrouping()
      NSAnimationContext.current.duration = 0
      NSAnimationContext.current.allowsImplicitAnimation = false
      defer { NSAnimationContext.endGrouping() }
      func apply(_ items: [SidebarOutlineItem]) {
        for item in items where !item.children.isEmpty {
          let expanded = item.node.isExpanded
          if expanded, !outline.isItemExpanded(item) {
            outline.expandItem(item)
          } else if !expanded, outline.isItemExpanded(item) {
            outline.collapseItem(item)
          }
          if expanded { apply(item.children) }
        }
      }
      apply(roots)
    }

    private func refreshVisibleRows() {
      guard let outline else { return }
      let rows = outline.rows(in: outline.visibleRect)
      for row in rows.location..<(rows.location + rows.length) {
        guard let item = outline.item(atRow: row) as? SidebarOutlineItem,
          let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarOutlineCell
        else { continue }
        show(item, in: cell)
      }
      scheduleHeightUpdate()
    }

    private func show(_ item: SidebarOutlineItem, in cell: SidebarOutlineCell) {
      guard let config else { return }
      let node = item.node
      cell.show(
        AnyView(SidebarOutlineRowHost(node: node, content: config.rowContent)),
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
      return item.children.count
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
