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
      reveal: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
      toggle: SidebarExpansionToggle? = nil, hostLevel: SidebarHostLevel? = nil
    ) {
      coordinator.update(
        with: SidebarOutline(
          nodes: SidebarOutlineModel.nodes(
            projects: projects, hostLevel: hostLevel, pendingWorktrees: [], filter: .all),
          selection: selection, selectedProjectID: selectedProjectID, revealTrigger: reveal,
          expansionToggle: toggle, bottomInset: 0,
          allowsWorktreeDrag: true, decorateRow: { $0 },
          rowContent: { node in AnyView(Text(node.id).frame(height: 20)) },
          onSelect: { [weak self] in self?.selections.append($0) },
          onMoveWorktrees: { _ in }, onToggleProject: { _ in }, onMoveProject: { _, _ in }))
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
  func onlyANewUserToggleAnimatesItsRow() async throws {
    let harness = Harness()
    var repo = repository("repo", worktrees: 2, expanded: false)
    // Reduce Motion turns the animation off for user toggles too.
    let projectNode =
      NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : "project:\(repo.id.raw)"
    let earlier = SidebarExpansionToggle(target: .project(repo.id), sequence: 1)

    // A toggle that is in the store before the outline shows (a filter
    // change rebuilt the view) does not animate.
    harness.show([repo], toggle: earlier)
    #expect(harness.coordinator.animatedNodeID == nil)

    // A catalog change with no new toggle (a reveal, the CLI) is instant.
    repo.isExpanded = true
    harness.show([repo], toggle: earlier)
    #expect(harness.coordinator.animatedNodeID == nil)
    #expect(harness.rowIDs.count == 4)

    // The user closes the row: it animates, and the outline ends in the
    // catalog state.
    repo.isExpanded = false
    let close = SidebarExpansionToggle.next(.project(repo.id), after: earlier)
    harness.show([repo], toggle: close)
    #expect(harness.coordinator.animatedNodeID == projectNode)

    // The user opens it again during the animation: it turns around.
    repo.isExpanded = true
    harness.show([repo], toggle: .next(.project(repo.id), after: close))
    #expect(harness.coordinator.animatedNodeID == projectNode)
    try await Task.sleep(for: .milliseconds(600))
    #expect(harness.rowIDs.count == 4)
  }

  /// An animated toggle opens a row with no children and inserts them, so
  /// the rows under an open child must come back too, and a closed child
  /// must stay closed.
  @Test
  func anAnimatedToggleEndsWithTheCatalogRowsAtEveryLevel() async throws {
    let harness = Harness()
    let open = repository("open", worktrees: 1)
    let closed = repository("closed", worktrees: 1, expanded: false)
    func show(collapsed: Set<SidebarHost>, toggle: SidebarExpansionToggle?) {
      harness.show(
        [open, closed], toggle: toggle,
        hostLevel: SidebarHostLevel(records: [], collapsed: collapsed, keepsThisMac: true))
    }
    show(collapsed: [], toggle: nil)
    let all = harness.rowIDs
    #expect(all.count == 5)

    let close = SidebarExpansionToggle.next(.host(.thisMac), after: nil)
    show(collapsed: [.thisMac], toggle: close)
    #expect(harness.rowIDs == [SidebarOutlineModel.hostNodeID(.thisMac)])

    show(collapsed: [], toggle: .next(.host(.thisMac), after: close))
    #expect(harness.rowIDs == all)
    try await Task.sleep(for: .milliseconds(600))
    #expect(harness.rowIDs == all)
  }

  /// On an animated close the child rows move up a few points while they
  /// fade (ADR 0008): the table's own `.slideUp` would move them by their
  /// whole height, so the outline adds the move to their layers.
  @Test
  func anAnimatedCloseLiftsTheChildRows() {
    let harness = Harness()
    var repo = repository("repo", worktrees: 2)
    harness.show([repo])
    let children = Array(harness.rowIDs.dropFirst())
    #expect(children.count == 3)

    repo.isExpanded = false
    harness.show([repo], toggle: .next(.project(repo.id), after: nil))
    // Reduce Motion closes the row at once, with nothing to lift.
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    #expect(harness.coordinator.liftedNodeIDs == (reduceMotion ? [] : children))
    #expect(harness.rowIDs == ["project:\(repo.id.raw)"])
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
