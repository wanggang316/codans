import ComposableArchitecture
import Foundation
import Testing
import CodansCore

@testable import Codans

@MainActor
struct HierarchySidebarFeatureTests {
  @Test
  func toggleProjectExpansionFlipsCatalogFlag() async {
    // Project expansion lives on `Project.isExpanded` (persisted) — the
    // reducer reads the current catalog value and forwards the flipped
    // value to `setProjectExpanded`. No reducer-state mutation expected.
    let projectID = ProjectID()
    let project = Project(id: projectID, name: "p", rootPath: "/p", isExpanded: true)
    let received = LockIsolated<[(ProjectID, Bool)]>([])

    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = {
        Catalog(projects: [project])
      }
      $0.hierarchyClient.setProjectExpanded = { id, expanded in
        received.withValue { $0.append((id, expanded)) }
      }
    }

    await store.send(.toggleProjectExpansion(projectID))
    #expect(received.value.count == 1)
    #expect(received.value[0].0 == projectID)
    #expect(received.value[0].1 == false)
  }

  @Test
  func worktreeRevealInFinderEmitsDelegate() async {
    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    }
    await store.send(.worktreeRevealInFinderTapped(path: "/tmp/demo"))
    await store.receive(.delegate(.revealInFinder(path: "/tmp/demo")))
  }

  @Test
  func worktreeOpenInDefaultEditorEmitsDelegate() async {
    let projectID = ProjectID()
    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    }
    await store.send(
      .worktreeOpenInDefaultEditorTapped(
        worktreeID: WorktreeID(),
        projectID: projectID,
        path: "/tmp/demo"
      )
    )
    await store.receive(
      .delegate(.openInDefaultEditor(worktreePath: "/tmp/demo", projectID: projectID))
    )
  }

  /// Opening the Create-Worktree sheet must seed `copyIgnored`,
  /// `copyUntracked`, `fetchOrigin`, and `baseRefOverride` from the effective
  /// settings (per-project Git overrides chained to the global Worktree
  /// pane). The bug was that the sheet always started at false / nil even
  /// when Project Settings pinned them on.
  @Test
  func projectAddWorktreeTappedSeedsToggleDefaultsFromSettings() async {
    let projectID = ProjectID()
    let project = Project(id: projectID, name: "p", rootPath: "/p", gitRoot: "/p")
    let settings: Settings = {
      var settings = Settings()
      settings.worktree.fetchRemoteOnCreate = true
      settings.worktree.copyIgnoredOnCreate = false
      settings.worktree.copyUntrackedOnCreate = false
      settings.projects[projectID] = ProjectSettings(
        git: GitProjectSettings(
          worktreeBaseRef: "origin/main",
          copyIgnoredOnWorktreeCreate: true,
          copyUntrackedOnWorktreeCreate: true,
          fetchRemoteOnWorktreeCreate: false
        )
      )
      return settings
    }()

    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { Catalog(projects: [project]) }
      $0[SettingsWriter.self].readSnapshotSync = { settings }
    }
    store.exhaustivity = .off

    await store.send(.projectAddWorktreeTapped(projectID: projectID)) {
      $0.createWorktreeSheet = CreateWorktreeFeature.State(
        projectID: projectID,
        repoRoot: URL(fileURLWithPath: "/p"),
        worktreesDirectory: settings.worktree.resolveBaseDirectory(
          forProjectName: "p", projectOverride: nil),
        currentPendingCountForProject: 0,
        baseRefOverride: "origin/main",
        fetchOrigin: false,
        copyIgnored: true,
        copyUntracked: true
      )
    }
  }

  /// Global Worktree pane defaults still win when the Project has no Git
  /// override — guards against the regression where the project-level
  /// inherit path silently fell back to literal `false`.
  @Test
  func projectAddWorktreeTappedInheritsGlobalDefaultsWhenProjectOverrideAbsent() async {
    let projectID = ProjectID()
    let project = Project(id: projectID, name: "p", rootPath: "/p", gitRoot: "/p")
    let settings: Settings = {
      var settings = Settings()
      settings.worktree.fetchRemoteOnCreate = false
      settings.worktree.copyIgnoredOnCreate = true
      settings.worktree.copyUntrackedOnCreate = true
      return settings
    }()

    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { Catalog(projects: [project]) }
      $0[SettingsWriter.self].readSnapshotSync = { settings }
    }
    store.exhaustivity = .off

    await store.send(.projectAddWorktreeTapped(projectID: projectID)) {
      $0.createWorktreeSheet = CreateWorktreeFeature.State(
        projectID: projectID,
        repoRoot: URL(fileURLWithPath: "/p"),
        worktreesDirectory: settings.worktree.resolveBaseDirectory(
          forProjectName: "p", projectOverride: nil),
        currentPendingCountForProject: 0,
        baseRefOverride: nil,
        fetchOrigin: false,
        copyIgnored: true,
        copyUntracked: true
      )
    }
  }

  // MARK: - Archive / Remove All Merged Worktrees (Project ⋯ menu)

  /// Builds a project with a main checkout plus two non-main worktrees.
  /// `mergedIDs` are the merged set the view would resolve from GitHub
  /// snapshots and hand to the batch action.
  private func mergedBatchFixture() -> (
    project: Project, main: WorktreeID, wtA: WorktreeID, wtB: WorktreeID
  ) {
    let main = WorktreeID()
    let wtA = WorktreeID()
    let wtB = WorktreeID()
    let project = Project(
      id: ProjectID(),
      name: "p",
      rootPath: "/p",
      gitRoot: "/p",
      worktrees: [
        Worktree(id: main, name: "main", path: "/p"),
        Worktree(id: wtA, name: "a", path: "/p-a", branch: "a"),
        Worktree(id: wtB, name: "b", path: "/p-b", branch: "b"),
      ]
    )
    return (project, main, wtA, wtB)
  }

  @Test
  func archiveAllMergedTappedFiltersMainCheckoutAndOpensDialog() async {
    let f = mergedBatchFixture()
    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { Catalog(projects: [f.project]) }
    }

    // The view passes every "merged" id including the main checkout; the
    // reducer must drop the main checkout (archiving it would hide the root).
    await store.send(
      .projectArchiveAllMergedTapped(
        projectID: f.project.id, worktreeIDs: [f.main, f.wtA, f.wtB]
      )
    ) {
      $0.pendingArchiveAllMerged = PendingMergedBatch(
        projectID: f.project.id, worktreeIDs: [f.wtA, f.wtB]
      )
    }
  }

  @Test
  func archiveAllMergedTappedWithOnlyMainCheckoutIsNoOp() async {
    let f = mergedBatchFixture()
    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { Catalog(projects: [f.project]) }
    }
    // No dialog when the only candidate is the main checkout.
    await store.send(
      .projectArchiveAllMergedTapped(projectID: f.project.id, worktreeIDs: [f.main])
    )
  }

  @Test
  func archiveAllMergedConfirmedFansOutAndSuppressesExplainer() async {
    let f = mergedBatchFixture()
    let archived = LockIsolated<[WorktreeID]>([])
    let store = TestStore(
      initialState: HierarchySidebarFeature.State(
        pendingArchiveAllMerged: PendingMergedBatch(
          projectID: f.project.id, worktreeIDs: [f.wtA, f.wtB]
        )
      )
    ) {
      HierarchySidebarFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { Catalog(projects: [f.project]) }
      $0.hierarchyClient.setWorktreeArchivedWithLifecycle = { wid, _, _ in
        archived.withValue { $0.append(wid) }
      }
    }
    store.exhaustivity = .off

    await store.send(.projectArchiveAllMergedConfirmed) {
      $0.pendingArchiveAllMerged = nil
      // The batch dialog stands in for the per-worktree explainer.
      $0.hasShownArchiveExplainer = true
    }
    await store.finish()
    #expect(Set(archived.value) == [f.wtA, f.wtB])
  }

  @Test
  func removeAllMergedTappedFiltersMainCheckoutAndOpensDialog() async {
    let f = mergedBatchFixture()
    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { Catalog(projects: [f.project]) }
    }
    await store.send(
      .projectRemoveAllMergedTapped(
        projectID: f.project.id, worktreeIDs: [f.main, f.wtA, f.wtB]
      )
    ) {
      $0.pendingRemoveAllMerged = PendingMergedBatch(
        projectID: f.project.id, worktreeIDs: [f.wtA, f.wtB]
      )
    }
  }

  @Test
  func removeAllMergedConfirmedFansOutToLifecycle() async {
    let f = mergedBatchFixture()
    let removed = LockIsolated<[WorktreeID]>([])
    let store = TestStore(
      initialState: HierarchySidebarFeature.State(
        pendingRemoveAllMerged: PendingMergedBatch(
          projectID: f.project.id, worktreeIDs: [f.wtA, f.wtB]
        )
      )
    ) {
      HierarchySidebarFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { Catalog(projects: [f.project]) }
      $0.hierarchyClient.removeWorktreeWithLifecycle = { wid, _ in
        removed.withValue { $0.append(wid) }
        return nil
      }
    }
    store.exhaustivity = .off

    await store.send(.projectRemoveAllMergedConfirmed) {
      $0.pendingRemoveAllMerged = nil
    }
    await store.finish()
    #expect(Set(removed.value) == [f.wtA, f.wtB])
  }

  @Test
  func removeAllMergedCancelledClearsPending() async {
    let f = mergedBatchFixture()
    let store = TestStore(
      initialState: HierarchySidebarFeature.State(
        pendingRemoveAllMerged: PendingMergedBatch(
          projectID: f.project.id, worktreeIDs: [f.wtA]
        )
      )
    ) {
      HierarchySidebarFeature()
    }
    await store.send(.projectRemoveAllMergedCancelled) {
      $0.pendingRemoveAllMerged = nil
    }
  }
}
