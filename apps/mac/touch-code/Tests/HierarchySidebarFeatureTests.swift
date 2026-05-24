import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

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

  /// HAN-83: opening the Create-Worktree sheet must seed `copyIgnored`,
  /// `copyUntracked`, `fetchOrigin`, and `baseRefOverride` from the effective
  /// settings (per-project Git overrides chained to the global Worktree
  /// pane). The bug was that the sheet always started at false / nil even
  /// when Project Settings pinned them on.
  @Test
  func projectAddWorktreeTappedSeedsToggleDefaultsFromSettings() async {
    let projectID = ProjectID()
    let project = Project(id: projectID, name: "p", rootPath: "/p", gitRoot: "/p")
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
    var settings = Settings()
    settings.worktree.fetchRemoteOnCreate = false
    settings.worktree.copyIgnoredOnCreate = true
    settings.worktree.copyUntrackedOnCreate = true

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
}
