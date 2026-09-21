import AppKit
import CodansCore
import SwiftUI

/// The changed-file list as an AppKit outline.
///
/// A SwiftUI `List` of nested `DisclosureGroup`s expanded one directory level per update pass,
/// so every new tree (the first open, a scope's first load, switching to the tree) opened level
/// by level for about 100 ms. `NSOutlineView` reloads and expands in one pass, and creates views
/// only for the rows on screen.
struct DiffFileOutline: NSViewRepresentable {
  /// Files in display order, already filtered.
  let files: [GitComparisonFile]
  let tree: Bool
  let selection: String?
  /// A hidden outline keeps its rows and scroll position, and applies changes once shown again.
  let isActive: Bool
  @Binding var collapsedFolders: Set<String>
  let onSelect: (String) -> Void
  let onOpenInEditor: (String) -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    Self.makeScrollView(coordinator: context.coordinator)
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    scrollView.isHidden = !isActive
    context.coordinator.update(with: self)
  }

  static func makeScrollView(coordinator: Coordinator) -> NSScrollView {
    let outline = NSOutlineView()
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
    column.resizingMask = .autoresizingMask
    outline.addTableColumn(column)
    outline.outlineTableColumn = column
    outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    outline.headerView = nil
    outline.style = .sourceList
    // Fixed row heights, not the system's sidebar size setting.
    outline.rowSizeStyle = .custom
    outline.backgroundColor = .clear
    outline.intercellSpacing = NSSize(width: 0, height: Coordinator.rowSpacing)
    outline.allowsMultipleSelection = false
    outline.allowsEmptySelection = true
    outline.dataSource = coordinator
    outline.delegate = coordinator
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.delegate = coordinator
    outline.menu = menu
    outline.setAccessibilityIdentifier("diff-file-list")

    let scrollView = NSScrollView()
    scrollView.documentView = outline
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    coordinator.outline = outline
    return scrollView
  }

  @MainActor
  final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    static let rowSpacing: CGFloat = 4
    private static let rowHeight: CGFloat = 28
    private static let twoLineRowHeight: CGFloat = 36

    weak var outline: NSOutlineView?
    private var config: DiffFileOutline?
    private var roots: [DiffOutlineItem] = []
    private var itemsByFileID: [String: DiffOutlineItem] = [:]
    /// Every folder, deepest first, so collapsing one never hides another still to collapse.
    private var foldersDeepestFirst: [DiffOutlineItem] = []
    private var shownFiles: [GitComparisonFile] = []
    private var shownTree = false
    private var shownCollapsed: Set<String> = []
    /// True while the outline is changed from `update`, so its delegate callbacks do not echo
    /// those changes back as user actions.
    private var applying = false

    // Explicit, so releasing the coordinator during a SwiftUI teardown skips the isolated-deinit hop.
    deinit {}

    func update(with config: DiffFileOutline) {
      self.config = config
      // Changes wait until the outline is shown, so a presentation switch reloads one outline.
      guard config.isActive, let outline else { return }
      applying = true
      defer { applying = false }

      let presentationChanged = config.tree != shownTree
      let rowsChanged =
        presentationChanged
        || !config.files.elementsEqual(shownFiles) { $0.path == $1.path && $0.status == $1.status }
      shownFiles = config.files
      shownTree = config.tree

      if rowsChanged {
        let anchor = topVisibleFile()
        rebuild()
        // Flat rows need no disclosure column, so the outline lays them out like a table.
        outline.outlineTableColumn = config.tree ? outline.tableColumns.first : nil
        outline.reloadData()
        applyExpansion(config.collapsedFolders)
        restore(anchor)
      } else if config.collapsedFolders != shownCollapsed {
        applyExpansion(config.collapsedFolders)
      }
      shownCollapsed = config.collapsedFolders
      syncSelection(config.selection)
    }

    private func rebuild() {
      itemsByFileID = [:]
      foldersDeepestFirst = []
      func items(_ nodes: [DiffFileTreeNode], depth: Int) -> [DiffOutlineItem] {
        nodes.map { node in
          let item = DiffOutlineItem(
            id: node.id, name: node.name, path: node.path, file: node.file, depth: depth,
            children: node.children.map { items($0, depth: depth + 1) })
          if let file = node.file { itemsByFileID[file.id] = item } else { foldersDeepestFirst.append(item) }
          return item
        }
      }
      if shownTree {
        roots = items(DiffFileTreeNode.build(shownFiles), depth: 0)
      } else {
        roots = shownFiles.map { file in
          let item = DiffOutlineItem(
            id: "file:\(file.id)", name: (file.path as NSString).lastPathComponent, path: file.path, file: file,
            depth: 0, children: nil)
          itemsByFileID[file.id] = item
          return item
        }
      }
      foldersDeepestFirst.sort { $0.depth > $1.depth }
    }

    /// Expands everything in one call, then collapses what the user collapsed. One update
    /// batch: expanding a thousand-row tree without it took about half as long again.
    private func applyExpansion(_ collapsed: Set<String>) {
      guard let outline, shownTree else { return }
      outline.beginUpdates()
      outline.expandItem(nil, expandChildren: true)
      for folder in foldersDeepestFirst where collapsed.contains(folder.id) {
        outline.collapseItem(folder)
      }
      outline.endUpdates()
    }

    /// Selects the row for `id`, and never scrolls: the list only moves when the user moves it.
    /// Switching scopes carries the selected file over, and scrolling to it threw away the
    /// position the user had in the scope they arrived at.
    private func syncSelection(_ id: String?) {
      guard let outline else { return }
      let row = id.flatMap { itemsByFileID[$0] }.map { outline.row(forItem: $0) } ?? -1
      guard row >= 0 else {
        if outline.selectedRow >= 0 { outline.deselectAll(nil) }
        return
      }
      if outline.selectedRow != row { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    }

    /// The first file row on screen and how far it sits below the top edge. Rows are rebuilt for
    /// a refresh or a presentation switch, and both keep whatever the user was looking at.
    private func topVisibleFile() -> (id: String, offset: CGFloat)? {
      guard let outline else { return nil }
      let visible = outline.visibleRect
      let rows = outline.rows(in: visible)
      for row in rows.location..<(rows.location + rows.length) {
        guard let file = (outline.item(atRow: row) as? DiffOutlineItem)?.file else { continue }
        return (file.id, outline.rect(ofRow: row).minY - visible.minY)
      }
      return nil
    }

    private func restore(_ anchor: (id: String, offset: CGFloat)?) {
      guard let outline, let anchor, let item = itemsByFileID[anchor.id] else { return }
      let row = outline.row(forItem: item)
      guard row >= 0 else { return }
      outline.scroll(NSPoint(x: 0, y: max(0, outline.rect(ofRow: row).minY - anchor.offset)))
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
      guard let item = item as? DiffOutlineItem else { return roots.count }
      return item.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
      ((item as? DiffOutlineItem)?.children ?? roots)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
      (item as? DiffOutlineItem)?.children != nil
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
      guard let item = item as? DiffOutlineItem else { return nil }
      let cell =
        outlineView.makeView(withIdentifier: DiffOutlineCell.identifier, owner: nil) as? DiffOutlineCell
        ?? DiffOutlineCell()
      cell.show(item, tree: shownTree)
      return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
      guard !shownTree, let file = (item as? DiffOutlineItem)?.file,
        !(file.path as NSString).deletingLastPathComponent.isEmpty
      else { return Self.rowHeight }
      return Self.twoLineRowHeight
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
      (item as? DiffOutlineItem)?.file != nil
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any)
      -> String?
    {
      (item as? DiffOutlineItem)?.name
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
      guard !applying, let outline,
        let file = (outline.item(atRow: outline.selectedRow) as? DiffOutlineItem)?.file
      else { return }
      config?.onSelect(file.id)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
      guard !applying, let item = notification.userInfo?["NSObject"] as? DiffOutlineItem else { return }
      shownCollapsed.remove(item.id)
      config?.collapsedFolders.remove(item.id)
      // Folders inside it open as the user left them, which the outline does not remember for
      // folders it had not loaded yet.
      applying = true
      defer { applying = false }
      expandDescendants(of: item)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
      guard !applying, let outline, let item = notification.userInfo?["NSObject"] as? DiffOutlineItem else { return }
      // Collapsing a folder also collapses the open folders inside it; only the one the user
      // closed is recorded, so the others open again with it.
      if let parent = outline.parent(forItem: item), !outline.isItemExpanded(parent) { return }
      shownCollapsed.insert(item.id)
      config?.collapsedFolders.insert(item.id)
    }

    private func expandDescendants(of item: DiffOutlineItem) {
      for child in item.children ?? [] where child.children != nil && !shownCollapsed.contains(child.id) {
        outline?.expandItem(child)
        expandDescendants(of: child)
      }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
      menu.removeAllItems()
      guard let outline, outline.clickedRow >= 0,
        let file = (outline.item(atRow: outline.clickedRow) as? DiffOutlineItem)?.file
      else { return }
      let open = NSMenuItem(title: "Open in Editor", action: #selector(openInEditor(_:)), keyEquivalent: "")
      open.target = self
      open.representedObject = file.id
      open.isEnabled = file.status != "D"
      menu.addItem(open)
    }

    @objc private func openInEditor(_ sender: NSMenuItem) {
      guard let id = sender.representedObject as? String else { return }
      config?.onOpenInEditor(id)
    }
  }
}

/// One outline row. A reference type because `NSOutlineView` tracks items by identity.
nonisolated final class DiffOutlineItem: NSObject {
  let id: String
  let name: String
  let path: String
  let file: GitComparisonFile?
  let depth: Int
  let children: [DiffOutlineItem]?

  init(id: String, name: String, path: String, file: GitComparisonFile?, depth: Int, children: [DiffOutlineItem]?) {
    self.id = id
    self.name = name
    self.path = path
    self.file = file
    self.depth = depth
    self.children = children
  }
}

/// One row's content, in AppKit: hosting a SwiftUI row per cell cost about a millisecond of layout
/// per row whenever the list changed, about half of a presentation switch.
private final class DiffOutlineCell: NSTableCellView {
  static let identifier = NSUserInterfaceItemIdentifier("DiffOutlineCell")
  private static let folderImage = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?
    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
  private static let iconWidth: CGFloat = 16
  private static let iconSpacing: CGFloat = 8
  private static let statusWidth: CGFloat = 12
  private static let lineSpacing: CGFloat = 2

  private let icon = NSImageView()
  private let name = NSTextField(labelWithString: "")
  private let directory = NSTextField(labelWithString: "")
  private let status = NSTextField(labelWithString: "")
  private var statusColor = NSColor.secondaryLabelColor
  private var isFolder = false
  private var inTree = false

  init() {
    super.init(frame: .zero)
    identifier = Self.identifier
    // Not the cell's `textField`: AppKit tints that one with the accent color on an inactive
    // selection, where the list has always used plain text.
    name.font = .systemFont(ofSize: 13)
    name.lineBreakMode = .byTruncatingMiddle
    directory.font = .systemFont(ofSize: 11)
    directory.lineBreakMode = .byTruncatingMiddle
    status.font = .systemFont(ofSize: 10, weight: .semibold)
    status.alignment = .center
    icon.imageScaling = .scaleProportionallyDown
    for view in [icon, name, directory, status] { addSubview(view) }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  // Explicit, so releasing the cell during a SwiftUI teardown skips the isolated-deinit hop.
  deinit {}

  override var isFlipped: Bool { true }

  func show(_ item: DiffOutlineItem, tree: Bool) {
    isFolder = item.file == nil
    inTree = tree
    name.stringValue = item.name
    toolTip = item.path
    if let file = item.file {
      // No icon: a kind symbol says nothing the file name does not, and the icon of the app that
      // happens to own the extension says even less.
      icon.image = nil
      let parent = (file.path as NSString).deletingLastPathComponent
      directory.stringValue = parent
      directory.isHidden = tree || parent.isEmpty
      status.stringValue = file.status
      status.isHidden = false
      statusColor = Self.color(forStatus: file.status)
    } else {
      icon.image = Self.folderImage
      directory.isHidden = true
      status.isHidden = true
    }
    applyColors()
    needsLayout = true
  }

  override var backgroundStyle: NSView.BackgroundStyle {
    didSet { applyColors() }
  }

  /// On the emphasized selection everything turns white, as it does in any source list.
  private func applyColors() {
    let emphasized = backgroundStyle == .emphasized
    name.textColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
    directory.textColor =
      emphasized ? .alternateSelectedControlTextColor.withAlphaComponent(0.75) : .secondaryLabelColor
    status.textColor = emphasized ? .alternateSelectedControlTextColor : statusColor
    icon.contentTintColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
  }

  override func layout() {
    super.layout()
    let height = bounds.height
    icon.frame = NSRect(x: 0, y: (height - Self.iconWidth) / 2, width: Self.iconWidth, height: Self.iconWidth)
    // In the tree a file's name lines up with the folder names, one indent step further in.
    let textX = isFolder || inTree ? Self.iconWidth + Self.iconSpacing : 2
    let trailing = status.isHidden ? 0 : Self.statusWidth + 4
    let textWidth = max(0, bounds.width - textX - trailing)
    let nameHeight = name.intrinsicContentSize.height
    if directory.isHidden {
      name.frame = NSRect(x: textX, y: (height - nameHeight) / 2, width: textWidth, height: nameHeight)
    } else {
      let directoryHeight = directory.intrinsicContentSize.height
      let top = (height - nameHeight - Self.lineSpacing - directoryHeight) / 2
      name.frame = NSRect(x: textX, y: top, width: textWidth, height: nameHeight)
      directory.frame = NSRect(
        x: textX, y: top + nameHeight + Self.lineSpacing, width: textWidth, height: directoryHeight)
    }
    let statusHeight = status.intrinsicContentSize.height
    status.frame = NSRect(
      x: bounds.width - Self.statusWidth, y: (height - statusHeight) / 2, width: Self.statusWidth,
      height: statusHeight)
  }

  private static func color(forStatus status: String) -> NSColor {
    switch status {
    case "A": NSColor(ThemeGit.kindAdded)
    case "D": NSColor(ThemeGit.kindDeleted)
    case "M": NSColor(ThemeGit.kindModified)
    case "R": NSColor(ThemeGit.kindRenamed)
    default: .secondaryLabelColor
    }
  }
}
