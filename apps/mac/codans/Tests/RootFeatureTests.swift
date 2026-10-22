import CodansCore
import CodansIPC
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

@MainActor
struct RootFeatureTests {
  @Test
  func openingDiffWithoutSelectionDoesNotChangeMainWindow() async {
    let store = TestStore(initialState: RootFeature.State()) { RootFeature() }
    await store.send(.openDiffRequested)
  }

  @Test
  func paneCrashedClearsRunningFlag() async {
    // Crashed panes stay in the catalog for the user to retry. The OSC 9;4
    // running flag must be force-cleared here because a crashing program
    // rarely emits the REMOVE state itself, which would otherwise leave
    // the tab-chip / sidebar spinners pinned on a dead pane forever.
    let (eventStream, eventContinuation) = AsyncStream<TerminalEvent>.makeStream()
    let (selectionStream, selectionContinuation) = AsyncStream<HierarchySelection>.makeStream()
    let contentID = ContentID()
    let markedIdle = LockIsolated<ContentID?>(nil)

    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { eventStream }
      $0.hierarchyClient.selectionChanges = { selectionStream }
      $0.hierarchyClient.snapshot = { Catalog() }
      $0.hierarchyClient.setProgressBusy = { id, busy in
        if !busy { markedIdle.withValue { $0 = id } }
      }
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.onLaunch)
    eventContinuation.yield(.paneCrashed(contentID, reason: "test"))
    await store.receive(\.paneProgressBusyChanged)

    eventContinuation.finish()
    selectionContinuation.finish()
    await store.send(.onQuit)

    #expect(markedIdle.value == contentID)
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
    let contentID = ContentID()
    eventContinuation.yield(.paneReady(contentID))
    await store.receive(\.engineEventReceived) { state in
      state.lastEvent = .paneReady
    }

    // Cancellation: onQuit closes the in-flight effects.
    eventContinuation.finish()
    selectionContinuation.finish()
    await store.send(.onQuit)
  }

  @Test
  func selectionChangedMirrorsWorktreeAndSeedsPaneHosts() async {
    // The reducer reads the selected Worktree through the snapshot, mirrors
    // its id into the split viewport and seeds one host per Pane (its
    // selected Tab's Content).
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let tab = Tab(name: "t", content: .terminal(workingDirectory: "/w"))
    let worktree = Self.worktree(id: worktreeID, name: "w", path: "/w", branch: "main", tabs: [tab])
    let project = Project(
      id: projectID, name: "p", rootPath: "/", gitRoot: "/",

      worktrees: [worktree], selectedWorktreeID: worktreeID
    )
    let catalog = Catalog(projects: [project])

    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.continuousClock = ImmediateClock()
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
    }
    // Non-exhaustive: this test is about the splitViewport mirror only.
    store.exhaustivity = .off

    let selection = HierarchySelection(projectID: projectID, worktreeID: worktreeID)
    await store.send(.selectionChanged(selection)) { state in
      state.selection = selection
      state.detail.splitViewport.worktreeID = worktreeID
      state.detail.splitViewport.paneHosts = [
        PaneHostFeature.State(
          contentID: tab.contentID, paneID: worktree.panes[0].id, tabID: tab.id,
          worktreeID: worktreeID, projectID: projectID)
      ]
    }
  }

  // MARK: - Layout fixtures

  /// A Worktree with one Pane holding `tabs`, the first one selected and
  /// the Pane focused.
  private static func worktree(
    id: WorktreeID = WorktreeID(), name: String, path: String, branch: String? = nil,
    tabs: [Tab], isNew: Bool = false
  ) -> Worktree {
    let pane = Pane(tabs: tabs)
    return Worktree(
      id: id, name: name, path: path, branch: branch,
      splitTree: SplitTree(leaf: pane.id), panes: [pane], focusedPaneID: pane.id, isNew: isNew)
  }

  /// The focused Pane's selected Tab of the selected Worktree, the way the
  /// live client answers `focusedContent`.
  private static func focusedContent(in catalog: Catalog, worktreeID: WorktreeID) -> TabAddress? {
    guard case let (project, worktree)? = catalog.worktree(worktreeID),
      let pane = worktree.focusedPane, let tab = pane.selectedTab
    else { return nil }
    return TabAddress(
      projectID: project.id, worktreeID: worktree.id, paneID: pane.id, tabID: tab.id, contentID: tab.contentID)
  }

  private static func address(_ catalog: Catalog, worktreeID: WorktreeID) -> TabAddress {
    focusedContent(in: catalog, worktreeID: worktreeID)!
  }

  // MARK: - Git Viewer routing

  /// Shared catalog fixture for Git Viewer tests. Two Worktrees under one
  /// Project so the selection delta is just the worktree leg.
  private static func gvFixtureCatalog(
    projectID: ProjectID,
    worktreeA: WorktreeID, worktreeB: WorktreeID
  ) -> Catalog {
    let wtA = Worktree(id: worktreeA, name: "A", path: "/a", branch: "a")
    let wtB = Worktree(id: worktreeB, name: "B", path: "/b", branch: "b")
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

  @Test(arguments: [false, true])
  func gitViewerChordRoutesBuiltInAndLegacyNilToDiffWindow(legacyNil: Bool) async {
    var initial = RootFeature.State()
    initial.selection = HierarchySelection(projectID: ProjectID(), worktreeID: WorktreeID())
    var settings = Settings()
    if legacyNil { settings.general.defaultGitViewerID = nil }
    let snapshot = settings
    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      // Isolate routing from live AppKit window creation: this worktree is no longer in the catalog.
      $0.hierarchyClient.snapshot = { Catalog() }
      $0[SettingsWriter.self].readSnapshotSync = { snapshot }
    }
    await store.send(.diffInspectorToggledForCurrentWorktree)
    await store.receive(.openDiffRequested)
    await store.finish()
  }

  @Test(arguments: [GitComparisonScope.all, .outgoing])
  func sidebarShowChangesOpensConfiguredExternalClientForTheRow(scope: GitComparisonScope) async {
    // The sidebar row's "Show Uncommitted" / "Show Outgoing" honor the Git
    // Viewer setting like the chord does, and act on the clicked row (B),
    // not the selection (A).
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
    initial.selection = HierarchySelection(projectID: projectID, worktreeID: worktreeA)
    initial.editor.descriptors = [descriptor]
    let settings = Settings(general: GeneralSettings(defaultGitViewerID: "fork"))

    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0[SettingsWriter.self].readSnapshotSync = { settings }
      $0.editorClient = EditorClient.testValue
      $0.editorClient.open = { _, id in
        EditorChoice(id: id ?? "finder", displayName: "x", binaryPath: nil)
      }
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(
      .sidebar(.delegate(.showChanges(projectID: projectID, worktreeID: worktreeB, scope: scope))))
    await store.receive(
      .editor(.openRequested(editorID: "fork", worktreePath: "/b", projectID: projectID)))
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
    let pane = ContentID()
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
      let tab = Tab(name: "t\(i)", content: .terminal(workingDirectory: "/tmp"))
      tabs.append(tab)
      ids.append(tab.id)
    }
    let pane = Pane(tabs: tabs, selectedTabID: ids[selectedIndex])
    let worktree = Worktree(
      id: worktreeID, name: "main", path: "/tmp", branch: "main",
      splitTree: SplitTree(leaf: pane.id), panes: [pane], focusedPaneID: pane.id
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
      // Opening a pane in a new tab waits out `TabBarMetrics.firstPaneDelay`.
      $0.continuousClock = ImmediateClock()
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.newTab = { _, _, _, _, _, _, _ in Self.address(catalog, worktreeID: wt) }
      // The new-tab reducer brings the session up; stub the call so the
      // unimplemented closure does not record.
      $0.hierarchyClient.ensureSurface = { _ in }
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
    // ⌘W closes the selected Tab of the focused Pane.
    let (pr, wt, ids, catalog) = Self.tabBarFixture(tabCount: 3, selectedIndex: 1)
    var initial = RootFeature.State()
    initial.selection = HierarchySelection(projectID: pr, worktreeID: wt)

    let captured = LockIsolated<TabID?>(nil)
    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.focusedContent = { id in Self.focusedContent(in: catalog, worktreeID: id) }
      $0.hierarchyClient.closeTab = { id in
        captured.withValue { $0 = id }
      }
    }
    store.exhaustivity = .off

    await store.send(.closeActiveTabForCurrentWorktree)
    await store.receive(\.detail.tabBar)
    #expect(captured.value == ids[1])
  }

  @Test
  func closeActiveTabForCurrentWorktreeClosesTheFocusedPanesTabWhenSplit() async throws {
    // Two Panes side by side, the right one focused: ⌘W closes the right
    // Pane's selected Tab and never a whole Pane directly.
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let leftTab = Tab(name: "l", content: .terminal(workingDirectory: "/tmp"))
    let rightTab = Tab(name: "r", content: .terminal(workingDirectory: "/tmp"))
    let leftPane = Pane(tabs: [leftTab])
    let rightPane = Pane(tabs: [rightTab])
    let worktree = Worktree(
      id: worktreeID, name: "main", path: "/tmp", branch: "main",
      splitTree: try SplitTree(leaf: leftPane.id).inserting(rightPane.id, at: leftPane.id, direction: .right),
      panes: [leftPane, rightPane], focusedPaneID: rightPane.id
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
      $0.hierarchyClient.focusedContent = { id in Self.focusedContent(in: catalog, worktreeID: id) }
      $0.hierarchyClient.closePane = { id in
        closedPane.withValue { $0 = id }
      }
      $0.hierarchyClient.closeTab = { id in
        closedTab.withValue { $0 = id }
      }
    }
    store.exhaustivity = .off

    await store.send(.closeActiveTabForCurrentWorktree)
    await store.finish()
    #expect(closedTab.value == rightTab.id)
    #expect(closedPane.value == nil)
  }

  @Test
  func paneLifecycleExitedClosesTheContentsTab() async {
    // ghostty's `close_surface` and a child exit both land here: the
    // session's Tab leaves the catalog; the manager retires the Pane when
    // that was its last Tab.
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let tab = Tab(name: "t", content: .terminal(workingDirectory: "/tmp"))
    let worktree = Self.worktree(id: worktreeID, name: "main", path: "/tmp", branch: "main", tabs: [tab])
    let project = Project(
      id: projectID, name: "p", rootPath: "/tmp",
      worktrees: [worktree], selectedWorktreeID: worktreeID
    )
    let catalog = Catalog(projects: [project])
    let address = Self.address(catalog, worktreeID: worktreeID)

    let closedTab = LockIsolated<TabID?>(nil)
    let closedPane = LockIsolated<PaneID?>(nil)
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.addressOf = { _ in address }
      $0.hierarchyClient.closeTab = { id in
        closedTab.withValue { $0 = id }
      }
      $0.hierarchyClient.closePane = { id in
        closedPane.withValue { $0 = id }
      }
    }
    store.exhaustivity = .off

    await store.send(.paneLifecycleExited(tab.contentID))
    await store.finish()
    #expect(closedTab.value == tab.id)
    #expect(closedPane.value == nil)
  }

  @Test
  func paneLifecycleExitedDropsTheGitCommandMarker() async {
    // A session that exits mid-command never emits its trailing git edge;
    // the tracked set must not keep it.
    let contentID = ContentID()
    var initial = RootFeature.State()
    initial.contentsRunningGitCommand = [contentID]
    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.addressOf = { _ in nil }
    }
    await store.send(.paneLifecycleExited(contentID)) { state in
      state.contentsRunningGitCommand = []
    }
  }

  @Test
  func selectTabAtIndexPicksNthTab() async {
    let (pr, wt, ids, catalog) = Self.tabBarFixture(tabCount: 3, selectedIndex: 0)
    var initial = RootFeature.State()
    initial.selection = HierarchySelection(projectID: pr, worktreeID: wt)

    let captured = LockIsolated<(Int, PaneID)?>(nil)
    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.focusedContent = { id in Self.focusedContent(in: catalog, worktreeID: id) }
      $0.hierarchyClient.selectTabAtIndex = { index, paneID in
        captured.withValue { $0 = (index, paneID) }
        return ids[index]
      }
    }
    store.exhaustivity = .off

    // ⌘3 is the third chip: a zero-based position in the focused Pane.
    await store.send(.selectTabAtIndexForCurrentWorktree(3))
    await store.finish()
    #expect(captured.value?.0 == 2)
    #expect(captured.value?.1 == catalog.projects[0].worktrees[0].panes[0].id)
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
      $0.hierarchyClient.focusedContent = { id in Self.focusedContent(in: catalog, worktreeID: id) }
      // The manager answers nil for a position past the strip.
      $0.hierarchyClient.selectTabAtIndex = { _, _ in nil }
    }

    // Tab count is 2; asking for the 5th is out of range.
    await store.send(.selectTabAtIndexForCurrentWorktree(5))
    await store.finish()
  }

  @Test
  func selectAdjacentTabCallsClient() async {
    let (pr, wt, _, catalog) = Self.tabBarFixture(tabCount: 2, selectedIndex: 0)
    var initial = RootFeature.State()
    initial.selection = HierarchySelection(projectID: pr, worktreeID: wt)

    let captured = LockIsolated<TabAdjacency?>(nil)
    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.focusedContent = { id in Self.focusedContent(in: catalog, worktreeID: id) }
      $0.hierarchyClient.selectAdjacentTab = { dir, _ in
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

    struct NewTabCall: Sendable, Equatable {
      let worktreeID: WorktreeID
      let projectID: ProjectID
      let cwd: String?
      let initialCommand: String?
    }
    let newTabCalls = LockIsolated<[NewTabCall]>([])
    let broughtUp = LockIsolated<[ContentID]>([])
    let contentID = ContentID()
    let created = TabAddress(
      projectID: projectID, worktreeID: worktreeID, paneID: PaneID(), tabID: tabID, contentID: contentID)

    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.newTab = { _, wt, pr, content, _, _, _ in
        newTabCalls.withValue {
          $0.append(
            NewTabCall(
              worktreeID: wt, projectID: pr, cwd: content.terminal?.workingDirectory,
              initialCommand: content.terminal?.initialCommand))
        }
        return created
      }
      $0.hierarchyClient.ensureSurface = { id in broughtUp.withValue { $0.append(id) } }
      $0.hierarchyClient.selectProject = { _ in }
      $0.hierarchyClient.selectWorktree = { _, _ in }
      $0.hierarchyClient.selectTab = { _ in }
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(
      .openShellEditorInWorktree(worktreePath: worktreePath, projectID: projectID))
    await store.finish()

    #expect(newTabCalls.value.count == 1)
    #expect(broughtUp.value == [contentID])
    let call = newTabCalls.value.first
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
    let tab = Tab(content: .terminal(workingDirectory: "/repo"))
    let worktree = Self.worktree(name: "main", path: "/repo", tabs: [tab])
    var project = Project(name: "p", rootPath: "/repo", gitRoot: "/repo")
    project.worktrees = [worktree]
    var catalog = Catalog()
    catalog.projects = [project]
    let address = Self.address(catalog, worktreeID: worktree.id)
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
      $0.hierarchyClient.selectTab = { _ in }
      $0.hierarchyClient.focusPane = { _ in }
      $0.hierarchyClient.focusSurfaceView = { _ in }
      $0.hierarchyClient.setProjectExpanded = { pid, expanded in
        expandCalls.withValue { $0.append((pid, expanded)) }
      }
    }
    store.exhaustivity = .off

    let before = store.state.revealSelectionTrigger
    await store.send(.agentState(.rowTapped(tab.contentID)))
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

  /// The Create sheet's agent launches once the worktree materializes (the
  /// setup script already ran in-stream); selection auto-seed is held off
  /// until the launch settles so the agent owns the first tab.
  @Test
  func materializedWithAgentLaunchesProfile() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let pendingID = PendingWorktreeID()
    let profileID = UUID()
    let launched = LockIsolated<[(UUID, ProjectID, WorktreeID)]>([])
    let store = makeGateStore(
      autoSwitch: true, activePendingWorktreeID: pendingID, recorder: SelectRecorder())
    store.dependencies.hierarchyClient.launchAgentProfile = { pid, proj, wt, _ in
      launched.withValue { $0.append((pid, proj, wt)) }
    }

    await store.send(
      .sidebar(
        .delegate(
          .worktreeMaterialized(
            worktreeID: worktreeID, projectID: projectID, pendingID: pendingID,
            agentProfileID: profileID)))
    ) {
      $0.agentLaunchWorktreeIDs = [worktreeID]
    }
    await store.receive(\.worktreeAgentLaunchFinished) {
      $0.agentLaunchWorktreeIDs = []
    }
    #expect(launched.value.count == 1)
    #expect(launched.value.first?.0 == profileID)
    #expect(launched.value.first?.1 == projectID)
    #expect(launched.value.first?.2 == worktreeID)
  }

  /// The New Agent dialog's prompt rides the pending creation and reaches
  /// the agent launch once the worktree materializes.
  @Test
  func materializedPassesTheAgentPrompt() async {
    let worktreeID = WorktreeID()
    let prompts = LockIsolated<[String?]>([])
    let store = makeGateStore(
      autoSwitch: true, activePendingWorktreeID: nil, recorder: SelectRecorder())
    store.dependencies.hierarchyClient.launchAgentProfile = { _, _, _, prompt in
      prompts.withValue { $0.append(prompt) }
    }

    await store.send(
      .sidebar(
        .delegate(
          .worktreeMaterialized(
            worktreeID: worktreeID, projectID: ProjectID(), pendingID: PendingWorktreeID(),
            agentProfileID: UUID(), agentPrompt: "Fix the login bug"))))
    await store.receive(\.worktreeAgentLaunchFinished)
    #expect(prompts.value == ["Fix the login bug"])
  }

  @Test
  func newAgentRequestedTogglesTheDialogOnTheSelectedProject() async {
    let projectID = ProjectID()
    var initial = RootFeature.State()
    initial.selection = HierarchySelection(projectID: projectID, worktreeID: nil)
    let store = TestStore(initialState: initial) { RootFeature() }
    store.exhaustivity = .off
    await store.send(.newAgentRequested) {
      $0.newAgent = NewAgentFeature.State(preferredProjectID: projectID)
    }
    await store.send(.newAgentRequested) {
      $0.newAgent = nil
    }
  }

  /// Sending to an existing worktree closes the dialog, takes the user
  /// there, and launches the agent with the prompt — parked so the
  /// selection's auto-seed leaves the first tab to the agent.
  @Test
  func newAgentLaunchInExistingWorktreeSelectsAndLaunches() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let profileID = UUID()
    let rec = SelectRecorder()
    let launched = LockIsolated<[(UUID, WorktreeID, String?)]>([])
    var initial = RootFeature.State()
    initial.newAgent = NewAgentFeature.State(preferredProjectID: projectID)
    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { Catalog() }
      $0.hierarchyClient.selectProject = { pid in rec.project.withValue { $0 = pid } }
      $0.hierarchyClient.selectWorktree = { wt, _ in rec.worktree.withValue { $0 = wt } }
      $0.hierarchyClient.setProjectExpanded = { _, _ in }
      $0.continuousClock = ImmediateClock()
      $0.hierarchyClient.launchAgentProfile = { id, _, wt, prompt in
        launched.withValue { $0.append((id, wt, prompt)) }
      }
    }
    store.exhaustivity = .off

    await store.send(
      .newAgent(
        .presented(
          .delegate(
            .launchAgent(
              profileID: profileID, prompt: "Review the diff", projectID: projectID,
              worktreeID: worktreeID))))
    ) {
      $0.newAgent = nil
      $0.agentLaunchWorktreeIDs = [worktreeID]
    }
    await store.receive(\.worktreeAgentLaunchFinished) {
      $0.agentLaunchWorktreeIDs = []
    }
    #expect(rec.project.value == projectID)
    #expect(rec.worktree.value == worktreeID)
    #expect(launched.value.count == 1)
    #expect(launched.value.first?.0 == profileID)
    #expect(launched.value.first?.1 == worktreeID)
    #expect(launched.value.first?.2 == "Review the diff")
  }

  /// Closing the dialog without sending keeps its choices for the next
  /// open; sending drops them.
  @Test
  func newAgentDraftSurvivesCloseAndClearsOnSend() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    var dialog = NewAgentFeature.State(preferredProjectID: projectID)
    dialog.projectID = projectID
    var initial = RootFeature.State()
    initial.newAgent = dialog
    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { Catalog() }
      $0.hierarchyClient.selectProject = { _ in }
      $0.hierarchyClient.selectWorktree = { _, _ in }
      $0.hierarchyClient.setProjectExpanded = { _, _ in }
      $0.hierarchyClient.launchAgentProfile = { _, _, _, _ in }
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.newAgent(.presented(.promptChanged("Half a thought"))))
    #expect(store.state.newAgentDraft?.prompt == "Half a thought")
    await store.send(.newAgentRequested) { $0.newAgent = nil }
    await store.send(.newAgentRequested)
    #expect(store.state.newAgent?.restoring?.prompt == "Half a thought")

    await store.send(
      .newAgent(
        .presented(
          .delegate(
            .launchAgent(
              profileID: UUID(), prompt: "Half a thought", projectID: projectID,
              worktreeID: worktreeID))))
    )
    #expect(store.state.newAgentDraft == nil)
  }

  @Test
  func materializedAgentLaunchFailureWarns() async {
    let worktreeID = WorktreeID()
    let profileID = UUID()
    let store = makeGateStore(
      autoSwitch: false, activePendingWorktreeID: nil, recorder: SelectRecorder())
    store.dependencies.hierarchyClient.launchAgentProfile = { id, _, _, _ in
      throw RunScriptError.unknownScript(id)
    }
    store.dependencies.continuousClock = ImmediateClock()

    await store.send(
      .sidebar(
        .delegate(
          .worktreeMaterialized(
            worktreeID: worktreeID, projectID: ProjectID(), pendingID: PendingWorktreeID(),
            agentProfileID: profileID))))
    await store.receive(
      .worktreeAgentLaunchFinished(
        worktreeID, failure: "Launch agent failed: profile no longer exists"))
    await store.receive(
      .statusBar(.push(.warning("Launch agent failed: profile no longer exists"))))
    #expect(store.state.agentLaunchWorktreeIDs.isEmpty)
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
    let tab = Tab(id: tabID, name: "t", content: .terminal(workingDirectory: "/w"))
    let worktree = Self.worktree(id: worktreeID, name: "w", path: "/w", branch: "main", tabs: [tab])
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
      // Opening a pane in a new tab waits out `TabBarMetrics.firstPaneDelay`.
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { catalog }
      $0.gitService = GitServiceClient.testValue
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.gitService.remoteInfo = { _ in RemoteInfo(host: "github.com", owner: "o", repo: "r") }
      $0[GitHubClient.self].batchPullRequests = { _, _, _, _ in [:] }
      $0.editorClient = EditorClient.testValue
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
    // new worktree has NO Pane → `newTab` then `ensureSurface` fire. Covers the
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

    // Catalog whose new worktree has NO Pane — the precondition that makes
    // the seed chain reach `newTab` + `ensureSurface`.
    let worktree = Worktree(id: worktreeID, name: "feat", path: "/repo/feat", branch: "feat")
    let project = Project(
      id: projectID, name: "p", rootPath: "/repo", gitRoot: "/repo",
      worktrees: [worktree], selectedWorktreeID: worktreeID
    )
    let catalog = Catalog(projects: [project])

    let settings = Settings(worktree: WorktreeSettings(autoSwitchToNewWorktree: true))

    let selectRecorder = SelectRecorder()
    struct NewTabCall: Sendable, Equatable {
      let worktreeID: WorktreeID
      let projectID: ProjectID
      let cwd: String?
    }
    let newTabCalls = LockIsolated<[NewTabCall]>([])
    let broughtUp = LockIsolated<[ContentID]>([])
    let created = TabAddress(
      projectID: projectID, worktreeID: worktreeID, paneID: PaneID(), tabID: newTabID, contentID: ContentID())

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
      $0.hierarchyClient.newTab = { _, wt, pr, content, _, _, _ in
        newTabCalls.withValue {
          $0.append(NewTabCall(worktreeID: wt, projectID: pr, cwd: content.terminal?.workingDirectory))
        }
        return created
      }
      $0.hierarchyClient.ensureSurface = { id in broughtUp.withValue { $0.append(id) } }
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

    // The post-switch selection lands and the seed chain runs. `ensureSurface`
    // is fired from a `Task { @MainActor }` inside the reducer, so let the
    // store settle before asserting the recorded calls.
    await store.send(
      .selectionChanged(HierarchySelection(projectID: projectID, worktreeID: worktreeID)))
    await store.finish()

    #expect(newTabCalls.value.count == 1, "the switch must seed a first tab")
    #expect(broughtUp.value == [created.contentID], "the switch must bring the first session up")
    let call = newTabCalls.value.first
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
    let tab = Tab(content: .terminal(workingDirectory: "/repo"))
    let worktree = Self.worktree(name: "main", path: "/repo", tabs: [tab])
    var project = Project(name: "p", rootPath: "/repo", gitRoot: "/repo")
    project.worktrees = [worktree]
    var catalog = Catalog()
    catalog.projects = [project]
    let source = InboxEntry.SourcePath(
      projectID: project.id, worktreeID: worktree.id, contentID: tab.contentID
    )
    let address = Self.address(catalog, worktreeID: worktree.id)
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
      $0.hierarchyClient.selectTab = { _ in }
      $0.hierarchyClient.focusPane = { _ in }
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

    let tab = Tab(id: tabID, name: "t", content: .terminal(workingDirectory: "/w"))
    let worktree = Self.worktree(id: worktreeID, name: "w", path: "/w", branch: "main", tabs: [tab], isNew: true)
    let project = Project(
      id: projectID, name: "p", rootPath: "/", gitRoot: "/",
      worktrees: [worktree], selectedWorktreeID: worktreeID
    )
    let catalog = Catalog(projects: [project])
    let isNewCalls = LockIsolated<[(WorktreeID, Bool)]>([])

    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      // Opening a pane in a new tab waits out `TabBarMetrics.firstPaneDelay`.
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.setWorktreeIsNew = { wt, isNew in
        isNewCalls.withValue { $0.append((wt, isNew)) }
      }
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

    let tab = Tab(id: tabID, name: "t", content: .terminal(workingDirectory: "/w"))
    let worktree = Self.worktree(id: worktreeID, name: "w", path: "/w", branch: "main", tabs: [tab], isNew: false)
    let project = Project(
      id: projectID, name: "p", rootPath: "/", gitRoot: "/",
      worktrees: [worktree], selectedWorktreeID: worktreeID
    )
    let catalog = Catalog(projects: [project])
    let isNewCalls = LockIsolated<[(WorktreeID, Bool)]>([])

    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      // Opening a pane in a new tab waits out `TabBarMetrics.firstPaneDelay`.
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.setWorktreeIsNew = { wt, isNew in
        isNewCalls.withValue { $0.append((wt, isNew)) }
      }
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

  // MARK: - Hand-off orders

  private static func handoffSource(contentID: ContentID) -> HandoffFeature.Source {
    HandoffFeature.Source(
      contentID: contentID, projectID: ProjectID(raw: UUID()), worktreeID: WorktreeID(raw: UUID()),
      agent: .claudeCode)
  }

  /// A brief order closes the panel at once, registers a one-shot request,
  /// types the instruction into the source pane, and reports the matching
  /// CLI completion as a toast. Nothing waits on screen.
  @Test
  func briefHandOffClosesThePanelAndFinishesOnTheMatchingCompletion() async {
    let contentID = ContentID()
    let requestID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    let (completions, continuation) = AsyncStream<HandoffCompletion>.makeStream()
    let registered = LockIsolated<[(UUID, ContentID)]>([])
    let typed = LockIsolated<[(ContentID, String)]>([])
    var initial = RootFeature.State()
    let source = Self.handoffSource(contentID: contentID)
    initial.handoff = HandoffFeature.State.make(source: source, profiles: [AgentProfile(kind: .codex)])

    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.uuid = .constant(requestID)
      $0.handoffClient.cli = "codans"
      $0.handoffClient.register = { id, pane in registered.withValue { $0.append((id, pane)) } }
      $0.handoffClient.completions = { completions }
      $0.handoffClient.sendInstruction = { pane, text in
        typed.withValue { $0.append((pane, text)) }
        return true
      }
      // The toast the outcome pushes arms its own dismiss timer.
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.handoff(.presented(.confirmSelection)))
    await store.receive(\.handoff.presented.delegate.handOff) { state in
      state.handoff = nil
    }
    #expect(registered.value.count == 1)
    #expect(registered.value.first?.0 == requestID)
    #expect(registered.value.first?.1 == contentID)
    #expect(typed.value.first?.0 == contentID)
    #expect(
      typed.value.first?.1
        == HandoffKickoff.sourceInstruction(for: .checkpoint, requestID: requestID, sourceContentID: contentID, cli: "codans")
        || typed.value.first?.1
          == HandoffKickoff.sourceInstruction(
            for: .handOff(to: .codex), requestID: requestID, sourceContentID: contentID, cli: "codans")
    )

    // A completion for another request is not ours.
    continuation.yield(
      HandoffCompletion(
        action: .to, sourceContentID: contentID, receiver: .codex, briefing: .inline, launched: nil,
        requestID: UUID()))
    // Ours, without a launched pane so no focus walk is needed here.
    let mine = HandoffCompletion(
      action: .to, sourceContentID: contentID, receiver: .codex, briefing: .inline, launched: nil,
      requestID: requestID)
    continuation.yield(mine)
    await store.receive(.handoffFinished(mine, targetTitle: "Codex"))
    await store.receive(.statusBar(.push(.success("Handed off to Codex"))))
    continuation.finish()
  }

  /// An undeliverable instruction retires the request and surfaces a warning
  /// instead of quietly downgrading to a context-only hand-off.
  @Test
  func undeliverableBriefRequestWarnsAndSupersedes() async {
    let contentID = ContentID()
    let requestID = UUID()
    let superseded = LockIsolated<[UUID]>([])
    var initial = RootFeature.State()
    initial.handoff = HandoffFeature.State.make(
      source: Self.handoffSource(contentID: contentID), profiles: [AgentProfile(kind: .codex)])

    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.uuid = .constant(requestID)
      $0.handoffClient.register = { _, _ in }
      $0.handoffClient.completions = { AsyncStream { $0.finish() } }
      $0.handoffClient.sendInstruction = { _, _ in false }
      $0.handoffClient.supersede = { id in
        superseded.withValue { $0.append(id) }
        return true
      }
      // The toast the outcome pushes arms its own dismiss timer.
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.handoff(.presented(.confirmSelection)))
    await store.receive(\.handoff.presented.delegate.handOff) { state in
      state.handoff = nil
    }
    await store.receive(\.handoffFailed)
    await store.receive(\.statusBar.push)
    #expect(superseded.value == [requestID])
  }

  /// Hand Off with Context runs the in-process transition straight away and
  /// lands on the receiver.
  @Test
  func contextOnlyHandOffRunsAtOnceAndReportsTheOutcome() async {
    let contentID = ContentID()
    let ran = LockIsolated<[IPC.HandoffRequest]>([])
    let source = Self.handoffSource(contentID: contentID)
    let profile = AgentProfile(kind: .codex, name: "Build")
    var initial = RootFeature.State()
    initial.handoff = HandoffFeature.State.make(source: source, profiles: [profile], placement: .split(.right))
    let completion = HandoffCompletion(
      action: .to, sourceContentID: contentID, receiver: .codex, briefing: .none, launched: nil, requestID: nil)

    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.handoffClient.run = { request in
        ran.withValue { $0.append(request) }
        return completion
      }
      // The toast the outcome pushes arms its own dismiss timer.
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.handoff(.presented(.confirmContextOnly)))
    await store.receive(\.handoff.presented.delegate.handOff) { state in
      state.handoff = nil
    }
    await store.receive(.handoffFinished(completion, targetTitle: "Build"))
    await store.receive(.statusBar(.push(.success("Handed off to Build"))))
    let request = ran.value.first
    #expect(request?.contextOnly == true)
    #expect(request?.receiver == "codex")
    #expect(request?.profile == profile.id.uuidString)
    #expect(request?.target == .split)
    #expect(request?.direction == .right)
    #expect(request?.requestID == nil)
  }
}
