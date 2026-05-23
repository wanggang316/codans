import AppKit
import ComposableArchitecture
import Foundation
import GhosttyKit
import TouchCodeCore

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

    var sidebar: HierarchySidebarFeature.State = .init()
    var detail: WorktreeDetailFeature.State = .init()
    /// C8 M6b (0005): editor preferences + per-Project override state.
    var editor: EditorFeature.State = .init()
    /// T2: Header feature (bell + Open-in split button + GV toggle).
    var worktreeHeader: WorktreeHeaderFeature.State = .init()
    /// 0012: GitHub integration — per-Worktree PR snapshots + popover state.
    var gitHub: GitHubFeature.State = .init()
    /// 0014: titlebar-center Worktree Status Bar — owns only the transient
    /// toast slot; PR / motivational forms are view-level projections.
    var statusBar: StatusBarFeature.State = .init()
    /// Diff inspector + drawer. Receives `worktreeSelected` forwarding from
    /// `selectionChanged` below so the changed-files list refreshes when the
    /// user navigates between Worktrees.
    var diff: DiffFeature.State = .init()
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

    /// T3: live read of the current Worktree's `diffInspectorVisible` against
    /// a catalog snapshot. Not a cached field — views pass in
    /// `hierarchyManager.catalog` so SwiftUI's `@Observable` tracking
    /// re-renders on catalog mutation from any writer (⌘⇧G, Header GV
    /// button, external API). This avoids the state-divergence risk of
    /// caching the value on State: both toggle entry points write through
    /// `HierarchyClient.setWorktreeDiffInspectorVisible`, and the view reads
    /// the authoritative catalog each render.
    func diffInspectorVisible(in catalog: Catalog) -> Bool {
      guard
        let projectID = selection.projectID,
        let worktreeID = selection.worktreeID,
        let project = catalog.projects.first(where: { $0.id == projectID }),
        let worktree = project.worktrees.first(where: { $0.id == worktreeID })
      else { return false }
      return worktree.diffInspectorVisible
    }
  }

  /// Opaque marker for diagnostic logging / tests — the full `TerminalEvent`
  /// is not Equatable (Data payloads in paneOutput), so we store a coarse
  /// discriminator.
  enum LastEventMarker: Equatable {
    case paneCreated
    case paneReady
    case paneOutput
    case paneExited
    case paneCrashed
    case paneClosedByTab
    case paneIdle
    case tabActivated
    case tabAutoClosed
    case worktreeActivated
    case hierarchyMutated
    case paneInfoChanged
    case paneActionRequested
    case windowActionRequested
    case configChanged

    init(_ event: TerminalEvent) {
      switch event {
      case .paneCreated: self = .paneCreated
      case .paneReady: self = .paneReady
      case .paneOutput: self = .paneOutput
      case .paneIdle: self = .paneIdle
      case .paneExited: self = .paneExited
      case .paneCrashed: self = .paneCrashed
      case .paneClosedByTab: self = .paneClosedByTab
      case .tabActivated: self = .tabActivated
      case .tabAutoClosed: self = .tabAutoClosed
      case .worktreeActivated: self = .worktreeActivated
      case .hierarchyMutated: self = .hierarchyMutated
      case .paneInfoChanged: self = .paneInfoChanged
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
    /// event stream. `isBusy` mirrors the supacode predicate: true for any
    /// non-`REMOVE` OSC 9;4 state. Drives the tab-chip running spinner
    /// (via `HierarchyManager.runningPanes`) and the sidebar busy glyph.
    case paneProgressBusyChanged(PaneID, Bool)
    /// Forwarded from `paneInfoChanged + .pwd(path)` in the engine event
    /// stream. Persists the pane's live cwd so a restart restores it at the
    /// directory the user last `cd`'d to rather than its creation-time cwd.
    /// The reducer routes through `HierarchyClient.updatePaneWorkingDirectory`,
    /// which is idempotent on equal paths so a shell that re-asserts the same
    /// pwd every prompt never touches the catalog file.
    case paneLivePwdChanged(PaneID, String)
    /// Emitted by `WorktreeHeadWatcher` when a worktree's `.git/HEAD`
    /// file changes — typically a `git checkout` / `git switch` inside
    /// a touch-code pane. The reducer reconciles that worktree's
    /// Project so the catalog's `Worktree.branch` follows HEAD, then
    /// pokes GitHubFeature so the PR badge re-fetches against the new
    /// branch set. Without this, branch flips that happen while the
    /// app stays focused never reach the sidebar / header / PR cache
    /// (the focus-driven reconcile path requires a `didBecomeActive`
    /// transition the user never triggers). See HAN-62.
    case worktreeHeadChanged(WorktreeID)
    /// T3: Toggles the Git Viewer overlay for the current Worktree.
    /// Sources: Header GV button (T2) + ⌘⇧G (T3 Commands). Optimistically
    /// flips `state.diffInspectorVisible` and fires
    /// `HierarchyClient.setWorktreeDiffInspectorVisible` to persist.
    case diffInspectorToggledForCurrentWorktree
    /// Sidebar entry point for the Git Viewer (HAN-25 follow-up). Same
    /// resolution as `.diffInspectorToggledForCurrentWorktree` but operates on
    /// an explicit (projectID, worktreeID) pair rather than the current
    /// selection — clicking the per-row `+N −M` chip targets that row even when
    /// it isn't the active selection. Always opens (no toggle-to-close) so the
    /// affordance reads as a "show me the diff" action.
    case openGitViewerForWorktreeRequested(projectID: ProjectID, worktreeID: WorktreeID)
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
    case editor(EditorFeature.Action)
    case worktreeHeader(WorktreeHeaderFeature.Action)
    case gitHub(GitHubFeature.Action)
    case statusBar(StatusBarFeature.Action)
    case paneActionRouter(PaneActionRouterFeature.Action)
    case windowActionRouter(WindowActionRouterFeature.Action)
    case diff(DiffFeature.Action)
  }

  nonisolated enum CancelID: Sendable {
    case events, selectionChanges, projectReconcileFocus, worktreeHeadWatcher
  }

  @Dependency(TerminalClient.self) private var terminalClient
  @Dependency(HierarchyClient.self) private var hierarchyClient
  @Dependency(FinderClient.self) private var finderClient
  @Dependency(SettingsWriter.self) private var settingsWriter
  @Dependency(ProjectReconciler.self) private var projectReconciler
  @Dependency(WorktreeHeadWatcher.self) private var worktreeHeadWatcher
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
    Scope(state: \.diff, action: \.diff) { DiffFeature() }
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
              case .paneInfoChanged(let paneID, .progress(let state, _)):
                // OSC 9;4 progress reports drive the per-pane "executing"
                // signal. Any non-REMOVE state (set / indeterminate /
                // pause / error) marks the pane as running; REMOVE clears
                // it. This is the only writer to `runningPanes` in the
                // app today and is what lights up the tab-chip spinner +
                // sidebar busy glyph.
                let isBusy = state != GHOSTTY_PROGRESS_STATE_REMOVE.rawValue
                await send(.paneProgressBusyChanged(paneID, isBusy))
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
            if let action = await MainActor.run(body: {
              Self.makeActiveProjectGitHubRefresh(client: client)
            }) {
              await send(.gitHub(action))
            }
          },

          // Re-sync on window focus. Debounced inside the actor. The
          // post-reconcile GitHub refresh covers the canonical HAN-62 flow:
          // user runs `git checkout` in a pane, switches back to the app —
          // focus fires, reconcile picks up the new branch, GitHubFeature
          // re-evaluates the PR cache against the updated branch set.
          .run { [projectReconciler, client = hierarchyClient] send in
            for await _ in focusStream {
              await projectReconciler.reconcileAll()
              if let action = await MainActor.run(body: {
                Self.makeActiveProjectGitHubRefresh(client: client)
              }) {
                await send(.gitHub(action))
              }
            }
          }
          .cancellable(id: CancelID.projectReconcileFocus, cancelInFlight: true),

          // HAN-62: terminal-initiated `git checkout` / `git switch` inside
          // a touch-code pane never fires `didBecomeActive`, so the focus-
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
          .cancel(id: CancelID.worktreeHeadWatcher)
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
        // M4: forward the selection into the Diff feature so the changed-
        // files list refreshes for the new Worktree. `nil` worktreeID resets
        // DiffFeature.State to defaults (no fetch).
        var effects: [Effect<Action>] = []
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
        effects.append(
          .send(
            .diff(
              .worktreeSelected(
                projectID: selection.projectID,
                worktreeID: selection.worktreeID,
                path: resolvedWorktreePath
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

      case .paneLivePwdChanged(let paneID, let path):
        // No reducer state mutation — the manager writes through to the
        // catalog directly and debounces the disk save via `scheduleSave`.
        hierarchyClient.updatePaneWorkingDirectory(paneID, path)
        return .none

      case .paneLifecycleExited(let paneID):
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
        try? hierarchyClient.selectProject(projectID)
        return .none

      case .sidebar(.delegate(.openTagManager)):
        state.tagManagerSheet = TagManagerFeature.State()
        return .none

      case .sidebar(.delegate(.openGitViewerRequested(let projectID, let worktreeID))):
        return .send(.openGitViewerForWorktreeRequested(projectID: projectID, worktreeID: worktreeID))

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

        case .runScriptRequested(let scriptID, let projectID, let worktreeID):
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

        case .manageScriptsRequested(let projectID):
          let presenter = settingsWindowPresenter
          return .run { _ in
            await MainActor.run {
              presenter.openAt(.projectScripts(projectID))
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

      case .diff:
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
        // Three-tier Git Viewer resolution for the ⌘⌥G chord:
        //   1. `projects[pid].defaultGitViewer == .builtin`  → force the
        //      in-app overlay (overrides any external global default).
        //   2. `projects[pid].defaultGitViewer == .external(id)` →
        //      open the worktree in that client (if installed).
        //   3. `projects[pid].defaultGitViewer == nil` (inherit) →
        //      fall back to `general.defaultGitViewerID`.
        // A `.external(id)` that no longer resolves to an installed
        // descriptor decays to the in-app overlay so the chord never
        // becomes a silent no-op.
        let snapshot = settingsWriter.readSnapshotSync()
        let projectOverride = snapshot.projects[projectID]?.defaultGitViewer
        let resolvedID: EditorID? = {
          switch projectOverride {
          case .builtin:
            return nil
          case .external(let id):
            return id
          case .none:
            return snapshot.general.defaultGitViewerID
          }
        }()
        let externalChoice: EditorID? = {
          guard let resolvedID else { return nil }
          return state.editor.descriptors.contains(where: { $0.id == resolvedID }) ? resolvedID : nil
        }()
        if let externalChoice {
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
        }
        let catalog = hierarchyClient.snapshot()
        let target = !state.diffInspectorVisible(in: catalog)
        let setter = hierarchyClient.setWorktreeDiffInspectorVisible
        return .run { _ in
          await MainActor.run { setter(worktreeID, target) }
        }

      case .openGitViewerForWorktreeRequested(let projectID, let worktreeID):
        // Mirrors `.diffInspectorToggledForCurrentWorktree`'s three-tier
        // resolution but reads an explicit (projectID, worktreeID) so a click
        // on a non-selected sidebar row still hits the right worktree. Built-in
        // path forces visibility on (not a toggle) so a "click to open" affordance
        // never appears to no-op when the inspector was already visible elsewhere.
        let snapshot = settingsWriter.readSnapshotSync()
        let projectOverride = snapshot.projects[projectID]?.defaultGitViewer
        let resolvedID: EditorID? = {
          switch projectOverride {
          case .builtin:
            return nil
          case .external(let id):
            return id
          case .none:
            return snapshot.general.defaultGitViewerID
          }
        }()
        let externalChoice: EditorID? = {
          guard let resolvedID else { return nil }
          return state.editor.descriptors.contains(where: { $0.id == resolvedID }) ? resolvedID : nil
        }()
        if let externalChoice {
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
        }
        // Built-in inspector lives in the detail column for the *selected* worktree,
        // so route the click through the same selection flow the keyboard chord
        // assumes — picking the row first, then flipping its inspector visibility on.
        let setter = hierarchyClient.setWorktreeDiffInspectorVisible
        return .merge(
          .send(.sidebar(.worktreeRowTapped(worktreeID, inProject: projectID))),
          .run { _ in
            await MainActor.run { setter(worktreeID, true) }
          }
        )

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
        try? hierarchyClient.selectProject(source.projectID)

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
        guard
          (try? hierarchyClient.openPane(
            tabID, worktreeID, projectID, worktreePath, "$EDITOR")) != nil
        else {
          return .send(.editor(.openFailed(reason: "Could not spawn $EDITOR pane")))
        }
        // Bring the user to the freshly spawned Pane. Selecting after the catalog
        // mutation lets `autoSeedTabAndPaneIfNeeded` (driven by selectionChanges)
        // see the populated tab and skip its own seed.
        try? hierarchyClient.selectProject(projectID)
        try? hierarchyClient.selectWorktree(worktreeID, projectID)
        try? hierarchyClient.selectTab(tabID, worktreeID, projectID)
        return .send(
          .editor(.openSucceeded(editorID: EditorRegistry.shellEditorID, displayName: "$EDITOR")))

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
      _ = try? hierarchyClient.openPane(tabID, worktreeID, projectID, cwd, nil)
      return
    }
    let activeTabID = worktree.selectedTabID ?? worktree.tabs.first?.id
    guard let activeTabID,
      let tab = worktree.tabs.first(where: { $0.id == activeTabID }),
      tab.panes.isEmpty
    else { return }
    _ = try? hierarchyClient.openPane(activeTabID, worktreeID, projectID, cwd, nil)
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
