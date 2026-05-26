import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

@MainActor
struct RootFeatureTests {
  @Test
  func onLaunchReceivesEngineEventThenCancels() async {
    let (eventStream, eventContinuation) = AsyncStream<TerminalEvent>.makeStream()
    let (selectionStream, selectionContinuation) = AsyncStream<HierarchySelection>.makeStream()

    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { eventStream }
      $0.hierarchyClient.selectionChanges = { selectionStream }
      // Engine events drive downstream child reducers (notably StatusBar) that
      // expect a real catalog/clock; stub both with quiet defaults so the
      // non-exhaustive assertion below doesn't trip on `unimplemented` issues
      // surfaced by side effects we don't care about here.
      $0.hierarchyClient.snapshot = { Catalog() }
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.onLaunch)

    // Yield a single lifecycle event.
    let paneID = PaneID()
    eventContinuation.yield(.paneReady(paneID))
    await store.receive(\.engineEventReceived) { state in
      state.lastEvent = .paneReady
    }

    // Cancellation: onQuit closes the in-flight effects.
    eventContinuation.finish()
    selectionContinuation.finish()
    await store.send(.onQuit)
  }

  // M0 cleanup: `selectionChangedUpdatesStateAndForwardsToGitViewer` removed —
  // the GitViewer feature no longer exists; the future Diff feature
  // (replacing it) will own its own forwarding test.

  @Test
  func selectionChangedMirrorsActiveTabFromSnapshot() async {
    // Build a catalog snapshot with a Worktree whose selectedTabID is a
    // known value; assert the reducer reads through the snapshot and
    // mirrors that TabID into state.detail.splitViewport.activeTabID.
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let tabID = TabID()

    let tab = Tab(id: tabID, name: "t", splitTree: SplitTree(), panes: [])
    let worktree = Worktree(
      id: worktreeID, name: "w", path: "/w", branch: "main",
      tabs: [tab], selectedTabID: tabID
    )
    let project = Project(
      id: projectID, name: "p", rootPath: "/", gitRoot: "/",

      worktrees: [worktree], selectedWorktreeID: worktreeID
    )
    let catalog = Catalog(projects: [project])

    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { catalog }
      $0.gitService = GitServiceClient.testValue
      // Worktree path resolves to a live directory in this catalog, so GitViewer reaches
      // `workingTreeDiff`. Stub it with an empty diff — the test is not about the diff.
      $0.gitService.workingTreeDiff = { _, _ in UnifiedDiff(scope: .working, files: []) }
      // M4: `.selectionChanged` now forwards into `.diff(.worktreeSelected(...))`,
      // which kicks a `diffNumstat` load. Stub empty so the effect resolves without
      // hitting `unimplemented`.
      $0.gitService.diffNumstat = { _ in [] }
      // 0013 M4 wired a `.gitHub(.projectActivated)` dispatch on projectID transitions.
      // This test is exhaustivity=off and not about GitHub, but the fetch effect still
      // runs and touches .date + remoteInfo + batchPullRequests — stub each to no-op.
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.gitService.remoteInfo = { _ in RemoteInfo(host: "github.com", owner: "o", repo: "r") }
      $0[GitHubClient.self].batchPullRequests = { _, _, _, _ in [:] }
      $0.editorClient = EditorClient.testValue
      // `.selectionChanged` runs `autoSeedTabAndPaneIfNeeded`, which spawns a
      // pane in the active tab when it has none. The fixture tab is empty so
      // `openPane` is reached; stub it to a no-op since this test asserts
      // only the splitViewport tabID mirror.
      $0.hierarchyClient.openPane = { _, _, _, _, _ in PaneID() }
    }
    // Non-exhaustive: this test is about the splitViewport tabID mirror only; the
    // downstream `.gitViewer.worktreeSelected` forwarding + its diff effect are
    // covered by `selectionChangedUpdatesStateAndForwardsToGitViewer`.
    store.exhaustivity = .off

    let selection = HierarchySelection(projectID: projectID, worktreeID: worktreeID)
    await store.send(.selectionChanged(selection)) { state in
      state.selection = selection
      state.detail.splitViewport.activeTabID = tabID
    }
  }

  // `inspectorVisibilityTogglesBothWays` removed in T3: replaced by the
  // per-Worktree `diffInspectorVisible` projection and
  // `.diffInspectorToggledForCurrentWorktree` action — covered below.

  // MARK: - T3 overlay projection + shortcuts

  /// Shared catalog fixture for T3 GV overlay tests. Worktree A is visible,
  /// B is hidden. The second Worktree lives under the same Project so the
  /// selection delta is just the worktree leg.
  private static func gvFixtureCatalog(
    projectID: ProjectID,
    worktreeA: WorktreeID, worktreeB: WorktreeID,
    aVisible: Bool, bVisible: Bool
  ) -> Catalog {
    let wtA = Worktree(
      id: worktreeA, name: "A", path: "/a", branch: "a",
      tabs: [], selectedTabID: nil, diffInspectorVisible: aVisible
    )
    let wtB = Worktree(
      id: worktreeB, name: "B", path: "/b", branch: "b",
      tabs: [], selectedTabID: nil, diffInspectorVisible: bVisible
    )
    let project = Project(
      id: projectID, name: "p", rootPath: "/", gitRoot: "/",

      worktrees: [wtA, wtB], selectedWorktreeID: worktreeA
    )
    return Catalog(projects: [project])
  }

  @Test
  func diffInspectorVisibleTracksSelectionAgainstCatalog() async {
    // With the T3-REV2 single-source-of-truth rewrite, the view reads
    // `State.diffInspectorVisible(in: catalog)` directly. After a
    // `.selectionChanged`, that read returns the target Worktree's
    // persisted `diffInspectorVisible` — no reducer projection in between.
    let projectID = ProjectID()
    let worktreeA = WorktreeID()
    let worktreeB = WorktreeID()
    let catalog = Self.gvFixtureCatalog(
      projectID: projectID,
      worktreeA: worktreeA, worktreeB: worktreeB,
      aVisible: true, bVisible: false
    )

    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { catalog }
      $0.gitService = GitServiceClient.testValue
      $0.gitService.workingTreeDiff = { _, _ in UnifiedDiff(scope: .working, files: []) }
      // M4: `.selectionChanged` forwards into `.diff(.worktreeSelected(...))` which
      // kicks `diffNumstat`; stub empty so the effect terminates cleanly.
      $0.gitService.diffNumstat = { _ in [] }
      // 0013 M4: selectionChanged now dispatches .gitHub(.projectActivated) when the
      // Project changes. Stub the downstream deps so exhaustivity=off still runs.
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.gitService.remoteInfo = { _ in RemoteInfo(host: "github.com", owner: "o", repo: "r") }
      $0[GitHubClient.self].batchPullRequests = { _, _, _, _ in [:] }
      $0.editorClient = EditorClient.testValue
      // The gv-fixture worktrees have no tabs, so `autoSeedTabAndPaneIfNeeded`
      // walks createTab → openPane on each selection switch.
      $0.hierarchyClient.createTab = { _, _, _ in TabID() }
      $0.hierarchyClient.openPane = { _, _, _, _, _ in PaneID() }
    }
    store.exhaustivity = .off

    // Initially no selection → helper returns false.
    #expect(store.state.diffInspectorVisible(in: catalog) == false)

    let selectionA = HierarchySelection(
      projectID: projectID, worktreeID: worktreeA
    )
    await store.send(.selectionChanged(selectionA)) { $0.selection = selectionA }
    #expect(store.state.diffInspectorVisible(in: catalog) == true)

    let selectionB = HierarchySelection(
      projectID: projectID, worktreeID: worktreeB
    )
    await store.send(.selectionChanged(selectionB)) { $0.selection = selectionB }
    #expect(store.state.diffInspectorVisible(in: catalog) == false)
  }

  @Test
  func diffInspectorVisibleFollowsCatalogMutationWithSameSelection() {
    // Second half of the single-source-of-truth contract: flipping the
    // catalog value (T2 Header button path) must flip the helper read
    // without any selection change and without any reducer projection.
    let projectID = ProjectID()
    let worktreeA = WorktreeID()
    let worktreeB = WorktreeID()

    var initial = RootFeature.State()
    initial.selection = HierarchySelection(
      projectID: projectID, worktreeID: worktreeA
    )
    let store = TestStore(initialState: initial) {
      RootFeature()
    }

    let hidden = Self.gvFixtureCatalog(
      projectID: projectID,
      worktreeA: worktreeA, worktreeB: worktreeB,
      aVisible: false, bVisible: false
    )
    let shown = Self.gvFixtureCatalog(
      projectID: projectID,
      worktreeA: worktreeA, worktreeB: worktreeB,
      aVisible: true, bVisible: false
    )
    #expect(store.state.diffInspectorVisible(in: hidden) == false)
    #expect(store.state.diffInspectorVisible(in: shown) == true)
  }

  @Test
  func diffInspectorToggleInvokesHierarchyClientWithFlippedValue() async {
    // The reducer now reads the current value from the catalog snapshot
    // and writes the flipped value; no state mutation. Both entry points
    // (⌘⇧G + Header button) share a single write path.
    let projectID = ProjectID()
    let worktreeA = WorktreeID()
    let worktreeB = WorktreeID()
    let recorded = LockIsolated<[(WorktreeID, Bool)]>([])
    let catalog = Self.gvFixtureCatalog(
      projectID: projectID,
      worktreeA: worktreeA, worktreeB: worktreeB,
      aVisible: false, bVisible: false
    )

    var initial = RootFeature.State()
    initial.selection = HierarchySelection(
      projectID: projectID, worktreeID: worktreeA
    )

    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.setWorktreeDiffInspectorVisible = { wt, visible in
        recorded.withValue { $0.append((wt, visible)) }
      }
      // No external git viewer configured — reducer falls through to the
      // built-in overlay toggle path that this test covers.
      $0[SettingsWriter.self].readSnapshotSync = { Settings() }
    }

    await store.send(.diffInspectorToggledForCurrentWorktree)
    await store.finish()
    #expect(recorded.value.count == 1)
    #expect(recorded.value.first?.0 == worktreeA)
    // Starting from `diffInspectorVisible: false`, toggle writes `true`.
    #expect(recorded.value.first?.1 == true)
  }

  @Test
  func diffInspectorToggleWithoutSelectionIsNoOp() async {
    // When no Worktree is selected, the toggle must not fire the setter.
    let recorded = LockIsolated<[(WorktreeID, Bool)]>([])
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { Catalog() }
      $0.hierarchyClient.setWorktreeDiffInspectorVisible = { wt, visible in
        recorded.withValue { $0.append((wt, visible)) }
      }
      $0[SettingsWriter.self].readSnapshotSync = { Settings() }
    }
    await store.send(.diffInspectorToggledForCurrentWorktree)
    await store.finish()
    #expect(recorded.value.isEmpty)
  }

  // MARK: - T2 worktreeHeader delegate routing

  @Test
  func headerOpenEditorWithExplicitIDForwardsToEditor() async {
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.editorClient = EditorClient.testValue
      $0.editorClient.open = { _, id in
        EditorChoice(
          id: id ?? "finder", displayName: "x", binaryPath: nil
        )
      }
      // .openSucceeded routes through StatusBarFeature which consumes the
      // continuous clock to schedule its auto-clear timer.
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    let projectID = ProjectID()
    await store.send(
      .worktreeHeader(
        .delegate(
          .openEditor(
            editorID: "vscode", worktreePath: "/tmp/w", projectID: projectID
          ))))
    await store.receive(
      .editor(
        .openRequested(
          editorID: "vscode", worktreePath: "/tmp/w", projectID: projectID
        )))
  }

  @Test
  func headerOpenEditorWithNilResolvesDefaultThenForwards() async {
    // Pre-populate EditorFeature cache with a descriptor + matching global
    // default. ResolveDefault should pick "cursor" and the root should
    // re-emit .editor(.openRequested) with that id.
    let descriptor = EditorDescriptor(
      id: "cursor",
      displayName: "Cursor",
      bundleIdentifier: "com.todesktop.230313mzl4w4u92",
      launchMode: .directory,
      appURL: URL(fileURLWithPath: "/Applications/Cursor.app"),
      alternateBundleIdentifiers: []
    )
    var initial = RootFeature.State()
    initial.editor.descriptors = [descriptor]
    initial.editor.globalDefault = "cursor"
    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { Catalog() }
      $0.editorClient = EditorClient.testValue
      $0.editorClient.open = { _, id in
        EditorChoice(
          id: id ?? "finder", displayName: "x", binaryPath: nil
        )
      }
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(
      .worktreeHeader(
        .delegate(
          .openEditor(
            editorID: nil, worktreePath: "/tmp/w", projectID: nil
          ))))
    await store.receive(
      .editor(
        .openRequested(
          editorID: "cursor", worktreePath: "/tmp/w", projectID: nil
        )))
  }

  @Test
  func headerOpenEditorWithNilDeferspreferredToServiceCascade() async {
    // Codex P2-3: when no project override and no global default resolves, the reducer
    // forwards `nil` as `preferred` so the service's priority cascade picks the first
    // installed editor (Cursor / Zed / VSCode / …) before falling through to Finder.
    // Previously the reducer forced `"finder"` here, which strict-matched Finder and
    // shadowed every higher-priority installed editor.
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { Catalog() }
      $0.editorClient = EditorClient.testValue
      $0.editorClient.open = { _, id in
        EditorChoice(
          id: id ?? "finder", displayName: "x", binaryPath: nil
        )
      }
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(
      .worktreeHeader(
        .delegate(
          .openEditor(
            editorID: nil, worktreePath: "/tmp/w", projectID: nil
          ))))
    await store.receive(
      .editor(
        .openRequested(
          editorID: nil,
          worktreePath: "/tmp/w",
          projectID: nil
        )))
  }

  @Test
  func headerShowCustomEditorsSettingsInvokesPresenter() async {
    // The Header "+ Custom editors…" delegate now opens the standalone Settings window via
    // `SettingsWindowPresenter` (post Step 6). Test overrides the presenter with a recorder
    // and asserts the closure fires exactly once when the delegate is dispatched.
    let openCount = LockIsolated(0)
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.settingsWindowPresenter = SettingsWindowPresenter(
        open: {
          openCount.withValue { $0 += 1 }
        },
        openAt: { _ in }
      )
    }
    store.exhaustivity = .off

    await store.send(.worktreeHeader(.delegate(.showCustomEditorsSettings)))
    await store.finish()
    #expect(openCount.value == 1)
  }

  @Test
  func headerSetProjectOverrideForwardsToEditor() async {
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      // v3: per-Project editor overrides go through SettingsWriter, not HierarchyClient.
      $0.settingsWriter.setProjectDefaultEditor = { _, _ in }
    }
    store.exhaustivity = .off
    let projectID = ProjectID()
    await store.send(
      .worktreeHeader(
        .delegate(
          .setProjectOverride(
            projectID: projectID, editorID: "zed"
          ))))
    await store.receive(
      .editor(
        .setProjectOverride(
          projectID: projectID, editorID: "zed"
        )))
  }

  // Removed in T1: `sidebarModeChangedUpdatesState` covered the
  // SidebarMode / .sidebarModeChanged plumbing that T0 left as
  // "T2 must either reuse or remove". T1 deleted the plumbing (the
  // sidebar unconditionally renders the hierarchy tree; T2 built the
  // Header bell fresh on WorktreeHeader).

  @Test
  func onLaunchExhaustivelyPropagatesSelectionFromStream() async {
    // Tight-scope TestStore: only the selection stream yields, the event
    // stream immediately finishes. Full exhaustivity verifies that
    // selectionChanged action propagates from the stream subscription
    // through the reducer with no extra actions dispatched.
    let (selectionStream, selectionContinuation) = AsyncStream<HierarchySelection>.makeStream()

    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { selectionStream }
      $0.hierarchyClient.snapshot = { Catalog() }
      $0.gitService = GitServiceClient.testValue
      $0.editorClient = EditorClient.testValue
    }

    await store.send(.onLaunch)

    // `worktreeID: nil` is the key: when GitViewerFeature receives a nil-worktree selection
    // it resets state without spawning a diff effect, so the test stays exhaustive without
    // any downstream action chain.
    let selection = HierarchySelection(
      projectID: nil,
      worktreeID: nil
    )
    selectionContinuation.yield(selection)
    // `selection.empty == State.selection.default` so the assignment is a
    // no-op observable change; we omit the trailing closure to satisfy the
    // strict no-change check.
    await store.receive(\.selectionChanged)
    // M4: `.selectionChanged` now forwards into `.diff(.worktreeSelected(...))`
    // unconditionally so DiffFeature can reset its state for the new (or absent)
    // Worktree. With `worktreeID: nil`, DiffFeature returns `.cancel(...)` —
    // no further actions follow.
    await store.receive(\.diff.worktreeSelected)

    selectionContinuation.finish()
    await store.send(.onQuit)
  }

  @Test
  func lastEventMarkerCoversAllVariants() {
    // Guard against forgetting to add a marker case when a new TerminalEvent
    // variant lands. Exhaustive switch at the enum level would be safer but
    // requires Equatable which TerminalEvent can't have (Data payload). This
    // test provides at least surface coverage that every variant maps.
    let pane = PaneID()
    let tab = TabID()
    let worktree = WorktreeID()

    let cases: [(TerminalEvent, RootFeature.LastEventMarker)] = [
      (.paneCreated(pane, tab), .paneCreated),
      (.paneReady(pane), .paneReady),
      (.paneOutput(pane, Data([0x01])), .paneOutput),
      (.paneIdle(pane, duration: 1), .paneIdle),
      (.paneExited(pane, code: 0, signal: nil), .paneExited),
      (.paneCrashed(pane, reason: "x"), .paneCrashed),
      (.paneClosedByTab(pane, cause: .other(reason: "x")), .paneClosedByTab),
      (.tabActivated(tab), .tabActivated),
      (.tabAutoClosed(tab, cause: .other(reason: "x")), .tabAutoClosed),
      (.worktreeActivated(worktree), .worktreeActivated),
      (.hierarchyMutated(.catalog), .hierarchyMutated),
      (.foregroundJobChanged(pane, ForegroundJob(processGroupID: 1, processes: [])), .foregroundJobChanged),
    ]
    for (event, expected) in cases {
      #expect(RootFeature.LastEventMarker(event) == expected)
    }
  }

  // MARK: - 0014 status-bar toast routing

  /// The multi-line / over-80-char scrubber that the `.editor(.openFailed)`
  /// and `.gitHub(...Completed)` branches pipe through before constructing a
  /// warning toast. Kept as a pure function so the message-shape invariants
  /// are locked in without spinning up a `RootFeature` TestStore — a full
  /// multi-scope TestStore interacts badly with the StatusBarFeature suite's
  /// TestClock-driven sleeps when they share the host-app process, so we
  /// exercise the forwarding itself through the M1/M7 app-run smoke tests
  /// instead.
  @Test
  func shortToastMessageTakesFirstLineAndCapsAt80Characters() {
    #expect(RootFeature.shortToastMessage("one") == "one")
    #expect(RootFeature.shortToastMessage("first\nsecond") == "first")
    #expect(RootFeature.shortToastMessage("  padded\n ") == "padded")
    let long = String(repeating: "x", count: 120)
    let clipped = RootFeature.shortToastMessage(long)
    #expect(clipped.count == 80)
    #expect(clipped.hasSuffix("…"))
  }

  // MARK: - Tab-bar shortcut resolvers (M2-T2.10)

  /// Builds a catalog with a single worktree carrying `tabCount` tabs;
  /// the `selectedIndex`-th tab is the active one. Each tab has a single
  /// pane so `trailingSplitRequested` paths (and closes in general) find
  /// the runtime surface teardown they expect.
  private static func tabBarFixture(
    tabCount: Int, selectedIndex: Int
  ) -> (ProjectID, WorktreeID, [TabID], Catalog) {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    var tabs: [Tab] = []
    var ids: [TabID] = []
    for i in 0..<tabCount {
      let tabID = TabID()
      let paneID = PaneID()
      let pane = Pane(id: paneID, workingDirectory: "/tmp", initialCommand: nil)
      tabs.append(
        Tab(id: tabID, name: "t\(i)", splitTree: SplitTree(leaf: paneID), panes: [pane])
      )
      ids.append(tabID)
    }
    let worktree = Worktree(
      id: worktreeID, name: "main", path: "/tmp", branch: "main",
      tabs: tabs, selectedTabID: ids[selectedIndex]
    )
    let project = Project(
      id: projectID, name: "p", rootPath: "/tmp",
      worktrees: [worktree], selectedWorktreeID: worktreeID
    )
    let catalog = Catalog(projects: [project])
    return (projectID, worktreeID, ids, catalog)
  }

  @Test
  func newTabForCurrentWorktreeForwardsToTabBar() async {
    let (pr, wt, _, catalog) = Self.tabBarFixture(tabCount: 2, selectedIndex: 0)
    var initial = RootFeature.State()
    initial.selection = HierarchySelection(projectID: pr, worktreeID: wt)

    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.createTab = { _, _, _ in TabID() }
      // The new-tab reducer auto-spawns a pane in the worktree cwd;
      // stub the call so the unimplemented closure does not record.
      $0.hierarchyClient.openPane = { _, _, _, _, _ in PaneID() }
    }
    store.exhaustivity = .off

    await store.send(.newTabForCurrentWorktree)
    await store.receive(\.detail.tabBar)
  }

  @Test
  func newTabForCurrentWorktreeIsNoOpWithoutSelection() async {
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    }
    // No snapshot stub needed — guard short-circuits before any client call.
    await store.send(.newTabForCurrentWorktree)
    await store.finish()
  }

  @Test
  func closeActiveTabForCurrentWorktreeForwardsActiveTab() async {
    // Each fixture tab has exactly one pane, so ⌘W takes the
    // single-pane branch and closes the whole tab.
    let (pr, wt, ids, catalog) = Self.tabBarFixture(tabCount: 3, selectedIndex: 1)
    var initial = RootFeature.State()
    initial.selection = HierarchySelection(projectID: pr, worktreeID: wt)

    let captured = LockIsolated<TabID?>(nil)
    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.closeTab = { id, _, _ in
        captured.withValue { $0 = id }
      }
    }
    store.exhaustivity = .off

    await store.send(.closeActiveTabForCurrentWorktree)
    await store.receive(\.detail.tabBar)
    #expect(captured.value == ids[1])
  }

  @Test
  func closeActiveTabForCurrentWorktreeClosesFocusedPaneWhenSplit() async throws {
    // Active tab has two panes: ⌘W must close the focused pane only,
    // leaving the tab itself open.
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let tabID = TabID()
    let leftPane = PaneID()
    let rightPane = PaneID()
    let tab = Tab(
      id: tabID, name: "t",
      splitTree: try SplitTree(leaf: leftPane).inserting(
        rightPane, at: leftPane, direction: .right
      ),
      panes: [
        Pane(id: leftPane, workingDirectory: "/tmp", initialCommand: nil),
        Pane(id: rightPane, workingDirectory: "/tmp", initialCommand: nil),
      ]
    )
    let worktree = Worktree(
      id: worktreeID, name: "main", path: "/tmp", branch: "main",
      tabs: [tab], selectedTabID: tabID
    )
    let project = Project(
      id: projectID, name: "p", rootPath: "/tmp",
      worktrees: [worktree], selectedWorktreeID: worktreeID
    )
    let catalog = Catalog(projects: [project])

    var initial = RootFeature.State()
    initial.selection = HierarchySelection(projectID: projectID, worktreeID: worktreeID)

    let closedPane = LockIsolated<PaneID?>(nil)
    let closedTab = LockIsolated<TabID?>(nil)
    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.lastFocusedPane = { _ in rightPane }
      $0.hierarchyClient.closePane = { id, _, _, _ in
        closedPane.withValue { $0 = id }
      }
      $0.hierarchyClient.closeTab = { id, _, _ in
        closedTab.withValue { $0 = id }
      }
    }
    store.exhaustivity = .off

    await store.send(.closeActiveTabForCurrentWorktree)
    await store.finish()
    #expect(closedPane.value == rightPane)
    #expect(closedTab.value == nil)
  }

  @Test
  func paneLifecycleExitedClosesTabWhenLastPaneInTab() async {
    // ⌘W routed via Ghostty's `close_surface` lands here. With one pane in
    // the tab, the surviving tab would be empty — close it instead of
    // leaving a zombie.
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let tabID = TabID()
    let paneID = PaneID()
    let pane = Pane(id: paneID, workingDirectory: "/tmp", initialCommand: nil)
    let tab = Tab(
      id: tabID, name: "t", splitTree: SplitTree(leaf: paneID), panes: [pane]
    )
    let worktree = Worktree(
      id: worktreeID, name: "main", path: "/tmp", branch: "main",
      tabs: [tab], selectedTabID: tabID
    )
    let project = Project(
      id: projectID, name: "p", rootPath: "/tmp",
      worktrees: [worktree], selectedWorktreeID: worktreeID
    )
    let catalog = Catalog(projects: [project])
    let address = PaneAddress(
      projectID: projectID, worktreeID: worktreeID,
      tabID: tabID, paneID: paneID
    )

    let closedTab = LockIsolated<TabID?>(nil)
    let closedPane = LockIsolated<PaneID?>(nil)
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.addressOf = { _ in address }
      $0.hierarchyClient.closeTab = { id, _, _ in
        closedTab.withValue { $0 = id }
      }
      $0.hierarchyClient.closePane = { id, _, _, _ in
        closedPane.withValue { $0 = id }
      }
    }
    store.exhaustivity = .off

    await store.send(.paneLifecycleExited(paneID))
    await store.finish()
    #expect(closedTab.value == tabID)
    #expect(closedPane.value == nil)
  }

  @Test
  func paneLifecycleExitedClosesOnlyPaneWhenTabHasSiblings() async {
    // Multi-pane tab: keep the tab, drop the pane, transfer focus.
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let tabID = TabID()
    let leftPane = PaneID()
    let rightPane = PaneID()
    let tab = Tab(
      id: tabID, name: "t",
      splitTree: try! SplitTree(leaf: leftPane).inserting(
        rightPane, at: leftPane, direction: .right
      ),
      panes: [
        Pane(id: leftPane, workingDirectory: "/tmp", initialCommand: nil),
        Pane(id: rightPane, workingDirectory: "/tmp", initialCommand: nil),
      ]
    )
    let worktree = Worktree(
      id: worktreeID, name: "main", path: "/tmp", branch: "main",
      tabs: [tab], selectedTabID: tabID
    )
    let project = Project(
      id: projectID, name: "p", rootPath: "/tmp",
      worktrees: [worktree], selectedWorktreeID: worktreeID
    )
    let catalog = Catalog(projects: [project])
    let address = PaneAddress(
      projectID: projectID, worktreeID: worktreeID,
      tabID: tabID, paneID: rightPane
    )

    let closedTab = LockIsolated<TabID?>(nil)
    let closedPane = LockIsolated<PaneID?>(nil)
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.addressOf = { _ in address }
      $0.hierarchyClient.closeTab = { id, _, _ in
        closedTab.withValue { $0 = id }
      }
      $0.hierarchyClient.closePane = { id, _, _, _ in
        closedPane.withValue { $0 = id }
      }
      $0.hierarchyClient.focusSurfaceView = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.paneLifecycleExited(rightPane))
    await store.finish()
    #expect(closedPane.value == rightPane)
    #expect(closedTab.value == nil)
  }

  @Test
  func selectTabAtIndexPicksNthTab() async {
    let (pr, wt, ids, catalog) = Self.tabBarFixture(tabCount: 3, selectedIndex: 0)
    var initial = RootFeature.State()
    initial.selection = HierarchySelection(projectID: pr, worktreeID: wt)

    let captured = LockIsolated<TabID?>(nil)
    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.selectTab = { id, _, _ in
        captured.withValue { $0 = id }
      }
    }
    store.exhaustivity = .off

    await store.send(.selectTabAtIndexForCurrentWorktree(3))
    await store.receive(\.detail.tabBar)
    #expect(captured.value == ids[2])
  }

  @Test
  func selectTabAtIndexOutOfRangeIsNoOp() async {
    let (pr, wt, _, catalog) = Self.tabBarFixture(tabCount: 2, selectedIndex: 0)
    var initial = RootFeature.State()
    initial.selection = HierarchySelection(projectID: pr, worktreeID: wt)
    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
    }

    // Tab count is 2; asking for the 5th is out of range.
    await store.send(.selectTabAtIndexForCurrentWorktree(5))
    await store.finish()
  }

  @Test
  func selectAdjacentTabCallsClient() async {
    let pr = ProjectID()
    let wt = WorktreeID()
    var initial = RootFeature.State()
    initial.selection = HierarchySelection(projectID: pr, worktreeID: wt)

    let captured = LockIsolated<TabAdjacency?>(nil)
    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.selectAdjacentTab = { dir, _, _ in
        captured.withValue { $0 = dir }
        return nil
      }
    }

    await store.send(.selectAdjacentTabForCurrentWorktree(.next))
    await store.finish()
    #expect(captured.value == .next)
  }

  // MARK: - $EDITOR Pane spawn

  @Test
  func openShellEditorInWorktreeSpawnsPaneWithDollarEditorCommand() async {
    // The `.openRequested(editorID: "editor", ...)` path delegates out to RootFeature
    // (because EditorService cannot launch $EDITOR — no Pane/Tab context). RootFeature
    // looks up the worktree by path, creates a fresh Tab, and opens a Pane carrying
    // `initialCommand: "$EDITOR"` so the Pane primitive handles the launch. This test
    // pins that wiring: every hierarchyClient call records its arguments so we can
    // assert the spawn lands on the matched (space, project, worktree, tab) and the
    // Pane was given `$EDITOR` exactly.
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let tabID = TabID()
    let worktreePath = "/repo/main"
    let worktree = Worktree(id: worktreeID, name: "main", path: worktreePath)
    let project = Project(
      id: projectID, name: "p", rootPath: worktreePath, gitRoot: worktreePath,
      worktrees: [worktree]
    )
    let catalog = Catalog(projects: [project])

    struct OpenPaneCall: Sendable, Equatable {
      let tabID: TabID
      let worktreeID: WorktreeID
      let projectID: ProjectID
      let cwd: String
      let initialCommand: String?
    }
    let openPaneCalls = LockIsolated<[OpenPaneCall]>([])
    let createTabCalls = LockIsolated<Int>(0)

    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.createTab = { _, _, _ in
        createTabCalls.withValue { $0 += 1 }
        return tabID
      }
      $0.hierarchyClient.openPane = { tab, wt, pr, cwd, cmd in
        openPaneCalls.withValue {
          $0.append(
            OpenPaneCall(
              tabID: tab, worktreeID: wt, projectID: pr, cwd: cwd, initialCommand: cmd))
        }
        return PaneID()
      }
      $0.hierarchyClient.selectProject = { _ in }
      $0.hierarchyClient.selectWorktree = { _, _ in }
      $0.hierarchyClient.selectTab = { _, _, _ in }
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(
      .openShellEditorInWorktree(worktreePath: worktreePath, projectID: projectID))
    await store.finish()

    #expect(createTabCalls.value == 1)
    #expect(openPaneCalls.value.count == 1)
    let call = openPaneCalls.value.first
    #expect(call?.tabID == tabID)
    #expect(call?.worktreeID == worktreeID)
    #expect(call?.projectID == projectID)
    #expect(call?.cwd == worktreePath)
    #expect(call?.initialCommand == "$EDITOR")
  }

  @Test
  func editorOpenRequestedRoutesShellEditorThroughDelegate() async {
    // EditorFeature intercepts `.openRequested(editorID: shellEditorID, ...)` and
    // emits `.delegate(.openShellEditorRequested(...))` instead of calling
    // `editorClient.open` (which would throw). RootFeature catches the delegate and
    // dispatches its own `.openShellEditorInWorktree(...)`.
    let projectID = ProjectID()
    let worktreePath = "/repo/x"
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { Catalog() }
      $0.editorClient = EditorClient.testValue
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(
      .editor(
        .openRequested(
          editorID: EditorRegistry.shellEditorID,
          worktreePath: worktreePath,
          projectID: projectID
        )))
    await store.receive(
      .editor(
        .delegate(
          .openShellEditorRequested(worktreePath: worktreePath, projectID: projectID))))
    await store.receive(
      .openShellEditorInWorktree(worktreePath: worktreePath, projectID: projectID))
  }
}
