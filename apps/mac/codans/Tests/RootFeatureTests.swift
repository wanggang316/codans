import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

@MainActor
struct RootFeatureTests {
  @Test
  func paneCrashedClearsRunningFlag() async {
    // Crashed panes stay in the catalog for the user to retry. The OSC 9;4
    // running flag must be force-cleared here because a crashing program
    // rarely emits the REMOVE state itself, which would otherwise leave
    // the tab-chip / sidebar spinners pinned on a dead pane forever.
    let (eventStream, eventContinuation) = AsyncStream<TerminalEvent>.makeStream()
    let (selectionStream, selectionContinuation) = AsyncStream<HierarchySelection>.makeStream()
    let paneID = PaneID()
    let markedIdle = LockIsolated<PaneID?>(nil)

    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { eventStream }
      $0.hierarchyClient.selectionChanges = { selectionStream }
      $0.hierarchyClient.snapshot = { Catalog() }
      $0.hierarchyClient.markPaneIdle = { id in
        markedIdle.withValue { $0 = id }
      }
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.onLaunch)
    eventContinuation.yield(.paneCrashed(paneID, reason: "test"))
    await store.receive(\.paneProgressBusyChanged)

    eventContinuation.finish()
    selectionContinuation.finish()
    await store.send(.onQuit)

    #expect(markedIdle.value == paneID)
  }

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
      // A `.gitHub(.projectActivated)` dispatch fires on projectID transitions.
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
    // Non-exhaustive: this test is about the splitViewport tabID mirror only.
    store.exhaustivity = .off

    let selection = HierarchySelection(projectID: projectID, worktreeID: worktreeID)
    await store.send(.selectionChanged(selection)) { state in
      state.selection = selection
      state.detail.splitViewport.activeTabID = tabID
    }
  }

  // MARK: - Git Viewer chord (opens external client)

  /// Shared catalog fixture for Git Viewer tests. Two Worktrees under one
  /// Project so the selection delta is just the worktree leg.
  private static func gvFixtureCatalog(
    projectID: ProjectID,
    worktreeA: WorktreeID, worktreeB: WorktreeID
  ) -> Catalog {
    let wtA = Worktree(
      id: worktreeA, name: "A", path: "/a", branch: "a",
      tabs: [], selectedTabID: nil
    )
    let wtB = Worktree(
      id: worktreeB, name: "B", path: "/b", branch: "b",
      tabs: [], selectedTabID: nil
    )
    let project = Project(
      id: projectID, name: "p", rootPath: "/", gitRoot: "/",
      worktrees: [wtA, wtB], selectedWorktreeID: worktreeA
    )
    return Catalog(projects: [project])
  }

  @Test
  func gitViewerChordOpensConfiguredExternalClient() async {
    // With a global `defaultGitViewerID` pointing at an installed client, the
    // ⌘⌥G chord resolves it and opens the current worktree there via
    // `.editor(.openRequested(...))`.
    let projectID = ProjectID()
    let worktreeA = WorktreeID()
    let worktreeB = WorktreeID()
    let catalog = Self.gvFixtureCatalog(
      projectID: projectID,
      worktreeA: worktreeA, worktreeB: worktreeB
    )

    let descriptor = EditorDescriptor(
      id: "fork",
      displayName: "Fork",
      bundleIdentifier: "com.DanPristupov.Fork",
      launchMode: .directory,
      appURL: URL(fileURLWithPath: "/Applications/Fork.app"),
      alternateBundleIdentifiers: []
    )
    var initial = RootFeature.State()
    initial.selection = HierarchySelection(
      projectID: projectID, worktreeID: worktreeA
    )
    initial.editor.descriptors = [descriptor]

    let settings = Settings(general: GeneralSettings(defaultGitViewerID: "fork"))

    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0[SettingsWriter.self].readSnapshotSync = { settings }
      // The resolved `.editor(.openRequested)` runs EditorFeature's open
      // effect; stub the client + clock so the downstream chain completes
      // without hitting unimplemented dependencies.
      $0.editorClient = EditorClient.testValue
      $0.editorClient.open = { _, id in
        EditorChoice(id: id ?? "finder", displayName: "x", binaryPath: nil)
      }
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.diffInspectorToggledForCurrentWorktree)
    await store.receive(\.editor.openRequested)
    await store.finish()
  }

  @Test
  func gitViewerChordIsNoOpWhenNoneSelected() async {
    // Default Git Viewer = None (defaultGitViewerID == nil): the chord opens
    // nothing — the built-in overlay no longer exists.
    let projectID = ProjectID()
    let worktreeA = WorktreeID()
    let worktreeB = WorktreeID()
    let catalog = Self.gvFixtureCatalog(
      projectID: projectID,
      worktreeA: worktreeA, worktreeB: worktreeB
    )

    var initial = RootFeature.State()
    initial.selection = HierarchySelection(
      projectID: projectID, worktreeID: worktreeA
    )

    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0[SettingsWriter.self].readSnapshotSync = { Settings() }
    }

    await store.send(.diffInspectorToggledForCurrentWorktree)
    await store.finish()
  }

  @Test
  func gitViewerChordWithoutSelectionIsNoOp() async {
    // When no Worktree is selected, the chord is a no-op.
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { Catalog() }
      $0[SettingsWriter.self].readSnapshotSync = { Settings() }
    }
    await store.send(.diffInspectorToggledForCurrentWorktree)
    await store.finish()
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
      // The remote-vs-local branch in `.openRequested` reads the catalog to
      // decide the transport; an empty catalog keeps this test on the local path.
      $0.hierarchyClient.snapshot = { Catalog() }
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
    // The launch sweep always arms the liveness poll. With an empty
    // Catalog there is no active Project, so it fires the paused variant
    // (`pollTargetChanged(nil, ...)`), a no-op state change. Receiving it before
    // yielding the selection keeps the merged-effect action order deterministic.
    await store.receive(\.gitHub.pollTargetChanged)

    // `worktreeID: nil` is the key: the all-nil selection leaves State at its
    // defaults, so the test stays exhaustive without any downstream diff chain.
    let selection = HierarchySelection(
      projectID: nil,
      worktreeID: nil
    )
    selectionContinuation.yield(selection)
    // `selection.empty == State.selection.default` so the assignment is a
    // no-op observable change; we omit the trailing closure to satisfy the
    // strict no-change check.
    await store.receive(\.selectionChanged)
    // `.selectionChanged` also forwards into `.branchSwitcher(.worktreeChanged)`.
    // All-nil ids leave State at its defaults (initial state matches the
    // mutation), so the assertion is a no-change receive.
    await store.receive(\.branchSwitcher.worktreeChanged)

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
      (.paneViewportChanged(pane, text: "screen"), .paneViewportChanged),
      (.paneIdle(pane, duration: 1), .paneIdle),
      (.paneExited(pane, code: 0, signal: nil), .paneExited),
      (.paneCrashed(pane, reason: "x"), .paneCrashed),
      (.paneClosedByTab(pane, cause: .other(reason: "x")), .paneClosedByTab),
      (.tabActivated(tab), .tabActivated),
      (.tabAutoClosed(tab, cause: .other(reason: "x")), .tabAutoClosed),
      (.worktreeActivated(worktree), .worktreeActivated),
      (.hierarchyMutated(.catalog), .hierarchyMutated),
      (
        .foregroundJobChanged(pane, ForegroundJob(processGroupID: 1, processes: [])),
        .foregroundJobChanged
      ),
    ]
    for (event, expected) in cases {
      #expect(RootFeature.LastEventMarker(event) == expected)
    }
  }

  // MARK: - status-bar toast routing

  /// The multi-line / over-80-char scrubber that the `.editor(.openFailed)`
  /// and `.gitHub(...Completed)` branches pipe through before constructing a
  /// warning toast. Kept as a pure function so the message-shape invariants
  /// are locked in without spinning up a `RootFeature` TestStore — a full
  /// multi-scope TestStore interacts badly with the StatusBarFeature suite's
  /// TestClock-driven sleeps when they share the host-app process, so we
  /// exercise the forwarding itself through the app-run smoke tests
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

  // MARK: - Tab-bar shortcut resolvers

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

  // MARK: - FU-T10 BranchSwitcher root-level routing

  @Test
  func worktreeHeadChangedForwardsToBranchSwitcherWhenIDMatches() async {
    // T10 wired `RootFeature.worktreeHeadChanged` to forward into
    // `branchSwitcher.headChangedForCurrentWorktree` ONLY when the changed
    // worktree matches the popover's currently-bound worktreeID. This test
    // pins the match arm of that filter.
    let projectID = ProjectID()
    let worktreeA = WorktreeID()
    let worktreeB = WorktreeID()
    let catalog = Self.gvFixtureCatalog(
      projectID: projectID,
      worktreeA: worktreeA, worktreeB: worktreeB
    )

    var initial = RootFeature.State()
    initial.branchSwitcher.worktreeID = worktreeA
    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      // The forward is the LAST step of the head-change effect; the live
      // diff monitor (testValue == liveValue) would spawn a real
      // `git diff` subprocess first and blow the receive window under
      // parallel suite load. A no-op fetch keeps the effect deterministic.
      $0[WorktreeLocalDiffMonitor.self] = WorktreeLocalDiffMonitor(fetch: { _ in nil })
    }
    store.exhaustivity = .off

    await store.send(.worktreeHeadChanged(worktreeA))
    await store.receive(\.branchSwitcher.headChangedForCurrentWorktree)
    await store.finish()
  }

  @Test
  func worktreeHeadChangedDoesNotForwardWhenIDDoesNotMatch() async {
    // Complement to the match-arm test: HEAD changes on a worktree that is
    // NOT the one the popover is currently bound to must not invalidate
    // the popover's caches.
    let projectID = ProjectID()
    let worktreeA = WorktreeID()
    let worktreeB = WorktreeID()
    let catalog = Self.gvFixtureCatalog(
      projectID: projectID,
      worktreeA: worktreeA, worktreeB: worktreeB
    )

    var initial = RootFeature.State()
    initial.branchSwitcher.worktreeID = worktreeA
    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      // Same no-op fetch as the match-arm test: keep the effect free of
      // real `git diff` subprocesses so finish() returns promptly.
      $0[WorktreeLocalDiffMonitor.self] = WorktreeLocalDiffMonitor(fetch: { _ in nil })
    }
    store.exhaustivity = .off

    // HEAD changes on the *other* worktree. With `exhaustivity = .off` the
    // absence of a forward is implicit; `store.finish()` makes it explicit
    // by asserting no leftover effects produced a `headChangedForCurrentWorktree`.
    await store.send(.worktreeHeadChanged(worktreeB))
    await store.finish()
  }

  // MARK: - Agents-panel row tap reveals the worktree

  @Test
  func agentStateRowTappedRevealsWorktreeInSidebar() async {
    // Tapping an Agents-panel row jumps to that pane's worktree; it must also
    // reveal the worktree in the sidebar — expand the parent project, show
    // the sidebar, and bump the reveal trigger — so a row scrolled off-screen
    // (or hidden under a collapsed project) scrolls into view.
    let pane = Pane(workingDirectory: "/repo")
    let tab = Tab(splitTree: SplitTree(leaf: pane.id), panes: [pane])
    let worktree = Worktree(name: "main", path: "/repo", tabs: [tab], selectedTabID: tab.id)
    var project = Project(name: "p", rootPath: "/repo", gitRoot: "/repo")
    project.worktrees = [worktree]
    var catalog = Catalog()
    catalog.projects = [project]
    let address = PaneAddress(
      projectID: project.id, worktreeID: worktree.id, tabID: tab.id, paneID: pane.id
    )
    let expandCalls = LockIsolated<[(ProjectID, Bool)]>([])
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.addressOf = { _ in address }
      $0.hierarchyClient.selectProject = { _ in }
      $0.hierarchyClient.selectWorktree = { _, _ in }
      $0.hierarchyClient.selectTab = { _, _, _ in }
      $0.hierarchyClient.focusPane = { _, _, _, _ in }
      $0.hierarchyClient.focusSurfaceView = { _ in }
      $0.hierarchyClient.setProjectExpanded = { pid, expanded in
        expandCalls.withValue { $0.append((pid, expanded)) }
      }
    }
    store.exhaustivity = .off

    let before = store.state.revealSelectionTrigger
    await store.send(.agentState(.rowTapped(pane.id)))
    await store.finish()

    #expect(store.state.revealSelectionTrigger != before)
    #expect(store.state.sidebarVisible)
    #expect(expandCalls.value.contains { $0.0 == project.id && $0.1 == true })
  }

  // MARK: - Post-completion switch gate (worktreeMaterialized)

  /// Recorder for the gate's selection and badge side-effects. Captures the
  /// project and worktree the reducer asks `HierarchyClient` to select, plus
  /// any `setWorktreeIsNew` calls, so each truth-table cell can assert
  /// "did / did not switch" and "did / did not mint the New marker".
  private struct SelectRecorder: Sendable {
    let project = LockIsolated<ProjectID?>(nil)
    let worktree = LockIsolated<WorktreeID?>(nil)
    /// (worktreeID, isNew) pairs recorded from `setWorktreeIsNew` calls.
    let isNewCalls = LockIsolated<[(WorktreeID, Bool)]>([])
    var didSelect: Bool { project.value != nil || worktree.value != nil }
  }

  /// Builds a gate TestStore with `selectProject`/`selectWorktree` and
  /// `setWorktreeIsNew` wired into `recorder`. `autoSwitch` sets the LIVE
  /// settings snapshot read at completion; `activePendingWorktreeID` seeds
  /// the state field (used by the loading-view resolver, independent of the
  /// switch gate). `selectionChanges` finishes immediately so the post-select
  /// stream does not feed back a `.selectionChanged` (the gate's switch
  /// decision is what these tests assert, not the downstream auto-seed).
  @MainActor
  private func makeGateStore(
    autoSwitch: Bool,
    activePendingWorktreeID: PendingWorktreeID?,
    recorder: SelectRecorder
  ) -> TestStore<RootFeature.State, RootFeature.Action> {
    var initial = RootFeature.State()
    initial.activePendingWorktreeID = activePendingWorktreeID
    let settings = Settings(worktree: WorktreeSettings(autoSwitchToNewWorktree: autoSwitch))
    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { Catalog() }
      $0[SettingsWriter.self].readSnapshotSync = { settings }
      $0.hierarchyClient.selectProject = { pid in
        recorder.project.withValue { $0 = pid }
      }
      $0.hierarchyClient.selectWorktree = { wt, _ in
        recorder.worktree.withValue { $0 = wt }
      }
      $0.hierarchyClient.setWorktreeIsNew = { wt, isNew in
        recorder.isNewCalls.withValue { $0.append((wt, isNew)) }
      }
    }
    store.exhaustivity = .off
    return store
  }

  @Test
  func gateOnWatchingSwitches() async {
    // VAL-SWITCH-001: auto-switch ON + still viewing this pending → switch.
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let pendingID = PendingWorktreeID()
    let rec = SelectRecorder()
    let store = makeGateStore(autoSwitch: true, activePendingWorktreeID: pendingID, recorder: rec)

    await store.send(
      .sidebar(
        .delegate(
          .worktreeMaterialized(
            worktreeID: worktreeID, projectID: projectID, pendingID: pendingID))))
    await store.finish()
    #expect(rec.project.value == projectID)
    #expect(rec.worktree.value == worktreeID)
  }

  @Test
  func gateOnAwaySwitches() async {
    // VAL-SWITCH-002: auto-switch ON + user navigated away (active id is a
    // different pending) → still switch, because the setting forces it.
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let pendingID = PendingWorktreeID()
    let rec = SelectRecorder()
    let store = makeGateStore(
      autoSwitch: true, activePendingWorktreeID: PendingWorktreeID(), recorder: rec)

    await store.send(
      .sidebar(
        .delegate(
          .worktreeMaterialized(
            worktreeID: worktreeID, projectID: projectID, pendingID: pendingID))))
    await store.finish()
    #expect(rec.project.value == projectID)
    #expect(rec.worktree.value == worktreeID)
  }

  @Test
  func gateOffAwayStays() async {
    // VAL-SWITCH-003: auto-switch OFF + away (active id is a *different*
    // pending) → do not switch. Selection is untouched, and the dangling
    // active id (a different pending) is left as-is.
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let pendingID = PendingWorktreeID()
    let otherPending = PendingWorktreeID()
    let rec = SelectRecorder()
    let store = makeGateStore(
      autoSwitch: false, activePendingWorktreeID: otherPending, recorder: rec)

    await store.send(
      .sidebar(
        .delegate(
          .worktreeMaterialized(
            worktreeID: worktreeID, projectID: projectID, pendingID: pendingID))))
    await store.finish()
    #expect(!rec.didSelect)
    #expect(store.state.activePendingWorktreeID == otherPending)
  }

  @Test
  func gateOffWatchingStays() async {
    // VAL-SWITCH-004: auto-switch OFF + still viewing this pending creation
    // → the NEW worktree never takes focus. With no pre-create selection
    // stashed (this harness seeds none) there is nothing to restore, so no
    // selection movement happens at all; the stashed-prior landing is
    // covered by `gateOffWatchingRestoresPriorSelection`.
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let pendingID = PendingWorktreeID()
    let rec = SelectRecorder()
    let store = makeGateStore(autoSwitch: false, activePendingWorktreeID: pendingID, recorder: rec)

    await store.send(
      .sidebar(
        .delegate(
          .worktreeMaterialized(
            worktreeID: worktreeID, projectID: projectID, pendingID: pendingID))))
    await store.finish()
    #expect(!rec.didSelect)
  }

  @Test
  func gateReadsLiveSettingAtCompletion() async {
    // VAL-SWITCH-006: a mid-flight toggle decides the outcome — the gate
    // reads the LIVE snapshot at completion, not a value captured at
    // kickoff. Here the snapshot reads OFF and the user is away, so the
    // late-flipped-OFF value makes the gate stay even though kickoff may
    // have happened while ON.
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let pendingID = PendingWorktreeID()
    let rec = SelectRecorder()
    let store = makeGateStore(
      autoSwitch: false, activePendingWorktreeID: PendingWorktreeID(), recorder: rec)

    await store.send(
      .sidebar(
        .delegate(
          .worktreeMaterialized(
            worktreeID: worktreeID, projectID: projectID, pendingID: pendingID))))
    await store.finish()
    #expect(!rec.didSelect)
  }

  @Test
  func gateCrossProjectSelectsNewProjectAndWorktree() async {
    // VAL-SWITCH-007: when the new worktree belongs to a different project
    // than the current selection, the gate selects BOTH the project and the
    // worktree so the user lands correctly cross-project.
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let pendingID = PendingWorktreeID()
    let rec = SelectRecorder()
    let store = makeGateStore(autoSwitch: true, activePendingWorktreeID: pendingID, recorder: rec)

    await store.send(
      .sidebar(
        .delegate(
          .worktreeMaterialized(
            worktreeID: worktreeID, projectID: projectID, pendingID: pendingID))))
    await store.finish()
    #expect(rec.project.value == projectID)
    #expect(rec.worktree.value == worktreeID)
  }

  // MARK: - badge-set-on-complete (M3): isNew marker

  @Test
  func gateOffMintsIsNewMarkerOnMaterializedWorktree() async {
    // badge-set-on-complete M3: auto-switch OFF → reducer calls
    // `setWorktreeIsNew(worktreeID, true)` on the just-materialized worktree.
    // The user stays put (unfocused new worktree) and a badge must land.
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let pendingID = PendingWorktreeID()
    let rec = SelectRecorder()
    let store = makeGateStore(autoSwitch: false, activePendingWorktreeID: pendingID, recorder: rec)

    await store.send(
      .sidebar(
        .delegate(
          .worktreeMaterialized(
            worktreeID: worktreeID, projectID: projectID, pendingID: pendingID))))
    await store.finish()

    // No selection was made.
    #expect(!rec.didSelect)
    // Exactly one isNew call, targeting the materialized worktree with true.
    #expect(rec.isNewCalls.value.count == 1)
    #expect(rec.isNewCalls.value.first?.0 == worktreeID)
    #expect(rec.isNewCalls.value.first?.1 == true)
  }

  @Test
  func gateOnDoesNotMintIsNewMarkerOnMaterializedWorktree() async {
    // badge-set-on-complete M3: auto-switch ON → reducer switches focus but
    // must NOT call `setWorktreeIsNew`. The focused worktree is already visible.
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let pendingID = PendingWorktreeID()
    let rec = SelectRecorder()
    let store = makeGateStore(autoSwitch: true, activePendingWorktreeID: pendingID, recorder: rec)

    await store.send(
      .sidebar(
        .delegate(
          .worktreeMaterialized(
            worktreeID: worktreeID, projectID: projectID, pendingID: pendingID))))
    await store.finish()

    // The switch happened.
    #expect(rec.project.value == projectID)
    #expect(rec.worktree.value == worktreeID)
    // No badge was minted.
    #expect(rec.isNewCalls.value.isEmpty)
  }

  // MARK: - Creation focus at kickoff (beginPendingWorktreeCreation)

  /// Recorder that keeps EVERY `selectWorktree` call (including nil
  /// deselects, which `SelectRecorder`'s single latest-value slot can't
  /// distinguish from "never called").
  private struct SelectCallRecorder: Sendable {
    let projects = LockIsolated<[ProjectID?]>([])
    let worktrees = LockIsolated<[WorktreeID?]>([])
    let isNewCalls = LockIsolated<[(WorktreeID, Bool)]>([])
  }

  /// Harness for the kickoff-focus tests: seeds a prior selection, wires
  /// the call recorder, stubs the child's creation stream to finish
  /// immediately (the row appends; no events arrive), and sets the LIVE
  /// auto-switch snapshot.
  @MainActor
  private func makeKickoffStore(
    autoSwitch: Bool,
    initial: RootFeature.State,
    recorder: SelectCallRecorder
  ) -> TestStore<RootFeature.State, RootFeature.Action> {
    let settings = Settings(worktree: WorktreeSettings(autoSwitchToNewWorktree: autoSwitch))
    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { Catalog() }
      $0[SettingsWriter.self].readSnapshotSync = { settings }
      $0.gitWorktreeClient.createWorktreeStream = { _ in
        AsyncThrowingStream { $0.finish() }
      }
      $0.hierarchyClient.selectProject = { pid in
        recorder.projects.withValue { $0.append(pid) }
      }
      $0.hierarchyClient.selectWorktree = { wt, _ in
        recorder.worktrees.withValue { $0.append(wt) }
      }
      $0.hierarchyClient.setWorktreeIsNew = { wt, isNew in
        recorder.isNewCalls.withValue { $0.append((wt, isNew)) }
      }
    }
    store.exhaustivity = .off
    return store
  }

  private static func makeRootPending(projectID: ProjectID) -> PendingWorktree {
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

  /// Clicking Create moves focus to the creation right away — the
  /// pre-create selection is stashed for the completion landing, the
  /// loading overlay arms, and the manager selection deselects the old
  /// row (project selected, worktree nil) so the sidebar highlight lands
  /// on the pending row's manual pill.
  @Test
  func beginPendingOnFocusesCreationAndStashesPrior() async {
    let projectID = ProjectID()
    let prior = HierarchySelection(projectID: projectID, worktreeID: WorktreeID())
    let pending = Self.makeRootPending(projectID: projectID)
    let rec = SelectCallRecorder()
    var initial = RootFeature.State()
    initial.selection = prior
    let store = makeKickoffStore(autoSwitch: true, initial: initial, recorder: rec)

    await store.send(.sidebar(.beginPendingWorktreeCreation(pending)))
    await store.finish()

    #expect(store.state.activePendingWorktreeID == pending.id)
    #expect(store.state.pendingPriorSelection == prior)
    #expect(rec.projects.value == [projectID])
    #expect(
      rec.worktrees.value == [nil], "old row must deselect so the pending pill reads as focus")
  }

  /// Creation focus at kickoff is UNCONDITIONAL — the auto-switch
  /// setting only decides where focus lands at COMPLETION. OFF must
  /// behave identically to ON at the click: overlay armed, prior
  /// stashed, old row deselected.
  @Test
  func beginPendingOffAlsoFocusesCreationAtKickoff() async {
    let projectID = ProjectID()
    let prior = HierarchySelection(projectID: projectID, worktreeID: WorktreeID())
    let pending = Self.makeRootPending(projectID: projectID)
    let rec = SelectCallRecorder()
    var initial = RootFeature.State()
    initial.selection = prior
    let store = makeKickoffStore(autoSwitch: false, initial: initial, recorder: rec)

    await store.send(.sidebar(.beginPendingWorktreeCreation(pending)))
    await store.finish()

    #expect(store.state.activePendingWorktreeID == pending.id)
    #expect(store.state.pendingPriorSelection == prior)
    #expect(rec.projects.value == [projectID])
    #expect(rec.worktrees.value == [nil])
  }

  /// Auto-switch OFF landing while still following the creation:
  /// completion mints the badge AND hands focus back to the stashed
  /// pre-create selection — OFF's contract is "when it's done, put me
  /// back where I was", never "leave me parked on a settled loading
  /// view with nothing selected".
  @Test
  func gateOffWatchingRestoresPriorSelection() async {
    let priorProject = ProjectID()
    let priorWorktree = WorktreeID()
    let prior = HierarchySelection(projectID: priorProject, worktreeID: priorWorktree)
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let pendingID = PendingWorktreeID()
    let rec = SelectCallRecorder()
    var initial = RootFeature.State()
    initial.activePendingWorktreeID = pendingID
    initial.pendingPriorSelection = prior
    let store = makeKickoffStore(autoSwitch: false, initial: initial, recorder: rec)

    await store.send(
      .sidebar(
        .delegate(
          .worktreeMaterialized(
            worktreeID: worktreeID, projectID: projectID, pendingID: pendingID))))
    await store.finish()

    #expect(rec.isNewCalls.value.count == 1)
    #expect(rec.isNewCalls.value.first?.1 == true)
    #expect(store.state.activePendingWorktreeID == nil)
    #expect(store.state.pendingPriorSelection == nil)
    #expect(rec.projects.value == [priorProject])
    #expect(rec.worktrees.value == [priorWorktree])
  }

  /// Clicking the pending row after navigating away re-arms the creation
  /// focus — the overlay, the pending pill, and the deselect all return,
  /// and the just-left selection becomes the new restore point. This is
  /// the "switch back" half of arbitrary switching during a creation.
  @Test
  func pendingRowTapRefocusesCreationAfterNavigatingAway() async {
    let projectID = ProjectID()
    let pending = Self.makeRootPending(projectID: projectID)
    let elsewhere = HierarchySelection(projectID: projectID, worktreeID: WorktreeID())
    let rec = SelectCallRecorder()
    var initial = RootFeature.State()
    // As after navigating away mid-creation: row still streaming, overlay
    // and stash both cleared by the real-worktree landing.
    initial.sidebar.pendingWorktrees.append(pending)
    initial.selection = elsewhere
    let store = makeKickoffStore(autoSwitch: true, initial: initial, recorder: rec)

    await store.send(.sidebar(.pendingWorktreeRowTapped(pending.id)))
    await store.finish()

    #expect(store.state.activePendingWorktreeID == pending.id)
    #expect(store.state.pendingPriorSelection == elsewhere)
    #expect(rec.projects.value == [projectID])
    #expect(rec.worktrees.value == [nil])
  }

  /// A tap racing the row's removal (completion / discard landed first)
  /// is dropped — no overlay pointing at a row that no longer exists.
  @Test
  func pendingRowTapOnRemovedRowIsNoOp() async {
    let pending = Self.makeRootPending(projectID: ProjectID())
    let rec = SelectCallRecorder()
    let store = makeKickoffStore(
      autoSwitch: true, initial: RootFeature.State(), recorder: rec)

    await store.send(.sidebar(.pendingWorktreeRowTapped(pending.id)))
    await store.finish()

    #expect(store.state.activePendingWorktreeID == nil)
    #expect(rec.projects.value.isEmpty)
  }

  /// Cancelling the FOLLOWED creation while still in the git-add leg
  /// (row discarded, nothing materializes) bounces focus back to the
  /// stashed pre-create selection.
  @Test
  func cancelOfFollowedCreationRestoresPrior() async {
    let priorProject = ProjectID()
    let priorWorktree = WorktreeID()
    let prior = HierarchySelection(projectID: priorProject, worktreeID: priorWorktree)
    let pending = Self.makeRootPending(projectID: ProjectID())
    let rec = SelectCallRecorder()
    var initial = RootFeature.State()
    initial.sidebar.pendingWorktrees.append(pending)
    initial.activePendingWorktreeID = pending.id
    initial.pendingPriorSelection = prior
    let store = makeKickoffStore(autoSwitch: true, initial: initial, recorder: rec)

    await store.send(.sidebar(.pendingWorktreeCancelTapped(pending.id)))
    await store.finish()

    #expect(store.state.sidebar.pendingWorktrees.isEmpty)
    #expect(store.state.activePendingWorktreeID == nil)
    #expect(store.state.pendingPriorSelection == nil)
    #expect(rec.projects.value == [priorProject])
    #expect(rec.worktrees.value == [priorWorktree])
  }

  // MARK: - Loading-view selection scoping (VAL-DETAIL-005 / VAL-DETAIL-006)

  /// VAL-DETAIL-005: selecting a REAL worktree mid-creation clears
  /// `activePendingWorktreeID`, so `ContentView.resolveActivePendingWorktree`
  /// returns nil and the detail pane renders THAT worktree's header — never
  /// the loading view hijacked onto an unrelated worktree. This is the
  /// regression that would make the whole app appear "stuck on Creating…",
  /// so it gets a dedicated reducer test over the clear logic the live
  /// resolver depends on.
  @Test
  func selectingRealWorktreeClearsActivePendingOverlay() async {
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

    var initial = RootFeature.State()
    initial.activePendingWorktreeID = PendingWorktreeID()

    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { catalog }
      $0.gitService = GitServiceClient.testValue
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.gitService.remoteInfo = { _ in RemoteInfo(host: "github.com", owner: "o", repo: "r") }
      $0[GitHubClient.self].batchPullRequests = { _, _, _, _ in [:] }
      $0.editorClient = EditorClient.testValue
      $0.hierarchyClient.openPane = { _, _, _, _, _ in PaneID() }
    }
    store.exhaustivity = .off

    await store.send(
      .selectionChanged(HierarchySelection(projectID: projectID, worktreeID: worktreeID))
    )
    #expect(
      store.state.activePendingWorktreeID == nil,
      "landing on a real worktree must retire the loading overlay"
    )
  }

  /// VAL-DETAIL-006: navigating to a NON-worktree selection (a project-only
  /// row, or empty selection) does NOT clear `activePendingWorktreeID`.
  /// Combined with the resolver reading the live `pendingWorktrees` row, this
  /// is what keeps the loading view up while the creation is focused (the
  /// focus move itself lands a nil-worktree selection) — only a REAL
  /// worktree landing retires the overlay.
  @Test
  func selectingNonWorktreeKeepsActivePendingOverlay() async {
    let projectID = ProjectID()
    let pendingID = PendingWorktreeID()

    var initial = RootFeature.State()
    initial.activePendingWorktreeID = pendingID

    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { Catalog() }
      $0.gitService = GitServiceClient.testValue
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.gitService.remoteInfo = { _ in RemoteInfo(host: "github.com", owner: "o", repo: "r") }
      $0[GitHubClient.self].batchPullRequests = { _, _, _, _ in [:] }
      $0.editorClient = EditorClient.testValue
    }
    store.exhaustivity = .off

    // Project-only selection (worktreeID == nil): the overlay must survive.
    await store.send(.selectionChanged(HierarchySelection(projectID: projectID, worktreeID: nil)))
    #expect(
      store.state.activePendingWorktreeID == pendingID,
      "a project-only selection must not retire the loading overlay"
    )

    // Empty selection (e.g. an aux window took focus): still survives.
    await store.send(.selectionChanged(HierarchySelection(projectID: nil, worktreeID: nil)))
    #expect(
      store.state.activePendingWorktreeID == pendingID,
      "an empty selection must not retire the loading overlay"
    )
  }

  @Test
  func gateSwitchSeedsFirstPaneViaLiveSelectionChain() async {
    // The other gate tests stub `selectionChanges` to finish immediately, so
    // they prove the SWITCH decision but never exercise the selection→seed
    // seam that actually lands a first pane. Here we let the post-switch
    // `.selectionChanged` actually run the live chain: gate switches →
    // `selectionChanged` is received → `autoSeedTabAndPaneIfNeeded` sees the
    // new worktree's EMPTY tabs → `createTab` then `openPane` fire. Covers the
    // switch→pane seam behind VAL-SWITCH-001..007.
    //
    // In the live app, the gate's `selectWorktree(...)` emits the
    // `.selectionChanged` through `hierarchyClient.selectionChanges`. We model
    // that emission by sending `.selectionChanged` directly after the gate —
    // the same technique `selectionChangedMirrorsActiveTabFromSnapshot` uses —
    // so the seed chain runs without `.onLaunch`'s unrelated effect fan-out.
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let pendingID = PendingWorktreeID()
    let newTabID = TabID()

    // Catalog whose new worktree has NO tabs — the precondition that makes
    // the seed chain reach `createTab` + `openPane`.
    let worktree = Worktree(
      id: worktreeID, name: "feat", path: "/repo/feat", branch: "feat",
      tabs: [], selectedTabID: nil
    )
    let project = Project(
      id: projectID, name: "p", rootPath: "/repo", gitRoot: "/repo",
      worktrees: [worktree], selectedWorktreeID: worktreeID
    )
    let catalog = Catalog(projects: [project])

    let settings = Settings(worktree: WorktreeSettings(autoSwitchToNewWorktree: true))

    let selectRecorder = SelectRecorder()
    let createTabCalls = LockIsolated<Int>(0)
    struct OpenPaneCall: Sendable, Equatable {
      let tabID: TabID
      let worktreeID: WorktreeID
      let projectID: ProjectID
      let cwd: String
    }
    let openPaneCalls = LockIsolated<[OpenPaneCall]>([])

    var initial = RootFeature.State()
    initial.activePendingWorktreeID = pendingID

    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { catalog }
      $0[SettingsWriter.self].readSnapshotSync = { settings }
      // Gate side-effects — record that the switch actually happened.
      $0.hierarchyClient.selectProject = { pid in
        selectRecorder.project.withValue { $0 = pid }
      }
      $0.hierarchyClient.selectWorktree = { wt, _ in
        selectRecorder.worktree.withValue { $0 = wt }
      }
      // The seed chain we are pinning.
      $0.hierarchyClient.createTab = { _, _, _ in
        createTabCalls.withValue { $0 += 1 }
        return newTabID
      }
      $0.hierarchyClient.openPane = { tab, wt, pr, cwd, _ in
        openPaneCalls.withValue {
          $0.append(OpenPaneCall(tabID: tab, worktreeID: wt, projectID: pr, cwd: cwd))
        }
        return PaneID()
      }
      // `.selectionChanged` with a real project transition fans into
      // `.gitHub(.projectActivated)`, which touches `.date` + remoteInfo +
      // batchPullRequests; stub each so the chain completes (mirrors
      // `selectionChangedMirrorsActiveTabFromSnapshot`).
      $0.gitService = GitServiceClient.testValue
      $0.gitService.remoteInfo = { _ in RemoteInfo(host: "github.com", owner: "o", repo: "r") }
      $0[GitHubClient.self].batchPullRequests = { _, _, _, _ in [:] }
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.editorClient = EditorClient.testValue
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    // Gate: autoSwitch ON → switch. Records the select; in the live app this
    // select is what emits the `.selectionChanged` below.
    await store.send(
      .sidebar(
        .delegate(
          .worktreeMaterialized(
            worktreeID: worktreeID, projectID: projectID, pendingID: pendingID))))
    #expect(selectRecorder.project.value == projectID, "gate must select the project")
    #expect(selectRecorder.worktree.value == worktreeID, "gate must select the worktree")

    // The post-switch selection lands and the seed chain runs. `.openPane` is
    // fired from a `Task { @MainActor }` inside the reducer, so let the store
    // settle before asserting the recorded calls.
    await store.send(
      .selectionChanged(HierarchySelection(projectID: projectID, worktreeID: worktreeID)))
    await store.finish()

    #expect(createTabCalls.value == 1, "the switch must seed a first tab")
    #expect(openPaneCalls.value.count == 1, "the switch must seed a first pane")
    let call = openPaneCalls.value.first
    #expect(call?.tabID == newTabID)
    #expect(call?.worktreeID == worktreeID)
    #expect(call?.projectID == projectID)
    #expect(call?.cwd == "/repo/feat")
  }

  @Test
  func focusHierarchyPathRevealsWorktreeInSidebar() async {
    // Notification deep-links — system notifications and the status-bar inbox
    // bell — funnel through `focusHierarchyPath`. Jumping to the pane must
    // also reveal its worktree in the sidebar so an off-screen / collapsed
    // target scrolls into view.
    let pane = Pane(workingDirectory: "/repo")
    let tab = Tab(splitTree: SplitTree(leaf: pane.id), panes: [pane])
    let worktree = Worktree(name: "main", path: "/repo", tabs: [tab], selectedTabID: tab.id)
    var project = Project(name: "p", rootPath: "/repo", gitRoot: "/repo")
    project.worktrees = [worktree]
    var catalog = Catalog()
    catalog.projects = [project]
    let source = InboxEntry.SourcePath(
      projectID: project.id, worktreeID: worktree.id, tabID: tab.id, paneID: pane.id
    )
    let expandCalls = LockIsolated<[(ProjectID, Bool)]>([])
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.selectProject = { _ in }
      $0.hierarchyClient.selectWorktree = { _, _ in }
      $0.hierarchyClient.selectTab = { _, _, _ in }
      $0.hierarchyClient.focusPane = { _, _, _, _ in }
      $0.hierarchyClient.focusSurfaceView = { _ in }
      $0.hierarchyClient.setProjectExpanded = { pid, expanded in
        expandCalls.withValue { $0.append((pid, expanded)) }
      }
    }
    store.exhaustivity = .off

    let before = store.state.revealSelectionTrigger
    await store.send(.focusHierarchyPath(source))
    await store.finish()

    #expect(store.state.revealSelectionTrigger != before)
    #expect(store.state.sidebarVisible)
    #expect(expandCalls.value.contains { $0.0 == project.id && $0.1 == true })
  }

  // MARK: - badge-clear-and-persist (M3): clear on first selection

  @Test
  func selectionChangedClearsIsNewOnBadgedWorktree() async {
    // badge-clear-and-persist M3: when selectionChanged lands on a worktree
    // with isNew == true, the reducer must call setWorktreeIsNew(worktreeID, false)
    // exactly once to retire the badge. All selection entry points (sidebar
    // click, keyboard nav, Back/Forward, deep-link) funnel here.
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let tabID = TabID()

    let tab = Tab(id: tabID, name: "t", splitTree: SplitTree(), panes: [])
    let worktree = Worktree(
      id: worktreeID, name: "w", path: "/w", branch: "main",
      tabs: [tab], selectedTabID: tabID, isNew: true
    )
    let project = Project(
      id: projectID, name: "p", rootPath: "/", gitRoot: "/",
      worktrees: [worktree], selectedWorktreeID: worktreeID
    )
    let catalog = Catalog(projects: [project])
    let isNewCalls = LockIsolated<[(WorktreeID, Bool)]>([])

    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.setWorktreeIsNew = { wt, isNew in
        isNewCalls.withValue { $0.append((wt, isNew)) }
      }
      $0.hierarchyClient.openPane = { _, _, _, _, _ in PaneID() }
      $0.gitService = GitServiceClient.testValue
      $0.gitService.remoteInfo = { _ in RemoteInfo(host: "github.com", owner: "o", repo: "r") }
      $0[GitHubClient.self].batchPullRequests = { _, _, _, _ in [:] }
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.editorClient = EditorClient.testValue
    }
    store.exhaustivity = .off

    await store.send(
      .selectionChanged(HierarchySelection(projectID: projectID, worktreeID: worktreeID)))
    await store.finish()

    #expect(isNewCalls.value.count == 1, "must clear the badge exactly once")
    #expect(isNewCalls.value.first?.0 == worktreeID, "must target the selected worktree")
    #expect(isNewCalls.value.first?.1 == false, "must clear to false")
  }

  @Test
  func selectionChangedDoesNotClearIsNewOnUnbadgedWorktree() async {
    // badge-clear-and-persist M3: when selectionChanged lands on a worktree
    // with isNew == false, the reducer must NOT call setWorktreeIsNew at all —
    // ordinary selections must never issue a redundant write.
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let tabID = TabID()

    let tab = Tab(id: tabID, name: "t", splitTree: SplitTree(), panes: [])
    let worktree = Worktree(
      id: worktreeID, name: "w", path: "/w", branch: "main",
      tabs: [tab], selectedTabID: tabID, isNew: false
    )
    let project = Project(
      id: projectID, name: "p", rootPath: "/", gitRoot: "/",
      worktrees: [worktree], selectedWorktreeID: worktreeID
    )
    let catalog = Catalog(projects: [project])
    let isNewCalls = LockIsolated<[(WorktreeID, Bool)]>([])

    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.setWorktreeIsNew = { wt, isNew in
        isNewCalls.withValue { $0.append((wt, isNew)) }
      }
      $0.hierarchyClient.openPane = { _, _, _, _, _ in PaneID() }
      $0.gitService = GitServiceClient.testValue
      $0.gitService.remoteInfo = { _ in RemoteInfo(host: "github.com", owner: "o", repo: "r") }
      $0[GitHubClient.self].batchPullRequests = { _, _, _, _ in [:] }
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.editorClient = EditorClient.testValue
    }
    store.exhaustivity = .off

    await store.send(
      .selectionChanged(HierarchySelection(projectID: projectID, worktreeID: worktreeID)))
    await store.finish()

    #expect(isNewCalls.value.isEmpty, "must not call setWorktreeIsNew for an unbadged worktree")
  }
}
