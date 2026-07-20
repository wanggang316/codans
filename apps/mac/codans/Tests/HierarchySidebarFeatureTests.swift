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

  // MARK: - Archive / delete lifecycle progress

  /// Catalog with one project owning a main checkout plus one extra
  /// worktree — the archive/remove guards read it to prove the target is
  /// NOT the main checkout.
  private static func makeLifecycleCatalog(
    projectID: ProjectID, worktreeID: WorktreeID
  ) -> Catalog {
    var project = Project(id: projectID, name: "p", rootPath: "/p", gitRoot: "/p")
    project.worktrees = [
      Worktree(name: "main", path: "/p"),
      Worktree(id: worktreeID, name: "feature", path: "/p-wts/feature"),
    ]
    return Catalog(projects: [project])
  }

  /// Archive with a configured archive script: the effect must narrate
  /// script → finalizing → gone, running the script BEFORE the flag flip.
  @Test
  func archiveWithScriptSequencesLifecyclePhases() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let scriptCalls = LockIsolated<[String]>([])
    let archivedCalls = LockIsolated<[(WorktreeID, Bool)]>([])
    var settings = Settings()
    settings.projects[projectID] = ProjectSettings(
      git: GitProjectSettings(archiveScript: ScriptDefinition(command: "docker compose down"))
    )
    let snapshot = settings

    var initial = HierarchySidebarFeature.State()
    initial.hasShownArchiveExplainer = true

    let store = TestStore(initialState: initial) {
      HierarchySidebarFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = {
        Self.makeLifecycleCatalog(projectID: projectID, worktreeID: worktreeID)
      }
      $0.hierarchyClient.runWorktreeLifecycleScript = { _, _, command, tabName in
        scriptCalls.withValue { $0.append("\(tabName): \(command)") }
      }
      $0.hierarchyClient.setWorktreeArchived = { wid, archived in
        archivedCalls.withValue { $0.append((wid, archived)) }
      }
      // Recorded into the same log as the script so the order — running
      // scripts torn down BEFORE the archive script runs — is pinned.
      $0.hierarchyClient.stopAllScripts = { _ in
        scriptCalls.withValue { $0.append("Stop") }
      }
      $0[SettingsWriter.self].readSnapshotSync = { snapshot }
    }

    await store.send(
      .worktreeArchiveTapped(worktreeID: worktreeID, inProject: projectID, name: "feature")
    )
    await store.receive(
      .lifecycleStarted(
        worktreeID: worktreeID,
        progress: WorktreeLifecycleProgress(kind: .archive, phase: .runningScript)
      )
    ) {
      $0.lifecycleProgress[worktreeID] = WorktreeLifecycleProgress(
        kind: .archive, phase: .runningScript
      )
    }
    await store.receive(
      .lifecyclePhaseChanged(worktreeID: worktreeID, phase: .finalizing)
    ) {
      $0.lifecycleProgress[worktreeID]?.phase = .finalizing
    }
    await store.receive(.lifecycleEnded(worktreeID: worktreeID)) {
      $0.lifecycleProgress = [:]
    }
    #expect(scriptCalls.value == ["Stop", "Archive: docker compose down"])
    #expect(archivedCalls.value.count == 1)
    #expect(archivedCalls.value[0].0 == worktreeID)
    #expect(archivedCalls.value[0].1 == true)
  }

  /// Archive with NO script configured: the row goes straight to the
  /// finalizing phase and the script endpoint is never touched.
  @Test
  func archiveWithoutScriptSkipsScriptPhase() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let scriptCalls = LockIsolated<Int>(0)

    var initial = HierarchySidebarFeature.State()
    initial.hasShownArchiveExplainer = true

    let store = TestStore(initialState: initial) {
      HierarchySidebarFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = {
        Self.makeLifecycleCatalog(projectID: projectID, worktreeID: worktreeID)
      }
      $0.hierarchyClient.runWorktreeLifecycleScript = { _, _, _, _ in
        scriptCalls.withValue { $0 += 1 }
      }
      $0.hierarchyClient.setWorktreeArchived = { _, _ in }
      $0.hierarchyClient.stopAllScripts = { _ in }
      $0[SettingsWriter.self].readSnapshotSync = { Settings() }
    }

    await store.send(
      .worktreeArchiveTapped(worktreeID: worktreeID, inProject: projectID, name: "feature")
    )
    await store.receive(
      .lifecycleStarted(
        worktreeID: worktreeID,
        progress: WorktreeLifecycleProgress(kind: .archive, phase: .finalizing)
      )
    ) {
      $0.lifecycleProgress[worktreeID] = WorktreeLifecycleProgress(
        kind: .archive, phase: .finalizing
      )
    }
    await store.receive(.lifecycleEnded(worktreeID: worktreeID)) {
      $0.lifecycleProgress = [:]
    }
    #expect(scriptCalls.value == 0)
  }

  /// Remove with a configured delete script: same narration shape as
  /// archive, with the git teardown as the finalizing step.
  @Test
  func removeWithScriptSequencesLifecyclePhases() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let scriptCalls = LockIsolated<[String]>([])
    let removeCalls = LockIsolated<Int>(0)
    var settings = Settings()
    settings.projects[projectID] = ProjectSettings(
      git: GitProjectSettings(deleteScript: ScriptDefinition(command: "rm -rf node_modules"))
    )
    let snapshot = settings

    var initial = HierarchySidebarFeature.State()
    initial.pendingWorktreeRemoval = PendingWorktreeRemoval(
      worktreeID: worktreeID, projectID: projectID, displayName: "feature"
    )

    let store = TestStore(initialState: initial) {
      HierarchySidebarFeature()
    } withDependencies: {
      $0.hierarchyClient.runWorktreeLifecycleScript = { _, _, command, tabName in
        scriptCalls.withValue { $0.append("\(tabName): \(command)") }
      }
      $0.hierarchyClient.removeWorktreeWithGit = { _, _ in
        removeCalls.withValue { $0 += 1 }
        return nil
      }
      // Same ordering pin as the archive test: teardown precedes the
      // delete script.
      $0.hierarchyClient.stopAllScripts = { _ in
        scriptCalls.withValue { $0.append("Stop") }
      }
      $0[SettingsWriter.self].readSnapshotSync = { snapshot }
    }

    await store.send(.worktreeRemoveConfirmed) {
      $0.pendingWorktreeRemoval = nil
    }
    await store.receive(
      .lifecycleStarted(
        worktreeID: worktreeID,
        progress: WorktreeLifecycleProgress(kind: .remove, phase: .runningScript)
      )
    ) {
      $0.lifecycleProgress[worktreeID] = WorktreeLifecycleProgress(
        kind: .remove, phase: .runningScript
      )
    }
    await store.receive(
      .lifecyclePhaseChanged(worktreeID: worktreeID, phase: .finalizing)
    ) {
      $0.lifecycleProgress[worktreeID]?.phase = .finalizing
    }
    await store.receive(.lifecycleEnded(worktreeID: worktreeID)) {
      $0.lifecycleProgress = [:]
    }
    #expect(scriptCalls.value == ["Stop", "Delete: rm -rf node_modules"])
    #expect(removeCalls.value == 1)
  }

  /// The phase line + stage value pairs are a fixed presentation contract
  /// (same style as the creation row's `creating`/`setupScript` values) —
  /// pin them so a rename shows up as a deliberate diff.
  @Test
  func lifecycleProgressStringsAreStable() {
    let cases: [(WorktreeLifecycleProgress, String, String)] = [
      (
        WorktreeLifecycleProgress(kind: .archive, phase: .runningScript),
        "Running archive script…", "archiveScript"
      ),
      (
        WorktreeLifecycleProgress(kind: .archive, phase: .finalizing),
        "Archiving…", "archiving"
      ),
      (
        WorktreeLifecycleProgress(kind: .remove, phase: .runningScript),
        "Running delete script…", "deleteScript"
      ),
      (
        WorktreeLifecycleProgress(kind: .remove, phase: .finalizing),
        "Removing worktree…", "removing"
      ),
    ]
    for (progress, line, stage) in cases {
      #expect(progress.phaseLine == line)
      #expect(progress.stageAccessibilityValue == stage)
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
      // No archive script configured -> the sequenced lifecycle skips the
      // script phase and flips the flag per worktree.
      $0[SettingsWriter.self].readSnapshotSync = { Settings() }
      $0.hierarchyClient.setWorktreeArchived = { wid, _ in
        archived.withValue { $0.append(wid) }
      }
      $0.hierarchyClient.stopAllScripts = { _ in }
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
      // No delete script configured -> the sequenced lifecycle goes straight
      // to the git teardown per worktree.
      $0[SettingsWriter.self].readSnapshotSync = { Settings() }
      $0.hierarchyClient.removeWorktreeWithGit = { wid, _ in
        removed.withValue { $0.append(wid) }
        return nil
      }
      $0.hierarchyClient.stopAllScripts = { _ in }
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
