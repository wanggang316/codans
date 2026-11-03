import AppKit
import CodansCore
import SwiftUI
import Testing

@testable import Codans

/// The sidebar outline on a real `NSOutlineView`: rows, expansion, selection,
/// and reveal follow the catalog, and only user actions are reported back.
@MainActor
struct SidebarOutlineTests {
  @MainActor
  private final class Harness {
    let coordinator = SidebarOutline.Coordinator()
    let scrollView: NSScrollView
    let window: NSWindow
    var selections: [SidebarSelection] = []

    init(height: CGFloat = 200) {
      scrollView = SidebarOutline.makeScrollView(coordinator: coordinator)
      window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 260, height: height), styleMask: [.titled], backing: .buffered,
        defer: false)
      window.isReleasedWhenClosed = false
      scrollView.frame = NSRect(x: 0, y: 0, width: 260, height: height)
      window.contentView = scrollView
    }

    var outline: SidebarOutlineView { coordinator.outline! }

    func show(
      _ projects: [Project], selection: SidebarSelection? = nil, selectedProjectID: ProjectID? = nil,
      reveal: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    ) {
      coordinator.update(
        with: SidebarOutline(
          nodes: SidebarOutlineModel.nodes(
            projects: projects, pendingWorktrees: [], filter: .all, isReordering: false),
          selection: selection, selectedProjectID: selectedProjectID, revealTrigger: reveal, bottomInset: 0,
          allowsWorktreeDrag: true, decorateRow: { $0 },
          rowContent: { node in AnyView(Text(node.id).frame(height: 20)) },
          onSelect: { [weak self] in self?.selections.append($0) },
          onMoveWorktrees: { _ in }, onMoveProjects: { _, _ in }))
      outline.layoutSubtreeIfNeeded()
    }

    var rowIDs: [String] {
      (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? SidebarOutlineItem)?.id }
    }

    var selectedID: String? {
      (outline.item(atRow: outline.selectedRow) as? SidebarOutlineItem)?.id
    }
  }

  private func repository(_ name: String, worktrees: Int, expanded: Bool = true) -> Project {
    let root = "/\(name)"
    let rows =
      [Worktree(name: "main", path: root, branch: "main")]
      + (0..<worktrees).map { Worktree(name: "w\($0)", path: "\(root)-\($0)", branch: "w\($0)") }
    return Project(
      name: name, rootPath: root, gitRoot: root, worktrees: rows, isExpanded: expanded, loadState: .ready)
  }

  @Test
  func rowsAndExpansionFollowTheCatalog() {
    let harness = Harness()
    var repo = repository("repo", worktrees: 2)
    harness.show([repo])
    #expect(harness.rowIDs.count == 4)

    repo.isExpanded = false
    harness.show([repo])
    #expect(harness.rowIDs == ["project:\(repo.id.raw)"])

    repo.isExpanded = true
    harness.show([repo])
    #expect(harness.rowIDs.count == 4)
  }

  @Test
  func theOutlineDoesNotOpenOrCloseRowsOnItsOwn() throws {
    let harness = Harness()
    let repo = repository("repo", worktrees: 2)
    harness.show([repo])
    let item = try #require(harness.outline.item(atRow: 0))
    // The keyboard's left arrow asks the outline to collapse; only the catalog may.
    harness.outline.collapseItem(item)
    #expect(harness.rowIDs.count == 4)
  }

  @Test
  func selectionFollowsTheCatalogWithoutBeingReported() {
    let harness = Harness()
    let repo = repository("repo", worktrees: 2)
    let target = repo.worktrees[2]
    harness.show([repo], selection: .worktree(target.id), selectedProjectID: repo.id)
    #expect(harness.selectedID == "wt:\(repo.id.raw):\(target.id.raw)")
    harness.show([repo], selection: nil)
    #expect(harness.outline.selectedRow == -1)
    #expect(harness.selections.isEmpty)
  }

  @Test
  func aUserSelectionIsReportedAndAGitProjectRowReportsNone() {
    let harness = Harness()
    let repo = repository("repo", worktrees: 2)
    harness.show([repo])
    harness.outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    // A git Project row stands for no selection, so nothing is reported.
    #expect(harness.selections.isEmpty)
    harness.outline.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
    #expect(harness.selections == [.worktree(repo.worktrees[1].id)])
  }

  @Test
  func aRevealCentersTheSelectedRow() async throws {
    let harness = Harness(height: 200)
    let repo = repository("repo", worktrees: 40)
    let target = repo.worktrees[30]
    harness.show([repo], selection: .worktree(target.id), selectedProjectID: repo.id)
    let clip = harness.scrollView.contentView
    #expect(clip.bounds.minY == 0)
    harness.show(
      [repo], selection: .worktree(target.id), selectedProjectID: repo.id,
      reveal: UUID())
    try await Task.sleep(for: .milliseconds(600))
    let row = harness.outline.row(forItem: try #require(harness.outline.item(atRow: harness.outline.selectedRow)))
    let rowMid = harness.outline.rect(ofRow: row).midY
    #expect(abs(rowMid - (clip.bounds.minY + clip.bounds.height / 2)) < 1)
  }
}
