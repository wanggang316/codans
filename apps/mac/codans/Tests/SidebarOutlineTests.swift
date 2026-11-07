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

  /// The table's own fade of inserted and removed rows runs over the whole
  /// row animation, so the outline adds the reference's fade and move to
  /// every child row on screen, on close and on open (ADR 0008).
  @Test
  func anAnimatedToggleAnimatesTheChildRowsOnScreen() {
    let harness = Harness()
    var repo = repository("repo", worktrees: 2)
    harness.show([repo])
    let children = Array(harness.rowIDs.dropFirst())
    #expect(children.count == 3)
    // Reduce Motion opens and closes at once, with no row to animate.
    let animated = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? [] : children

    repo.isExpanded = false
    let close = SidebarExpansionToggle.next(.project(repo.id), after: nil)
    harness.show([repo], toggle: close)
    #expect(harness.coordinator.animatedChildIDs == animated)
    #expect(harness.rowIDs == ["project:\(repo.id.raw)"])

    repo.isExpanded = true
    harness.show([repo], toggle: .next(.project(repo.id), after: close))
    #expect(harness.coordinator.animatedChildIDs == animated)
    #expect(harness.rowIDs == ["project:\(repo.id.raw)"] + children)
  }

  /// After an animated close and a later animated open, every row shows:
  /// no row view the table reuses keeps an opacity the animation set. (An
  /// offscreen window does not run the animations to their end, so this
  /// checks the layers' own values.)
  @Test
  func everyRowShowsAfterAnAnimatedCloseAndOpen() async throws {
    let harness = Harness()
    var repo = repository("repo", worktrees: 2)
    harness.show([repo])
    repo.isExpanded = false
    let close = SidebarExpansionToggle.next(.project(repo.id), after: nil)
    harness.show([repo], toggle: close)
    try await Task.sleep(for: .milliseconds(500))
    repo.isExpanded = true
    harness.show([repo], toggle: .next(.project(repo.id), after: close))
    try await Task.sleep(for: .milliseconds(500))
    harness.outline.layoutSubtreeIfNeeded()
    #expect(harness.rowIDs.count == 4)
    for row in 0..<harness.outline.numberOfRows {
      let view = try #require(harness.outline.rowView(atRow: row, makeIfNecessary: false))
      #expect(view.alphaValue == 1)
      #expect((view.layer?.opacity ?? 1) == 1)
    }
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

  /// A Project that failed to load is a child row like any other: a user
  /// toggle of its Host fades and moves it with the same plan as its
  /// siblings, on open, on close, and on a toggle during the animation. A
  /// catalog update that leaves the failed row as it is (a sweep that finds
  /// it still failed) keeps the running animations.
  @Test
  func aFailedProjectRowFadesLikeTheOtherChildRows() async throws {
    try #require(!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    let harness = Harness(height: 400)
    let healthy = repository("healthy", worktrees: 1, expanded: false)
    let failed = Project(name: "failed", rootPath: "/failed", loadState: .failed(reason: "Cannot reach host"))
    let failedID = SidebarOutlineModel.projectNodeID(failed.id)
    func show(collapsed: Set<SidebarHost>, toggle: SidebarExpansionToggle?, failed: Project = failed) {
      harness.show(
        [healthy, failed], toggle: toggle,
        hostLevel: SidebarHostLevel(records: [], collapsed: collapsed, keepsThisMac: true))
    }
    /// The cell fade and the row move on each child row view.
    func animations() throws -> [String: (fade: CAKeyframeAnimation, move: CAKeyframeAnimation)] {
      var result: [String: (fade: CAKeyframeAnimation, move: CAKeyframeAnimation)] = [:]
      for row in 1..<harness.outline.numberOfRows {
        let item = try #require(harness.outline.item(atRow: row) as? SidebarOutlineItem)
        let view = try #require(harness.outline.rowView(atRow: row, makeIfNecessary: false))
        let cell = try #require(view.subviews.first?.layer)
        let fade = try #require(cell.animation(forKey: "sidebar.childFade") as? CAKeyframeAnimation)
        let move = try #require(view.layer?.animation(forKey: "sidebar.childMove") as? CAKeyframeAnimation)
        result[item.id] = (fade, move)
      }
      return result
    }
    func expectSameAnimation(_ shown: [String: (fade: CAKeyframeAnimation, move: CAKeyframeAnimation)]) throws {
      let failedRow = try #require(shown[failedID])
      let sibling = try #require(shown[SidebarOutlineModel.projectNodeID(healthy.id)])
      for (a, b) in [(failedRow.fade, sibling.fade), (failedRow.move, sibling.move)] {
        #expect(a.values as? [Double] == b.values as? [Double])
        #expect(a.keyTimes == b.keyTimes)
        #expect(abs(a.beginTime - b.beginTime) < 1e-6)
      }
    }

    show(collapsed: [.thisMac], toggle: nil)
    let open = SidebarExpansionToggle.next(.host(.thisMac), after: nil)
    show(collapsed: [], toggle: open)
    #expect(harness.coordinator.animatedChildIDs.contains(failedID))
    try expectSameAnimation(animations())

    // A sweep finds the Project still failed: the row stays, with its fade.
    let failedRow = try #require(harness.rowIDs.firstIndex(of: failedID))
    let failedView = harness.outline.rowView(atRow: failedRow, makeIfNecessary: false)
    var stillFailed = failed
    stillFailed.loadState = .failed(reason: "Cannot reach host again")
    show(collapsed: [], toggle: open, failed: stillFailed)
    #expect(harness.outline.rowView(atRow: failedRow, makeIfNecessary: false) === failedView)
    try expectSameAnimation(animations())

    // The user closes the Host during the open: both rows turn around alike.
    try await Task.sleep(for: .milliseconds(60))
    let close = SidebarExpansionToggle.next(.host(.thisMac), after: open)
    show(collapsed: [.thisMac], toggle: close, failed: stillFailed)
    #expect(harness.coordinator.animatedChildIDs.contains(failedID))
    #expect(harness.rowIDs == [SidebarOutlineModel.hostNodeID(.thisMac)])
  }

  // MARK: Child row fade and move (ADR 0008)

  /// The largest change in one 1/60 s frame of what shows of a row: the
  /// table's fade of the row view times the plan's fade of the cell.
  private func largestStep(_ plan: ChildRowPlan, opening: Bool) -> Double {
    func shown(_ frame: Int) -> Double {
      let time = Double(frame) / 60
      return ChildRowPlan.shown(cell: plan.state(at: plan.start + time).opacity, at: time, opening: opening)
    }
    let frames = Int(plan.duration * 60) + 1
    return (1...frames).map { abs(shown($0) - shown($0 - 1)) }.max() ?? 0
  }

  @Test
  func childRowsFadeInFromNothingAndOutToNothingWithNoStep() {
    let open = ChildRowPlan.open(at: 10)
    #expect(open.state(at: 10).opacity == 0)
    #expect(open.state(at: 10 + open.duration).opacity == 1)
    #expect(open.state(at: 10 + open.duration).offset == 0)
    // No larger than the largest step of the reference recording.
    #expect(largestStep(open, opening: true) < 0.217)

    let close = ChildRowPlan.close(from: ChildRowState(opacity: 1, offset: 0), at: 10)
    #expect(close.state(at: 10).opacity == 1)
    #expect(close.state(at: 10 + close.duration).opacity == 0)
    #expect(largestStep(close, opening: false) < 0.222)
  }

  private func isClose(_ a: ChildRowState, _ b: ChildRowState) -> Bool {
    abs(a.opacity - b.opacity) < 1e-6 && abs(a.offset - b.offset) < 1e-6
  }

  /// The eye sees most in the faint range, so both ends of the fade stay
  /// there a while: an expand is under 0.25 for the first 50 ms of its fade,
  /// and a collapse for the last 50 ms before it is gone.
  @Test
  func childRowsStayFaintAtBothEndsOfTheFade() {
    let timing = SidebarDisclosureTiming.self
    let open = ChildRowPlan.open(at: 0)
    func shownOpen(_ time: TimeInterval) -> Double {
      ChildRowPlan.shown(cell: open.state(at: time).opacity, at: time, opening: true)
    }
    #expect(shownOpen(timing.openFadeDelay + 0.05) <= 0.25)
    #expect(shownOpen(timing.openFadeDelay + 0.2) > 0.85)

    let close = ChildRowPlan.close(from: ChildRowState(opacity: 1, offset: 0), at: 0)
    func shownClose(_ time: TimeInterval) -> Double {
      ChildRowPlan.shown(cell: close.state(at: time).opacity, at: time, opening: false)
    }
    let gone = stride(from: 0.0, to: close.duration, by: 0.001).first { shownClose($0) < 0.001 } ?? close.duration
    #expect(shownClose(gone - 0.05) <= 0.25)
    #expect(shownClose(0.02) > 0.85)
  }

  /// A second toggle starts from where the first has got to, in both
  /// directions, so the opacity and the offset do not jump.
  @Test
  func aSecondToggleContinuesFromTheRunningOne() {
    let close = ChildRowPlan.close(from: ChildRowState(opacity: 1, offset: 0), at: 10)
    let closed = close.state(at: 10.08)
    let reopen = ChildRowPlan.reopen(from: closed, at: 10.08)
    #expect(isClose(reopen.state(at: 10.08), closed))
    #expect(isClose(reopen.state(at: 10.08 + reopen.duration), ChildRowState(opacity: 1, offset: 0)))

    let open = ChildRowPlan.open(at: 20)
    let opened = open.state(at: 20.12)
    let closeAgain = ChildRowPlan.close(from: opened, at: 20.12)
    #expect(isClose(closeAgain.state(at: 20.12), opened))
    #expect(closeAgain.state(at: 20.12 + closeAgain.duration).opacity == 0)
  }

  /// The layer animation runs the same curves the plan works out.
  @Test
  func theLayerAnimationMatchesThePlan() throws {
    let plan = ChildRowPlan.open(at: 0)
    let animation = plan.opacity.animation("opacity")
    let values = try #require(animation.values as? [Double])
    let times = try #require(animation.keyTimes).map(\.doubleValue)
    #expect(values.count == times.count)
    #expect(values.first == 0 && values.last == 1)
    #expect(times.first == 0 && times.last == 1)
    #expect(abs(animation.duration - plan.opacity.duration) < 1e-9)
  }
}
