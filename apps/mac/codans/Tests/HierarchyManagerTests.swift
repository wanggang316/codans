import Foundation
import Testing
import CodansCore

@testable import Codans

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

  private var worktree: Worktree {
    manager.catalog.projects[0].worktrees[0]
  }

  @discardableResult
  private func newTab(
    in worktreeID: WorktreeID, in projectID: ProjectID, name: String? = nil,
    workingDirectory: String = "/tmp", initialCommand: String? = nil
  ) throws -> TabAddress {
    try manager.newTab(
      in: nil, worktreeID: worktreeID, projectID: projectID,
      content: .terminal(workingDirectory: workingDirectory, initialCommand: initialCommand),
      name: name)
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
  func newTabAppendsAndSetsSelected() throws {
    let projectID = manager.addProject(name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID,
      name: "main",
      path: "/repo",
      branch: "main"
    )

    let created = try newTab(in: worktreeID, in: projectID, name: "tab1")

    #expect(worktree.allTabs.count == 1)
    #expect(worktree.allTabs[0].id == created.tabID)
    #expect(worktree.allTabs[0].name == "tab1")
    #expect(worktree.pane(created.paneID)?.selectedTabID == created.tabID)
  }

  @Test
  func newTabInEmptyWorktreeCreatesLeaf() async throws {
    let projectID = manager.addProject(name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID,
      name: "main",
      path: "/repo",
      branch: "main"
    )

    let created = try newTab(in: worktreeID, in: projectID)
    try await manager.ensureSurface(for: created.contentID)

    #expect(worktree.panes.count == 1)
    #expect(worktree.panes[0].id == created.paneID)
    #expect(worktree.splitTree.leaves() == [created.paneID])
    #expect(fakeRuntime.ensureSurfaceCalls.count == 1)
    #expect(fakeRuntime.ensureSurfaceCalls[0].contentID == created.contentID)
  }

  @Test
  func splitPaneCreatesNewLeaf() async throws {
    let projectID = manager.addProject(name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID,
      name: "main",
      path: "/repo",
      branch: "main"
    )
    let first = try newTab(in: worktreeID, in: projectID)
    try await manager.ensureSurface(for: first.contentID)

    fakeRuntime.reset()
    let created = try manager.splitPane(
      from: first.paneID, direction: .right, content: .terminal(workingDirectory: "/tmp"))
    try await manager.ensureSurface(for: created.contentID)

    #expect(worktree.panes.count == 2)
    #expect(worktree.splitTree.leaves().count == 2)
    #expect(worktree.splitTree.contains(created.paneID))
    #expect(fakeRuntime.ensureSurfaceCalls.count == 1)
    #expect(fakeRuntime.ensureSurfaceCalls[0].contentID == created.contentID)
  }

  /// Regression guard for the worktree-create double-seed race. The
  /// create-worktree flow seeds its first Tab from a *synchronous* reducer
  /// body so the row is observable before the `.selectionChanged` it
  /// triggers reaches `RootFeature`. If the row only landed after an
  /// `await`, the auto-seed would read an empty Worktree and race in a
  /// second Tab — the two concurrent `zmx serve` spawns then collide and
  /// one fails with `zmxServeFailed`. So `newTab` must (a) insert the Tab
  /// synchronously and (b) NOT bring the surface up; `ensureSurface` is
  /// the async half, and bringing it up once spawns exactly one surface.
  @Test
  func newTabInsertsRowSynchronouslyAndSurfaceComesUpOnce() async throws {
    let projectID = manager.addProject(name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "main", path: "/repo", branch: "main"
    )

    let created = try newTab(
      in: worktreeID, in: projectID, workingDirectory: "/repo", initialCommand: "echo setup")

    #expect(worktree.allTabs.count == 1)
    #expect(worktree.allTabs[0].id == created.tabID)
    #expect(worktree.allTabs[0].content.terminal?.initialCommand == "echo setup")
    #expect(worktree.splitTree.leaves() == [created.paneID])
    #expect(fakeRuntime.ensureSurfaceCalls.isEmpty)

    try await manager.ensureSurface(for: created.contentID)
    try await manager.ensureSurface(for: created.contentID)
    #expect(worktree.allTabs.count == 1)
    #expect(fakeRuntime.ensureSurfaceCalls.count == 1)
    #expect(fakeRuntime.ensureSurfaceCalls[0].contentID == created.contentID)
  }

  @Test
  func closeTabRemovesLeafFromSplitTree() async throws {
    let projectID = manager.addProject(name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID,
      name: "main",
      path: "/repo",
      branch: "main"
    )
    let created = try newTab(in: worktreeID, in: projectID)
    try await manager.ensureSurface(for: created.contentID)

    fakeRuntime.reset()
    try manager.closeTab(created.tabID)

    #expect(worktree.panes.isEmpty)
    #expect(worktree.splitTree.isEmpty)
    #expect(fakeRuntime.closeSurfaceCalls == [created.contentID])
  }

  @Test
  func worktreeValidateInvariantsHoldsAfterSplit() async throws {
    let projectID = manager.addProject(name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID,
      name: "main",
      path: "/repo",
      branch: "main"
    )
    let first = try newTab(in: worktreeID, in: projectID)

    _ = try manager.splitPane(
      from: first.paneID, direction: .right, content: .terminal(workingDirectory: "/tmp"))

    #expect(throws: Never.self) {
      try worktree.validateInvariants()
    }
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
  func removeProjectSuspendsEveryContentAndAnnounces() async throws {
    let projectID = manager.addProject(name: "p", rootPath: "/repo", gitRoot: "/repo")
    let liveWorktree = try manager.createWorktree(
      in: projectID, name: "feature", path: "/repo/feat", branch: "feature"
    )
    let live = try newTab(in: liveWorktree, in: projectID, workingDirectory: "/repo/feat")
    try await manager.ensureSurface(for: live.contentID)
    let archivedWorktree = try manager.createWorktree(
      in: projectID, name: "old", path: "/repo/old", branch: "old"
    )
    let archived = try newTab(in: archivedWorktree, in: projectID, workingDirectory: "/repo/old")
    try await manager.ensureSurface(for: archived.contentID)
    try manager.setWorktreeArchived(worktreeID: archivedWorktree, archived: true)
    fakeRuntime.reset()

    try manager.removeProject(projectID)

    // Suspend, not close: surfaces are lazy, so a backgrounded Content's zmx
    // daemon would otherwise leak, and `.paneExited` would route through
    // the exit path → closeTab for Tabs already deleted wholesale.
    // Archived worktrees are included — their control socket is gone, which
    // the live runtime treats as a no-op.
    #expect(Set(fakeRuntime.suspendSurfaceCalls) == Set([live.contentID, archived.contentID]))
    #expect(fakeRuntime.closeSurfaceCalls.isEmpty)
    // One structural-mutation announce so the AgentState reconcile runs
    // against the now-smaller catalog and retires the project's agent rows.
    #expect(fakeRuntime.announceHierarchyMutatedCount == 1)
    #expect(manager.catalog.projects.isEmpty)
  }

  @Test
  func removeProjectClearsBusySignal() async throws {
    let projectID = manager.addProject(name: "p", rootPath: "/repo", gitRoot: "/repo")
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "feature", path: "/repo/feat", branch: "feature"
    )
    let created = try newTab(in: worktreeID, in: projectID, workingDirectory: "/repo/feat")
    try await manager.ensureSurface(for: created.contentID)
    manager.setCommandQueue([QueuedCommand(text: "make", timing: .afterCurrentTask)], for: created.contentID)
    #expect(manager.isBusy(created.contentID))

    try manager.removeProject(projectID)

    // Removal suspends rather than closes, so the `.paneExited` cleanup in
    // closeTab never runs; the busy predicate must still read false for a
    // Content the catalog no longer holds.
    #expect(!manager.isBusy(created.contentID))
  }

  @Test
  func removeProjectClearsSelectionAndRejectsUnknownID() throws {
    let projectID = manager.addProject(name: "p", rootPath: "/repo", gitRoot: "/repo")
    manager.selectProject(projectID)

    #expect(throws: HierarchyError.self) {
      try manager.removeProject(ProjectID())
    }
    #expect(manager.catalog.projects.count == 1)

    try manager.removeProject(projectID)
    #expect(manager.catalog.selectedProjectID == nil)
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
    // `codans open` from a subdirectory must still resolve to the parent Project, so the
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

  /// Seeds a worktree with three Tabs in one Pane and returns
  /// (project, worktree, pane, tabIDs). Every Tab's surface is brought up
  /// so `closeTab`'s runtime-teardown path is exercised the same way the
  /// real UI drives it.
  @MainActor
  private func makeFixtureWithThreeTabs() async throws -> (ProjectID, WorktreeID, PaneID, [TabID]) {
    let projectID = manager.addProject(
      name: "project", rootPath: "/tmp", gitRoot: "/tmp"
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "main", path: "/repo", branch: "main"
    )
    var tabIDs: [TabID] = []
    var paneID: PaneID?
    for name in ["one", "two", "three"] {
      let created = try newTab(in: worktreeID, in: projectID, name: name)
      try await manager.ensureSurface(for: created.contentID)
      tabIDs.append(created.tabID)
      paneID = created.paneID
    }
    return (projectID, worktreeID, try #require(paneID), tabIDs)
  }

  private func selectedTabID(in paneID: PaneID) -> TabID? {
    manager.catalog.pane(paneID)?.selectedTabID
  }

  @Test
  func renameTabWritesName() async throws {
    let (_, _, _, tabs) = try await makeFixtureWithThreeTabs()
    try manager.renameTab(tabs[1], name: "renamed")
    let stored = worktree.allTabs[1].name
    #expect(stored == "renamed")
  }

  @Test
  func renameTabWithUnchangedNameIsNoOp() async throws {
    let (_, _, _, tabs) = try await makeFixtureWithThreeTabs()
    // Same value → no throw, still equals the original.
    try manager.renameTab(tabs[0], name: "one")
    #expect(worktree.allTabs[0].name == "one")
  }

  @Test
  func renameTabThrowsOnMissingID() async throws {
    _ = try await makeFixtureWithThreeTabs()
    #expect(throws: HierarchyError.self) {
      try manager.renameTab(TabID(), name: "nope")
    }
  }

  @Test
  func reorderTabsAcceptsPermutation() async throws {
    let (_, _, pane, tabs) = try await makeFixtureWithThreeTabs()
    let permuted = [tabs[2], tabs[0], tabs[1]]
    try manager.reorderTabs(in: pane, orderedIDs: permuted)
    let stored = worktree.allTabs.map(\.id)
    #expect(stored == permuted)
  }

  @Test
  func reorderTabsRejectsMismatchedSet() async throws {
    let (_, _, pane, tabs) = try await makeFixtureWithThreeTabs()
    // Drop the last id → set mismatch → invariantViolation.
    let shortened = Array(tabs.dropLast())
    #expect(throws: HierarchyError.self) {
      try manager.reorderTabs(in: pane, orderedIDs: shortened)
    }
  }

  @Test
  func closeOtherTabsKeepsPivotSelected() async throws {
    let (_, _, pane, tabs) = try await makeFixtureWithThreeTabs()
    try manager.closeOtherTabs(keeping: tabs[1])
    let remaining = worktree.allTabs.map(\.id)
    #expect(remaining == [tabs[1]])
    #expect(selectedTabID(in: pane) == tabs[1])
  }

  @Test
  func closeTabsToRightTrimsSuffix() async throws {
    let (_, _, _, tabs) = try await makeFixtureWithThreeTabs()
    try manager.closeTabsToRight(of: tabs[0])
    let remaining = worktree.allTabs.map(\.id)
    #expect(remaining == [tabs[0]])
  }

  @Test
  func closeTabsToRightNoOpForLastTab() async throws {
    let (_, _, _, tabs) = try await makeFixtureWithThreeTabs()
    try manager.closeTabsToRight(of: tabs.last!)
    let remaining = worktree.allTabs.map(\.id)
    #expect(remaining == tabs)
  }

  @Test
  func closeTabsToRightKeepsPivotSelectedWhenActiveWasDoomed() async throws {
    let (_, _, pane, tabs) = try await makeFixtureWithThreeTabs()
    // makeFixtureWithThreeTabs leaves the last tab selected; ask to
    // close everything to the right of the first one. The user's
    // active tab is in the doomed suffix, so without the explicit
    // reseat the auto-advance would land on `tabs.first` regardless
    // of which pivot was passed.
    try manager.closeTabsToRight(of: tabs[0])
    #expect(selectedTabID(in: pane) == tabs[0])
  }

  @Test
  func closeTabsToRightKeepsPivotSelectedWhenPivotIsMid() async throws {
    let (_, _, pane, tabs) = try await makeFixtureWithThreeTabs()
    // Pivot is the middle tab; auto-advance would otherwise land on
    // tabs[0] when tabs[2] (the active tab) closes.
    try manager.closeTabsToRight(of: tabs[1])
    let remaining = worktree.allTabs.map(\.id)
    #expect(remaining == [tabs[0], tabs[1]])
    #expect(selectedTabID(in: pane) == tabs[1])
  }

  @Test
  func closeTabSelectsRightNeighborWhenMiddleTabClosed() async throws {
    let (_, _, pane, tabs) = try await makeFixtureWithThreeTabs()
    try manager.selectTab(tabs[1])
    try manager.closeTab(tabs[1])
    #expect(selectedTabID(in: pane) == tabs[2])
  }

  @Test
  func closeTabFallsBackToLeftNeighborWhenLastTabClosed() async throws {
    let (_, _, pane, tabs) = try await makeFixtureWithThreeTabs()
    // makeFixtureWithThreeTabs already leaves tabs[2] (the trailing tab) selected.
    try manager.closeTab(tabs[2])
    #expect(selectedTabID(in: pane) == tabs[1])
  }

  @Test
  func closeTabClosesPaneWhenSoleTabClosed() throws {
    let projectID = manager.addProject(
      name: "p", rootPath: "/tmp", gitRoot: "/tmp"
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "main", path: "/repo", branch: "main"
    )
    let only = try newTab(in: worktreeID, in: projectID, name: "only")
    try manager.closeTab(only.tabID)
    #expect(worktree.panes.isEmpty)
    #expect(worktree.focusedPaneID == nil)
  }

  @Test
  func closeTabPreservesSelectionWhenInactiveTabClosed() async throws {
    let (_, _, pane, tabs) = try await makeFixtureWithThreeTabs()
    try manager.selectTab(tabs[1])
    // Closing a non-selected tab must not move the selection.
    try manager.closeTab(tabs[0])
    #expect(selectedTabID(in: pane) == tabs[1])
  }

  @Test
  func closeTabFocusesSurfaceOfNewlySelectedTab() async throws {
    // Without this focus transfer, the closed surface's responder slot
    // stays empty and subsequent ⌘W bypasses Ghostty's perfKE, falling
    // through to the menu where the system Close Window can shadow
    // our binding and close the whole window.
    let (_, _, pane, tabs) = try await makeFixtureWithThreeTabs()
    fakeRuntime.reset()
    // Close the trailing (selected) tab → fallback to its left neighbor.
    try manager.closeTab(tabs[2])
    #expect(selectedTabID(in: pane) == tabs[1])
    let neighbourContentID = try #require(manager.catalog.tab(tabs[1])).contentID
    #expect(fakeRuntime.focusSurfaceViewCalls.contains(neighbourContentID))
  }

  @Test
  func closeAllTabsEmptiesWorktree() async throws {
    let (_, _, pane, _) = try await makeFixtureWithThreeTabs()
    try manager.closeAllTabs(in: pane)
    #expect(worktree.allTabs.isEmpty)
    #expect(worktree.panes.isEmpty)
    #expect(worktree.focusedPaneID == nil)
  }

  @Test
  func selectAdjacentTabWrapsForward() async throws {
    let (_, _, pane, tabs) = try await makeFixtureWithThreeTabs()
    // After makeFixtureWithThreeTabs the last-created tab is selected.
    #expect(selectedTabID(in: pane) == tabs[2])
    let next = try manager.selectAdjacentTab(direction: .next, in: pane)
    #expect(next == tabs[0])
    #expect(selectedTabID(in: pane) == tabs[0])
  }

  @Test
  func selectAdjacentTabWrapsBackward() async throws {
    let (_, _, pane, tabs) = try await makeFixtureWithThreeTabs()
    // Selected is tabs[2]; previous from 2 is 1, from 0 is 2 (wrap). Check both.
    try manager.selectTab(tabs[0])
    let previous = try manager.selectAdjacentTab(direction: .previous, in: pane)
    #expect(previous == tabs[2])
    #expect(selectedTabID(in: pane) == tabs[2])
  }

  @Test
  func selectAdjacentTabThrowsOnUnknownPane() throws {
    let projectID = manager.addProject(
      name: "project", rootPath: "/tmp", gitRoot: "/tmp"
    )
    _ = try manager.createWorktree(
      in: projectID, name: "main", path: "/repo", branch: "main"
    )
    // An empty Worktree has no Pane to walk, so there is no id to pass.
    #expect(throws: HierarchyError.self) {
      try manager.selectAdjacentTab(direction: .next, in: PaneID())
    }
  }

  // MARK: - Runtime state: Pane focus across Tabs

  /// Seeds a worktree with two Panes. Pane A has two Tabs, Pane B has one.
  @MainActor
  private func makeFixtureTwoPanes() async throws -> (
    ProjectID, WorktreeID, TabAddress, TabAddress, TabAddress
  ) {
    let projectID = manager.addProject(
      name: "project", rootPath: "/tmp", gitRoot: "/tmp"
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "main", path: "/repo", branch: "main"
    )
    let paneATab1 = try newTab(in: worktreeID, in: projectID, name: "A1")
    try await manager.ensureSurface(for: paneATab1.contentID)
    let paneB = try manager.splitPane(
      from: paneATab1.paneID, direction: .right, content: .terminal(workingDirectory: "/tmp"))
    try await manager.ensureSurface(for: paneB.contentID)
    let paneATab2 = try manager.newTab(
      in: paneATab1.paneID, worktreeID: worktreeID, projectID: projectID,
      content: .terminal(workingDirectory: "/tmp"), name: "A2")
    try await manager.ensureSurface(for: paneATab2.contentID)
    return (projectID, worktreeID, paneATab1, paneATab2, paneB)
  }

  @Test
  func focusPaneRestoresItsSelectedTab() async throws {
    let (_, _, paneATab1, paneATab2, paneB) = try await makeFixtureTwoPanes()
    // Pane A's selection is its second Tab; bounce through Pane B and back.
    #expect(selectedTabID(in: paneATab1.paneID) == paneATab2.tabID)
    try manager.focusPane(paneB.paneID)
    fakeRuntime.reset()
    try manager.selectTab(paneATab2.tabID)
    #expect(worktree.focusedPaneID == paneATab1.paneID)
    #expect(fakeRuntime.focusSurfaceViewCalls.contains(paneATab2.contentID))
  }

  @Test
  func focusNeighbourFallsBackToTheSelectedTabWhenTheRememberedOneClosed() async throws {
    let (_, _, paneATab1, paneATab2, paneB) = try await makeFixtureTwoPanes()
    // The selected Tab disappears out from under us.
    try manager.closeTab(paneATab2.tabID)
    try manager.focusPane(paneB.paneID)
    fakeRuntime.reset()
    let landed = try manager.focusNeighbour(of: paneB.paneID, direction: .left)
    #expect(landed == paneATab1.paneID)
    // Fallback: the Pane's surviving selected Tab.
    #expect(fakeRuntime.focusSurfaceViewCalls.contains(paneATab1.contentID))
  }

  @Test
  func closePaneDropsProcessRowsOfEveryTab() async throws {
    let (_, worktreeID, paneATab1, paneATab2, paneB) = try await makeFixtureTwoPanes()
    manager.recordProcessLaunch(contentID: paneATab1.contentID, name: "make", kind: .run)
    manager.recordProcessLaunch(contentID: paneATab2.contentID, name: "test", kind: .run)
    #expect(manager.processEntries(in: worktreeID).count == 2)
    try manager.closePane(paneATab1.paneID)
    #expect(manager.processEntries(in: worktreeID).isEmpty)
    #expect(worktree.panes.map(\.id) == [paneB.paneID])
  }
}
