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
