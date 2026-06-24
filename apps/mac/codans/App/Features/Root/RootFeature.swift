import AppKit
import CodansCore
import ComposableArchitecture
import Foundation
import GhosttyKit

/// Root reducer for the TCA shell. Composes sub-features for the sidebar,
/// the worktree detail column, and top-level presentations. Also owns the
/// two long-running subscriptions that every feature depends on:
///   - `terminalClient.events()` — drives crash / exit / output lifecycle
///   - `hierarchyClient.selectionChanges()` — drives worktree-scoped
///     features (C7 diff viewer, M4 detail column swap)
///
/// The sidebar unconditionally renders the hierarchy tree.
@Reducer
struct RootFeature {
  @ObservableState
  struct State: Equatable {
    /// Most recent `HierarchySelection` seen from the stream. Features read
    /// this instead of holding a HierarchyManager reference.
    var selection: HierarchySelection = .empty

    /// Most recent engine event — diagnostic only in M2; M3/M4 features
    /// observe the stream directly via child-feature subscriptions.
    var lastEvent: LastEventMarker?

    /// Panes whose foreground process group is currently a `git` / `gh`
    /// command (see `ForegroundJobClassifier.indicatesGitCommand`). A pane
    /// leaving this set is the trailing edge of a prompt-run VCS command —
    /// the moment we kick an immediate git + PR refresh for its Project so a
    /// `gh pr create` / `git push` surfaces in the sidebar within seconds
    /// instead of waiting for the 60 s liveness poll (0018 M4 follow-up).
    var panesRunningGitCommand: Set<PaneID> = []

    var sidebar: HierarchySidebarFeature.State = .init()
    var detail: WorktreeDetailFeature.State = .init()
    /// T10: Branch popover / switch state. Owned at the root so the HEAD
    /// watcher's `worktreeHeadChanged` and the sidebar's `selectionChanged`
    /// can both forward into it from a single dispatch site, matching the
    /// per-worktree-aware peer features around it.
    var branchSwitcher: BranchSwitcherFeature.State = .init()
    /// C8 M6b (0005): editor preferences + per-Project override state.
    var editor: EditorFeature.State = .init()
    /// T2: Header feature (bell + Open-in split button + GV toggle).
    var worktreeHeader: WorktreeHeaderFeature.State = .init()
    /// 0012: GitHub integration — per-Worktree PR snapshots + popover state.
    var gitHub: GitHubFeature.State = .init()
    /// 0014: titlebar-center Worktree Status Bar — owns only the transient
    /// toast slot; PR / motivational forms are view-level projections.
    var statusBar: StatusBarFeature.State = .init()
    /// 0008: router for tab/split intents decoded from ghostty keybinds.
    var paneActionRouter: PaneActionRouterFeature.State = .init()
    /// 0008: router for window/app-level intents decoded from ghostty keybinds.
    var windowActionRouter: WindowActionRouterFeature.State = .init()

    /// In-flight `wt sw` whose detail-pane WorktreeLoadingView should
    /// take precedence over the resolved selection. Set when the user
    /// triggers `beginPendingWorktreeCreation`; cleared when the
    /// resolved selection lands on a real Worktree (success path) or
    /// when the user discards/cancels the row from the sidebar (the
    /// pending entry leaves `sidebar.pendingWorktrees`, so the resolver
    /// in `ContentView` falls back to the selection-based render).
    /// `.failed` keeps the id around so the detail view can surface
    /// the error until the user takes action.
    var activePendingWorktreeID: PendingWorktreeID?

    /// Command Palette overlay presentation. `nil` = hidden; non-nil
    /// renders the floating search card on top of the main split. Cleared
    /// on activation (the child emits `.delegate(.activate(…))`, the root
    /// routes it to a feature action and nils this slot in the same tick).
    @Presents var commandPalette: CommandPaletteFeature.State?

    /// M5 (project-tags): Tag CRUD sheet. `nil` = hidden; non-nil hosts
    /// `TagManagerSheet`. Opened from the sidebar via
    /// `.sidebar(.delegate(.openTagManager))`.
    @Presents var tagManagerSheet: TagManagerFeature.State?

    /// Whether the Hierarchy sidebar column is visible. Bound into
    /// `NavigationSplitView`'s `columnVisibility` from `ContentView` so the
    /// menu chord (⌘[) and the system disclosure button stay in sync.
    var sidebarVisible: Bool = true

    /// Reveal-in-sidebar trigger. The chord (⌘⇧E) bumps this to a fresh
    /// UUID; `HierarchySidebarView` observes the change and asks its
    /// `ScrollViewProxy` to scroll the currently-selected row into view.
    /// Stored as a UUID rather than a counter so the value is robust to
    /// state-codable round trips and to avoid integer overflow on long
    /// sessions, even though neither matters in practice.
    var revealSelectionTrigger: UUID = UUID()

    /// Show-unread trigger. The chord (⌘U) bumps this to a fresh UUID;
    /// `InboxBellView` observes the change through the WorktreeDetailView
    /// scope and opens its popover. Same pattern as
    /// `revealSelectionTrigger` — UUID rather than Bool so back-to-back
    /// invocations always register as a new value.
    var inboxBellPopoverTrigger: UUID = UUID()

    /// Back/forward history of selections, browser-style. `Back` pops from
    /// `navigationHistoryBack` and pushes onto `navigationHistoryForward`;
    /// `Forward` reverses. A new selection that did not come from a
    /// back/forward navigation pushes onto Back and clears Forward.
    var navigationHistoryBack: [HierarchySelection] = []
    var navigationHistoryForward: [HierarchySelection] = []
    /// True for one tick after a Back/Forward dispatch so the next
    /// `selectionChanged` does not re-record the navigation as a fresh
    /// step. Cleared in `selectionChanged` itself.
    var suppressHistoryPush: Bool = false
  }

  /// Opaque marker for diagnostic logging / tests — the full `TerminalEvent`
  /// is not Equatable (Data payloads in paneOutput), so we store a coarse
  /// discriminator.
  enum LastEventMarker: Equatable {
    case paneCreated
    case paneReady
    case paneOutput
    case paneViewportChanged
    case paneExited
    case paneCrashed
    case paneClosedByTab
    case paneIdle
    case tabActivated
    case tabAutoClosed
    case worktreeActivated
    case hierarchyMutated
    case paneInfoChanged
    case foregroundJobChanged
    case paneActionRequested
    case windowActionRequested
    case configChanged

    init(_ event: TerminalEvent) {
      switch event {
      case .paneCreated: self = .paneCreated
      case .paneReady: self = .paneReady
      case .paneOutput: self = .paneOutput
      case .paneViewportChanged: self = .paneViewportChanged
      case .paneIdle: self = .paneIdle
      case .paneExited: self = .paneExited
      case .paneCrashed: self = .paneCrashed
      case .paneClosedByTab: self = .paneClosedByTab
      case .tabActivated: self = .tabActivated
      case .tabAutoClosed: self = .tabAutoClosed
      case .worktreeActivated: self = .worktreeActivated
      case .hierarchyMutated: self = .hierarchyMutated
      case .paneInfoChanged: self = .paneInfoChanged
      case .foregroundJobChanged: self = .foregroundJobChanged
      case .paneActionRequested: self = .paneActionRequested
      case .windowActionRequested: self = .windowActionRequested
      case .configChanged: self = .configChanged
      }
    }
  }

  enum Action: Equatable {
    case onLaunch
    case onQuit
    case selectionChanged(HierarchySelection)
    case engineEventReceived(LastEventMarker)
    /// Emitted from the event stream when libghostty reports a surface
    /// has exited (child died, user-initiated close via `close_surface`
    /// binding, or crash). The root reducer resolves the pane's address
    /// and calls `hierarchyClient.closePane` to drop the catalog entry.
    case paneLifecycleExited(PaneID)
    /// Forwarded from `paneInfoChanged + .progress(...)` in the engine
    /// event stream. `isBusy` is true for any non-`REMOVE` OSC 9;4
    /// state. Drives the tab-chip running spinner (via
    /// `HierarchyManager.runningPanes`) and the sidebar busy glyph.
    case paneProgressBusyChanged(PaneID, Bool)
    /// Forwarded from `foregroundJobChanged` in the engine event stream.
    /// `isBusy` is true when the pane's foreground process group is a real
    /// non-agent command (see `ForegroundJobClassifier`). A session-level
    /// "terminal busy" source unioned with OSC 9;4 in the sidebar / tab-chip
    /// spinner, so plain commands that never emit OSC 9;4 still light it.
    case paneCommandBusyChanged(PaneID, Bool)
    /// Forwarded from `foregroundJobChanged` in the engine event stream.
    /// `running` is true when the pane's foreground process group is a
    /// `git` / `gh` command (see `ForegroundJobClassifier.indicatesGitCommand`).
    /// The reducer tracks the running set and, on the trailing edge (a
    /// prompt-run VCS command finishing), kicks an immediate git + PR refresh
    /// for the pane's Project (0018 M4 follow-up).
    case paneGitCommandActivity(PaneID, running: Bool)
    /// Forwarded from `paneInfoChanged + .pwd(path)` in the engine event
    /// stream. Persists the pane's live cwd so a restart restores it at the
    /// directory the user last `cd`'d to rather than its creation-time cwd.
    /// The reducer routes through `HierarchyClient.updatePaneWorkingDirectory`,
    /// which is idempotent on equal paths so a shell that re-asserts the same
    /// pwd every prompt never touches the catalog file.
    case paneLivePwdChanged(PaneID, String)
    /// Emitted by `WorktreeHeadWatcher` when a worktree's `.git/HEAD`
    /// file changes — typically a `git checkout` / `git switch` inside
    /// a codans pane. The reducer reconciles that worktree's
    /// Project so the catalog's `Worktree.branch` follows HEAD, then
    /// pokes GitHubFeature so the PR badge re-fetches against the new
    /// branch set. Without this, branch flips that happen while the
    /// app stays focused never reach the sidebar / header / PR cache
    /// (the focus-driven reconcile path requires a `didBecomeActive`
    /// transition the user never triggers). See HAN-62.
    case worktreeHeadChanged(WorktreeID)
    /// Emitted by `WorktreeWorkingTreeWatcher` when a file under a
    /// worktree's working tree changes (an edit in a pane / editor). Only
    /// the uncommitted-edit line counts can have shifted — branch / HEAD
    /// are handled by `worktreeHeadChanged` — so the reducer just refreshes
    /// that worktree's `+N −M` diff chip. Without this the chip only updated
    /// on commit / branch-switch or row remount, lagging real edits.
    case worktreeWorkingTreeChanged(WorktreeID)
    /// Opens the current Worktree in the configured Git Viewer. Sources:
    /// the ⌘⌥G chord, the "Toggle Git Viewer" menu item, and the command
    /// palette. Resolves `general.defaultGitViewerID` to an installed git
    /// client and opens the worktree there; a no-op when nothing is selected
    /// (Settings → General → Default Git Viewer = None) or the chosen client
    /// is no longer installed.
    case diffInspectorToggledForCurrentWorktree
    /// T3: ⌘O entry point. Resolves the current Worktree's path from the
    /// catalog snapshot (via `hierarchyClient` — reducer-scoped dependency,
    /// unlike SwiftUI `Commands` structs where `@Dependency` falls through
    /// to `liveValue` and crashes on the stubbed `snapshot` accessor) and
    /// dispatches `.editor(.openDefaultInCurrentWorktreeRequested)`.
    case openDefaultForCurrentWorktreeRequested
    /// ⌘⇧G entry point. Looks up the current Worktree's PR snapshot in
    /// `state.gitHub.snapshots` and forwards the URL through
    /// `.gitHub(.delegate(.openURL(...)))` — the same hop the status-bar
    /// PR badge uses on click. No-op when no Worktree is selected or no
    /// PR snapshot has been fetched for it yet (typical for non-GitHub
    /// repos or freshly created branches).
    case openCurrentPRRequested
    /// ⌘⇧G entry point (HAN-58). Resolves the current Project's gitRoot from
    /// the catalog, asks `gitService.remoteInfo` to parse the origin remote,
    /// and forwards `https://<host>/<owner>/<repo>` through the GitHub
    /// delegate's `openURL` hop. Silent no-op when no Project is selected,
    /// the Project has no gitRoot (plain directory Project), or the remote
    /// cannot be parsed (no origin, malformed URL).
    case openCurrentProjectOnGitHubRequested
    /// ⌘N entry point. Looks up the current Project from `state.selection`
    /// and forwards `.sidebar(.projectAddWorktreeTapped(projectID:))` so
    /// `HierarchySidebarFeature` opens its `CreateWorktreeFeature` sheet —
    /// same path the per-Project hover `+` button drives. No-op when no
    /// project is selected.
    case newWorktreeForCurrentProjectRequested
    /// `⌘D` / `⌘⇧D` menu bindings — split the active tab's leftmost leaf
    /// pane in the requested direction. Silent no-op when no project / tab
    /// is active. Equivalent to clicking the tab-bar trailing split
    /// buttons; both routes land on `.detail(.tabBar(.trailingSplitRequested))`
    /// so trees / hooks fire identically.
    case splitCurrentPaneRequested(direction: SplitTree<PaneID>.NewDirection)
    /// `⌘⌥←/→/↑/↓` menu bindings — moves focus to the adjacent split inside
    /// the active tab. Resolves the focused pane via `lastFocusedPane` (with
    /// a leftmost-leaf fallback so the chord still works on a freshly
    /// selected tab) and forwards `.gotoSplit(direction:)` through the same
    /// router that handles libghostty's built-in `goto_split` keybind.
    case focusAdjacentPaneInCurrentTabRequested(direction: FocusDirection)
    /// Tab-bar uplift: `⌘T` menu binding. Resolves the current Worktree
    /// and forwards `.detail(.tabBar(.newTabButtonTapped))`.
    case newTabForCurrentWorktree
    /// `⌘W` menu binding — closes the Worktree's active tab via
    /// `.detail(.tabBar(.closeButtonTapped))`. Silent no-op when no tab
    /// is active.
    case closeActiveTabForCurrentWorktree
    /// `⌥⌘1..⌥⌘9` menu bindings — selects the Nth tab (1-indexed).
    /// Silent no-op when the index exceeds the tab count.
    case selectTabAtIndexForCurrentWorktree(Int)
    /// `⌘⇧[` / `⌘⇧]` menu bindings — jumps to the previous / next tab
    /// with wrap-around. Calls `HierarchyClient.selectAdjacentTab`
    /// directly since the traversal logic lives in `HierarchyManager`.
    case selectAdjacentTabForCurrentWorktree(TabAdjacency)
    /// `⌘⇧R` menu binding — opens the rename sheet for the current
    /// Worktree's active tab. Resolves the tab here (in the root) and
    /// forwards `.detail(.tabBar(.renameRequested(...)))` so chip
    /// context-menu and chord paths land on the same reducer transition.
    /// Silent no-op when no tab is active.
    case renameActiveTabForCurrentWorktreeRequested
    case changeActiveTabColorForCurrentWorktreeRequested
    /// Resolves the current Worktree's path and asks the Finder client
    /// to reveal it. Mirrors the palette's `revealCurrentWorktreeInFinder`
    /// kind so the menu binding and the palette item land on the same
    /// effect. Silent no-op when no worktree is selected.
    case revealCurrentWorktreeInFinderRequested
    /// Resolves current selection and forwards to the existing
    /// `worktreeArchiveTapped` flow so the archive confirmation dialog
    /// runs identically to the row context-menu path.
    case archiveCurrentWorktreeRequested
    /// Resolves current selection and forwards to `worktreeRemoveTapped`
    /// so the delete confirmation dialog runs identically to the row
    /// context-menu path.
    case deleteCurrentWorktreeRequested
    /// Opens the Archived Worktrees sheet for the current Project. No-op
    /// when no project is selected.
    case showArchivedWorktreesForCurrentProjectRequested
    /// Forwards `WindowAction.checkForUpdates` through the router so the
    /// menu chord, the palette item, and any other entry point share the
    /// same effect.
    case checkForUpdatesRequested
    /// Opens the status-bar bell popover (the in-app unread inbox). Bumps
    /// `state.inboxBellPopoverTrigger` so `InboxBellView` toggles its
    /// popover; the chord (⌘U) routes here from the main menu.
    case showUnreadRequested
    /// Resolves the current Worktree's absolute path and writes it to the
    /// system pasteboard. Silent no-op when no worktree is selected.
    case copyCurrentWorktreePathRequested
    /// Flips `state.sidebarVisible`. ContentView's NavigationSplitView reads
    /// this through a binding, so the chord, the disclosure button, and any
    /// future UI affordance share the same source of truth.
    case toggleSidebarRequested
    /// Ensures the sidebar is open and asks the sidebar view to scroll the
    /// selected row into view. Bumps `revealSelectionTrigger` so the view's
    /// `.onChange` fires even when the chord is pressed twice in a row.
    case revealCurrentWorktreeInSidebarRequested
    /// Moves selection to the next/previous Worktree in sidebar display
    /// order, wrapping at the ends. Display order matches what the sidebar
    /// renders: projects in catalog order, within each project the main
    /// row first, then pinned, then unpinned, archived rows excluded.
    case selectAdjacentWorktreeRequested(TabAdjacency)
    /// Pops the last entry from `navigationHistoryBack` and selects it,
    /// pushing the current selection onto `navigationHistoryForward`.
    case worktreeHistoryBackRequested
    /// Mirror of `worktreeHistoryBackRequested` in the opposite direction.
    case worktreeHistoryForwardRequested
    /// $EDITOR routing. Dispatched from `EditorFeature.delegate.openShellEditorRequested`
    /// when any editor-open path resolves the preferred id to `EditorRegistry.shellEditorID`.
    /// Locates the target Worktree by path, creates a fresh Tab, and spawns a Pane with
    /// `initialCommand: "$EDITOR"` so the Pane primitive handles the launch the way
    /// `EditorService.open` cannot (no Pane/Tab context in the service signature).
    case openShellEditorInWorktree(worktreePath: String, projectID: ProjectID?)
    /// Toggle the Command Palette overlay. Sources: `⌘P` menu binding
    /// (source pane unknown — payload is `nil`), and
    /// `paneActionRouter(.delegate(.commandPaletteToggleRequested(paneID)))`
    /// forwarded from the ghostty keybind pipeline (payload carries the
    /// source pane so Pane-scoped palette actions target the right
    /// split).
    case commandPaletteToggle(PaneID?)
    case commandPalette(PresentationAction<CommandPaletteFeature.Action>)
    /// M5 (project-tags): Tag CRUD sheet presentation. `tagManagerSheetShown`
    /// kicks the sheet visible, the `PresentationAction` carries child
    /// actions and dismiss.
    case tagManagerSheet(PresentationAction<TagManagerFeature.Action>)
    case tagManagerSheetShown
    /// v1 notifications navigation. Dispatched by InboxBellView's row tap
    /// and by AppDelegate's macOS banner-click handler. Walks the path
    /// (`projectID → worktreeID → tabID → paneID`) and lands selection
    /// state at the deepest still-existing ancestor; missing ancestors
    /// fall through silently rather than blocking. Routed through
    /// RootFeature (rather than PaneActionRouter) because cross-worktree
    /// focus belongs to the feature that owns selection state.
    case focusHierarchyPath(InboxEntry.SourcePath)
    case sidebar(HierarchySidebarFeature.Action)
    case detail(WorktreeDetailFeature.Action)
    case branchSwitcher(BranchSwitcherFeature.Action)
    case editor(EditorFeature.Action)
    case worktreeHeader(WorktreeHeaderFeature.Action)
    case gitHub(GitHubFeature.Action)
    case statusBar(StatusBarFeature.Action)
    case paneActionRouter(PaneActionRouterFeature.Action)
    case windowActionRouter(WindowActionRouterFeature.Action)
    /// T6 (active-agents): rows in the AgentStateView dispatch
    /// here. Cross-Project / Worktree / Tab focus belongs to the same
    /// reducer that owns selection state — same precedent as
    /// `.focusHierarchyPath` for inbox-row taps.
    case agentState(AgentStateAction)
  }

  /// Child action enum for the agent-state view. `.rowTapped` walks the
  /// catalog to the (project, worktree, tab) chain containing the pane
  /// and lands focus on the pane itself. `.dismissRequested` is reserved
  /// for future use — today the sidebar panel manages its own open state
  /// via `@AppStorage`, but keeping the case in the enum lets a future
  /// programmatic close chord land without a reshuffle.
  enum AgentStateAction: Equatable {
    case rowTapped(PaneID)
    case dismissRequested
  }

  nonisolated enum CancelID: Hashable, Sendable {
    case events, selectionChanges, projectReconcileFocus, worktreeHeadWatcher
    /// FSEvents working-tree observation that refreshes the `+N −M` chip
    /// after in-pane / in-editor edits (separate from the HEAD watcher).
    case worktreeWorkingTreeWatcher
    /// `NSApplication.didResignActiveNotification` observation — pauses the GitHub
    /// liveness poll when the app is no longer frontmost (0018 M1).
    case appResignActive
    /// Debounces the immediate git + PR refresh kicked when a `git` / `gh`
    /// command finishes in a pane, per owning Project, so a burst of VCS
    /// commands coalesces into one fetch (0018 M4 follow-up).
    case gitCommandRefresh(ProjectID)
  }

  @Dependency(TerminalClient.self) private var terminalClient
  @Dependency(HierarchyClient.self) private var hierarchyClient
  @Dependency(FinderClient.self) private var finderClient
  @Dependency(SettingsWriter.self) private var settingsWriter
  @Dependency(ProjectReconciler.self) private var projectReconciler
  @Dependency(WorktreeHeadWatcher.self) private var worktreeHeadWatcher
  @Dependency(WorktreeWorkingTreeWatcher.self) private var worktreeWorkingTreeWatcher
  @Dependency(WorktreeLocalDiffMonitor.self) private var worktreeLocalDiffMonitor
  @Dependency(SettingsWindowPresenter.self) private var settingsWindowPresenter
  @Dependency(GitHubSnapshotCacheClient.self) private var gitHubSnapshotCache
  @Dependency(GitServiceClient.self) private var gitServiceClient

  /// Child-feature scopes. Split from `body` so Swift's type inference budget stays under
  /// the single-expression limit — each additional top-level `Scope` in `body` adds to the
  /// inferred return type and past ~7 scopes the compiler fails with "unable to type-check
  /// in reasonable time".
  @ReducerBuilder<State, Action>
  private var sidebarAndDetailScopes: some Reducer<State, Action> {
    Scope(state: \.sidebar, action: \.sidebar) { HierarchySidebarFeature() }
    Scope(state: \.detail, action: \.detail) { WorktreeDetailFeature() }
    Scope(state: \.branchSwitcher, action: \.branchSwitcher) { BranchSwitcherFeature() }
  }

  @ReducerBuilder<State, Action>
  private var headerAndEditorScopes: some Reducer<State, Action> {
    Scope(state: \.editor, action: \.editor) { EditorFeature() }
    Scope(state: \.worktreeHeader, action: \.worktreeHeader) { WorktreeHeaderFeature() }
    Scope(state: \.gitHub, action: \.gitHub) {
      GitHubFeature()
      GitHubRootBindings()
    }
    Scope(state: \.statusBar, action: \.statusBar) { StatusBarFeature() }
  }

  @ReducerBuilder<State, Action>
  private var routerScopes: some Reducer<State, Action> {
    Scope(state: \.paneActionRouter, action: \.paneActionRouter) { PaneActionRouterFeature() }
    Scope(state: \.windowActionRouter, action: \.windowActionRouter) { WindowActionRouterFeature() }
  }

  var body: some Reducer<State, Action> {
    sidebarAndDetailScopes
    headerAndEditorScopes
    routerScopes
    coreReducer
  }

  /// The large `Reduce { state, action in switch action { ... } }` block that wires root
  /// lifecycle, cross-feature action forwarding, and delegate handling. Split from `body`
  /// to keep the result-builder expression under the Swift type-inference budget.
  private var coreReducer: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .onLaunch:
        let eventStream = terminalClient.events()
        let selectionStream = hierarchyClient.selectionChanges()
        // `didBecomeActive` fires every time the app window re-gains focus;
        // per-run debounce lives inside `ProjectReconciler.reconcileAll`, so
        // click storms collapse into a single scan. The notification stream
        // via AsyncSequence is fine to hold for the full app lifetime;
        // `CancelID.projectReconcileFocus` stops it at quit.
        let focusStream = NotificationCenter.default.notifications(
          named: NSApplication.didBecomeActiveNotification
        )
        // 0018 M1: the GitHub liveness poll is gated on the app being frontmost. Resign
        // pauses the loop (target → nil); become-active re-points it at the active
        // Project. Held for the app lifetime; `CancelID.appResignActive` stops it at quit.
        let resignStream = NotificationCenter.default.notifications(
          named: NSApplication.didResignActiveNotification
        )
        return .merge(
          .run { send in
            for await event in eventStream {
              // 0008: action-router events are routed to their dedicated
              // reducers; everything else just bumps the diagnostic marker.
              // Intent events also bump the marker so tests that observe
              // `lastEvent` still see them pass through.
              switch event {
              case .paneActionRequested(let paneID, let request):
                await send(.paneActionRouter(.requested(paneID, request)))
              case .windowActionRequested(let request):
                await send(.windowActionRouter(.requested(request)))
              case .paneExited(let paneID, _, _):
                // ghostty's `close_surface` binding + child-exit both land
                // here. Surface memory is already freed by the engine; we
                // still need to remove the Pane from the catalog so the
                // SplitTree collapses and no stale black rect is rendered.
                await send(.paneLifecycleExited(paneID))
              case .paneCrashed(let paneID, _):
                // The pane stays in the catalog for the user to retry, but
                // its OSC 9;4 running flag would otherwise leak: a crashing
                // program rarely gets a chance to emit the REMOVE state
                // that closes out the indicator. Force-clear so the
                // tab-chip / sidebar spinners do not pin on a dead pane.
                await send(.paneProgressBusyChanged(paneID, false))
              case .paneInfoChanged(let paneID, .progress(let state, _)):
                // OSC 9;4 progress reports drive the per-pane "executing"
                // signal. Any non-REMOVE state (set / indeterminate /
                // pause / error) marks the pane as running; REMOVE clears
                // it. This is the only writer to `runningPanes` in the
                // app today and is what lights up the tab-chip spinner +
                // sidebar busy glyph.
                let isBusy = state != GHOSTTY_PROGRESS_STATE_REMOVE.rawValue
                await send(.paneProgressBusyChanged(paneID, isBusy))
              case .foregroundJobChanged(let paneID, let job):
                // Foreground process group → session-level "terminal busy".
                // A non-shell, non-agent command lights the tab-chip /
                // sidebar spinner even when the program never emits OSC 9;4.
                // Agents are excluded here; their activity is render-derived.
                await send(
                  .paneCommandBusyChanged(
                    paneID, ForegroundJobClassifier.indicatesRunningCommand(job)))
                // Same source, narrower predicate: track `git` / `gh` commands
                // so a finishing `gh pr create` / `git push` triggers an
                // immediate PR + diff refresh (0018 M4 follow-up).
                await send(
                  .paneGitCommandActivity(
                    paneID, running: ForegroundJobClassifier.indicatesGitCommand(job)))
              case .paneInfoChanged(let paneID, .pwd(let pwd)):
                // libghostty OSC 7 → persist the live cwd so a restart
                // restores the pane at the directory the user last `cd`'d
                // to. Nil / empty payloads are dropped here so we never
                // overwrite a real path with a transient clear; the
                // manager-side mutator further dedupes equal-path writes.
                if let pwd, !pwd.isEmpty {
                  await send(.paneLivePwdChanged(paneID, pwd))
                }
              default:
                break
              }
              await send(.engineEventReceived(LastEventMarker(event)))
            }
          }
          .cancellable(id: CancelID.events, cancelInFlight: true),

          .run { send in
            for await selection in selectionStream {
              await send(.selectionChanged(selection))
            }
          }
          .cancellable(id: CancelID.selectionChanges, cancelInFlight: true),

          // Initial sweep: every persisted Project transitions out of .loading
          // once the reconciler fans out against the current snapshot.
          // After the sweep settles any branch changes that happened while
          // the app was closed (HAN-62), poke GitHubFeature so the PR badges
          // reflect the post-reconcile branch set.
          .run { [projectReconciler, client = hierarchyClient] send in
            await projectReconciler.reconcileAll()
            let actions: [GitHubFeature.Action] = await MainActor.run {
              var result: [GitHubFeature.Action] = []
              if let refresh = Self.makeActiveProjectGitHubRefresh(client: client) {
                result.append(refresh)
              }
              // Arm the liveness poll if the app launched frontmost (0018 M1).
              result.append(
                Self.makePollTargetChange(
                  client: client, appActive: NSApplication.shared.isActive
                )
              )
              return result
            }
            for action in actions { await send(.gitHub(action)) }
          },

          // Re-sync on window focus. Debounced inside the actor. The
          // post-reconcile GitHub refresh covers the canonical HAN-62 flow:
          // user runs `git checkout` in a pane, switches back to the app —
          // focus fires, reconcile picks up the new branch, GitHubFeature
          // re-evaluates the PR cache against the updated branch set.
          .run { [projectReconciler, client = hierarchyClient] send in
            for await _ in focusStream {
              await projectReconciler.reconcileAll()
              let actions: [GitHubFeature.Action] = await MainActor.run {
                var result: [GitHubFeature.Action] = []
                if let refresh = Self.makeActiveProjectGitHubRefresh(client: client) {
                  result.append(refresh)
                }
                // Re-point the liveness poll at the active Project (app is frontmost
                // because didBecomeActive just fired) — 0018 M1.
                result.append(Self.makePollTargetChange(client: client, appActive: true))
                return result
              }
              for action in actions { await send(.gitHub(action)) }
            }
          }
          .cancellable(id: CancelID.projectReconcileFocus, cancelInFlight: true),

          // 0018 M1: pause the liveness poll the instant the app resigns active, so a
          // backgrounded / idle app fires zero `gh api graphql` subprocesses.
          .run { send in
            for await _ in resignStream {
              await send(
                .gitHub(.pollTargetChanged(nil, gitRoot: nil, worktreeBranches: []))
              )
            }
          }
          .cancellable(id: CancelID.appResignActive, cancelInFlight: true),

          // HAN-62: terminal-initiated `git checkout` / `git switch` inside
          // a codans pane never fires `didBecomeActive`, so the focus-
          // driven reconcile path alone wouldn't pick up the new branch.
          // `WorktreeHeadWatcher` taps `.git/HEAD` via DispatchSource and
          // yields the changed `WorktreeID`; we forward into the reducer
          // for a targeted reconcile + GitHub refresh.
          .run { [worktreeHeadWatcher] send in
            let stream = await MainActor.run { worktreeHeadWatcher.events() }
            for await worktreeID in stream {
              await send(.worktreeHeadChanged(worktreeID))
            }
          }
          .cancellable(id: CancelID.worktreeHeadWatcher, cancelInFlight: true),

          // Working-tree edits inside a pane / editor change `git diff HEAD`
          // but not `.git/HEAD`, so the HEAD watcher never fires for them.
          // `WorktreeWorkingTreeWatcher` taps the working-tree subtree via
          // FSEvents and yields the changed `WorktreeID`; we forward it for a
          // targeted diff-chip refresh.
          .run { [worktreeWorkingTreeWatcher] send in
            let stream = await MainActor.run { worktreeWorkingTreeWatcher.events() }
            for await worktreeID in stream {
              await send(.worktreeWorkingTreeChanged(worktreeID))
            }
          }
          .cancellable(id: CancelID.worktreeWorkingTreeWatcher, cancelInFlight: true),

          // 0013 M4 follow-up: hydrate the GitHub integration's in-memory state from
          // its on-disk snapshot cache so the sidebar paints PR badges on the first
          // render pass, without the blank-then-populated flash the user sees when
          // the first `gh api graphql` round-trip is the only data source. Walks the
          // live catalog once to build the branch→worktreeID map the reducer needs
          // to project cached branches into per-Worktree snapshot state.
          .run { [cache = gitHubSnapshotCache, client = hierarchyClient] send in
            let cached = cache.load()
            guard !cached.isEmpty else { return }
            let catalog = await MainActor.run { client.snapshot() }
            var pairsByProject: [ProjectID: [GitHubFeature.Action.WorktreeBranchPair]] = [:]
            for project in catalog.projects {
              let pairs = project.worktrees.compactMap {
                worktree -> GitHubFeature.Action.WorktreeBranchPair? in
                guard !worktree.archived, let branch = worktree.branch, !branch.isEmpty
                else { return nil }
                return GitHubFeature.Action.WorktreeBranchPair(
                  worktreeID: worktree.id, branch: branch
                )
              }
              if !pairs.isEmpty { pairsByProject[project.id] = pairs }
            }
            await send(
              .gitHub(.seedFromCache(cached: cached, branchPairsByProject: pairsByProject))
            )
          }
        )
      // Worst case for sidebar context-menu "Open in default editor" is an
      // empty descriptor cache → resolution falls through to
      // EditorRegistry.finderID, which is always installed. Priming via
      // `.send(.editor(.onAppear))` here was considered but was dropped
      // because it runs the live EditorService on a background Task and
      // the live factory's `MainActor.assumeIsolated { ... }` assertion
      // fails from a non-MainActor queue during test-host bootstrap. The
      // WorktreeHeaderOpenButton's own `.task { store.send(.onAppear) }`
      // is the canonical hydration path.

      case .onQuit:
        return .merge(
          .cancel(id: CancelID.events),
          .cancel(id: CancelID.selectionChanges),
          .cancel(id: CancelID.projectReconcileFocus),
          .cancel(id: CancelID.worktreeHeadWatcher),
          .cancel(id: CancelID.worktreeWorkingTreeWatcher),
          .cancel(id: CancelID.appResignActive)
        )

      case .selectionChanged(let selection):
        let priorProjectID = state.selection.projectID
        let priorSelection = state.selection
        state.selection = selection
        // Browser-style history. Skip the push when we just dispatched a
        // Back/Forward (otherwise that navigation would itself become a new
        // step); otherwise record the *previous* selection so a future Back
        // can return to it.
        if state.suppressHistoryPush {
          state.suppressHistoryPush = false
        } else if priorSelection.worktreeID != nil,
          priorSelection.worktreeID != selection.worktreeID
        {
          state.navigationHistoryBack.append(priorSelection)
          state.navigationHistoryForward.removeAll()
        }
        // Selection landed on a real Worktree → drop the pending-loading
        // overlay so the detail pane reverts to the regular terminal
        // surface. The success path of `pendingWorktreeFinished` calls
        // `selectWorktree(realID)` after the catalog write, which is
        // the moment we want the overlay to retire.
        if selection.worktreeID != nil {
          state.activePendingWorktreeID = nil
        }
        // Auto-seed a Tab + Pane when the selected Worktree has none so
        // switching to a brand-new Worktree immediately shows a live
        // terminal rooted at `worktree.path` instead of a placeholder that
        // forces the user to click twice. Safe to run unconditionally on
        // every selection change: createTab/openPane are no-ops when the
        // Worktree already has tabs/panes (we gate on .isEmpty below).
        autoSeedTabAndPaneIfNeeded(for: selection)
        // Mirror the selection's active tab into the split viewport so M5
        // lazy-surface lifecycle can react without reading HierarchyManager
        // from a reducer. Tab is resolved on-the-fly from the catalog.
        let tabID = resolveActiveTab(selection: selection)
        state.detail.splitViewport.activeTabID = tabID
        // Eagerly rebuild `paneHosts` for the new selection in the SAME
        // reducer tick, with warm ghostty surfaces pre-attached. SwiftUI's
        // next render then finds a fully populated `.ready` host array —
        // no ProgressView scope-miss frame, no "Creating surface…"
        // placeholder frame. The existing `.task(id:)` sync in
        // `SplitViewportView` stays as a fallback for paths that don't go
        // through `selectionChanged` (TabBar tap within the same worktree,
        // pane open / split / close inside the active tab).
        reconcilePaneHosts(
          &state.detail.splitViewport, selection: selection, tabID: tabID
        )
        var effects: [Effect<Action>] = []
        // Resolved once and reused by the branch-switcher forwarding below.
        // `nil` when either id is nil, which downstream reducers treat as a
        // full caches+ids reset.
        let resolvedWorktreePath: String? = {
          guard
            let projectID = selection.projectID,
            let worktreeID = selection.worktreeID
          else { return nil }
          let snapshot = hierarchyClient.snapshot()
          return snapshot
            .projects.first(where: { $0.id == projectID })?
            .worktrees.first(where: { $0.id == worktreeID })?.path
        }()
        // T10: forward selection delta into the branch switcher so the
        // next popover open re-fetches against the new worktree path.
        // `resolvedWorktreePath` already resolves to nil when either id is
        // nil, which the reducer treats as a full caches+ids reset.
        //
        // Phase B: also compute the "blocked branches" map — branches
        // checked out in OTHER worktrees of the same Project, keyed by
        // branch short-name → that worktree's folder name. The popover
        // greys these rows so users see the constraint before clicking.
        let blockedBranches: [String: String] = {
          guard
            let projectID = selection.projectID,
            let worktreeID = selection.worktreeID
          else { return [:] }
          let snapshot = hierarchyClient.snapshot()
          guard
            let project = snapshot.projects.first(where: { $0.id == projectID })
          else { return [:] }
          var map: [String: String] = [:]
          for worktree in project.worktrees {
            // The active worktree's own branch is never "blocked from
            // itself"; detached worktrees (branch == nil) cannot block.
            if worktree.id == worktreeID { continue }
            guard let branch = worktree.branch else { continue }
            map[branch] = worktree.name
          }
          return map
        }()
        effects.append(
          .send(
            .branchSwitcher(
              .worktreeChanged(
                projectID: selection.projectID,
                worktreeID: selection.worktreeID,
                path: resolvedWorktreePath,
                blockedBranches: blockedBranches
              )))
        )
        // v2 GitHub integration (0013 M4): when the active Project changes, ask
        // GitHubFeature to batch-fetch PR data for every branch in that Project.
        // The reducer runs one `gh api graphql` for the whole repo instead of
        // N per-Worktree calls — see docs/exec-plans/0013-github-integration-batched.md.
        if selection.projectID != priorProjectID,
          let projectID = selection.projectID,
          let project = lookupProject(projectID: projectID),
          let gitRootString = project.gitRoot
        {
          let gitRoot = URL(fileURLWithPath: gitRootString)
          let pairs = project.worktrees.compactMap { worktree -> GitHubFeature.Action.WorktreeBranchPair? in
            guard !worktree.archived, let branch = worktree.branch, !branch.isEmpty else {
              return nil
            }
            return GitHubFeature.Action.WorktreeBranchPair(
              worktreeID: worktree.id, branch: branch
            )
          }
          effects.append(
            .send(
              .gitHub(
                .projectActivated(projectID, gitRoot: gitRoot, worktreeBranches: pairs)
              ))
          )
          // 0018 M1: re-point the liveness poll at the newly-activated Project (or pause
          // it if the app is not frontmost). `projectActivated` above owns the immediate
          // refresh; this only arms the recurring poll.
          if NSApplication.shared.isActive {
            effects.append(
              .send(
                .gitHub(
                  .pollTargetChanged(projectID, gitRoot: gitRoot, worktreeBranches: pairs)
                ))
            )
          } else {
            effects.append(
              .send(.gitHub(.pollTargetChanged(nil, gitRoot: nil, worktreeBranches: [])))
            )
          }
        }
        return .merge(effects)

      case .worktreeHeadChanged(let worktreeID):
        // HEAD-file change fired by `WorktreeHeadWatcher`. Resolve the owning
        // Project so the reconciler can rerun `git worktree list --porcelain`
        // for that repo only — cheap, and `reconcileDiscoveredWorktrees`
        // now updates `Worktree.branch` in place (HAN-62). The trailing
        // GitHub refresh re-evaluates the active Project's PR cache against
        // whatever branch set the reconcile settled on.
        let catalog = hierarchyClient.snapshot()
        guard
          let projectID = catalog.projects.first(where: { project in
            project.worktrees.contains(where: { $0.id == worktreeID })
          })?.id
        else { return .none }
        let worktreePath = catalog.projects.first(where: { $0.id == projectID })?
          .worktrees.first(where: { $0.id == worktreeID })?.path
        // T10: route the HEAD-change into the branch switcher ONLY when
        // the watched worktree matches the one the popover currently
        // backs. Reducers run on the main actor, so reading
        // `state.branchSwitcher.worktreeID` here is the authoritative
        // value at dispatch time — no captured-snapshot races.
        let shouldForwardToBranchSwitcher = worktreeID == state.branchSwitcher.worktreeID
        return .run {
          [projectReconciler, client = hierarchyClient, monitor = worktreeLocalDiffMonitor] send in
          // HEAD moved → the cached `git diff HEAD --shortstat` numbers are
          // stale by definition. Drop the freshness stamp and immediately
          // re-fetch so the sidebar chip updates in the same tick the
          // reconciler runs, instead of waiting for the row to remount.
          if let worktreePath {
            await MainActor.run { monitor.invalidate(worktreeID: worktreeID) }
            await monitor.refresh(
              worktreeID: worktreeID,
              path: URL(fileURLWithPath: worktreePath)
            )
          }
          await projectReconciler.reconcile(projectID: projectID)
          if let action = await MainActor.run(body: {
            Self.makeActiveProjectGitHubRefresh(client: client)
          }) {
            await send(.gitHub(action))
          }
          if shouldForwardToBranchSwitcher {
            await send(.branchSwitcher(.headChangedForCurrentWorktree))
          }
        }

      case .worktreeWorkingTreeChanged(let worktreeID):
        // FSEvents fired for a working-tree edit. Branch / HEAD are
        // unaffected, so skip the reconcile + GitHub refresh the HEAD path
        // runs — only the `git diff HEAD --shortstat` numbers can have moved.
        // Drop the freshness stamp and re-fetch so the chip tracks the edit
        // instead of waiting for the row to remount.
        let catalog = hierarchyClient.snapshot()
        guard
          let worktreePath = catalog.projects
            .flatMap(\.worktrees)
            .first(where: { $0.id == worktreeID })?.path
        else { return .none }
        return .run { [monitor = worktreeLocalDiffMonitor] _ in
          await MainActor.run { monitor.invalidate(worktreeID: worktreeID) }
          await monitor.refresh(
            worktreeID: worktreeID,
            path: URL(fileURLWithPath: worktreePath)
          )
        }

      case .engineEventReceived(let marker):
        state.lastEvent = marker
        return .none

      case .paneProgressBusyChanged(let paneID, let isBusy):
        // Idempotent: `markPaneRunning` / `markPaneIdle` collapse repeats
        // through `Set.insert` / `Set.remove`, so we don't dedupe here.
        // No state mutation — the dirty flags read straight off
        // `HierarchyManager.runningPanes` and SwiftUI invalidates via the
        // chip / sidebar's binding to that runtime set.
        if isBusy {
          hierarchyClient.markPaneRunning(paneID)
        } else {
          hierarchyClient.markPaneIdle(paneID)
        }
        return .none

      case .paneCommandBusyChanged(let paneID, let isBusy):
        // Sibling of `paneProgressBusyChanged` for the foreground-job source.
        // No reducer state mutation — the dirty flags read straight off
        // `HierarchyManager.commandBusyPanes` and SwiftUI invalidates via the
        // chip / sidebar's binding to that runtime set.
        hierarchyClient.setPaneCommandBusy(paneID, isBusy)
        return .none

      case .paneGitCommandActivity(let paneID, let running):
        // Edge-triggered on the foreground `git` / `gh` set. We act ONLY on
        // the trailing edge (a command the user ran at the prompt finishing)
        // and ONLY for panes we previously saw running one — so an idle
        // shell's unrelated job churn never triggers a fetch.
        if running {
          state.panesRunningGitCommand.insert(paneID)
          return .none
        }
        guard state.panesRunningGitCommand.remove(paneID) != nil else { return .none }
        // Resolve the pane's owning Project + Worktree from the live catalog
        // (same walk as `worktreeHeadChanged`).
        let catalog = hierarchyClient.snapshot()
        let owner = catalog.projects.first { project in
          project.worktrees.contains { worktree in
            worktree.tabs.contains { $0.panes.contains { $0.id == paneID } }
          }
        }
        guard
          let project = owner,
          let gitRootString = project.gitRoot,
          let worktree = project.worktrees.first(where: { worktree in
            worktree.tabs.contains { $0.panes.contains { $0.id == paneID } }
          })
        else { return .none }
        let projectID = project.id
        let worktreeID = worktree.id
        let worktreePath = worktree.path
        let gitRoot = URL(fileURLWithPath: gitRootString)
        let pairs = project.worktrees.compactMap {
          worktree -> GitHubFeature.Action.WorktreeBranchPair? in
          guard !worktree.archived, let branch = worktree.branch, !branch.isEmpty
          else { return nil }
          return GitHubFeature.Action.WorktreeBranchPair(
            worktreeID: worktree.id, branch: branch
          )
        }
        return .run { [projectReconciler, monitor = worktreeLocalDiffMonitor] send in
          // `git commit` / `git push` move the working-tree diff and the
          // ahead/behind counts but NOT `.git/HEAD`, so neither the HEAD
          // watcher nor the working-tree watcher reliably fires for a push —
          // drop the freshness stamp, refresh the chip, and reconcile now.
          await MainActor.run { monitor.invalidate(worktreeID: worktreeID) }
          await monitor.refresh(
            worktreeID: worktreeID,
            path: URL(fileURLWithPath: worktreePath)
          )
          await projectReconciler.reconcile(projectID: projectID)
          // PR state lives server-side. Give GitHub ~1.5 s to settle the write
          // (mirrors the 2 s post-mutation delay), then force a batched fetch.
          // `projectRefreshRequested` bypasses the 30 s freshness gate so a
          // just-created PR surfaces in seconds, not on the next 60 s poll tick.
          // A burst of git commands in the same Project coalesces via the
          // per-Project cancellable id.
          try? await Task.sleep(for: .milliseconds(1500))
          await send(
            .gitHub(
              .projectRefreshRequested(
                projectID, gitRoot: gitRoot, worktreeBranches: pairs
              )
            )
          )
        }
        .cancellable(id: CancelID.gitCommandRefresh(projectID), cancelInFlight: true)

      case .paneLivePwdChanged(let paneID, let path):
        // No reducer state mutation — the manager writes through to the
        // catalog directly and debounces the disk save via `scheduleSave`.
        hierarchyClient.updatePaneWorkingDirectory(paneID, path)
        return .none

      case .paneLifecycleExited(let paneID):
        // A pane that exits mid-command never emits its trailing git-edge,
        // so drop any tracked running-state to keep the set bounded.
        state.panesRunningGitCommand.remove(paneID)
        // Resolve the pane's address from the live catalog (the engine
        // already unregistered the surface, but the catalog still holds
        // the Pane entity here). Address can be nil if a racing teardown
        // dropped the pane first — then there's nothing to do.
        guard let address = hierarchyClient.addressOf(paneID) else {
          return .none
        }
        let catalog = hierarchyClient.snapshot()
        guard
          let tab = catalog
            .projects.first(where: { $0.id == address.projectID })?
            .worktrees.first(where: { $0.id == address.worktreeID })?
            .tabs.first(where: { $0.id == address.tabID })
        else { return .none }
        // Single-pane tab: ⌘W's `close_surface` should also retire the now-empty
        // tab. Leaving a zombie tab with no panes shows a blank pane area and
        // makes the window look broken. `closeTab` is a no-op for the surface
        // (already torn down by the engine) but does the catalog cleanup and
        // routes selection to the adjacent tab.
        if tab.panes.count <= 1 {
          try? hierarchyClient.closeTab(
            address.tabID, address.worktreeID, address.projectID
          )
          return .none
        }
        // Multi-pane tab: drop the pane and transfer focus to the survivor.
        // Compute the focus target BEFORE mutating the tree so the leaf
        // identity is still valid. Matches ghostty's macOS controller:
        // closing the leftmost leaf → focus next; otherwise → focus previous.
        let focusTarget = tab.splitTree.focusTargetAfterClosing(paneID)
        try? hierarchyClient.closePane(
          paneID, address.tabID, address.worktreeID, address.projectID
        )
        if let focusTarget {
          return .run { [client = hierarchyClient] _ in
            await MainActor.run {
              client.focusSurfaceView(focusTarget)
            }
          }
        }
        return .none

      // Sidebar delegate routing. Must come before the catch-all
      // `case .sidebar:` so the nested pattern matches first.

      case .sidebar(.delegate(.openInDefaultEditor(let path, let projectID))):
        // Route through the shared `resolveInstalledPreference` helper so the sidebar
        // context menu, the Header Open-in button, and the ⌘O shortcut use one resolution
        // path. When neither override nor global default is installed, pass `nil` so the
        // service's priority cascade picks the first installed editor (Cursor / Zed /
        // VSCode / …) before falling through to Finder. Passing `"finder"` here short-
        // circuits the priority walk because the service's `preferred` tier is strict.
        let preferred = EditorFeature.resolveInstalledPreference(
          projectOverride: projectOverrideEditorID(for: projectID),
          globalDefault: state.editor.globalDefault,
          descriptors: state.editor.descriptors
        )
        return .send(
          .editor(
            .openRequested(
              editorID: preferred,
              worktreePath: path,
              projectID: projectID
            )))

      case .sidebar(.delegate(.openInEditor(let path, let projectID, let editorID))):
        // Sidebar's "Open in <Editor>" submenu picked an explicit
        // editor — bypass the project-override / global-default cascade
        // and ask the service to open with that ID directly.
        return .send(
          .editor(
            .openRequested(
              editorID: editorID,
              worktreePath: path,
              projectID: projectID
            )))

      case .sidebar(.delegate(.revealInFinder(let path))):
        let client = finderClient
        return .run { _ in
          await MainActor.run { client.reveal(path) }
        }

      case .sidebar(.delegate(.reconcileProjectRequested(let projectID))):
        // Kick the ProjectReconciler so the newly-added (or retried)
        // Project transitions through .loading → .ready (or .failed) and the
        // worktree list populates via T-WORKTREE's reconcileDiscoveredWorktrees
        // closure (once that PR lands; currently a no-op stub).
        return .run { [client = hierarchyClient] send in
          await projectReconciler.reconcile(projectID: projectID)
          if let action = await MainActor.run(body: {
            Self.makeActiveProjectGitHubRefresh(client: client)
          }) {
            await send(.gitHub(action))
          }
        }

      case .sidebar(.delegate(.refreshAllProjectsRequested)):
        // Manual refresh from the sidebar bottom-bar. `force: true` bypasses
        // the reconciler's focus-driven debounce so the click takes effect
        // immediately even when a focus-triggered pass just ran. Follow up
        // with a GitHub refresh so HAN-62-style branch changes propagate
        // to the PR badges without waiting for the next selection event.
        return .run { [client = hierarchyClient] send in
          await projectReconciler.reconcileAll(force: true)
          if let action = await MainActor.run(body: {
            Self.makeActiveProjectGitHubRefresh(client: client)
          }) {
            await send(.gitHub(action))
          }
        }

      case .sidebar(.delegate(.revealExistingProject(let projectID))):
        // Add Project picker hit a duplicate folder — jump the user to
        // the already-registered row.
        hierarchyClient.selectProject(projectID)
        return .none

      case .sidebar(.delegate(.openTagManager)):
        state.tagManagerSheet = TagManagerFeature.State()
        return .none

      // Pending-worktree focus: when the user kicks off creation, snap
      // the detail pane to the WorktreeLoadingView. The child reducer
      // appends the row to `sidebar.pendingWorktrees` first; we mark it
      // as the active overlay so `ContentView` resolves it ahead of the
      // selection-based render. Cleared from `.selectionChanged` when
      // a real worktree lands, or implicitly when the row leaves
      // `pendingWorktrees` (cancel / discard).
      case .sidebar(.beginPendingWorktreeCreation(let pending)):
        state.activePendingWorktreeID = pending.id
        return .none

      // Post-completion switch gate. The sidebar has already written the
      // catalog and removed the pending row; it delegates the "switch to
      // the new worktree" decision here because the still-viewing signal
      // (`activePendingWorktreeID`) lives only on this reducer.
      //
      // Switch when EITHER the auto-switch setting is on, OR the user is
      // still viewing this pending creation. The setting is read LIVE at
      // completion time so a mid-flight toggle decides the outcome.
      // "Still viewing" falls out of `activePendingWorktreeID == pendingID`:
      // the clear logic in `.selectionChanged` only fires when a REAL
      // worktree lands, so empty selection or an open aux window (Settings)
      // keep the id set → switch; selecting another real worktree or
      // another pending changes/clears it → stay.
      //
      // A FAILED creation never reaches here (it routes through
      // `pendingWorktreeFailed`), so failure never switches.
      case .sidebar(.delegate(.worktreeMaterialized(let worktreeID, let projectID, let pendingID))):
        let autoSwitch =
          settingsWriter.readSnapshotSync().worktree.autoSwitchToNewWorktree
        let stillViewing = (state.activePendingWorktreeID == pendingID)
        let shouldSelect = autoSwitch || stillViewing
        guard shouldSelect else {
          // No switch: leave the current selection untouched. The pending
          // this id pointed at is gone, so defensively clear the dangling
          // overlay marker (the New-badge write for this branch is a later
          // feature — not here).
          if state.activePendingWorktreeID == pendingID {
            state.activePendingWorktreeID = nil
          }
          return .none
        }
        // Select the project too for cross-project correctness, then the
        // worktree. `selectWorktree` emits a `.selectionChanged` that runs
        // `autoSeedTabAndPaneIfNeeded` (seeds the first tab/pane) and clears
        // `activePendingWorktreeID`.
        hierarchyClient.selectProject(projectID)
        try? hierarchyClient.selectWorktree(worktreeID, projectID)
        return .none

      case .sidebar:
        return .none

      case .tagManagerSheetShown:
        state.tagManagerSheet = TagManagerFeature.State()
        return .none

      case .tagManagerSheet:
        return .none

      case .detail:
        return .none

      // 0014 M2: surface editor-open outcomes in the titlebar status bar.
      // The child `Scope(state: \.editor, ...)` has already mutated
      // `lastOpenResult`; we only fan a toast out. Success shows the chosen
      // editor's display name; failure shows a scrubbed one-line reason.
      case .editor(.openSucceeded(_, let displayName)):
        return .send(.statusBar(.push(.success("Opened in \(displayName)"))))

      case .editor(.openFailed(let reason)):
        return .send(.statusBar(.push(.warning(Self.shortToastMessage(reason)))))

      case .editor(.delegate(.openShellEditorRequested(let worktreePath, let projectID))):
        return .send(
          .openShellEditorInWorktree(worktreePath: worktreePath, projectID: projectID))

      case .editor:
        return .none

      case .worktreeHeader(.delegate(let delegate)):
        switch delegate {
        case .openEditor(let editorID, let worktreePath, let projectID):
          // An explicit pick from the "Open in ▾" submenu is strict; absent that, fall to
          // the shared resolver which returns nil when nothing is installed so the service
          // cascades through the priority list (see `resolveInstalledPreference`).
          let preferred: EditorID? =
            editorID
            ?? EditorFeature.resolveInstalledPreference(
              projectOverride: projectOverrideEditorID(for: projectID),
              globalDefault: state.editor.globalDefault,
              descriptors: state.editor.descriptors
            )
          return .send(
            .editor(
              .openRequested(
                editorID: preferred,
                worktreePath: worktreePath,
                projectID: projectID
              )))

        case .showCustomEditorsSettings:
          let presenter = settingsWindowPresenter
          return .run { _ in await MainActor.run { presenter.open() } }

        case .setProjectOverride(let projectID, let editorID):
          return .send(
            .editor(
              .setProjectOverride(
                projectID: projectID,
                editorID: editorID
              )))

        case .pickEditorFromMenu(let editorID):
          // Resolve worktree path from `state.selection` at handle-time —
          // the SwiftUI Menu's NSMenuItem actions can hold stale closure
          // captures of `worktreePath` after worktree selection changes,
          // which previously routed the open to the project root instead
          // of the active sub-worktree.
          guard
            let projectID = state.selection.projectID,
            let worktreeID = state.selection.worktreeID
          else { return .none }
          let catalog = hierarchyClient.snapshot()
          guard
            let path = catalog
              .projects.first(where: { $0.id == projectID })?
              .worktrees.first(where: { $0.id == worktreeID })?.path
          else { return .none }
          return .merge(
            .send(
              .editor(
                .setProjectOverride(
                  projectID: projectID,
                  editorID: editorID
                ))),
            .send(
              .editor(
                .openRequested(
                  editorID: editorID,
                  worktreePath: path,
                  projectID: projectID
                )))
          )

        case .runScriptRequested(let scriptID):
          // Resolve target Project + Worktree from `state.selection` at
          // handle-time — the SwiftUI Menu's NSMenuItem actions and the
          // `.keyboardShortcut`-bridged chord can hold stale closure
          // captures after a worktree switch, which previously fired the
          // script against the wrong worktree. Same fix pattern as
          // `pickEditorFromMenu` above.
          guard
            let projectID = state.selection.projectID,
            let worktreeID = state.selection.worktreeID
          else { return .none }
          let client = hierarchyClient
          let presenter = settingsWindowPresenter
          return .run { send in
            do {
              try await client.runScript(scriptID, projectID, worktreeID)
            } catch let error as RunScriptError {
              await send(.statusBar(.push(.warning(Self.runScriptErrorMessage(error)))))
              _ = presenter  // Settings is not auto-opened on failure; user can navigate themselves.
            } catch {
              await send(.statusBar(.push(.warning("Run script failed: \(error.localizedDescription)"))))
            }
          }

        case .runGlobalScriptRequested(let scriptID):
          // Same selection-resolution + staleness rationale as
          // `runScriptRequested`, routed through the global run path which
          // resolves the script from `general.globalScripts`.
          guard
            let projectID = state.selection.projectID,
            let worktreeID = state.selection.worktreeID
          else { return .none }
          let client = hierarchyClient
          return .run { send in
            do {
              try await client.runGlobalScript(scriptID, projectID, worktreeID)
            } catch let error as RunScriptError {
              await send(.statusBar(.push(.warning(Self.runScriptErrorMessage(error)))))
            } catch {
              await send(.statusBar(.push(.warning("Run script failed: \(error.localizedDescription)"))))
            }
          }

        case .stopScriptRequested(let scriptID):
          // Same selection-resolution + staleness rationale as
          // `runScriptRequested`. `stopScript` is a synchronous, best-effort
          // MainActor call (sends Ctrl-C to the tracked run pane), so it runs
          // inline like the pane-busy writers rather than through `.run`.
          // Serves both project and global commands (the run pane is keyed by
          // worktree+scriptID).
          guard
            let projectID = state.selection.projectID,
            let worktreeID = state.selection.worktreeID
          else { return .none }
          hierarchyClient.stopScript(scriptID, projectID, worktreeID)
          return .none

        case .manageScriptsRequested(let projectID):
          let presenter = settingsWindowPresenter
          return .run { _ in
            await MainActor.run {
              presenter.openAt(.projectScripts(projectID))
            }
          }

        case .manageGlobalScriptsRequested:
          let presenter = settingsWindowPresenter
          return .run { _ in
            await MainActor.run {
              presenter.openAt(.globalCommands)
            }
          }
        }

      case .worktreeHeader:
        return .none

      // 0014 M3: surface gh mutation outcomes in the status bar. The child
      // `Scope(state: \.gitHub, ...)` has already updated `mutating` / `lastError`;
      // we only fan a toast out. Message format mirrors the sidebar popover's
      // verb so cross-surface language stays consistent.
      case .gitHub(.mergeCompleted(_, let prNumber, .success)):
        return .send(.statusBar(.push(.success("PR #\(prNumber) merged"))))
      case .gitHub(.closeCompleted(_, .success)):
        return .send(.statusBar(.push(.success("PR closed"))))
      case .gitHub(.markReadyCompleted(_, .success)):
        return .send(.statusBar(.push(.success("PR marked ready"))))
      case .gitHub(.rerunFailedJobsCompleted(_, .success)):
        return .send(.statusBar(.push(.success("Re-ran failed jobs"))))

      // Failure cases keep the verb prefix so the user can tell merge / close /
      // mark-ready / rerun-failed-jobs apart in the warning toast.
      case .gitHub(.mergeCompleted(_, _, .failure(let error))):
        let reason = Self.shortToastMessage(String(describing: error))
        return .send(.statusBar(.push(.warning("Merge failed: \(reason)"))))
      case .gitHub(.closeCompleted(_, .failure(let error))):
        let reason = Self.shortToastMessage(String(describing: error))
        return .send(.statusBar(.push(.warning("Close failed: \(reason)"))))
      case .gitHub(.markReadyCompleted(_, .failure(let error))):
        let reason = Self.shortToastMessage(String(describing: error))
        return .send(.statusBar(.push(.warning("Mark ready failed: \(reason)"))))
      case .gitHub(.rerunFailedJobsCompleted(_, .failure(let error))):
        let reason = Self.shortToastMessage(String(describing: error))
        return .send(.statusBar(.push(.warning("Rerun failed: \(reason)"))))

      // 0012: GitHub integration delegate actions. Detailed handling (openURL →
      // NSWorkspace.open, showSettingsGitHub → SettingsWindowPresenter, pullRequestMerged
      // → M7 post-merge Worktree action) moves into `GitHubRootBindings` stacked under the
      // gitHub scope — leaving the inline case a no-op keeps this reducer's switch-body
      // small enough for Swift's type-inference budget.
      case .gitHub:
        return .none

      // 0014: status-bar child scope is self-contained (toast slot + timers).
      // Cross-feature toast emission (editor open, gh mutation completion) lands
      // in subsequent milestones as additional cases BEFORE this catch-all.
      case .statusBar:
        return .none

      // 0008: pane-action router delegate actions.
      // `commandPaletteToggleRequested` forwards the ghostty keybind
      // pipeline into the palette's top-level toggle. `presentTerminal`
      // stays an explicit no-op — the sidebar/detail focus flow already
      // handles active-worktree swaps.
      case .paneActionRouter(.delegate(.commandPaletteToggleRequested(let paneID))):
        return .send(.commandPaletteToggle(paneID))
      case .paneActionRouter(.delegate(.presentTerminalRequested)):
        return .none

      case .paneActionRouter:
        return .none

      case .windowActionRouter:
        return .none

      case .branchSwitcher:
        // Sub-feature transitions handled by the Scope; ignore in root.
        return .none

      case .agentState(.rowTapped(let paneID)):
        // Walk the live catalog to the (project, worktree, tab) chain
        // containing `paneID` and land focus on the pane. Same shape as
        // `.focusHierarchyPath` — re-read snapshot between mutations so
        // a teardown race steers us to the deepest still-existing
        // ancestor rather than committing a doomed selection. Silent
        // no-op when the pane has already left the catalog (close + tap
        // race).
        guard let address = hierarchyClient.addressOf(paneID) else {
          return .none
        }
        hierarchyClient.selectProject(address.projectID)
        guard
          hierarchyClient.snapshot()
            .projects.first(where: { $0.id == address.projectID })?
            .worktrees.contains(where: { $0.id == address.worktreeID }) == true
        else { return .none }
        try? hierarchyClient.selectWorktree(address.worktreeID, address.projectID)
        // Scroll the now-selected worktree into view. Done before the
        // tab/pane guards so a teardown race that drops the tab still leaves
        // the worktree revealed.
        revealWorktreeInSidebar(projectID: address.projectID, state: &state)
        guard
          hierarchyClient.snapshot()
            .projects.first(where: { $0.id == address.projectID })?
            .worktrees.first(where: { $0.id == address.worktreeID })?
            .tabs.contains(where: { $0.id == address.tabID }) == true
        else { return .none }
        try? hierarchyClient.selectTab(address.tabID, address.worktreeID, address.projectID)
        guard
          hierarchyClient.snapshot()
            .projects.first(where: { $0.id == address.projectID })?
            .worktrees.first(where: { $0.id == address.worktreeID })?
            .tabs.first(where: { $0.id == address.tabID })?
            .flatPaneIDs.contains(paneID) == true
        else { return .none }
        try? hierarchyClient.focusPane(
          paneID, address.tabID, address.worktreeID, address.projectID
        )
        hierarchyClient.focusSurfaceView(paneID)
        return .none

      case .agentState(.dismissRequested):
        // Reserved for future direct close-from-reducer paths (e.g. a
        // ⌘W variant that closes the popover before the chord routes
        // elsewhere). The view manages its own presentation state
        // today; landing here is a no-op rather than an error so
        // future call sites don't blow up.
        return .none

      case .commandPaletteToggle(let sourcePaneID):
        if state.commandPalette == nil {
          state.commandPalette = CommandPaletteFeature.State()
          let selection = state.selection
          let catalog = hierarchyClient.snapshot()
          let descriptors = state.editor.descriptors
          let recency = CommandPaletteRecencyPersistence.load()
          // Menu-triggered palette opens have no source pane; fall back
          // to the first leaf of the selected tab's split tree so Window-
          // scoped actions still resolve to the correct NSWindow.
          // Pane-scoped palette items that depend on real focus are
          // omitted by the builder when the source is a leaf fallback.
          // Prefer the tab's last-focused pane as the fallback so menu-
          // triggered palette opens still anchor split / focus / zoom on
          // the pane the user actually worked in. `lastFocusedPane`
          // mirrors the same per-tab focus libghostty owns, so a fallback
          // that hits it is as precise as the keybind pipeline.
          let activeTabID = catalog
            .projects.first(where: { $0.id == selection.projectID })?
            .worktrees.first(where: { $0.id == selection.worktreeID })?
            .selectedTabID
          let lastFocused = activeTabID.flatMap { hierarchyClient.lastFocusedPane($0) }
          let fallbackPaneID = CommandPaletteItems.resolveFocusedPaneID(
            selection: selection, catalog: catalog,
            lastFocusedPane: { _ in lastFocused }
          )
          let resolvedPaneID = sourcePaneID ?? fallbackPaneID
          let paneSourceIsPrecise =
            sourcePaneID != nil || (lastFocused != nil && fallbackPaneID == lastFocused)
          return .send(
            .commandPalette(
              .presented(
                .appeared(
                  selection, catalog, descriptors, recency,
                  resolvedPaneID, paneSourceIsPrecise
                )
              )
            )
          )
        } else {
          // Closing without activating: persist any pruning the child
          // did on `.appeared` so stale entries don't re-surface on the
          // next open. Activation path already persists via the
          // `.activate` branch above.
          if let recency = state.commandPalette?.recency {
            CommandPaletteRecencyPersistence.save(recency)
          }
          state.commandPalette = nil
          return .none
        }

      case .commandPalette(.presented(.delegate(.activate(let kind)))):
        if let recency = state.commandPalette?.recency {
          CommandPaletteRecencyPersistence.save(recency)
        }
        let sourcePaneID = state.commandPalette?.focusedPaneID
        state.commandPalette = nil
        return route(kind, state: &state, sourcePaneID: sourcePaneID)

      case .commandPalette(.dismiss):
        state.commandPalette = nil
        return .none

      case .commandPalette:
        return .none

      case .diffInspectorToggledForCurrentWorktree:
        guard
          let projectID = state.selection.projectID,
          let worktreeID = state.selection.worktreeID
        else { return .none }
        // Git Viewer resolution for the ⌘⌥G chord / menu / palette: read the
        // global `general.defaultGitViewerID`. `nil` (Default Git Viewer =
        // None) or an id that no longer resolves to an installed descriptor
        // makes the chord a no-op — the built-in overlay no longer exists.
        let snapshot = settingsWriter.readSnapshotSync()
        let resolvedID = snapshot.general.defaultGitViewerID
        guard
          let externalChoice = resolvedID,
          state.editor.descriptors.contains(where: { $0.id == externalChoice })
        else { return .none }
        let catalog = hierarchyClient.snapshot()
        guard
          let path = catalog
            .projects.first(where: { $0.id == projectID })?
            .worktrees.first(where: { $0.id == worktreeID })?.path
        else { return .none }
        return .send(
          .editor(
            .openRequested(
              editorID: externalChoice,
              worktreePath: path,
              projectID: projectID
            )))

      case .openDefaultForCurrentWorktreeRequested:
        guard
          let projectID = state.selection.projectID,
          let worktreeID = state.selection.worktreeID
        else { return .none }
        let catalog = hierarchyClient.snapshot()
        guard
          let path = catalog
            .projects.first(where: { $0.id == projectID })?
            .worktrees.first(where: { $0.id == worktreeID })?.path
        else { return .none }
        return .send(
          .editor(
            .openDefaultInCurrentWorktreeRequested(
              projectID: projectID,
              worktreeID: worktreeID,
              worktreePath: path
            )))

      case .openCurrentPRRequested:
        guard
          let worktreeID = state.selection.worktreeID,
          let snapshot = state.gitHub.snapshots[worktreeID]
        else { return .none }
        return .send(.gitHub(.delegate(.openURL(snapshot.url))))

      case .openCurrentProjectOnGitHubRequested:
        guard let projectID = state.selection.projectID else { return .none }
        // Prefer the cached batched-PR snapshot when present — it already holds
        // a parsed `(host, owner, repo)` triple, so we skip the subprocess.
        if let cached = state.gitHub.snapshotsByProject[projectID],
          let url = URL(string: "https://\(cached.host)/\(cached.owner)/\(cached.repo)")
        {
          return .send(.gitHub(.delegate(.openURL(url))))
        }
        let catalog = hierarchyClient.snapshot()
        guard
          let project = catalog.projects.first(where: { $0.id == projectID }),
          let gitRootPath = project.gitRoot
        else { return .none }
        let gitRoot = URL(fileURLWithPath: gitRootPath)
        return .run { [gitService = gitServiceClient] send in
          guard let info = try? await gitService.remoteInfo(gitRoot) else { return }
          guard
            let url = URL(string: "https://\(info.host)/\(info.owner)/\(info.repo)")
          else { return }
          await send(.gitHub(.delegate(.openURL(url))))
        }

      case .newWorktreeForCurrentProjectRequested:
        guard let projectID = state.selection.projectID else { return .none }
        return .send(.sidebar(.projectAddWorktreeTapped(projectID: projectID)))

      case .splitCurrentPaneRequested(let direction):
        guard
          let projectID = state.selection.projectID,
          let worktreeID = state.selection.worktreeID
        else { return .none }
        return .send(
          .detail(
            .tabBar(
              .trailingSplitRequested(
                direction: direction,
                inWorktree: worktreeID, inProject: projectID
              ))))

      case .focusAdjacentPaneInCurrentTabRequested(let direction):
        // Resolve the active tab from the selection, then prefer its
        // remembered focused pane so the neighbor walk starts from where
        // the user actually is — falling back to the leftmost leaf when no
        // pane has been focused yet (freshly selected tab). Dispatching
        // through the router lets libghostty's built-in `goto_split` chord
        // and our menu chord share the exact same effect.
        guard
          let projectID = state.selection.projectID,
          let worktreeID = state.selection.worktreeID
        else { return .none }
        let catalog = hierarchyClient.snapshot()
        guard
          let worktree = catalog
            .projects.first(where: { $0.id == projectID })?
            .worktrees.first(where: { $0.id == worktreeID }),
          let tabID = worktree.selectedTabID,
          let tab = worktree.tabs.first(where: { $0.id == tabID })
        else { return .none }
        let paneID =
          hierarchyClient.lastFocusedPane(tabID)
          ?? tab.splitTree.leaves().first
        guard let paneID else { return .none }
        return .send(
          .paneActionRouter(.requested(paneID, .gotoSplit(direction: direction))))

      case .focusHierarchyPath(let source):
        // Walk the source path against the *live* catalog, re-reading the
        // snapshot between each `select*` mutation so a tab autoclose or
        // pane teardown that lands mid-walk steers us to the deepest
        // still-existing ancestor (G3 fallback) rather than an empty leaf.
        // Holding a single `let catalog =` across mutations would tell us
        // a deleted node still exists — see review notes.
        guard hierarchyClient.snapshot().projects.contains(where: { $0.id == source.projectID }) else {
          return .none
        }
        hierarchyClient.selectProject(source.projectID)

        guard
          let project = hierarchyClient.snapshot()
            .projects.first(where: { $0.id == source.projectID }),
          let targetWorktree = project.worktrees.first(where: { $0.id == source.worktreeID })
        else {
          return .none
        }
        // Refuse to navigate into an archived worktree. The row is hidden
        // from the sidebar and selecting it would persist a stale
        // `project.selectedWorktreeID = <archived>` that snaps focus back
        // to a closed pane on the next launch — and surfaces a non-
        // navigable target via the StatusBar notification taps.
        guard !targetWorktree.archived else { return .none }
        try? hierarchyClient.selectWorktree(source.worktreeID, source.projectID)
        // Scroll the deep-linked worktree into view before the tab/pane
        // guards so a teardown race still leaves the worktree revealed.
        revealWorktreeInSidebar(projectID: source.projectID, state: &state)

        guard
          let worktree = hierarchyClient.snapshot()
            .projects.first(where: { $0.id == source.projectID })?
            .worktrees.first(where: { $0.id == source.worktreeID }),
          worktree.tabs.contains(where: { $0.id == source.tabID })
        else {
          return .none
        }
        try? hierarchyClient.selectTab(source.tabID, source.worktreeID, source.projectID)

        guard
          let tab = hierarchyClient.snapshot()
            .projects.first(where: { $0.id == source.projectID })?
            .worktrees.first(where: { $0.id == source.worktreeID })?
            .tabs.first(where: { $0.id == source.tabID }),
          tab.flatPaneIDs.contains(source.paneID)
        else {
          return .none
        }
        try? hierarchyClient.focusPane(
          source.paneID, source.tabID, source.worktreeID, source.projectID
        )
        hierarchyClient.focusSurfaceView(source.paneID)
        return .none

      case .openShellEditorInWorktree(let worktreePath, let projectIDHint):
        let catalog = hierarchyClient.snapshot()
        guard
          let address = Self.findWorktreeAddress(
            worktreePath: worktreePath, projectIDHint: projectIDHint, in: catalog)
        else {
          return .send(
            .editor(.openFailed(reason: "Could not locate worktree at \(worktreePath)")))
        }
        let (projectID, worktreeID) = address
        guard
          let tabID = try? hierarchyClient.createTab(worktreeID, projectID, nil)
        else {
          return .send(.editor(.openFailed(reason: "Could not create tab for $EDITOR")))
        }
        // openPane is async (zmx daemon spawn); thread through an Effect so the
        // post-spawn selection and success notification happen after the pane
        // is wired into the catalog. On openPane failure the editor open is
        // reported as failed instead of half-succeeded.
        return .run { [client = hierarchyClient] send in
          do {
            _ = try await client.openPane(
              tabID, worktreeID, projectID, worktreePath, "$EDITOR")
          } catch {
            await send(.editor(.openFailed(reason: "Could not spawn $EDITOR pane")))
            return
          }
          // Bring the user to the freshly spawned Pane. Selecting after the catalog
          // mutation lets `autoSeedTabAndPaneIfNeeded` (driven by selectionChanges)
          // see the populated tab and skip its own seed.
          await MainActor.run {
            client.selectProject(projectID)
            try? client.selectWorktree(worktreeID, projectID)
            try? client.selectTab(tabID, worktreeID, projectID)
          }
          await send(
            .editor(.openSucceeded(editorID: EditorRegistry.shellEditorID, displayName: "$EDITOR")))
        }

      case .newTabForCurrentWorktree:
        guard
          let projectID = state.selection.projectID,
          let worktreeID = state.selection.worktreeID
        else { return .none }
        return .send(
          .detail(
            .tabBar(
              .newTabButtonTapped(
                inWorktree: worktreeID, inProject: projectID
              ))))

      case .closeActiveTabForCurrentWorktree:
        guard
          let projectID = state.selection.projectID,
          let worktreeID = state.selection.worktreeID
        else { return .none }
        let catalog = hierarchyClient.snapshot()
        guard
          let worktree = catalog
            .projects.first(where: { $0.id == projectID })?
            .worktrees.first(where: { $0.id == worktreeID }),
          let activeTabID = worktree.selectedTabID,
          let activeTab = worktree.tabs.first(where: { $0.id == activeTabID })
        else { return .none }
        // Multi-pane tab: ⌘W closes just the focused pane, leaving the tab
        // open with its remaining panes (matches iTerm/Terminal.app). Single
        // (or zero) pane: fall through and close the whole tab.
        if activeTab.panes.count > 1 {
          let focusID =
            hierarchyClient.lastFocusedPane(activeTabID)
            ?? activeTab.splitTree.leaves().first
          if let focusID {
            try? hierarchyClient.closePane(
              focusID, activeTabID, worktreeID, projectID
            )
          }
          return .none
        }
        return .send(
          .detail(
            .tabBar(
              .closeButtonTapped(
                activeTabID, inWorktree: worktreeID, inProject: projectID
              ))))

      case .selectTabAtIndexForCurrentWorktree(let n):
        guard
          n >= 1,
          let projectID = state.selection.projectID,
          let worktreeID = state.selection.worktreeID
        else { return .none }
        let catalog = hierarchyClient.snapshot()
        guard
          let worktree = catalog
            .projects.first(where: { $0.id == projectID })?
            .worktrees.first(where: { $0.id == worktreeID }),
          n <= worktree.tabs.count
        else { return .none }
        let targetTabID = worktree.tabs[n - 1].id
        return .send(
          .detail(
            .tabBar(
              .tabButtonTapped(
                targetTabID, inWorktree: worktreeID, inProject: projectID
              ))))

      case .selectAdjacentTabForCurrentWorktree(let direction):
        guard
          let projectID = state.selection.projectID,
          let worktreeID = state.selection.worktreeID
        else { return .none }
        // Selection mutation lives in HierarchyManager — no TabBarFeature
        // action to forward since there's no TabID to look up yet.
        _ = try? hierarchyClient.selectAdjacentTab(direction, worktreeID, projectID)
        return .none

      case .renameActiveTabForCurrentWorktreeRequested:
        guard
          let projectID = state.selection.projectID,
          let worktreeID = state.selection.worktreeID
        else { return .none }
        let catalog = hierarchyClient.snapshot()
        guard
          let worktree = catalog
            .projects.first(where: { $0.id == projectID })?
            .worktrees.first(where: { $0.id == worktreeID }),
          let activeTabID = worktree.selectedTabID,
          let activeTab = worktree.tabs.first(where: { $0.id == activeTabID })
        else { return .none }
        return .send(
          .detail(
            .tabBar(
              .renameRequested(activeTabID, currentName: activeTab.name ?? "")
            )))

      case .changeActiveTabColorForCurrentWorktreeRequested:
        guard
          let projectID = state.selection.projectID,
          let worktreeID = state.selection.worktreeID
        else { return .none }
        let catalog = hierarchyClient.snapshot()
        guard
          let worktree = catalog
            .projects.first(where: { $0.id == projectID })?
            .worktrees.first(where: { $0.id == worktreeID }),
          let activeTabID = worktree.selectedTabID,
          let activeTab = worktree.tabs.first(where: { $0.id == activeTabID })
        else { return .none }
        return .send(
          .detail(
            .tabBar(
              .colorRequested(activeTabID, currentColor: activeTab.color)
            )))

      case .revealCurrentWorktreeInFinderRequested:
        guard
          let projectID = state.selection.projectID,
          let worktreeID = state.selection.worktreeID
        else { return .none }
        let catalog = hierarchyClient.snapshot()
        guard
          let path = catalog
            .projects.first(where: { $0.id == projectID })?
            .worktrees.first(where: { $0.id == worktreeID })?.path
        else { return .none }
        let client = finderClient
        return .run { _ in await MainActor.run { client.reveal(path) } }

      case .archiveCurrentWorktreeRequested:
        guard
          let projectID = state.selection.projectID,
          let worktreeID = state.selection.worktreeID
        else { return .none }
        let catalog = hierarchyClient.snapshot()
        let name =
          catalog
          .projects.first(where: { $0.id == projectID })?
          .worktrees.first(where: { $0.id == worktreeID })?.name ?? ""
        return .send(
          .sidebar(
            .worktreeArchiveTapped(
              worktreeID: worktreeID, inProject: projectID, name: name
            )
          )
        )

      case .deleteCurrentWorktreeRequested:
        guard
          let projectID = state.selection.projectID,
          let worktreeID = state.selection.worktreeID
        else { return .none }
        let catalog = hierarchyClient.snapshot()
        let name =
          catalog
          .projects.first(where: { $0.id == projectID })?
          .worktrees.first(where: { $0.id == worktreeID })?.name ?? ""
        return .send(
          .sidebar(
            .worktreeRemoveTapped(
              worktreeID: worktreeID, inProject: projectID, name: name
            )
          )
        )

      case .showArchivedWorktreesForCurrentProjectRequested:
        guard let projectID = state.selection.projectID else { return .none }
        return .send(.sidebar(.projectShowArchivedTapped(projectID: projectID)))

      case .checkForUpdatesRequested:
        return .send(.windowActionRouter(.requested(.checkForUpdates)))

      case .showUnreadRequested:
        state.inboxBellPopoverTrigger = UUID()
        return .none

      case .copyCurrentWorktreePathRequested:
        guard
          let projectID = state.selection.projectID,
          let worktreeID = state.selection.worktreeID
        else { return .none }
        let catalog = hierarchyClient.snapshot()
        guard
          let path = catalog
            .projects.first(where: { $0.id == projectID })?
            .worktrees.first(where: { $0.id == worktreeID })?.path
        else { return .none }
        return .run { _ in
          await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
          }
        }

      case .toggleSidebarRequested:
        state.sidebarVisible.toggle()
        return .none

      case .revealCurrentWorktreeInSidebarRequested:
        state.sidebarVisible = true
        state.revealSelectionTrigger = UUID()
        return .none

      case .selectAdjacentWorktreeRequested(let direction):
        let catalog = hierarchyClient.snapshot()
        let order = Self.flattenedWorktreeOrder(in: catalog)
        guard !order.isEmpty else { return .none }
        let currentIndex =
          order.firstIndex(where: { $0.worktreeID == state.selection.worktreeID }) ?? -1
        let count = order.count
        let nextIndex: Int
        switch direction {
        case .next:
          nextIndex = currentIndex < 0 ? 0 : (currentIndex + 1) % count
        case .previous:
          nextIndex = currentIndex < 0 ? count - 1 : (currentIndex - 1 + count) % count
        }
        let target = order[nextIndex]
        return .send(
          .sidebar(.worktreeRowTapped(target.worktreeID, inProject: target.projectID))
        )

      case .worktreeHistoryBackRequested:
        guard let target = state.navigationHistoryBack.popLast() else { return .none }
        state.navigationHistoryForward.append(state.selection)
        state.suppressHistoryPush = true
        guard
          let projectID = target.projectID,
          let worktreeID = target.worktreeID
        else { return .none }
        // After navigating, reveal the new selection in the sidebar so users
        // see where ⌘⌃[ landed instead of having to scroll for it (HAN-68).
        state.sidebarVisible = true
        state.revealSelectionTrigger = UUID()
        return .send(.sidebar(.worktreeRowTapped(worktreeID, inProject: projectID)))

      case .worktreeHistoryForwardRequested:
        guard let target = state.navigationHistoryForward.popLast() else { return .none }
        state.navigationHistoryBack.append(state.selection)
        state.suppressHistoryPush = true
        guard
          let projectID = target.projectID,
          let worktreeID = target.worktreeID
        else { return .none }
        // After navigating, reveal the new selection in the sidebar so users
        // see where ⌘⌃] landed instead of having to scroll for it (HAN-68).
        state.sidebarVisible = true
        state.revealSelectionTrigger = UUID()
        return .send(.sidebar(.worktreeRowTapped(worktreeID, inProject: projectID)))
      }
    }
    .ifLet(\.$commandPalette, action: \.commandPalette) {
      CommandPaletteFeature()
    }
    .ifLet(\.$tagManagerSheet, action: \.tagManagerSheet) {
      TagManagerFeature()
    }
  }

  /// Reveal the just-selected worktree in the sidebar: expand its parent
  /// project so the row renders, force the sidebar visible, and bump
  /// `revealSelectionTrigger` so the sidebar's `onChange` scrolls the row
  /// into view. Shared by every "jump to a worktree" entry point (command
  /// palette, Agents-panel row tap, notification deep-link) so a target
  /// that's scrolled off-screen or hidden under a collapsed project always
  /// comes into view. The sidebar reads the scroll target from the live
  /// catalog, so callers must have already committed the worktree selection.
  private func revealWorktreeInSidebar(projectID: ProjectID, state: inout State) {
    hierarchyClient.setProjectExpanded(projectID, true)
    state.sidebarVisible = true
    state.revealSelectionTrigger = UUID()
  }

  // swiftlint:disable cyclomatic_complexity
  /// Dispatches a Command Palette activation into the feature action
  /// that already implements the command. Every case forwards into a
  /// pre-existing action or client — the palette invents no new
  /// behavior.
  private func route(
    _ kind: CommandPaletteItem.Kind,
    state: inout State,
    sourcePaneID: PaneID?
  ) -> Effect<Action> {
    switch kind {
    // App
    case .openSettings:
      let presenter = settingsWindowPresenter
      return .run { _ in await MainActor.run { presenter.open() } }
    case .checkForUpdates:
      return .send(.checkForUpdatesRequested)
    case .quit:
      return .send(.windowActionRouter(.requested(.quit)))

    // Worktree
    case .selectWorktree(let projectID, let worktreeID):
      // The palette is keyboard-only, so the user can't act on a highlighted
      // row that's scrolled off-screen or hidden under a collapsed project —
      // reveal it. Selection itself still routes through the sidebar.
      revealWorktreeInSidebar(projectID: projectID, state: &state)
      return .send(
        .sidebar(.worktreeRowTapped(worktreeID, inProject: projectID))
      )
    case .closeCurrentWorktree:
      return .send(.deleteCurrentWorktreeRequested)
    case .refreshCurrentWorktree:
      guard let projectID = state.selection.projectID else { return .none }
      return .run { [projectReconciler, client = hierarchyClient] send in
        await projectReconciler.reconcile(projectID: projectID)
        if let action = await MainActor.run(body: {
          Self.makeActiveProjectGitHubRefresh(client: client)
        }) {
          await send(.gitHub(action))
        }
      }
    case .toggleDiffInspector:
      return .send(.diffInspectorToggledForCurrentWorktree)

    // Editor
    case .openCurrentWorktreeInDefaultEditor:
      return .send(.openDefaultForCurrentWorktreeRequested)
    case .openCurrentWorktreeIn(let editorID):
      guard let projectID = state.selection.projectID,
        let worktreeID = state.selection.worktreeID
      else { return .none }
      let catalog = hierarchyClient.snapshot()
      guard
        let path = catalog
          .projects.first(where: { $0.id == projectID })?
          .worktrees.first(where: { $0.id == worktreeID })?.path
      else { return .none }
      return .send(
        .editor(
          .openRequested(
            editorID: editorID, worktreePath: path, projectID: projectID
          )
        )
      )
    case .revealCurrentWorktreeInFinder:
      return .send(.revealCurrentWorktreeInFinderRequested)

    // Project scripts (Phase 2 / M10) — palette item carries the
    // (projectID, worktreeID, scriptID) triple, fan out into the same
    // run-script effect the WorktreeHeader split-button and the Scripts
    // pane Run button use, so failure handling stays in one place.
    case .runProjectScript(let projectID, let worktreeID, let scriptID):
      let client = hierarchyClient
      return .run { send in
        do {
          try await client.runScript(scriptID, projectID, worktreeID)
        } catch let error as RunScriptError {
          await send(.statusBar(.push(.warning(Self.runScriptErrorMessage(error)))))
        } catch {
          await send(.statusBar(.push(.warning("Run script failed: \(error.localizedDescription)"))))
        }
      }

    // Global commands — palette item carries the (projectID, worktreeID,
    // scriptID) triple; fan out into the same global run-script effect the
    // WorktreeHeader split-button uses, so failure handling stays in one place.
    case .runGlobalScript(let projectID, let worktreeID, let scriptID):
      let client = hierarchyClient
      return .run { send in
        do {
          try await client.runGlobalScript(scriptID, projectID, worktreeID)
        } catch let error as RunScriptError {
          await send(.statusBar(.push(.warning(Self.runScriptErrorMessage(error)))))
        } catch {
          await send(.statusBar(.push(.warning("Run script failed: \(error.localizedDescription)"))))
        }
      }

    // Pane / Window — thin wrappers over the routers
    case .paneAction(let req):
      guard
        let paneID = sourcePaneID
          ?? CommandPaletteItems.resolveFocusedPaneID(
            selection: state.selection, catalog: hierarchyClient.snapshot(),
            lastFocusedPane: { hierarchyClient.lastFocusedPane($0) }
          )
      else { return .none }
      return .send(.paneActionRouter(.requested(paneID, req)))
    case .windowAction(let req):
      return .send(.windowActionRouter(.requested(req)))
    }
  }
  // swiftlint:enable cyclomatic_complexity

  /// Per-Project editor override, if any. Used to resolve the Header's
  /// default-editor dispatch through `EditorFeature.resolveDefault` without
  /// the reducer needing to hold a second cache of the catalog. v3 moved
  /// the override off catalog.json; read via `SettingsWriter`'s sync
  /// snapshot closure (itself MainActor-assumed internally).
  private func projectOverrideEditorID(for projectID: ProjectID?) -> EditorID? {
    guard let projectID else { return nil }
    return settingsWriter.readSnapshotSync().projects[projectID]?.defaultEditor
  }

  /// Walks `catalog` to find the `(ProjectID, WorktreeID)` pair whose Worktree
  /// has the given path. Used by the `.openShellEditorInWorktree` handler to recover
  /// the full address from the path-only handoff that propagates through the editor
  /// open chain. The optional `projectIDHint` short-circuits the project loop when the
  /// caller already knows the parent.
  nonisolated static func findWorktreeAddress(
    worktreePath: String,
    projectIDHint: ProjectID?,
    in catalog: Catalog
  ) -> (ProjectID, WorktreeID)? {
    for project in catalog.projects {
      if let hint = projectIDHint, project.id != hint { continue }
      if let worktree = project.worktrees.first(where: { $0.path == worktreePath }) {
        return (project.id, worktree.id)
      }
    }
    return nil
  }

  /// Ensures the selected Worktree has at least one Tab, and the active
  /// Tab has at least one Pane. Both spawn with `cwd = worktree.path` so
  /// the terminal lands in the correct directory. Idempotent: skips when
  /// the Worktree already has tabs / the tab already has panes.
  ///
  /// Runs on every `.selectionChanged`. Mutations do not change the
  /// selection tuple `(space, project, worktree)`, so the downstream
  /// stream does not re-fire and there is no loop.
  private func autoSeedTabAndPaneIfNeeded(for selection: HierarchySelection) {
    guard
      let projectID = selection.projectID,
      let worktreeID = selection.worktreeID
    else { return }
    let catalog = hierarchyClient.snapshot()
    guard
      let project = catalog.projects.first(where: { $0.id == projectID }),
      let worktree = project.worktrees.first(where: { $0.id == worktreeID })
    else { return }
    let cwd = worktree.path
    if worktree.tabs.isEmpty {
      guard let tabID = try? hierarchyClient.createTab(worktreeID, projectID, nil)
      else { return }
      // Auto-seed runs from a synchronous reducer body; `openPane` is now
      // async (zmx daemon bringup). Fire-and-forget — the result is unused
      // and PaneHostFeature reports any bring-up error to the user via its
      // own `.failed` phase.
      let client = hierarchyClient
      Task { @MainActor in
        _ = try? await client.openPane(tabID, worktreeID, projectID, cwd, nil)
      }
      return
    }
    let activeTabID = worktree.selectedTabID ?? worktree.tabs.first?.id
    guard let activeTabID,
      let tab = worktree.tabs.first(where: { $0.id == activeTabID }),
      tab.panes.isEmpty
    else { return }
    let client = hierarchyClient
    Task { @MainActor in
      _ = try? await client.openPane(activeTabID, worktreeID, projectID, cwd, nil)
    }
  }

  /// Rebuilds `SplitViewportFeature.State.paneHosts` for the selection's
  /// active Tab in the same reducer tick, eagerly marking entries `.ready`
  /// when the engine already holds a live surface for the pane. Without
  /// this, the first render after a Worktree switch sees a stale
  /// `paneHosts` (still keyed by the previous Worktree's PaneIDs), which
  /// forces `LeafView`'s `store.scope(...)` lookup to return nil and
  /// render a `ProgressView` placeholder — the visible "flash" on
  /// cross-Worktree navigation. Preserving entries carried from the prior
  /// selection keeps any pending `.failed` / `.retry` state intact when
  /// the same pane re-enters the viewport (e.g. tab-bar cycle).
  private func reconcilePaneHosts(
    _ splitViewport: inout SplitViewportFeature.State,
    selection: HierarchySelection,
    tabID: TabID?
  ) {
    guard
      let projectID = selection.projectID,
      let worktreeID = selection.worktreeID,
      let tabID
    else {
      splitViewport.paneHosts = []
      return
    }
    let catalog = hierarchyClient.snapshot()
    guard
      let tab = catalog
        .projects.first(where: { $0.id == projectID })?
        .worktrees.first(where: { $0.id == worktreeID })?
        .tabs.first(where: { $0.id == tabID })
    else {
      splitViewport.paneHosts = []
      return
    }
    let existing = splitViewport.paneHosts
    splitViewport.paneHosts = IdentifiedArray(
      uniqueElements: tab.panes.map { pane in
        if let carry = existing[id: pane.id] { return carry }
        var seeded = PaneHostFeature.State(
          paneID: pane.id,
          tabID: tabID,
          worktreeID: worktreeID,
          projectID: projectID
        )
        if let surface = terminalClient.surface(pane.id) {
          seeded.phase = .ready
          seeded.surface = SurfaceBox(surface: surface)
        }
        return seeded
      }
    )
  }

  /// Collapses a potentially multi-line error / warning string into a single
  /// status-bar-sized line. Keeps the first line (trimmed) and caps at 80
  /// characters so paths, tokens, and shell noise inside an `EditorError`
  /// don't bleed into the titlebar.
  ///
  /// The 80-char limit is not PII scrubbing per se — it's UX width. Upstream
  /// callers are responsible for not stuffing secrets into error messages;
  /// `EditorFeature.editorErrorDescription` already emits short friendly
  /// strings, so the truncation here is usually a no-op.
  static func shortToastMessage(_ raw: String) -> String {
    let firstLine = raw.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? raw
    let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > 80 else { return trimmed }
    let cutoff = trimmed.index(trimmed.startIndex, offsetBy: 79)
    return String(trimmed[..<cutoff]) + "…"
  }

  static func runScriptErrorMessage(_ error: RunScriptError) -> String {
    switch error {
    case .unknownScript:
      return "Run script failed: script no longer exists"
    case .missingWorktree:
      return "Run script failed: worktree not available"
    case .missingProject:
      return "Run script failed: project not available"
    }
  }

  /// Resolve the active tab for a selection using the snapshot from the
  /// hierarchy client. The snapshot is synchronously available because
  /// `HierarchyClient.snapshot` forwards `hierarchyManager.catalog` which
  /// is updated on the MainActor before `selectionChanges` yields.
  private func resolveActiveTab(selection: HierarchySelection) -> TabID? {
    let catalog = hierarchyClient.snapshot()
    guard
      let projectID = selection.projectID,
      let worktreeID = selection.worktreeID,
      let project = catalog.projects.first(where: { $0.id == projectID }),
      let worktree = project.worktrees.first(where: { $0.id == worktreeID })
    else { return nil }
    return worktree.selectedTabID
  }

  /// Locates a `Project` in the current catalog snapshot by `projectID`.
  private func lookupProject(projectID: ProjectID) -> Project? {
    let catalog = hierarchyClient.snapshot()
    return catalog.projects.first(where: { $0.id == projectID })
  }

  /// Builds the `.gitHub(.projectActivated)` follow-up that runs after a
  /// reconcile sweep so PR data tracks worktree-branch changes (HAN-62).
  /// Reconcile updates `Worktree.branch` when `git checkout` lands inside
  /// a pane; GitHubFeature's internal freshness check (30s) plus branch-
  /// set diff (`isCacheFreshAndComplete`) decides whether the dispatch
  /// triggers a fetch or no-ops. Returns nil when there is no active
  /// project or the active project has no git root yet.
  ///
  /// `@MainActor` because `hierarchyClient.snapshot()` is main-isolated;
  /// callers in `.run` closures bridge via `MainActor.run`.
  @MainActor
  static func makeActiveProjectGitHubRefresh(
    client: HierarchyClient
  ) -> GitHubFeature.Action? {
    let catalog = client.snapshot()
    guard let projectID = catalog.selectedProjectID,
      let project = catalog.projects.first(where: { $0.id == projectID }),
      let gitRootString = project.gitRoot
    else { return nil }
    let gitRoot = URL(fileURLWithPath: gitRootString)
    let pairs = project.worktrees.compactMap { worktree -> GitHubFeature.Action.WorktreeBranchPair? in
      guard !worktree.archived, let branch = worktree.branch, !branch.isEmpty
      else { return nil }
      return GitHubFeature.Action.WorktreeBranchPair(
        worktreeID: worktree.id, branch: branch
      )
    }
    return .projectActivated(projectID, gitRoot: gitRoot, worktreeBranches: pairs)
  }

  /// Builds the `.gitHub(.pollTargetChanged)` that drives the active-Project liveness
  /// poll (0018 M1). Returns a paused target (`nil`) when the app is not frontmost or
  /// there is no active Project with a git root; otherwise targets the active Project.
  /// Mirrors `makeActiveProjectGitHubRefresh`'s catalog walk so the poll tracks the same
  /// branch set the immediate refresh fetches.
  ///
  /// `@MainActor` because `client.snapshot()` is main-isolated; callers in `.run`
  /// closures bridge via `MainActor.run`.
  @MainActor
  static func makePollTargetChange(
    client: HierarchyClient, appActive: Bool
  ) -> GitHubFeature.Action {
    let paused = GitHubFeature.Action.pollTargetChanged(
      nil, gitRoot: nil, worktreeBranches: []
    )
    guard appActive else { return paused }
    let catalog = client.snapshot()
    guard let projectID = catalog.selectedProjectID,
      let project = catalog.projects.first(where: { $0.id == projectID }),
      let gitRootString = project.gitRoot
    else { return paused }
    let gitRoot = URL(fileURLWithPath: gitRootString)
    let pairs = project.worktrees.compactMap { worktree -> GitHubFeature.Action.WorktreeBranchPair? in
      guard !worktree.archived, let branch = worktree.branch, !branch.isEmpty
      else { return nil }
      return GitHubFeature.Action.WorktreeBranchPair(
        worktreeID: worktree.id, branch: branch
      )
    }
    return .pollTargetChanged(projectID, gitRoot: gitRoot, worktreeBranches: pairs)
  }

  /// Flat list of (projectID, worktreeID) tuples in the order the sidebar
  /// renders: projects in catalog order; within each project, main row
  /// first, then pinned, then unpinned. Archived rows are excluded — they
  /// only appear in the Archived sheet, not the navigable list.
  static func flattenedWorktreeOrder(
    in catalog: Catalog
  ) -> [(projectID: ProjectID, worktreeID: WorktreeID)] {
    var result: [(projectID: ProjectID, worktreeID: WorktreeID)] = []
    for project in catalog.projects {
      let visible = project.worktrees.filter { !$0.archived }
      let main = visible.filter { $0.path == project.rootPath }
      let pinned = visible.filter { $0.isPinned && $0.path != project.rootPath }
      let unpinned = visible.filter { !$0.isPinned && $0.path != project.rootPath }
      for worktree in main + pinned + unpinned {
        result.append((projectID: project.id, worktreeID: worktree.id))
      }
    }
    return result
  }

}
