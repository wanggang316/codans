import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

@MainActor
struct HierarchyManagerTests {
  var fakeRuntime: FakeHierarchyRuntime!
  var store: CatalogStore!
  var manager: HierarchyManager!

  init() {
    let tempURL = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString + ".json")
    fakeRuntime = FakeHierarchyRuntime()
    store = CatalogStore(fileURL: tempURL)
    manager = HierarchyManager(catalog: .default, store: store, runtime: fakeRuntime)
  }

  @Test
  func createWorktreeAppendsAndSetsSelected() throws {
    let projectID = manager.addProject(name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID,
      name: "main",
      path: "/repo",
      branch: "main"
    )

    #expect(manager.catalog.projects[0].worktrees.count == 1)
    #expect(manager.catalog.projects[0].worktrees[0].id == worktreeID)
    #expect(manager.catalog.projects[0].selectedWorktreeID == worktreeID)
    #expect(fakeRuntime.ensureSurfaceCalls.isEmpty)
  }

  @Test
  func removeNonExistentWorktreeThrows() throws {
    let projectID = manager.addProject(name: "project", rootPath: "/tmp", gitRoot: "/tmp")

    let fakeID = WorktreeID()
    #expect(throws: HierarchyError.self) {
      try manager.removeWorktree(fakeID, from: projectID)
    }
  }

  @Test
  func createTabAppendsAndSetsSelected() throws {
    let projectID = manager.addProject(name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID,
      name: "main",
      path: "/repo",
      branch: "main"
    )

    let tabID = try manager.createTab(in: worktreeID, in: projectID, name: "tab1")

    #expect(manager.catalog.projects[0].worktrees[0].tabs.count == 1)
    #expect(manager.catalog.projects[0].worktrees[0].tabs[0].id == tabID)
    #expect(manager.catalog.projects[0].worktrees[0].selectedTabID == tabID)
  }

  @Test
  func openPaneInEmptyTabCreatesLeaf() throws {
    let projectID = manager.addProject(name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID,
      name: "main",
      path: "/repo",
      branch: "main"
    )
    let tabID = try manager.createTab(in: worktreeID, in: projectID, name: nil)

    let paneID = try manager.openPane(
      in: tabID,
      in: worktreeID,
      in: projectID,
      workingDirectory: "/tmp",
      initialCommand: nil
    )

    let tab = manager.catalog.projects[0].worktrees[0].tabs[0]
    #expect(tab.panes.count == 1)
    #expect(tab.panes[0].id == paneID)
    #expect(tab.splitTree.leaves() == [paneID])
    #expect(fakeRuntime.ensureSurfaceCalls.count == 1)
    #expect(fakeRuntime.ensureSurfaceCalls[0].paneID == paneID)
  }

  @Test
  func splitPaneCreatesNewLeaf() throws {
    let projectID = manager.addProject(name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID,
      name: "main",
      path: "/repo",
      branch: "main"
    )
    let tabID = try manager.createTab(in: worktreeID, in: projectID, name: nil)
    let paneID = try manager.openPane(
      in: tabID,
      in: worktreeID,
      in: projectID,
      workingDirectory: "/tmp",
      initialCommand: nil
    )

    fakeRuntime.reset()
    let newPaneID = try manager.splitPane(
      paneID,
      direction: .right,
      in: tabID,
      in: worktreeID,
      in: projectID,
      workingDirectory: "/tmp",
      initialCommand: nil
    )

    let tab = manager.catalog.projects[0].worktrees[0].tabs[0]
    #expect(tab.panes.count == 2)
    #expect(tab.splitTree.leaves().count == 2)
    #expect(tab.splitTree.contains(newPaneID))
    #expect(fakeRuntime.ensureSurfaceCalls.count == 1)
    #expect(fakeRuntime.ensureSurfaceCalls[0].paneID == newPaneID)
  }

  /// Regression guard for the worktree-create double-seed race
  /// (`fix/resume-bug`). The create-worktree flow seeds its first pane via
  /// `createPaneRow` from a *synchronous* reducer body so the Pane row is
  /// observable before the `.selectionChanged` it triggers reaches
  /// `RootFeature`. If the row only landed after an `await` (as the
  /// all-in-one async `openPane` does), `autoSeedTabAndPaneIfNeeded` would
  /// read an empty tab and race in a second pane — the two concurrent
  /// `zmx serve` spawns then collide and one fails with `zmxServeFailed`.
  /// So `createPaneRow` must (a) insert the pane synchronously and (b) NOT
  /// bring the surface up.
  @Test
  func createPaneRowInsertsPaneSynchronouslyWithoutSurface() throws {
    let projectID = manager.addProject(name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "main", path: "/repo", branch: "main"
    )
    let tabID = try manager.createTab(in: worktreeID, in: projectID, name: nil)

    let paneID = try manager.createPaneRow(
      in: tabID, in: worktreeID, in: projectID,
      workingDirectory: "/repo", initialCommand: "echo setup"
    )

    // Row is observable immediately — no `await`, so an auto-seed snapshot
    // taken right after this point sees a non-empty tab.
    let tab = manager.catalog.projects[0].worktrees[0].tabs[0]
    #expect(tab.panes.count == 1)
    #expect(tab.panes[0].id == paneID)
    #expect(tab.panes[0].initialCommand == "echo setup")
    #expect(tab.splitTree.leaves() == [paneID])
    // The async half (`ensurePaneSurface`) has not run, so no daemon spawn.
    #expect(fakeRuntime.ensureSurfaceCalls.isEmpty)
  }

  /// `openPane` stays the all-in-one path: synchronous `createPaneRow`
  /// followed by the async surface bringup. Exactly one pane, one surface —
  /// the two-phase split must not double-spawn.
  @Test
  func openPaneSeedsRowAndSurfaceExactlyOnce() async throws {
    let projectID = manager.addProject(name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "main", path: "/repo", branch: "main"
    )
    let tabID = try manager.createTab(in: worktreeID, in: projectID, name: nil)

    let paneID = try await manager.openPane(
      in: tabID, in: worktreeID, in: projectID,
      workingDirectory: "/repo", initialCommand: nil
    )

    let tab = manager.catalog.projects[0].worktrees[0].tabs[0]
    #expect(tab.panes.count == 1)
    #expect(tab.panes[0].id == paneID)
    #expect(fakeRuntime.ensureSurfaceCalls.count == 1)
    #expect(fakeRuntime.ensureSurfaceCalls[0].paneID == paneID)
  }

  @Test
  func closePaneRemovesFromSplitTree() throws {
    let projectID = manager.addProject(name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID,
      name: "main",
      path: "/repo",
      branch: "main"
    )
    let tabID = try manager.createTab(in: worktreeID, in: projectID, name: nil)
    let paneID = try manager.openPane(
      in: tabID,
      in: worktreeID,
      in: projectID,
      workingDirectory: "/tmp",
      initialCommand: nil
    )

    fakeRuntime.reset()
    try manager.closePane(paneID, in: tabID, in: worktreeID, in: projectID)

    let tab = manager.catalog.projects[0].worktrees[0].tabs[0]
    #expect(tab.panes.isEmpty)
    #expect(tab.splitTree.isEmpty)
    #expect(fakeRuntime.closeSurfaceCalls == [paneID])
  }

  @Test
  func tabValidateInvariantsHoldsAfterSplit() throws {
    let projectID = manager.addProject(name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID,
      name: "main",
      path: "/repo",
      branch: "main"
    )
    let tabID = try manager.createTab(in: worktreeID, in: projectID, name: nil)
    let paneID = try manager.openPane(
      in: tabID,
      in: worktreeID,
      in: projectID,
      workingDirectory: "/tmp",
      initialCommand: nil
    )

    _ = try manager.splitPane(
      paneID,
      direction: .right,
      in: tabID,
      in: worktreeID,
      in: projectID,
      workingDirectory: "/tmp",
      initialCommand: nil
    )

    let tab = manager.catalog.projects[0].worktrees[0].tabs[0]
    #expect(throws: Never.self) {
      try tab.validateInvariants()
    }
  }

  @Test
  func focusPaneSetsZoom() throws {
    let projectID = manager.addProject(name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID,
      name: "main",
      path: "/repo",
      branch: "main"
    )
    let tabID = try manager.createTab(in: worktreeID, in: projectID, name: nil)
    let paneID = try manager.openPane(
      in: tabID,
      in: worktreeID,
      in: projectID,
      workingDirectory: "/tmp",
      initialCommand: nil
    )

    try manager.focusPane(paneID, in: tabID, in: worktreeID, in: projectID)

    let tab = manager.catalog.projects[0].worktrees[0].tabs[0]
    #expect(tab.splitTree.zoomed == paneID)
  }

  // Per-Project editor / worktrees-directory mutators moved off HierarchyManager in v3
  // and now live on `SettingsStore.mutateProject`; see `SettingsStoreTests` for their
  // coverage.

  // MARK: - P0.2: Project Management mutations

  @Test
  func reorderProjectsMovesInPlaceAndPersists() throws {
    let a = manager.addProject(name: "a", rootPath: "/tmp/a")
    let b = manager.addProject(name: "b", rootPath: "/tmp/b")
    let c = manager.addProject(name: "c", rootPath: "/tmp/c")

    // Move the third entry ("c") to the front.
    try manager.reorderProjects(from: IndexSet(integer: 2), to: 0)

    let order = manager.catalog.projects.map(\.id)
    #expect(order == [c, a, b])
  }

  @Test
  func setProjectLoadStateUpdatesAndHandlesEqualValue() throws {
    let projectID = manager.addProject(name: "p", rootPath: "/tmp/p")
    #expect(manager.catalog.projects[0].loadState == .loading)

    manager.setProjectLoadState(.ready, projectID: projectID)
    #expect(manager.catalog.projects[0].loadState == .ready)

    // Dedup — setting the same value again is a no-op (same final state, no throw).
    manager.setProjectLoadState(.ready, projectID: projectID)
    #expect(manager.catalog.projects[0].loadState == .ready)

    manager.setProjectLoadState(.failed(reason: "gone"), projectID: projectID)
    #expect(manager.catalog.projects[0].loadState == .failed(reason: "gone"))
  }

  @Test
  func setProjectLoadStateMissingProjectIsSilentNoOp() {
    let bogusProject = ProjectID()
    manager.setProjectLoadState(.ready, projectID: bogusProject)
    #expect(manager.catalog.projects.isEmpty)
  }

  @Test
  func isPathRegisteredReturnsPairForCanonicalizedMatch() throws {
    let projectID = manager.addProject(
      name: "p",
      rootPath: HierarchyManager.canonicalPath("/tmp/p")
    )

    let match = manager.isPathRegistered(canonical: HierarchyManager.canonicalPath("/tmp/p"))
    #expect(match == projectID)

    // The canonical form strips symlinks and trailing slashes — callers always
    // pass canonical paths. Passing a non-canonical form intentionally does NOT
    // match, enforcing the contract.
    let absent = manager.isPathRegistered(canonical: "/tmp/p/")
    #expect(absent == nil)
  }

  @Test
  func isPathRegisteredReturnsNilWhenAbsent() {
    let match = manager.isPathRegistered(canonical: "/does/not/exist")
    #expect(match == nil)
  }

  // MARK: - project(containing:) — Codex P2-4

  @Test
  func projectContainingMatchesRootExactly() throws {
    let projectID = manager.addProject(
      name: "p",
      rootPath: HierarchyManager.canonicalPath("/tmp/p")
    )
    let match = manager.project(containing: HierarchyManager.canonicalPath("/tmp/p"))
    #expect(match == projectID)
  }

  @Test
  func projectContainingMatchesSubdirectoryOfRoot() throws {
    let projectID = manager.addProject(
      name: "p",
      rootPath: HierarchyManager.canonicalPath("/tmp/p")
    )
    // `tc open` from a subdirectory must still resolve to the parent Project, so the
    // project's `defaultEditor` override applies to arbitrarily deep paths.
    let subPath = HierarchyManager.canonicalPath("/tmp/p") + "/src/Features"
    let match = manager.project(containing: subPath)
    #expect(match == projectID)
  }

  @Test
  func projectContainingRespectsPathSegmentBoundary() throws {
    _ = manager.addProject(
      name: "p",
      rootPath: HierarchyManager.canonicalPath("/tmp/repo")
    )
    // `/tmp/repo` must not match `/tmp/repository`; prefix-match on the raw string alone
    // would incorrectly match, so the implementation anchors on `/` segment boundaries.
    let absent = manager.project(containing: "/tmp/repository")
    #expect(absent == nil)
  }

  @Test
  func projectContainingPicksDeepestMatchWhenProjectsNest() throws {
    // Monorepo with a nested sub-project — deepest root wins so the closest override is
    // applied, not the outer monorepo's override.
    let outerID = manager.addProject(
      name: "outer",
      rootPath: HierarchyManager.canonicalPath("/tmp/mono")
    )
    let innerID = manager.addProject(
      name: "inner",
      rootPath: HierarchyManager.canonicalPath("/tmp/mono/apps/web")
    )
    let innerPath = HierarchyManager.canonicalPath("/tmp/mono/apps/web") + "/src/pages"
    let match = manager.project(containing: innerPath)
    #expect(match == innerID)
    #expect(match != outerID)

    // Outside the inner project but inside the outer — falls back to outer.
    let outerPath = HierarchyManager.canonicalPath("/tmp/mono") + "/packages"
    let outerMatch = manager.project(containing: outerPath)
    #expect(outerMatch == outerID)
  }

  @Test
  func projectContainingReturnsNilWhenNoProjectContains() {
    let match = manager.project(containing: "/var/no/project/here")
    #expect(match == nil)
  }

  // MARK: - Tab-bar uplift (M2-T2.1)

  /// Seeds a worktree with three tabs and returns (space, project, worktree, tabIDs).
  /// Every tab gets one pane so `closeTab`'s runtime-teardown path is exercised
  /// the same way the real UI drives it.
  @MainActor
  private func makeFixtureWithThreeTabs() throws -> (ProjectID, WorktreeID, [TabID]) {
    let projectID = manager.addProject(
      name: "project", rootPath: "/tmp", gitRoot: "/tmp"
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "main", path: "/repo", branch: "main"
    )
    var tabIDs: [TabID] = []
    for name in ["one", "two", "three"] {
      let tid = try manager.createTab(in: worktreeID, in: projectID, name: name)
      _ = try manager.openPane(
        in: tid, in: worktreeID, in: projectID,
        workingDirectory: "/tmp", initialCommand: nil
      )
      tabIDs.append(tid)
    }
    return (projectID, worktreeID, tabIDs)
  }

  @Test
  func renameTabWritesName() throws {
    let (pr, wt, tabs) = try makeFixtureWithThreeTabs()
    try manager.renameTab(tabs[1], in: wt, in: pr, name: "renamed")
    let stored = manager.catalog.projects[0].worktrees[0].tabs[1].name
    #expect(stored == "renamed")
  }

  @Test
  func renameTabWithUnchangedNameIsNoOp() throws {
    let (pr, wt, tabs) = try makeFixtureWithThreeTabs()
    // Same value → no throw, still equals the original.
    try manager.renameTab(tabs[0], in: wt, in: pr, name: "one")
    #expect(manager.catalog.projects[0].worktrees[0].tabs[0].name == "one")
  }

  @Test
  func renameTabThrowsOnMissingID() throws {
    let (pr, wt, _) = try makeFixtureWithThreeTabs()
    #expect(throws: HierarchyError.self) {
      try manager.renameTab(TabID(), in: wt, in: pr, name: "nope")
    }
  }

  @Test
  func reorderTabsAcceptsPermutation() throws {
    let (pr, wt, tabs) = try makeFixtureWithThreeTabs()
    let permuted = [tabs[2], tabs[0], tabs[1]]
    try manager.reorderTabs(in: wt, in: pr, orderedIDs: permuted)
    let stored = manager.catalog.projects[0].worktrees[0].tabs.map(\.id)
    #expect(stored == permuted)
  }

  @Test
  func reorderTabsRejectsMismatchedSet() throws {
    let (pr, wt, tabs) = try makeFixtureWithThreeTabs()
    // Drop the last id → set mismatch → invariantViolation.
    let shortened = Array(tabs.dropLast())
    #expect(throws: HierarchyError.self) {
      try manager.reorderTabs(in: wt, in: pr, orderedIDs: shortened)
    }
  }

  @Test
  func closeOtherTabsKeepsPivotSelected() throws {
    let (pr, wt, tabs) = try makeFixtureWithThreeTabs()
    try manager.closeOtherTabs(keeping: tabs[1], in: wt, in: pr)
    let remaining = manager.catalog.projects[0].worktrees[0].tabs.map(\.id)
    #expect(remaining == [tabs[1]])
    #expect(manager.catalog.projects[0].worktrees[0].selectedTabID == tabs[1])
  }

  @Test
  func closeTabsToRightTrimsSuffix() throws {
    let (pr, wt, tabs) = try makeFixtureWithThreeTabs()
    try manager.closeTabsToRight(of: tabs[0], in: wt, in: pr)
    let remaining = manager.catalog.projects[0].worktrees[0].tabs.map(\.id)
    #expect(remaining == [tabs[0]])
  }

  @Test
  func closeTabsToRightNoOpForLastTab() throws {
    let (pr, wt, tabs) = try makeFixtureWithThreeTabs()
    try manager.closeTabsToRight(of: tabs.last!, in: wt, in: pr)
    let remaining = manager.catalog.projects[0].worktrees[0].tabs.map(\.id)
    #expect(remaining == tabs)
  }

  @Test
  func closeTabsToRightKeepsPivotSelectedWhenActiveWasDoomed() throws {
    let (pr, wt, tabs) = try makeFixtureWithThreeTabs()
    // makeFixtureWithThreeTabs leaves the last tab selected; ask to
    // close everything to the right of the first one. The user's
    // active tab is in the doomed suffix, so without the explicit
    // reseat the auto-advance would land on `tabs.first` regardless
    // of which pivot was passed.
    try manager.closeTabsToRight(of: tabs[0], in: wt, in: pr)
    #expect(manager.catalog.projects[0].worktrees[0].selectedTabID == tabs[0])
  }

  @Test
  func closeTabsToRightKeepsPivotSelectedWhenPivotIsMid() throws {
    let (pr, wt, tabs) = try makeFixtureWithThreeTabs()
    // Pivot is the middle tab; auto-advance would otherwise land on
    // tabs[0] when tabs[2] (the active tab) closes.
    try manager.closeTabsToRight(of: tabs[1], in: wt, in: pr)
    let remaining = manager.catalog.projects[0].worktrees[0].tabs.map(\.id)
    #expect(remaining == [tabs[0], tabs[1]])
    #expect(manager.catalog.projects[0].worktrees[0].selectedTabID == tabs[1])
  }

  @Test
  func closeTabSelectsRightNeighborWhenMiddleTabClosed() throws {
    let (pr, wt, tabs) = try makeFixtureWithThreeTabs()
    try manager.selectTab(tabs[1], in: wt, in: pr)
    try manager.closeTab(tabs[1], in: wt, in: pr)
    #expect(manager.catalog.projects[0].worktrees[0].selectedTabID == tabs[2])
  }

  @Test
  func closeTabFallsBackToLeftNeighborWhenLastTabClosed() throws {
    let (pr, wt, tabs) = try makeFixtureWithThreeTabs()
    // makeFixtureWithThreeTabs already leaves tabs[2] (the trailing tab) selected.
    try manager.closeTab(tabs[2], in: wt, in: pr)
    #expect(manager.catalog.projects[0].worktrees[0].selectedTabID == tabs[1])
  }

  @Test
  func closeTabClearsSelectionWhenSoleTabClosed() throws {
    let projectID = manager.addProject(
      name: "p", rootPath: "/tmp", gitRoot: "/tmp"
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "main", path: "/repo", branch: "main"
    )
    let only = try manager.createTab(in: worktreeID, in: projectID, name: "only")
    try manager.closeTab(only, in: worktreeID, in: projectID)
    #expect(manager.catalog.projects[0].worktrees[0].selectedTabID == nil)
  }

  @Test
  func closeTabPreservesSelectionWhenInactiveTabClosed() throws {
    let (pr, wt, tabs) = try makeFixtureWithThreeTabs()
    try manager.selectTab(tabs[1], in: wt, in: pr)
    // Closing a non-selected tab must not move the selection.
    try manager.closeTab(tabs[0], in: wt, in: pr)
    #expect(manager.catalog.projects[0].worktrees[0].selectedTabID == tabs[1])
  }

  @Test
  func closeTabFocusesSurfaceOfNewlySelectedTab() throws {
    // Without this focus transfer, the closed surface's responder slot
    // stays empty and subsequent ⌘W bypasses Ghostty's perfKE, falling
    // through to the menu where the system Close Window can shadow
    // our binding and close the whole window.
    let (pr, wt, tabs) = try makeFixtureWithThreeTabs()
    fakeRuntime.reset()
    // Close the trailing (selected) tab → fallback to its left neighbor.
    try manager.closeTab(tabs[2], in: wt, in: pr)
    let newSelected = manager.catalog.projects[0].worktrees[0].selectedTabID
    #expect(newSelected == tabs[1])
    let neighborPaneID = manager.catalog.projects[0]
      .worktrees[0].tabs.first { $0.id == tabs[1] }!.panes[0].id
    #expect(fakeRuntime.focusSurfaceViewCalls.contains(neighborPaneID))
  }

  @Test
  func closeAllTabsEmptiesWorktree() throws {
    let (pr, wt, _) = try makeFixtureWithThreeTabs()
    try manager.closeAllTabs(in: wt, in: pr)
    #expect(manager.catalog.projects[0].worktrees[0].tabs.isEmpty)
    #expect(manager.catalog.projects[0].worktrees[0].selectedTabID == nil)
  }

  @Test
  func selectAdjacentTabWrapsForward() throws {
    let (pr, wt, tabs) = try makeFixtureWithThreeTabs()
    // After makeFixtureWithThreeTabs the last-created tab is selected.
    #expect(manager.catalog.projects[0].worktrees[0].selectedTabID == tabs[2])
    let next = try manager.selectAdjacentTab(direction: .next, in: wt, in: pr)
    #expect(next == tabs[0])
    #expect(manager.catalog.projects[0].worktrees[0].selectedTabID == tabs[0])
  }

  @Test
  func selectAdjacentTabWrapsBackward() throws {
    let (pr, wt, tabs) = try makeFixtureWithThreeTabs()
    // Selected is tabs[2]; previous from 2 is 1, from 0 is 2 (wrap). Check both.
    _ = try manager.selectTab(tabs[0], in: wt, in: pr)
    let previous = try manager.selectAdjacentTab(direction: .previous, in: wt, in: pr)
    #expect(previous == tabs[2])
    #expect(manager.catalog.projects[0].worktrees[0].selectedTabID == tabs[2])
  }

  @Test
  func selectAdjacentTabReturnsNilOnEmptyWorktree() throws {
    let projectID = manager.addProject(
      name: "project", rootPath: "/tmp", gitRoot: "/tmp"
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "main", path: "/repo", branch: "main"
    )
    let result = try manager.selectAdjacentTab(
      direction: .next, in: worktreeID, in: projectID
    )
    #expect(result == nil)
  }

  // MARK: - Runtime state: focus memory + dirty (M3-T3.5)

  /// Seeds a worktree with two tabs. Tab A has two panes (so we can
  /// remember "the second pane"), tab B has one pane (so selectTab has
  /// a fallback leaf on the other side).
  @MainActor
  private func makeFixtureTwoTabsWithPanes() throws -> (
    ProjectID, WorktreeID, TabID, TabID, PaneID, PaneID, PaneID
  ) {
    let projectID = manager.addProject(
      name: "project", rootPath: "/tmp", gitRoot: "/tmp"
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "main", path: "/repo", branch: "main"
    )
    let tabA = try manager.createTab(in: worktreeID, in: projectID, name: "A")
    let tabAPane1 = try manager.openPane(
      in: tabA, in: worktreeID, in: projectID,
      workingDirectory: "/tmp", initialCommand: nil
    )
    let tabAPane2 = try manager.splitPane(
      tabAPane1, direction: .right,
      in: tabA, in: worktreeID, in: projectID,
      workingDirectory: "/tmp", initialCommand: nil
    )
    let tabB = try manager.createTab(in: worktreeID, in: projectID, name: "B")
    let tabBPane = try manager.openPane(
      in: tabB, in: worktreeID, in: projectID,
      workingDirectory: "/tmp", initialCommand: nil
    )
    return (projectID, worktreeID, tabA, tabB, tabAPane1, tabAPane2, tabBPane)
  }

  @Test
  func selectTabRestoresLastFocusedPane() throws {
    let (pr, wt, tabA, tabB, _, tabAPane2, _) = try makeFixtureTwoTabsWithPanes()
    // Remember tabA's second pane, then bounce through tabB and back.
    try manager.focusPane(tabAPane2, in: tabA, in: wt, in: pr)
    fakeRuntime.reset()
    try manager.selectTab(tabB, in: wt, in: pr)
    try manager.selectTab(tabA, in: wt, in: pr)
    // Selecting tabA restores tabAPane2 (focusSurfaceView called with it).
    #expect(fakeRuntime.focusSurfaceViewCalls.contains(tabAPane2))
  }

  @Test
  func selectTabFallsBackToLeftmostLeafWhenRememberedPaneClosed() throws {
    let (pr, wt, tabA, tabB, tabAPane1, tabAPane2, _) = try makeFixtureTwoTabsWithPanes()
    try manager.focusPane(tabAPane2, in: tabA, in: wt, in: pr)
    // The remembered pane disappears out from under us.
    try manager.closePane(tabAPane2, in: tabA, in: wt, in: pr)
    fakeRuntime.reset()
    try manager.selectTab(tabB, in: wt, in: pr)
    try manager.selectTab(tabA, in: wt, in: pr)
    // Fallback: leftmost leaf of tabA's tree = tabAPane1.
    #expect(fakeRuntime.focusSurfaceViewCalls.contains(tabAPane1))
  }

  @Test
  func closePaneClearsLastFocusedAndRunningEntries() throws {
    let (pr, wt, tabA, _, _, tabAPane2, _) = try makeFixtureTwoTabsWithPanes()
    try manager.focusPane(tabAPane2, in: tabA, in: wt, in: pr)
    manager.markPaneRunning(tabAPane2)
    #expect(manager.lastFocusedPane(in: tabA) == tabAPane2)
    #expect(manager.tabIsDirty(tabA))
    try manager.closePane(tabAPane2, in: tabA, in: wt, in: pr)
    #expect(manager.lastFocusedPane(in: tabA) == nil)
    #expect(!manager.tabIsDirty(tabA))
  }

  @Test
  func closeTabClearsRuntimeMapsForAllPanes() throws {
    let (pr, wt, tabA, _, tabAPane1, tabAPane2, _) = try makeFixtureTwoTabsWithPanes()
    try manager.focusPane(tabAPane1, in: tabA, in: wt, in: pr)
    manager.markPaneRunning(tabAPane2)
    try manager.closeTab(tabA, in: wt, in: pr)
    #expect(manager.lastFocusedPane(in: tabA) == nil)
    // Dirty read on a now-absent tab: the walk finds no tab → false.
    #expect(!manager.tabIsDirty(tabA))
  }

  @Test
  func selectAdjacentTabRestoresLastFocusedPaneOnTarget() throws {
    let (pr, wt, tabA, tabB, _, tabAPane2, _) = try makeFixtureTwoTabsWithPanes()
    // Remember tabA's second pane, then bounce to tabB so adjacency
    // jumps land back on tabA.
    try manager.focusPane(tabAPane2, in: tabA, in: wt, in: pr)
    try manager.selectTab(tabB, in: wt, in: pr)
    fakeRuntime.reset()
    let landed = try manager.selectAdjacentTab(
      direction: .previous, in: wt, in: pr
    )
    #expect(landed == tabA)
    #expect(fakeRuntime.focusSurfaceViewCalls.contains(tabAPane2))
  }

  @Test
  func tabIsDirtyReflectsAnyRunningPane() throws {
    let (_, _, tabA, _, tabAPane1, tabAPane2, _) = try makeFixtureTwoTabsWithPanes()
    #expect(!manager.tabIsDirty(tabA))
    manager.markPaneRunning(tabAPane1)
    #expect(manager.tabIsDirty(tabA))
    manager.markPaneIdle(tabAPane1)
    #expect(!manager.tabIsDirty(tabA))
    manager.markPaneRunning(tabAPane2)
    #expect(manager.tabIsDirty(tabA))
  }

  @Test
  func tabIsDirtyUnionsCommandBusyWithProgress() throws {
    let (_, _, tabA, _, tabAPane1, tabAPane2, _) = try makeFixtureTwoTabsWithPanes()
    #expect(!manager.tabIsDirty(tabA))

    // The foreground-command source lights the tab on its own.
    manager.setPaneCommandBusy(tabAPane1, true)
    #expect(manager.tabIsDirty(tabA))

    // OSC progress and command sources are independent: clearing one while
    // the other still holds keeps the tab dirty (no clobbering a shared set).
    manager.markPaneRunning(tabAPane2)
    manager.setPaneCommandBusy(tabAPane1, false)
    #expect(manager.tabIsDirty(tabA))

    manager.markPaneIdle(tabAPane2)
    #expect(!manager.tabIsDirty(tabA))
  }

  @Test
  func closePaneClearsCommandBusyEntry() throws {
    let (pr, wt, tabA, _, _, tabAPane2, _) = try makeFixtureTwoTabsWithPanes()
    manager.setPaneCommandBusy(tabAPane2, true)
    #expect(manager.tabIsDirty(tabA))
    try manager.closePane(tabAPane2, in: tabA, in: wt, in: pr)
    #expect(!manager.tabIsDirty(tabA))
  }
}
