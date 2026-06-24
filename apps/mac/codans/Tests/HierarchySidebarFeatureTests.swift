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

  /// Reducer boundary: a whitespace-only `createScript.command` is stashed
  /// VERBATIM into the pending's `spec.setupCommand` — the reducer does NOT
  /// trim or null it. The trim/skip itself lives in the git layer (see the
  /// `empty-command-skips-setup` integration test), so the reducer must
  /// faithfully forward whatever the project's createScript holds.
  @Test
  func beginStashesWhitespaceOnlySetupCommandVerbatim() async {
    let projectID = ProjectID()
    let pending = Self.makePending(projectID: projectID)
    let whitespaceCommand = "   "

    let settings: Settings = {
      var settings = Settings()
      settings.projects[projectID] = ProjectSettings(
        git: GitProjectSettings(createScript: ScriptDefinition(command: whitespaceCommand))
      )
      return settings
    }()
    // Records the spec the stream was invoked with so we can assert the
    // whitespace-only command was stashed unchanged before streaming began.
    let invokedSetup = LockIsolated<String?>(nil)

    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: {
      $0[SettingsWriter.self].readSnapshotSync = { settings }
      $0.gitWorktreeClient.createWorktreeStream = { spec in
        invokedSetup.setValue(spec.setupCommand)
        return AsyncThrowingStream { $0.finish() }
      }
    }
    store.exhaustivity = .off

    await store.send(.beginPendingWorktreeCreation(pending)) {
      // The reducer forwards the exact whitespace string — no trim, no nil.
      var stashed = pending
      stashed.spec.setupCommand = whitespaceCommand
      $0.pendingWorktrees.append(stashed)
    }
    #expect(invokedSetup.value == whitespaceCommand)

    await store.skipReceivedActions()
  }

  // MARK: - Pending cancel + failure (pending-cancel-and-failure)

  /// VAL-LIFECYCLE-006: Cancel while the setup script is running must NOT
  /// orphan the already-materialized worktree. The handler cancels the
  /// running script (stream effect) AND reuses the finish path so the
  /// worktree is written to the catalog and the pending row is removed.
  @Test
  func cancelDuringSetupPhaseMaterializesViaFinish() async {
    let projectID = ProjectID()
    var pending = Self.makePending(projectID: projectID)
    pending.phase = .runningSetupScript
    let materialized = URL(fileURLWithPath: "/repo/.worktrees/feat-x")
    pending.materializedPath = materialized
    let id = pending.id
    let newWorktreeID = WorktreeID()

    var initial = HierarchySidebarFeature.State()
    initial.pendingWorktrees.append(pending)

    let created = LockIsolated<[(ProjectID, String, String, String)]>([])

    let store = TestStore(initialState: initial) {
      HierarchySidebarFeature()
    } withDependencies: {
      $0.hierarchyClient.createWorktreeWithGit = { pid, display, branch, path in
        created.withValue { $0.append((pid, display, branch, path)) }
        return newWorktreeID
      }
    }
    store.exhaustivity = .off

    await store.send(.pendingWorktreeCancelTapped(id))
    // Cancel reuses the existing finish path to materialize. Finish now
    // delegates the switch decision up (`.worktreeMaterialized`) rather than
    // selecting / seeding inline; with exhaustivity off we don't assert that
    // tail here — see `finishedEmitsWorktreeMaterializedDelegate...`.
    await store.receive(.pendingWorktreeFinished(id, materialized)) {
      $0.pendingWorktrees.remove(id: id)
    }

    // Worktree reached the catalog (no orphan dir), pending row gone.
    #expect(created.value.count == 1)
    #expect(created.value[0].3 == materialized.path)
    #expect(store.state.pendingWorktrees[id: id] == nil)
  }

  /// VAL-LIFECYCLE-005: Cancel during the git-add phase (not yet
  /// materialized) discards the pending row and cancels the stream effect
  /// (whose `onTermination` terminates the spawned git child). Nothing is
  /// written to the catalog.
  @Test
  func cancelDuringCreatingPhaseDiscardsCleanly() async {
    let projectID = ProjectID()
    let pending = Self.makePending(projectID: projectID)  // phase == .creatingWorktree
    let id = pending.id

    var initial = HierarchySidebarFeature.State()
    initial.pendingWorktrees.append(pending)

    let createdCount = LockIsolated(0)

    let store = TestStore(initialState: initial) {
      HierarchySidebarFeature()
    } withDependencies: {
      $0.hierarchyClient.createWorktreeWithGit = { _, _, _, _ in
        createdCount.withValue { $0 += 1 }
        return WorktreeID()
      }
    }

    await store.send(.pendingWorktreeCancelTapped(id)) {
      $0.pendingWorktrees.remove(id: id)
    }

    // No finish action, no catalog write.
    #expect(createdCount.value == 0)
    #expect(store.state.pendingWorktrees[id: id] == nil)
  }

  /// Cancel arriving after `pendingWorktreeFinished` already removed the
  /// row is a harmless no-op — guards against a late cancel racing
  /// completion into double-acting (a pending row AND a catalog row).
  @Test
  func cancelAfterFinishedIsNoOp() async {
    let projectID = ProjectID()
    let pending = Self.makePending(projectID: projectID)
    let id = pending.id

    // Empty pending set models the post-finish state (row already removed).
    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    }

    // No state mutation, no effects — the guard short-circuits.
    await store.send(.pendingWorktreeCancelTapped(id))
  }

  /// completion-switch-gate: `pendingWorktreeFinished` writes the catalog,
  /// removes the pending row, and now DELEGATES the switch decision up
  /// instead of selecting / seeding panes itself. Pins the new contract:
  /// exactly one `.delegate(.worktreeMaterialized(...))` carrying the new
  /// WorktreeID + the pending's IDs, and no inline selectProject /
  /// selectWorktree call.
  @Test
  func finishedEmitsWorktreeMaterializedDelegateAndDoesNotSelect() async {
    let projectID = ProjectID()
    let pending = Self.makePending(projectID: projectID)
    let id = pending.id
    let materialized = URL(fileURLWithPath: "/repo/.worktrees/feat-x")
    let newWorktreeID = WorktreeID()

    var initial = HierarchySidebarFeature.State()
    initial.pendingWorktrees.append(pending)

    let selectProjectCalls = LockIsolated(0)
    let selectWorktreeCalls = LockIsolated(0)

    let store = TestStore(initialState: initial) {
      HierarchySidebarFeature()
    } withDependencies: {
      $0.hierarchyClient.createWorktreeWithGit = { _, _, _, _ in newWorktreeID }
      $0.hierarchyClient.selectProject = { _ in
        selectProjectCalls.withValue { $0 += 1 }
      }
      $0.hierarchyClient.selectWorktree = { _, _ in
        selectWorktreeCalls.withValue { $0 += 1 }
      }
    }
    store.exhaustivity = .off

    await store.send(.pendingWorktreeFinished(id, materialized)) {
      $0.pendingWorktrees.remove(id: id)
    }
    await store.receive(
      .delegate(
        .worktreeMaterialized(
          worktreeID: newWorktreeID, projectID: projectID, pendingID: id)))
    await store.finish()

    #expect(selectProjectCalls.value == 0)
    #expect(selectWorktreeCalls.value == 0)
  }

  /// VAL-SWITCH-008 (sidebar leg): a FAILED creation routes through
  /// `pendingWorktreeFailed`, which never materializes and never emits the
  /// switch delegate — so failure can never switch the user away.
  @Test
  func failedDoesNotEmitWorktreeMaterializedDelegate() async {
    let projectID = ProjectID()
    let pending = Self.makePending(projectID: projectID)
    let id = pending.id

    var initial = HierarchySidebarFeature.State()
    initial.pendingWorktrees.append(pending)

    let store = TestStore(initialState: initial) {
      HierarchySidebarFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .pendingWorktreeFailed(id, .commandFailed(command: "git", stderr: "boom"))
    ) {
      $0.pendingWorktrees[id: id]?.status = .failed(
        .commandFailed(command: "git", stderr: "boom"))
    }
    // No delegate, no further effects: `store.finish()` would trip if a
    // `.worktreeMaterialized` (or any other) effect were still in flight.
    await store.finish()
    #expect(store.state.pendingWorktrees[id: id]?.status != .running)
  }
}
