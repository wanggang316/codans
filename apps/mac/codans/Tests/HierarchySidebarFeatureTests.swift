import CodansCore
import ComposableArchitecture
import Foundation
import Testing

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

  /// HAN-83: opening the Create-Worktree sheet must seed `copyIgnored`,
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

  // MARK: - Pending phase lifecycle (pending-phase-lifecycle)

  /// Builds a `.running` pending row whose spec carries no setup command —
  /// `beginPendingWorktreeCreation` stashes the project's createScript into
  /// the spec before streaming.
  private static func makePending(projectID: ProjectID) -> PendingWorktree {
    PendingWorktree(
      id: PendingWorktreeID(),
      projectID: projectID,
      spec: CreateWorktreeSpec(
        repoRoot: URL(fileURLWithPath: "/repo"),
        baseDirectory: URL(fileURLWithPath: "/repo/.worktrees"),
        name: "feat-x",
        baseRef: "origin/main",
        fetchOrigin: false,
        copyIgnored: false,
        copyUntracked: false
      ),
      displayName: "feat/x",
      status: .running,
      lastProgressLine: nil,
      startedAt: Date(timeIntervalSince1970: 0)
    )
  }

  /// beginPendingWorktreeCreation reads the project's createScript and
  /// stashes it into the pending's spec `setupCommand` so the stream runs
  /// it in-phase; the stream's `.setupPhaseBegan` flips the row to
  /// `.runningSetupScript` + records the materialized path; `.progressLine`
  /// keeps updating `lastProgressLine` across both phases.
  @Test
  func beginStashesSetupCommandAndStreamsBothPhases() async {
    let projectID = ProjectID()
    let pending = Self.makePending(projectID: projectID)
    let id = pending.id
    let materialized = URL(fileURLWithPath: "/repo/.worktrees/feat-x")

    let settings: Settings = {
      var settings = Settings()
      settings.projects[projectID] = ProjectSettings(
        git: GitProjectSettings(createScript: ScriptDefinition(command: "npm install"))
      )
      return settings
    }()
    // Records the spec the stream was invoked with so we can assert the
    // setup command was stashed before streaming began.
    let invokedSetup = LockIsolated<String?>(nil)

    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: {
      $0[SettingsWriter.self].readSnapshotSync = { settings }
      $0.gitWorktreeClient.createWorktreeStream = { spec in
        invokedSetup.setValue(spec.setupCommand)
        return AsyncThrowingStream { continuation in
          continuation.yield(.progressLine("Cloning…"))
          continuation.yield(.setupPhaseBegan(worktreePath: materialized))
          continuation.yield(.progressLine("added 42 packages"))
          continuation.finish()
        }
      }
    }
    store.exhaustivity = .off

    await store.send(.beginPendingWorktreeCreation(pending)) {
      // The row is appended with the createScript stashed into its spec.
      var stashed = pending
      stashed.spec.setupCommand = "npm install"
      $0.pendingWorktrees.append(stashed)
    }
    #expect(invokedSetup.value == "npm install")

    await store.receive(.pendingWorktreeProgress(id, "Cloning…")) {
      $0.pendingWorktrees[id: id]?.lastProgressLine = "Cloning…"
      $0.pendingWorktrees[id: id]?.progressLines = ["Cloning…"]
    }
    await store.receive(.pendingWorktreeSetupPhaseBegan(id, materialized)) {
      $0.pendingWorktrees[id: id]?.phase = .runningSetupScript
      $0.pendingWorktrees[id: id]?.materializedPath = materialized
    }
    await store.receive(.pendingWorktreeProgress(id, "added 42 packages")) {
      // Second line keeps streaming through the setup phase.
      $0.pendingWorktrees[id: id]?.lastProgressLine = "added 42 packages"
      $0.pendingWorktrees[id: id]?.progressLines = ["Cloning…", "added 42 packages"]
    }

    await store.skipReceivedActions()
  }

  /// An empty / unset createScript leaves `setupCommand` nil — the stream
  /// never emits `.setupPhaseBegan`, so the row stays in `.creatingWorktree`.
  @Test
  func emptySetupCommandKeepsPhaseCreating() async {
    let projectID = ProjectID()
    let pending = Self.makePending(projectID: projectID)
    let id = pending.id
    let invokedSetup = LockIsolated<String?>("sentinel")

    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: {
      // No project entry → no createScript → nil setupCommand.
      $0[SettingsWriter.self].readSnapshotSync = { Settings() }
      $0.gitWorktreeClient.createWorktreeStream = { spec in
        invokedSetup.setValue(spec.setupCommand)
        return AsyncThrowingStream { $0.finish() }
      }
    }
    store.exhaustivity = .off

    await store.send(.beginPendingWorktreeCreation(pending))
    #expect(invokedSetup.value == nil)
    #expect(store.state.pendingWorktrees[id: id]?.phase == .creatingWorktree)

    await store.skipReceivedActions()
  }
}
