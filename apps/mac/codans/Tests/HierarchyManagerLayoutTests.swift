import CodansCore
import Foundation
import Testing

@testable import Codans

/// The Pane / Tab verbs behind ⌘T, ⌘W, split, zoom and the chip
/// strip, driven through the fake runtime. Every test ends with the
/// Worktree's layout invariants holding: no empty Pane, a resolved
/// selection per Pane, a focus that exists iff Panes exist.
@MainActor
struct HierarchyManagerLayoutTests {
  let fakeRuntime = FakeHierarchyRuntime()
  let manager: HierarchyManager
  let projectID: ProjectID
  let worktreeID: WorktreeID

  init() throws {
    let tempURL = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString + ".json")
    manager = HierarchyManager(catalog: .default, store: CatalogStore(fileURL: tempURL), runtime: fakeRuntime)
    projectID = manager.addProject(name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    worktreeID = try manager.createWorktree(in: projectID, name: "main", path: "/tmp", branch: "main")
  }

  private var worktree: Worktree {
    manager.catalog.projects[0].worktrees[0]
  }

  @discardableResult
  private func newTab(in paneID: PaneID? = nil, select: Bool = true) throws -> TabAddress {
    try manager.newTab(
      in: paneID, worktreeID: worktreeID, projectID: projectID,
      content: .terminal(workingDirectory: "/tmp"), select: select)
  }

  @discardableResult
  private func split(from paneID: PaneID, _ direction: SplitTree<PaneID>.NewDirection = .right) throws -> TabAddress {
    try manager.splitPane(from: paneID, direction: direction, content: .terminal(workingDirectory: "/tmp"))
  }

  private func expectConsistent(_ location: SourceLocation = #_sourceLocation) {
    let worktree = worktree
    #expect(worktree.isConsistent, sourceLocation: location)
    #expect(worktree.panes.allSatisfy { !$0.tabs.isEmpty }, sourceLocation: location)
    #expect(worktree.panes.allSatisfy { $0.hasResolvedSelection }, sourceLocation: location)
    #expect((worktree.focusedPaneID == nil) == worktree.panes.isEmpty, sourceLocation: location)
  }

  // MARK: - New Tab

  @Test
  func firstTabCreatesAndFocusesTheFirstPane() throws {
    #expect(worktree.panes.isEmpty)
    let created = try newTab()
    #expect(worktree.panes.count == 1)
    #expect(worktree.splitTree.leaves() == [created.paneID])
    #expect(worktree.focusedPaneID == created.paneID)
    #expect(worktree.pane(created.paneID)?.selectedTabID == created.tabID)
    #expect(created.contentID == worktree.allTabs[0].contentID)
    // Catalog only: the surface comes up through `ensureSurface`.
    #expect(fakeRuntime.ensureSurfaceCalls.isEmpty)
    expectConsistent()
  }

  @Test
  func newTabLandsInTheFocusedPane() throws {
    let first = try newTab()
    let other = try split(from: first.paneID)
    #expect(worktree.focusedPaneID == other.paneID)
    try manager.focusPane(first.paneID)

    let created = try newTab()
    #expect(created.paneID == first.paneID)
    #expect(worktree.pane(first.paneID)?.tabIDs == [first.tabID, created.tabID])
    #expect(worktree.pane(first.paneID)?.selectedTabID == created.tabID)
    #expect(worktree.pane(other.paneID)?.tabIDs == [other.tabID])
    expectConsistent()
  }

  @Test
  func newTabInAnExplicitPaneSelectsItAndFocusesThePane() throws {
    let first = try newTab()
    let other = try split(from: first.paneID)
    let created = try newTab(in: first.paneID)
    #expect(created.paneID == first.paneID)
    #expect(worktree.focusedPaneID == first.paneID)
    #expect(worktree.pane(first.paneID)?.selectedTabID == created.tabID)
    _ = other
    expectConsistent()
  }

  @Test
  func backgroundNewTabKeepsSelectionAndFocus() throws {
    let first = try newTab()
    let other = try split(from: first.paneID)
    let created = try newTab(in: first.paneID, select: false)
    #expect(worktree.focusedPaneID == other.paneID)
    #expect(worktree.pane(first.paneID)?.selectedTabID == first.tabID)
    #expect(worktree.pane(first.paneID)?.tabIDs == [first.tabID, created.tabID])
    expectConsistent()
  }

  @Test
  func ensureSurfaceBringsTheContentUpWithItsAddress() async throws {
    let created = try newTab()
    try await manager.ensureSurface(for: created.contentID, env: ["X": "1"])
    #expect(fakeRuntime.ensureSurfaceCalls.count == 1)
    let call = try #require(fakeRuntime.ensureSurfaceCalls.first)
    #expect(call.contentID == created.contentID)
    #expect(call.address == created)
    #expect(call.env["X"] == "1")
    #expect(call.env[BuiltinEnvVar.worktreePath.key] == "/tmp")
    // Idempotent once live.
    try await manager.ensureSurface(for: created.contentID)
    #expect(fakeRuntime.ensureSurfaceCalls.count == 1)
  }

  // MARK: - Split

  @Test
  func splitCreatesAPaneWithOneTabBesideTheAnchorAndFocusesIt() throws {
    let first = try newTab()
    let created = try split(from: first.paneID, .down)
    #expect(created.paneID != first.paneID)
    #expect(Set(worktree.splitTree.leaves()) == [first.paneID, created.paneID])
    #expect(worktree.splitTree.isSplit)
    #expect(worktree.focusedPaneID == created.paneID)
    #expect(worktree.pane(created.paneID)?.tabIDs == [created.tabID])
    #expect(worktree.pane(created.paneID)?.selectedTabID == created.tabID)
    #expect(fakeRuntime.ensureSurfaceCalls.isEmpty)
    expectConsistent()
  }

  @Test
  func splitClearsAnActiveZoom() throws {
    let first = try newTab()
    let second = try split(from: first.paneID)
    #expect(try manager.toggleZoom(first.paneID))
    #expect(worktree.splitTree.zoomed == first.paneID)
    let third = try split(from: first.paneID)
    #expect(worktree.splitTree.zoomed == nil)
    #expect(worktree.focusedPaneID == third.paneID)
    _ = second
    expectConsistent()
  }

  // MARK: - Close

  @Test
  func closingTheLastTabClosesThePaneAndFocusesTheNeighbour() throws {
    let first = try newTab()
    let second = try split(from: first.paneID)
    #expect(worktree.focusedPaneID == second.paneID)

    try manager.closeTab(second.tabID)
    #expect(worktree.panes.map(\.id) == [first.paneID])
    #expect(worktree.splitTree.leaves() == [first.paneID])
    #expect(worktree.focusedPaneID == first.paneID)
    #expect(fakeRuntime.closeSurfaceCalls == [second.contentID])
    #expect(fakeRuntime.focusSurfaceViewCalls.last == first.contentID)
    expectConsistent()
  }

  @Test
  func closingANonFocusedPaneKeepsFocus() throws {
    let first = try newTab()
    let second = try split(from: first.paneID)
    try manager.closePane(first.paneID)
    #expect(worktree.focusedPaneID == second.paneID)
    #expect(worktree.panes.map(\.id) == [second.paneID])
    #expect(fakeRuntime.closeSurfaceCalls == [first.contentID])
    expectConsistent()
  }

  @Test
  func closingTheSelectedTabSelectsTheRightNeighbourThenTheLast() throws {
    let a = try newTab()
    let b = try newTab()
    let c = try newTab()
    try manager.selectTab(b.tabID)
    try manager.closeTab(b.tabID)
    #expect(worktree.pane(a.paneID)?.selectedTabID == c.tabID)
    #expect(fakeRuntime.focusSurfaceViewCalls.last == c.contentID)
    try manager.closeTab(c.tabID)
    #expect(worktree.pane(a.paneID)?.selectedTabID == a.tabID)
    expectConsistent()
  }

  @Test
  func closingAnUnselectedTabKeepsTheSelection() throws {
    let a = try newTab()
    let b = try newTab()
    #expect(worktree.pane(a.paneID)?.selectedTabID == b.tabID)
    try manager.closeTab(a.tabID)
    #expect(worktree.pane(a.paneID)?.selectedTabID == b.tabID)
    expectConsistent()
  }

  @Test
  func closingEveryTabLeavesAnEmptyWorktree() throws {
    let a = try newTab()
    let b = try split(from: a.paneID)
    let c = try newTab(in: b.paneID)
    for tabID in [c.tabID, a.tabID, b.tabID] {
      try manager.closeTab(tabID)
      expectConsistent()
    }
    #expect(worktree.panes.isEmpty)
    #expect(worktree.splitTree.isEmpty)
    #expect(worktree.focusedPaneID == nil)
    #expect(Set(fakeRuntime.closeSurfaceCalls) == [a.contentID, b.contentID, c.contentID])
  }

  @Test
  func closePaneClosesEveryTabOfThePane() throws {
    let a = try newTab()
    let b = try newTab()
    let other = try split(from: a.paneID)
    try manager.closePane(a.paneID)
    #expect(Set(fakeRuntime.closeSurfaceCalls) == [a.contentID, b.contentID])
    #expect(worktree.panes.map(\.id) == [other.paneID])
    #expect(worktree.focusedPaneID == other.paneID)
    expectConsistent()
  }

  @Test
  func paneIsNeverEmptyAcrossRandomCloseSequences() throws {
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<5 {
      let root = try newTab()
      var panes = [root.paneID]
      for _ in 0..<3 {
        let anchor = panes.randomElement(using: &generator)!
        panes.append(try split(from: anchor, Bool.random(using: &generator) ? .right : .down).paneID)
        for _ in 0..<Int.random(in: 0...2, using: &generator) {
          try newTab(in: panes.last!)
        }
      }
      expectConsistent()
      while !worktree.allTabs.isEmpty {
        let tab = worktree.allTabs.randomElement(using: &generator)!
        if Bool.random(using: &generator), let paneID = worktree.pane(forTab: tab.id)?.id {
          try manager.closePane(paneID)
        } else {
          try manager.closeTab(tab.id)
        }
        expectConsistent()
      }
    }
  }

  // MARK: - Batch close

  @Test
  func batchClosesLeaveAValidSelection() throws {
    let a = try newTab()
    let b = try newTab()
    let c = try newTab()
    let d = try newTab()
    try manager.selectTab(a.tabID)

    try manager.closeTabsToRight(of: b.tabID)
    #expect(worktree.pane(a.paneID)?.tabIDs == [a.tabID, b.tabID])
    #expect(worktree.pane(a.paneID)?.selectedTabID == b.tabID)
    expectConsistent()

    let e = try newTab()
    try manager.closeOtherTabs(keeping: a.tabID)
    #expect(worktree.pane(a.paneID)?.tabIDs == [a.tabID])
    #expect(worktree.pane(a.paneID)?.selectedTabID == a.tabID)
    expectConsistent()
    _ = (c, d, e)

    let other = try split(from: a.paneID)
    try manager.closeAllTabs(in: a.paneID)
    #expect(worktree.panes.map(\.id) == [other.paneID])
    expectConsistent()
  }

  // MARK: - Select

  @Test
  func selectTabFocusesItsPaneAndTheSurface() throws {
    let a = try newTab()
    let other = try split(from: a.paneID)
    #expect(worktree.focusedPaneID == other.paneID)
    try manager.selectTab(a.tabID)
    #expect(worktree.focusedPaneID == a.paneID)
    #expect(fakeRuntime.focusSurfaceViewCalls.last == a.contentID)
    expectConsistent()
  }

  @Test
  func selectTabAtIndexAndAdjacentWrap() throws {
    let a = try newTab()
    let b = try newTab()
    let c = try newTab()
    #expect(try manager.selectTab(at: 0, in: a.paneID) == a.tabID)
    #expect(worktree.pane(a.paneID)?.selectedTabID == a.tabID)
    #expect(try manager.selectTab(at: 7, in: a.paneID) == nil)
    #expect(worktree.pane(a.paneID)?.selectedTabID == a.tabID)
    #expect(try manager.selectAdjacentTab(direction: .previous, in: a.paneID) == c.tabID)
    #expect(try manager.selectAdjacentTab(direction: .next, in: a.paneID) == a.tabID)
    #expect(try manager.selectAdjacentTab(direction: .next, in: a.paneID) == b.tabID)
    expectConsistent()
  }

  // MARK: - Focus and zoom

  @Test
  func focusNeighbourWalksTheTree() throws {
    let a = try newTab()
    let b = try split(from: a.paneID, .right)
    #expect(try manager.focusNeighbour(of: b.paneID, direction: .left) == a.paneID)
    #expect(worktree.focusedPaneID == a.paneID)
    #expect(fakeRuntime.focusSurfaceViewCalls.last == a.contentID)
    #expect(try manager.focusNeighbour(of: a.paneID, direction: .left) == nil)
    #expect(worktree.focusedPaneID == a.paneID)
    #expect(try manager.focusNeighbour(of: a.paneID, direction: .next) == b.paneID)
    expectConsistent()
  }

  @Test
  func toggleZoomRoundTrip() throws {
    let a = try newTab()
    let b = try split(from: a.paneID)
    #expect(worktree.splitTree.zoomed == nil)
    #expect(try manager.toggleZoom(a.paneID))
    #expect(worktree.splitTree.zoomed == a.paneID)
    #expect(worktree.focusedPaneID == a.paneID)
    #expect(!(try manager.toggleZoom(a.paneID)))
    #expect(worktree.splitTree.zoomed == nil)
    // Zooming another Pane moves the zoom and the focus.
    #expect(try manager.toggleZoom(b.paneID))
    #expect(worktree.splitTree.zoomed == b.paneID)
    #expect(worktree.focusedPaneID == b.paneID)
    expectConsistent()
  }

  @Test
  func closingTheZoomedPaneClearsTheZoom() throws {
    let a = try newTab()
    let b = try split(from: a.paneID)
    _ = try manager.toggleZoom(b.paneID)
    try manager.closePane(b.paneID)
    #expect(worktree.splitTree.zoomed == nil)
    #expect(worktree.focusedPaneID == a.paneID)
    expectConsistent()
  }

  @Test
  func focusedContentIsTheFocusedPanesSelectedTab() throws {
    #expect(manager.focusedContent(in: worktreeID) == nil)
    let a = try newTab()
    let b = try newTab()
    #expect(manager.focusedContent(in: worktreeID) == b)
    try manager.selectTab(a.tabID)
    #expect(manager.focusedContent(in: worktreeID) == a)
  }

  // MARK: - Chip attributes and session fields

  @Test
  func chipAttributesKeyOnTheTab() throws {
    let a = try newTab()
    try manager.renameTab(a.tabID, name: "build")
    try manager.setTabColor(a.tabID, color: .red)
    try manager.setTabIcon(a.tabID, icon: "hammer", lock: .user)
    manager.setCachedTabTitle("make", for: a.tabID)
    let tab = try #require(manager.catalog.tab(a.tabID))
    #expect(tab.name == "build")
    #expect(tab.color == .red)
    #expect(tab.icon == "hammer")
    #expect(tab.iconLock == .user)
    #expect(tab.cachedDisplayTitle == "make")
  }

  @Test
  func sessionFieldsKeyOnTheContent() throws {
    let a = try newTab()
    manager.setContentLabel(a.contentID, label: "ci", present: true)
    try manager.setContentLabels(a.contentID, labels: ["x"])
    manager.setAgentKind(a.contentID, kind: .claudeCode)
    manager.setAgentSessionID(a.contentID, sessionID: "s1")
    manager.updateWorkingDirectory(for: a.contentID, to: "/var")
    let state = try #require(manager.catalog.content(a.contentID)?.terminal)
    #expect(state.labels == ["ci", "x"])
    #expect(state.agentKind == .claudeCode)
    #expect(state.agentSessionID == "s1")
    #expect(state.workingDirectory == "/var")
    #expect(throws: HierarchyError.self) {
      try manager.setContentLabels(ContentID(), labels: ["y"])
    }
  }

  @Test
  func reorderAndMoveTabStayInsideThePane() throws {
    let a = try newTab()
    let b = try newTab()
    let c = try newTab()
    try manager.reorderTabs(in: a.paneID, orderedIDs: [c.tabID, a.tabID, b.tabID])
    #expect(worktree.pane(a.paneID)?.tabIDs == [c.tabID, a.tabID, b.tabID])
    try manager.moveTab(b.tabID, offset: 1)
    #expect(worktree.pane(a.paneID)?.tabIDs == [b.tabID, c.tabID, a.tabID])
    #expect(throws: HierarchyError.self) {
      try manager.reorderTabs(in: a.paneID, orderedIDs: [a.tabID])
    }
    expectConsistent()
  }
}
