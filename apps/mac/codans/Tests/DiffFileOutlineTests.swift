import AppKit
import CodansCore
import SwiftUI
import Testing

@testable import Codans

@MainActor
struct DiffFileOutlineTests {
  private let one = GitComparisonFile(path: "a/b/c/one.swift", status: "M")
  private let two = GitComparisonFile(path: "a/two.swift", status: "A")
  private let top = GitComparisonFile(path: "z.swift", status: "D")

  @Test func treeShowsEveryFolderExpandedAfterOneUpdate() throws {
    let harness = try Harness()
    harness.show([one, two, top])
    #expect(harness.rowNames == ["a", "b", "c", "one.swift", "two.swift", "z.swift"])
  }

  @Test func collapsedFoldersStayCollapsedWhenTheFilesChange() throws {
    let harness = try Harness()
    harness.collapsed = ["dir:a/b"]
    harness.show([one, two, top])
    #expect(harness.rowNames == ["a", "b", "two.swift", "z.swift"])
    harness.show([one, GitComparisonFile(path: "a/b/c/three.swift", status: "A"), two, top])
    #expect(harness.rowNames == ["a", "b", "two.swift", "z.swift"])
  }

  @Test func collapsingAndExpandingByHandUpdatesTheBindingAndRestoresInnerFolders() throws {
    let harness = try Harness()
    harness.show([one, two, top])
    let folder = try #require(harness.outline.item(atRow: 0) as? DiffOutlineItem)
    harness.outline.collapseItem(folder)
    #expect(harness.collapsed == ["dir:a"])
    #expect(harness.rowNames == ["a", "z.swift"])
    harness.outline.expandItem(folder)
    #expect(harness.collapsed.isEmpty)
    #expect(harness.rowNames == ["a", "b", "c", "one.swift", "two.swift", "z.swift"])
  }

  @Test func clickingAFolderRowAnywhereButTheTriangleOpensAndClosesIt() throws {
    let harness = try Harness()
    harness.show([one, two, top])
    harness.coordinator.toggleFolder(atRow: 0, clickedAt: nil)
    #expect(harness.collapsed == ["dir:a"])
    #expect(harness.rowNames == ["a", "z.swift"])
    harness.coordinator.toggleFolder(atRow: 0, clickedAt: nil)
    #expect(harness.collapsed.isEmpty)
    #expect(harness.rowNames == ["a", "b", "c", "one.swift", "two.swift", "z.swift"])

    // The triangle toggles the folder on its own, and a file row is not a folder at all.
    let triangle = harness.outline.frameOfOutlineCell(atRow: 0)
    #expect(triangle.width > 0)
    harness.coordinator.toggleFolder(atRow: 0, clickedAt: NSPoint(x: triangle.midX, y: triangle.midY))
    harness.coordinator.toggleFolder(atRow: harness.row(named: "one.swift"), clickedAt: nil)
    #expect(harness.rowNames.count == 6)
  }

  @Test func aFileNameStartsWhereTheNameOfTheFolderItSitsInStarts() throws {
    let harness = try Harness()
    harness.show([one, two, top])
    // One step per level, so the rows below are being measured and not defaulted.
    #expect(harness.nameX(named: "b") == harness.nameX(named: "a") + DiffOutlineCell.indentPerLevel)
    #expect(harness.nameX(named: "one.swift") == harness.nameX(named: "c"))
    #expect(harness.nameX(named: "two.swift") == harness.nameX(named: "a"))
    // A file at the root of the tree has no folder above it and stays in the root's column.
    #expect(harness.nameX(named: "z.swift") == harness.nameX(named: "a"))
  }

  @Test func flatListShowsOneRowPerFileAndMakesRowsWithADirectoryTaller() throws {
    let harness = try Harness()
    harness.show([one, two, top], tree: false)
    #expect(harness.rowNames == ["one.swift", "two.swift", "z.swift"])
    #expect(harness.outline.rect(ofRow: 0).height > harness.outline.rect(ofRow: 2).height)
  }

  @Test func selectionFollowsTheStoreAndOnlyUserChangesAreReported() throws {
    let harness = try Harness()
    harness.show([one, two, top], selection: top.id)
    #expect(harness.selectedName == "z.swift")
    #expect(harness.selected.isEmpty)

    harness.outline.selectRowIndexes(IndexSet(integer: harness.row(named: "two.swift")), byExtendingSelection: false)
    #expect(harness.selected == [two.id])

    let folder = try #require(harness.outline.item(atRow: 0))
    #expect(harness.coordinator.outlineView(harness.outline, shouldSelectItem: folder) == false)

    // A selected file that leaves the list leaves no selected row behind.
    harness.show([one, two], selection: top.id)
    #expect(harness.outline.selectedRow == -1)
  }

  @Test func switchingPresentationKeepsTheFileTheUserIsLookingAt() throws {
    let harness = try Harness()
    let many = (0..<60).map { GitComparisonFile(path: "d/f\(String(format: "%02d", $0)).swift", status: "M") }
    harness.show(many)
    harness.scroll(toRow: 40)
    let anchor = try #require(harness.topVisibleName)

    harness.show(many, tree: false)
    #expect(harness.topVisibleName == anchor)
    harness.show(many)
    #expect(harness.topVisibleName == anchor)

    // Selecting a file the user cannot see — switching scopes carries the selection over — must
    // not scroll the list to it either.
    harness.show(many, selection: try #require(many.last).id)
    #expect(harness.topVisibleName == anchor)
  }

  @Test func hiddenOutlineAppliesChangesOnceShown() throws {
    let harness = try Harness()
    harness.show([one, two, top])
    harness.show([top], active: false)
    #expect(harness.rowNames == ["a", "b", "c", "one.swift", "two.swift", "z.swift"])
    harness.show([top], active: true)
    #expect(harness.rowNames == ["z.swift"])
  }

  @Test func contextMenuOpensFilesButNotDeletedFilesOrFolders() throws {
    let harness = try Harness()
    harness.show([one, two, top])
    #expect(harness.menuItems(atRow: harness.row(named: "one.swift")) == ["Open in Editor: enabled"])
    #expect(harness.menuItems(atRow: harness.row(named: "z.swift")) == ["Open in Editor: disabled"])
    #expect(harness.menuItems(atRow: 0).isEmpty)

    let menu = try #require(harness.outline.menu)
    _ = harness.menuItems(atRow: harness.row(named: "two.swift"))
    menu.performActionForItem(at: 0)
    #expect(harness.opened == [two.id])
  }
}

/// A real outline in an off-screen window, driven the way SwiftUI drives the representable.
@MainActor
private final class Harness {
  let coordinator = DiffFileOutline.Coordinator()
  let outline: NSOutlineView
  private let window: NSWindow
  var collapsed: Set<String> = []
  var selected: [String] = []
  var opened: [String] = []

  init() throws {
    let scrollView = DiffFileOutline.makeScrollView(coordinator: coordinator)
    outline = try #require(scrollView.documentView as? NSOutlineView)
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 600), styleMask: [.titled], backing: .buffered,
      defer: false)
    window.contentView = scrollView
  }

  deinit {}

  var rowNames: [String] {
    (0..<outline.numberOfRows).map { (outline.item(atRow: $0) as? DiffOutlineItem)?.name ?? "?" }
  }

  var selectedName: String? {
    (outline.item(atRow: outline.selectedRow) as? DiffOutlineItem)?.name
  }

  func row(named name: String) -> Int {
    rowNames.firstIndex(of: name) ?? -1
  }

  /// The first row on screen, as the user sees it.
  var topVisibleName: String? {
    let visible = outline.rows(in: outline.visibleRect)
    guard visible.length > 0 else { return nil }
    return (outline.item(atRow: visible.location) as? DiffOutlineItem)?.name
  }

  /// Where the row's name is drawn, across the whole outline.
  func nameX(named name: String) -> CGFloat {
    outline.layoutSubtreeIfNeeded()
    guard let cell = outline.view(atColumn: 0, row: row(named: name), makeIfNecessary: true) as? DiffOutlineCell
    else { return -1 }
    cell.layoutSubtreeIfNeeded()
    return cell.convert(cell.nameFrame.origin, to: outline).x
  }

  func scroll(toRow row: Int) {
    outline.scroll(NSPoint(x: 0, y: outline.rect(ofRow: row).minY))
    outline.layoutSubtreeIfNeeded()
  }

  func show(_ files: [GitComparisonFile], tree: Bool = true, selection: String? = nil, active: Bool = true) {
    coordinator.update(
      with: DiffFileOutline(
        files: files, tree: tree, selection: selection, isActive: active,
        collapsedFolders: Binding(get: { self.collapsed }, set: { self.collapsed = $0 }),
        onSelect: { self.selected.append($0) },
        onOpenInEditor: { self.opened.append($0) }))
  }

  /// Right-clicks the row, as the outline sees it, and returns the menu it would show.
  func menuItems(atRow row: Int) -> [String] {
    let rect = outline.rect(ofRow: row)
    let location = outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
    guard
      let event = NSEvent.mouseEvent(
        with: .rightMouseDown, location: location, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
      let menu = outline.menu(for: event)
    else { return ["no menu"] }
    coordinator.menuNeedsUpdate(menu)
    return menu.items.map { "\($0.title): \($0.isEnabled ? "enabled" : "disabled")" }
  }
}
