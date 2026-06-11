# ExecPlan: TCA Shell (0007)

**Status:** Completed
**Author:** Gump (with Claude)
**Date:** 2026-04-20

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this plan lands, running `make mac-run-app` opens a codans window that looks like a terminal orchestrator rather than a single-shell demo:

- A two-column `NavigationSplitView` — sidebar on the left, active-Worktree detail on the right.
- The sidebar lists every Space, expands into Projects, and each Project expands into Worktrees. Clicking a Worktree makes it the active context.
- The active Worktree shows a horizontal tab bar. Clicking "New Tab" adds a Tab and makes it active; clicking a Tab swaps the detail pane to that Tab's `SplitTree<PaneID>`.
- Each Tab's viewport renders one or more live libghostty Panes, recursively laid out from `SplitTree`. "Split right" / "Split down" commands add a new Pane inside the active Tab; closing the last Pane leaves an empty Tab placeholder.
- Quitting and relaunching restores every level — sidebar selection, active Tab, and split geometry — via the shipped `CatalogStore`.
- Creating a Worktree / Tab / Pane and removing them is driven through `HierarchyClient` and `TerminalClient` `DependencyKey` bridges. Every future feature (C6 inbox sidebar, C7 git viewer, C8 editor settings) composes into `RootFeature` and reuses these clients without touching runtime state directly.

This is the composition layer that unlocks downstream capability work. C6 / C7 / C8 don't ship here; they get a `RootFeature` to inject into and a place in the view hierarchy to live.

## Progress

- [x] M1 — Add TCA dependency + `HierarchyClient` and `TerminalClient` `DependencyKey`s with `liveValue` / `testValue` wired into the shipped `HierarchyManager` and `TerminalEngine` — 2026-04-20
- [x] M2 — `RootFeature` scaffold + `ContentView` with an empty `NavigationSplitView`; `CodansApp` mounts `ContentView` in place of `MainView`; event-stream + selection subscriptions armed — 2026-04-20
- [x] M3 — `HierarchySidebarFeature` + `HierarchySidebarView` with Space → Project → Worktree navigation driven by `HierarchyClient`; DEC-2 mode-swap (`hierarchy` ↔ `inbox`) shipped with C6 placeholder — 2026-04-20
- [x] M4 — `WorktreeDetailFeature` composing `TabBarFeature` and `SplitViewportFeature`; detail column renders active Tab's `SplitTree<PaneID>` via `PaneHostView`; DEC-9 C7 inspector slot reserved — 2026-04-20
- [x] M5 — Lazy surface lifecycle via `LazyPaneHost` wrapper: first-appearance creation, registry reuse across tab switches, explicit close via `HierarchyClient.closePanel`. HSplitView/VSplitView containers + C7 inspector icon variants + snapshot-driven activeTabID mirroring (with tests) — 2026-04-20
- [x] M6 — Presentation plumbing: sheets for "New Space" + "New Tab"; destructive alert for Worktree removal; C8 settings slot reserved; `MainView` + `SingleSurfaceHostTests` deleted; LazyPaneHost refactored to TerminalClient dependency + 3 tests — 2026-04-20. (AddProject folder picker and NewWorktree path templating deferred to a follow-up plan — minimal shell scope.)

## Surprises & Discoveries

(None yet)

## Decision Log

- **DEC-0 (planning, 2026-04-20): nit fix on `selectProject` / `selectWorktree` signatures.** Original draft used two `_ in:` parameter labels in a row, which does not compile. Renamed to `inSpace` / `inProject` at signature level; keeps call sites readable (`hierarchyClient.selectWorktree(id, inProject: p, inSpace: s)`).
- **DEC-1 (M1 gate, 2026-04-20): `selectionChanges()` added to `HierarchyClient` in M1.** Downstream C7 `GitViewerFeature` and C6 inbox both need to react to Worktree selection changes. Without a stream on the client, features would need to hold a `HierarchyManager` reference and observe `@Observable` directly — leaking the single-writer concern into TCA reducers. The stream samples on `TerminalEvent.hierarchyMutated(.selection | .space | .project | .worktree)` and dedupes. M4 `WorktreeDetailFeature` also consumes it to swap the detail column on worktree change. **Must ship in M1** so M3+ features build against a stable surface.
- **DEC-2 (resolved M3, 2026-04-20): C6 Inbox placement — option (b), leading-column mode-swap.** Per design-doc approval, C6 ships as a sidebar mode rather than a third column. `SidebarMode { .hierarchy, .inbox }` lives on `RootFeature.State` and `ContentView` swaps the leading column's content via `@ViewBuilder`. `InboxSidebarPlaceholder` is the C6 drop-in slot. Toolbar picker in `ContentView` flips the mode; C6 M5 will add keyboard-shortcut and badge-count triggers. Three-column topology rejected: visually heavy on a single-window tool; C8 editor settings + C7 diff viewer can compose into the detail column rather than squeeze into a third sidebar.
- **DEC-3 (M4 gate, 2026-04-20 — deferred to M4 kickoff): `SplitViewportFeature.State` needs `activeTabID: TabID?`.** M4 must seed this as part of state so M5's `.tabActivated` transition has a field to update. Documented here so M4 doesn't ship "empty state" and M5 doesn't have to retrofit.
- **DEC-4 (M6 gate, 2026-04-20 — deferred to M6 kickoff): C8 Settings presentation slot.** M6 adds `@Presents var settingsSheet: SettingsFeature.State?` to `RootFeature.State` as a commented placeholder. C8 plan will define `SettingsFeature`; today's M6 reserves the slot so C8 can drop in without reshaping root state. One-line `// @Presents var settingsSheet: … // reserved for C8` comment is enough.
- **DEC-5 (M1, 2026-04-20): `@Dependency(Client.self)` key-type form instead of `@Dependency(\\.keyPath)`.** Under Swift 6 strict concurrency with `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`, the keypath form emits `WritableKeyPath<DependencyValues, Client> does not conform to Sendable`. The `@Dependency(Type.self)` form sidesteps the keypath-Sendable check. Clients still expose `DependencyValues.hierarchyClient` / `.terminalClient` subscripts for call-site ergonomics; reducers can use either form.
- **DEC-6 (M2, 2026-04-20): `HierarchyClient`, `TerminalClient`, `HierarchySelection` marked `nonisolated struct`.** App-target default actor isolation is MainActor. Structures that the TCA `@Dependency` / `DependencyKey` system reads from need nonisolated defaults (the closures inside are individually `@MainActor @Sendable`). Without `nonisolated` on the struct, MainActor-inference propagates and breaks Sendable conformance at the boundary.
- **DEC-7 (M2, 2026-04-20): Runtime constructors in `CodansApp.AppState.init`, ghostty bring-up deferred to `bringUp()`.** `HierarchyManager` + `TerminalEngine` must exist before the SwiftUI scene renders the placeholder loading view; `GhosttyRuntime` needs `GhosttyBootstrap.initialize` env vars set first, so constructing it in the init path risked deadlock/timing issues. `bringUp` runs from a `.task { }` modifier, assembles ghostty, and then rebuilds the TCA `Store` with the live clients. `GhosttyBackedHierarchyRuntime` uses a `weak` engine ref attached post-construction to break the `Manager ↔ Engine` circular dep.
- **DEC-8 (M2, 2026-04-20): `selectionChanges()` pre-arm race closed.** Review flagged that between a yield and the next `withObservationTracking` arm, a mutation could land unobserved. Fix: sample `currentSelection` BEFORE arming tracking and yield immediately if it diverges from `last`. Regression tested via `selectionChangesDedupesIdenticalSelectSpace` (identical selects do not cause phantom emissions) and `selectionChangesPopulatesAllThreeLevelsOnWorktreeSelect` (pre-seeded catalog yields fully-populated first emission).
- **DEC-9 (M4, 2026-04-20): C7 inspector slot reserved as a trailing column, default hidden.** M4 review suggested adding a placeholder now so C7 M3 doesn't need to restructure `RootFeature.State` when it lands. Decision: single `inspectorVisible: Bool` on `RootFeature.State` with a toolbar toggle; when true, `ContentView` appends a fixed-width `InspectorPlaceholder` after the detail content inside an `HStack` (not as a third `NavigationSplitView` column — `NavigationSplitView`'s three-column mode on macOS 14 has fiddly collapse behaviour). C7 replaces the placeholder with a real reducer + view without touching root state shape.
- **DEC-10 (M4, 2026-04-20): Recursive SwiftUI view uses `AnyView`.** First compile of `SplitViewportView` with `@ViewBuilder` recursive `renderNode` hung the Swift type checker (single file compile stuck > 5 min). Type erasure via `AnyView` at every recursion level compiles in seconds. Cost is negligible at realistic tree sizes (≤ 32 panes/tab). Swift 6 generic inference on recursive view hierarchies is a known sharp edge; erasure is the standard escape hatch.
- **DEC-11 (M4, 2026-04-20): `SplitTree<PaneID>.Tab` → `CodansCore.Tab` qualification.** SwiftUI's `Tab` type (added in macOS 14) shadows `CodansCore.Tab`. Feature views must fully qualify as `CodansCore.Tab` in every signature that mentions the type. Domain name kept — renaming to avoid collision isn't worth the churn.

## Outcomes & Retrospective

### M1 — TCA dep + clients (2026-04-20)

**What landed:**
- `apps/mac/Tuist/Package.swift` — `swift-composable-architecture` pinned at `1.23.1`; Tuist fetched swift-custom-dump, swift-navigation, swift-sharing, swift-dependencies transitively.
- `apps/mac/Project.swift` — `.external(name: "ComposableArchitecture")` added to the `codans` app target.
- `apps/mac/codans/App/Clients/HierarchyClient.swift` — 18 commands + `snapshot` + `selectionChanges` stream. Per DEC-1, `selectionChanges` uses `withObservationTracking` to sample `manager.catalog.selectedSpaceID/Project/Worktree` on every mutation, deduped against the prior snapshot. `HierarchyClient.live(manager:)` static factory for app startup; `liveValue` + `testValue` `DependencyKey` conformance with `unimplemented` placeholders.
- `apps/mac/codans/App/Clients/TerminalClient.swift` — 6 commands (sendInput, setFocus, retryPanel, ensureSurface, closeSurface, events). `ensureSurface` throws `TerminalClient.Error.worktreeNotFound` when the address doesn't resolve inside the current catalog.
- `apps/mac/codans/Runtime/HierarchyManager.swift` — added `selectSpace`, `selectProject(in:)`, `selectWorktree(in:in:)`, `selectTab(in:in:in:)` backing mutations the client wraps.
- `apps/mac/codans/Tests/HierarchyClientTests.swift` (4 tests) + `TerminalClientTests.swift` (2 tests).

**Verification:** `make mac-build` → `BUILD SUCCEEDED`. `make mac-lint` → clean. `xcodebuild test -scheme codans` → **39 tests in 7 suites passed** (33 prior + 6 new client tests). No user-visible change — app still launches via `MainView`'s `SingleSurfaceHost`.

**Carry-forward to M2:** `RootFeature.onLaunch` will subscribe to `terminalClient.events()` and `hierarchyClient.selectionChanges()` concurrently. `ContentView` will use `.withDependencies { $0.hierarchyClient = .live(manager:); $0.terminalClient = .live(engine:) }` at store construction.

### M2 — RootFeature + ContentView + CodansApp swap (2026-04-20)

**What landed:**
- `apps/mac/codans/App/Features/Root/RootFeature.swift` — `@Reducer` with `@ObservableState` holding `selection: HierarchySelection` + `lastEvent: LastEventMarker?`. `onLaunch` action arms two cancellable `Effect.run` subscriptions concurrently (`terminalClient.events()` → `.engineEventReceived(marker)`; `hierarchyClient.selectionChanges()` → `.selectionChanged(selection)`). `onQuit` cancels both effects. `LastEventMarker` enum covers all 11 `TerminalEvent` variants (checked by `lastEventMarkerCoversAllVariants` test).
- `apps/mac/codans/App/ContentView.swift` — `NavigationSplitView(columnVisibility:)` with placeholder sidebar + detail views. Sidebar shows current selection (IDs) for visual verification until M3. Detail says "Select a Worktree" when empty, shows the last engine event marker when ready. `@Environment(HierarchyManager.self)` is propagated to descendant views; terminal engine is passed explicitly (not `@Observable`, so environment injection doesn't apply).
- `apps/mac/codans/App/CodansApp.swift` — `AppState` (`@MainActor @Observable`) owns the single long-lived runtime stack: `CatalogStore` + `GhosttyBackedHierarchyRuntime` + `HierarchyManager` + `TerminalEngine`. `bringUp()` (idempotent) attempts `GhosttyRuntime()` and rebuilds `TerminalEngine` with the runtime if init succeeds; then assembles the TCA `Store` with `.withDependencies` injecting `HierarchyClient.live(manager:)` + `TerminalClient.live(engine:)`. `GhosttyBackedHierarchyRuntime` is the adapter between `HierarchyManager.HierarchyRuntime` protocol and the real engine's ensureSurface/closeSurface — `weak` engine reference breaks the circular dep.
- M1 review follow-ups folded in: pre-arm race on `selectionChanges` closed (sample before tracking arm); tautological test replaced with `selectionChangesDedupesIdenticalSelectSpace` + `selectionChangesPopulatesAllThreeLevelsOnWorktreeSelect`.
- `apps/mac/codans/Tests/RootFeatureTests.swift` — 3 tests: `onLaunchReceivesEngineEventThenCancels` (TestStore with injected AsyncStream continuations; exhaustivity `.off` because the selection subscription is co-running), `selectionChangedUpdatesState`, `lastEventMarkerCoversAllVariants`.

**Verification:** `make mac-build` → `BUILD SUCCEEDED`. `make mac-lint` → clean. `xcodebuild test -scheme codans` → **43 tests in 8 suites pass**. App binary launches, shows loading spinner briefly, then the two-column NavigationSplitView with sidebar placeholder + "Select a Worktree" detail. No segfault; `.task { store.send(.onLaunch) }` fires both subscriptions; `.onDisappear` cancels via `onQuit`.

**Carry-forward to M3:** `HierarchySidebarFeature` replaces the `SidebarPlaceholder` view; root reduces `Scope(state: \.sidebar, action: \.sidebar) { HierarchySidebarFeature() }`. The selection stream already drives `store.selection` so M3's view can read it for row highlights without touching the sidebar feature's own state. DEC-2 decision (three-column vs. leading-column mode-swap for C6 inbox) needs to be finalised at M3 kickoff before the sidebar view topology freezes.

### M3 — HierarchySidebar + DEC-2 mode-swap (2026-04-20)

**What landed:**
- `apps/mac/codans/App/Features/Root/RootFeature.swift` — `SidebarMode` enum, `sidebar: HierarchySidebarFeature.State` substate, `Scope` composition, `.sidebarModeChanged` + `.sidebar(…)` actions.
- `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarFeature.swift` — @Reducer holding `expandedSpaceIDs` + `expandedProjectIDs` view state; row-tap actions forward to `hierarchyClient.select*`; `pruneExpansionSets` keeps the sets tidy after catalog mutations.
- `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarView.swift` — `List(.sidebar)` with nested `DisclosureGroup`s (Space → Project → Worktree); row highlight backed by `currentSelection: HierarchySelection` passed from `RootFeature.State`. Reads `HierarchyManager.catalog` via `@Environment` at render time — no catalog copy in TCA state.
- `apps/mac/codans/App/Features/InboxSidebar/InboxSidebarPlaceholder.swift` — C6 M5 drop-in slot.
- `apps/mac/codans/App/ContentView.swift` — sidebar column now `@ViewBuilder`-switches on `store.sidebarMode`; toolbar segmented Picker toggles between `.hierarchy` and `.inbox`. `.onChange(of: store.selection)` dispatches `.sidebar(.pruneExpansionSets(…))` to keep expansion sets aligned with catalog reality.
- M2 polish folded in: `AppState` constructs `TerminalEngine` once in `bringUp()` (no more throwaway engine in init); `RootFeatureTests` gains `onLaunchExhaustivelyPropagatesSelectionFromStream` using full-exhaustivity TestStore; `ContentView.terminalEngine` parameter documented with an M4 carry-forward comment.
- `apps/mac/codans/Tests/HierarchySidebarFeatureTests.swift` — 4 tests: toggleSpaceExpansion, toggleProjectExpansion, worktreeRowTappedForwardsToHierarchyClient (LockIsolated closure captures arguments), pruneExpansionSetsDropsStaleIDs.

**Verification:** `make mac-build` → `BUILD SUCCEEDED`. `make mac-lint` → clean (required `.accessibilityHidden(true)` on every decorative `Image` inside row buttons). `xcodebuild test -scheme codans` → **48 tests in 9 suites pass** (43 prior + 5 new: 4 sidebar + 1 exhaustive RootFeature). App binary launches; sidebar shows "No Spaces yet" placeholder (M6 will seed creation UI); toolbar Picker swaps in/out the InboxSidebarPlaceholder.

**Carry-forward to M4:** `WorktreeDetailFeature` replaces the `DetailPlaceholder` view; composes `TabBarFeature` + `SplitViewportFeature`. Per DEC-3 (M4 kickoff), `SplitViewportFeature.State` must seed `activeTabID: TabID?` at introduction so M5's `.tabActivated` lifecycle has a field to mutate. `HierarchyClient.selectionChanges` stream already drives detail-column swap.

### M4 — WorktreeDetailFeature + TabBar + SplitViewport + inspector slot (2026-04-20)

**What landed:**
- `apps/mac/codans/App/Features/WorktreeDetail/WorktreeDetailFeature.swift` — composition reducer with `Scope` wiring for `tabBar` + `splitViewport` substates. Renders `emptyTab` when a worktree is selected but has no active tab; `placeholder` when no worktree is selected.
- `apps/mac/codans/App/Features/TabBar/TabBarFeature.swift` — state-free controller: actions forward to `hierarchyClient.createTab / selectTab / closeTab`. View reads `Worktree.tabs` from environment.
- `apps/mac/codans/App/Features/TabBar/TabBarView.swift` — horizontal button strip with New-Tab `+` button, close buttons per tab, `activeTabID` highlight.
- `apps/mac/codans/App/Features/SplitViewport/SplitViewportFeature.swift` — state seeds `activeTabID: TabID?` per DEC-3; actions `newPanelButtonTapped`, `splitButtonTapped`, `closePanelButtonTapped`, `focusPanelRequested`, `resizeSplitRequested`, `activeTabChanged`. Forwards to `hierarchyClient` equivalents.
- `apps/mac/codans/App/Features/SplitViewport/SplitViewportView.swift` — recursive render over `SplitTree<PaneID>.Node` with `AnyView` erasure to sidestep Swift 6 generic inference (DEC-10). Leaves resolve `PaneSurface` via `terminalEngine.ghosttyRuntime?.surface(for:)`; splits render via `HStack`/`VStack` (placeholder for future `NSSplitView` resize handles).
- `apps/mac/codans/App/Features/Root/RootFeature.swift` — state gains `detail: WorktreeDetailFeature.State` + `inspectorVisible: Bool`; action gains `.detail(…)` + `.inspectorVisibilityToggled`. `.selectionChanged` now mirrors the active tab via `resolveActiveTab(selection:)` so lazy-surface logic in M5 has a single source of truth.
- `apps/mac/codans/App/ContentView.swift` — detail column becomes `HStack { WorktreeDetailView; divider; InspectorPlaceholder }` when `inspectorVisible == true`. Toolbar button toggles the inspector; DEC-2 sidebar picker still lives on the leading column's toolbar.
- M3 review polish folded in: DEC-0 positional-call clarity commented at call sites (closure-typed clients don't propagate labels); `HierarchySidebarFeatureTests` stub no longer synthesises fallback WorktreeID; `RootFeatureTests.sidebarModeChangedUpdatesState` + `inspectorVisibilityTogglesBothWays` added.
- `apps/mac/codans/Tests/TabBarFeatureTests.swift` (3 tests) + `SplitViewportFeatureTests.swift` (4 tests).

**Verification:** `make mac-build` → `BUILD SUCCEEDED`. `make mac-lint` → clean. `xcodebuild test -scheme codans` → **57 tests in 11 suites pass** (48 prior + 9 new: 3 TabBar + 4 SplitViewport + 2 RootFeature additions). App binary launches; toolbar shows sidebar-mode picker + inspector toggle; sidebar + detail + hidden inspector compose without layout glitches.

**Carry-forward to M5:** Lazy surface lifecycle. M5 observes `.tabActivated` on the engine event stream + `.selectionChanged` route in root reducer; iterates the incoming tab's panes and calls `terminalClient.ensureSurface` for each. Outgoing tabs' surfaces are NOT destroyed (product NFR: tab switch < 16ms; reopening surfaces would cost shell bootstrap time). The `SplitViewportView.placeholderCell` stands in for panes whose surface hasn't been lazily created yet — M5 should see it only briefly on first tab visit.

### M5 — Lazy surface lifecycle + M4 polish (2026-04-20)

**What landed:**
- `apps/mac/codans/App/Features/SplitViewport/LazyPaneHost.swift` — new `View` wrapper implementing the M5 lifecycle: `.task(id: paneID)` calls `terminalEngine.ensureSurface` on first appearance, renders `PaneHostView` on success, shows a labelled placeholder with a "Retry" button on failure. Surfaces are reused across tab switches via the engine registry (`ghosttyRuntime.surface(for:)`); view appearance does not destroy them. Close flows through `HierarchyClient.closePanel` → `HierarchyManager.closePanel` → `TerminalEngine.closeSurface`.
- `apps/mac/codans/App/Features/SplitViewport/SplitViewportView.swift` — `panelLeaf` replaced with `LazyPaneHost`; the stale "Surface not yet created" placeholder + os_log warning removed in favour of the live loading/retry states inside `LazyPaneHost`.
- M4 polish folded in:
  - Split containers switched from `HStack`/`VStack` to `HSplitView`/`VSplitView` for free drag-resize dividers; doc comment updated.
  - Inspector toolbar button uses distinct icons (`sidebar.right` visible / `sidebar.squares.right` hidden).
  - `RootFeature.reducer` now documents the `hierarchyClient.snapshot` TestStore contract as an inline comment on `.selectionChanged`.
- `apps/mac/codans/Tests/WorktreeDetailFeatureTests.swift` — 2 tests covering the two Scope routings.
- `apps/mac/codans/Tests/RootFeatureTests.swift` — `selectionChangedMirrorsActiveTabFromSnapshot` asserts that a selection pointing at a worktree with a selected tab populates `state.detail.splitViewport.activeTabID` correctly.

**Verification:** `make mac-build` → `BUILD SUCCEEDED`. `make mac-lint` → clean. `xcodebuild test -scheme codans` → **60 tests in 12 suites pass** (57 prior + 3 new: 2 WorktreeDetail + 1 snapshot mirroring). App binary launches with the split viewport lazy-creation path active.

**Carry-forward to M6:** Creation sheets (Space/Project/Worktree/Tab), destructive confirmation alerts, `@Presents settingsSheet` placeholder for C8 (DEC-4), delete `MainView.swift` + `SingleSurfaceHostTests.swift`.

### M6 — Modals, confirmation, cleanup, LazyPaneHost refactor (2026-04-20)

**What landed:**
- `apps/mac/codans/App/Clients/TerminalClient.swift` — gains `surface(paneID)` closure for registry lookup after `ensureSurface`. `live(engine:)` forwards to `engine.ghosttyRuntime?.surface(for:)`; `testValue` uses `unimplemented(…, placeholder: nil)`.
- `apps/mac/codans/App/Features/SplitViewport/LazyPaneHost.swift` — refactored to `@Dependency(TerminalClient.self)` (no longer takes a `TerminalEngine` parameter; no longer reads `HierarchyManager` from the environment). Registry short-circuit via `terminalClient.surface(paneID)`; if nil, calls `ensureSurface`, then re-looks-up and transitions state. Retry button re-invokes.
- `SplitViewportView` / `WorktreeDetailView` / `ContentView` / `CodansApp` — drop the `terminalEngine` parameter chain, one less explicit dependency through the view tree.
- `apps/mac/codans/App/Features/Modals/CreationModals.swift` + `CreationModalViews.swift` — `NewSpaceFeature` + `NewTabFeature` reducers and sheet views. Both use `BindableAction` for `TextField` binding, dispatch through `HierarchyClient`, dismiss via `@Dependency(\.dismiss)`. AddProject folder-picker and NewWorktree path-templating flows are deferred — minimal shell ships 2 creation paths as proof, follow-up plan fills in 2 more.
- `apps/mac/codans/App/Features/Root/RootFeature.swift` — state gains `@Presents var newSpaceSheet`, `@Presents var newTabSheet`, `@Presents var confirmAlert: AlertState<ConfirmAlertAction>?`. Actions `newSpaceButtonTapped` / `newTabButtonTapped` / `removeWorktreeButtonTapped` open the right presentation; `confirmRemoveWorktree` routes to `hierarchyClient.removeWorktree`. C8 reservation is an inline commented `@Presents var settingsSheet` that C8 M6 uncomments and types.
- `apps/mac/codans/App/ContentView.swift` — new `+` toolbar button fires `.newSpaceButtonTapped`; `.sheet(item:)` + `.alert(…)` modifiers bind the scoped stores.
- Deleted `MainView.swift` (pre-TCA bring-up path; `ContentView` is now the only entry) and `Tests/SingleSurfaceHostTests.swift` (the host type it covered no longer exists).
- `apps/mac/codans/Tests/LazyPanelHostTests.swift` (3 tests) — covers first-appearance ensureSurface, retry re-invokes, registry short-circuit.

**Verification:** `make mac-build` → `BUILD SUCCEEDED`. `make mac-lint` → clean. `xcodebuild test -scheme codans` → **61 tests in 12 suites pass** (60 prior - 2 deleted SingleSurfaceHostTests + 3 LazyPanelHostTests). App launches; toolbar "+" opens New Space sheet; submitting adds a Space; sidebar reflects the addition.

**Exec plan 0007 CLOSED.** C6 M5 (InboxSidebarPlaceholder slot), C7 M3/M4 (inspector slot + GitViewerFeature), C8 M6 (settings sheet slot) are unblocked.

## Context and Orientation

Related documents (all in this repo):

- Product spec — [docs/product-spec.md](../product-spec.md), capabilities C1 and C2 are already shipped; this plan stands up the TCA shell that C6/C7/C8 will plug into.
- Design doc — [docs/design-docs/0007-tca-shell.md](../design-docs/0007-tca-shell.md) — **authoritative** for every design decision (state ownership, client split, feature topology).
- Previous ExecPlan — [docs/exec-plans/0002-terminal-and-hierarchy.md](0002-terminal-and-hierarchy.md) — shipped `HierarchyManager`, `TerminalEngine`, `CatalogStore`, `GhosttyRuntime`, `PaneSurface`, `PaneHostView`. This plan composes them; it does not modify the shipped primitives.
- Architecture — [docs/architecture.md](../architecture.md), especially `§ State Management` (hybrid TCA + `@Observable`) and the `codans/App` module boundary.
- Golden rules — [docs/golden-rules.md](../golden-rules.md)

Reference projects (filesystem-local, read-only — borrow first, deviate with stated reason):

- **supacode** — `/Users/wanggang/dev/opensource/supacode`
  - `supacode/App/ContentView.swift` — canonical `NavigationSplitView` host with `@Bindable var store: StoreOf<AppFeature>` and `terminalManager: WorktreeTerminalManager` passed separately. This is exactly the pattern our `ContentView` adopts.
  - `supacode/Features/App/Reducer/AppFeature.swift` — root reducer composing sub-features with `Scope`; `@Dependency` injection; `enum Action` with `case terminalEvent(TerminalClient.Event)`.
  - `supacode/Clients/Terminal/TerminalClient.swift` — `DependencyKey` + `liveValue` + `testValue` pattern we replicate for both clients.
  - `supacode/Features/Repositories/Views/SidebarView.swift` — sidebar list view pattern with `store.send(…)` row actions.
- **supaterm** — `/Users/wanggang/dev/opensource/supaterm`
  - `apps/mac/supaterm/Features/Terminal/TerminalWindowFeature.swift` — `@Reducer` + `@ObservableState` layout with presentation state, modal editor state, and a `CancelID` enum for the event subscription effect.

Source files this plan touches (all under `apps/mac/codans/`):

- `App/CodansApp.swift` — `@main` entry; currently mounts `MainView()`; M2 replaces the body content with `ContentView` wrapping a `StoreOf<RootFeature>`.
- `App/MainView.swift` — shipped single-surface demo; superseded by `ContentView`. Kept for the `#Preview { … }` usage in M2, deleted in M6 once the shell is self-sufficient.
- `App/PaneHostView.swift` — shipped `NSViewRepresentable` over `PaneSurface`. Unchanged; M4 consumes it from `SplitViewportView`.
- `Runtime/HierarchyManager.swift`, `Runtime/TerminalEngine.swift`, `Runtime/Ghostty/*` — shipped. Read-only from this plan's perspective.
- `App/Clients/HierarchyClient.swift`, `App/Clients/TerminalClient.swift` — new in M1.
- `App/Features/Root/RootFeature.swift`, `App/ContentView.swift` — new in M2.
- `App/Features/HierarchySidebar/{HierarchySidebarFeature,HierarchySidebarView}.swift` — new in M3.
- `App/Features/WorktreeDetail/{WorktreeDetailFeature,WorktreeDetailView}.swift`, `App/Features/TabBar/{TabBarFeature,TabBarView}.swift`, `App/Features/SplitViewport/{SplitViewportFeature,SplitViewportView}.swift` — new in M4.
- `Tuist/Package.swift` — M1 adds `swift-composable-architecture`.
- `Project.swift` — M1 extends the `codans` target's `dependencies:` with `.external(name: "ComposableArchitecture")`.

**Terminology used in this plan** (define once, use everywhere):

- **DependencyKey** — a Point-Free Dependencies API type with `liveValue`, `testValue`, optionally `previewValue`. Injected into TCA reducers via `@Dependency(\.keyPath)`. `HierarchyClient` and `TerminalClient` conform.
- **Scope** — TCA's mechanism to route a sub-state/sub-action pair from a parent reducer to a child reducer. `RootFeature.body` uses `Scope(state: \.sidebar, action: \.sidebar) { HierarchySidebarFeature() }`.
- **@ObservableState** — TCA macro that makes feature state participate in SwiftUI observation (no `viewStore` wrapper needed; views read `store.state` directly).
- **snapshot** — `HierarchyClient.snapshot() -> Catalog` returns an immutable value-type copy. Useful in TestStores and as an `Equatable` payload for features that need the tree in their state. The live UI does not use this — it reads `HierarchyManager.catalog` through `@Environment` at render time.
- **Lazy surface creation** — a `PaneSurface` is created (via `TerminalEngine.ensureSurface`) only when its containing Tab becomes visible. Switching away does not destroy it in v1; that happens on explicit pane close. Addresses NFR: idle CPU ≈ 0%.

**Orientation paragraph.** Six milestones slice the shell vertically. M1 drops in TCA and the two client bridges — nothing user-visible, but the foundation every subsequent feature builds on. M2 lights up a two-column empty shell so the window frame reflects the new topology immediately. M3 brings the sidebar online, so Spaces / Projects / Worktrees can be navigated. M4 fills the detail column with a functional tab bar and split viewport, hooked up to the shipped `PaneHostView`. M5 adds the lazy lifecycle so switching between Worktrees with many Tabs stays snappy. M6 wires creation/removal modals and the empty-Tab placeholder so every mutation has a UI entry point. After M6, C6 / C7 / C8 can land without further shell changes.

## Plan of Work

### Milestone 1: TCA dependency + client bridges

**Goal after this milestone.** `ComposableArchitecture` is on SPM; `HierarchyClient.liveValue` and `TerminalClient.liveValue` forward commands to the shipped `HierarchyManager` and `TerminalEngine`; `testValue` uses unimplemented closures for TDD; a trivial test feature confirms `@Dependency` injection works end-to-end. Nothing user-visible changes — the app still launches with `MainView` and the single hardcoded shell.

**Work.** Add `.package(url: "https://github.com/pointfreeco/swift-composable-architecture", exact: "1.23.1")` to `apps/mac/Tuist/Package.swift` (matching supacode and supaterm). In `apps/mac/Project.swift`, add `.external(name: "ComposableArchitecture")` to the `codans` target's `dependencies:`. `make mac-generate` picks up both changes.

Create `apps/mac/codans/App/Clients/HierarchyClient.swift`. Define a `HierarchyClient` struct of `@MainActor @Sendable` closures, one per command from the design doc's API surface (`createSpace`, `renameSpace`, `removeSpace`, `addProject`, `removeProject`, `createWorktree`, `removeWorktree`, `selectSpace`, `selectProject`, `selectWorktree`, `createTab`, `closeTab`, `selectTab`, `openPanel`, `splitPanel`, `closePanel`, `focusPanel`, `resizeSplit`, plus a `snapshot` read). Because `HierarchyManager`'s APIs are already `@MainActor`, each `liveValue` closure is a one-line call into the manager. `testValue` uses `XCTestDynamicOverlay.unimplemented` so unexercised closures trap. Expose `DependencyValues.hierarchyClient`.

Also expose `selectionChanges() -> AsyncStream<HierarchySelection>` — a coarse stream that emits whenever the `selectedSpaceID → selectedProjectID → selectedWorktreeID` chain changes in the catalog. The `liveValue` implementation is a thin wrapper around `HierarchyManager`'s existing `@Observable` accessors: an `AsyncStream` continuation that samples on every `.hierarchyMutated(.selection)` / `.hierarchyMutated(.space(_))` / `.hierarchyMutated(.project(_, _))` / `.hierarchyMutated(.worktree(_, _, _))` event from the engine stream and dedupes against the previous snapshot. Required by C7 `GitViewerFeature` (worktree-scope changes drive diff refresh) and C6 inbox (per-worktree filtering); adding it here keeps TCA reducers feature-pure — they never hold a `HierarchyManager` reference.

Create `apps/mac/codans/App/Clients/TerminalClient.swift` with a parallel structure: `sendInput`, `setFocus`, `retryPanel`, `ensureSurface(paneID, spaceID, projectID, worktreeID, tabID)`, `closeSurface(paneID)`, and `events() -> AsyncStream<TerminalEvent>`. `liveValue` wraps `TerminalEngine`; note that `ensureSurface` needs the full hierarchy address because `HierarchyManager.findWorktree` is private — the live implementation looks the worktree up via `hierarchyManager.catalog` and throws `TerminalClient.Error.worktreeNotFound` if missing.

Add `apps/mac/codans/Tests/HierarchyClientTests.swift` and `TerminalClientTests.swift`: each instantiates a TCA `TestStore` using a trivial throwaway reducer that exposes one `@Dependency` closure and verifies the injected `testValue` override traps / the `liveValue` with a real `HierarchyManager` produces the expected catalog mutation. Two tests per file is enough — the clients are thin forwarders.

**Observable acceptance.** `make mac-generate && make mac-build` produces `BUILD SUCCEEDED`. `xcodebuild test -scheme codans` → 35 tests pass (existing 33 + 2 client tests). `make mac-lint` is clean. App binary still launches `MainView` with the single shell (no regression).

**Expected commits.** Two commits: `chore(tuist): add TCA dependency (TCA Shell M1)` and `feat(app): HierarchyClient + TerminalClient DependencyKeys (TCA Shell M1)`.

### Milestone 2: RootFeature + empty NavigationSplitView + CodansApp swap

**Goal after this milestone.** `CodansApp` mounts a `StoreOf<RootFeature>`-backed `ContentView` that renders an empty two-column `NavigationSplitView`. `RootFeature` subscribes to `terminalClient.events()` on launch and cancels the effect on quit. The old `MainView` is not yet removed — it's still compiled but unreachable. No hierarchy data is visible yet; the sidebar is a placeholder "No Space selected" and the detail column shows a blank `EmptyView`.

**Work.** Create `apps/mac/codans/App/Features/Root/RootFeature.swift`:

    @Reducer
    struct RootFeature {
      @ObservableState
      struct State: Equatable {
        var sidebar = HierarchySidebarFeature.State()     // added in M3
        var detail  = WorktreeDetailFeature.State()       // added in M4
      }
      enum Action: Equatable {
        case onLaunch
        case engineEvent(TerminalEvent)
        case sidebar(HierarchySidebarFeature.Action)      // routed in M3
        case detail(WorktreeDetailFeature.Action)         // routed in M4
      }
      @Dependency(\.terminalClient) var terminalClient
      // body composes sub-features via Scope; M3 / M4 fill in.
    }

M2 leaves the sub-feature cases + `Scope` calls commented out — the root body only handles `.onLaunch` (subscribes to events via `Effect.run(priority: .background) { send in for await event in terminalClient.events() { await send(.engineEvent(event)) } }` with `CancelID.events`) and `.engineEvent` (no-op routing until features exist).

Create `apps/mac/codans/App/ContentView.swift`:

    struct ContentView: View {
      @Bindable var store: StoreOf<RootFeature>
      let hierarchyManager: HierarchyManager
      let terminalEngine: TerminalEngine
      @State private var columnVisibility: NavigationSplitViewVisibility = .all

      var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
          Text("Sidebar placeholder")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
          Text("Select a Worktree")
        }
        .environment(hierarchyManager)
        .environment(terminalEngine)
        .task { store.send(.onLaunch) }
      }
    }

Update `apps/mac/codans/App/CodansApp.swift`. The `@main` struct gains a once-initialised `HierarchyManager` + `TerminalEngine` + `CatalogStore` + `GhosttyRuntime` stack (formerly inside `SingleSurfaceHost`), constructs the root `Store`, and passes both the store and the managers into `ContentView`. Use `.init(initialState:reducer:withDependencies:)` to override `.hierarchyClient` / `.terminalClient` with `liveValue` variants bound to the actual manager/engine instances — the built-in `liveValue` is too early-bound for this pattern.

`MainView` is **not deleted** in M2. Keep the file; remove it in M6 once `ContentView` is fully featured so the in-flight milestone always has a fallback.

Add `apps/mac/codans/Tests/RootFeatureTests.swift` with two tests: `onLaunchArmsEventSubscription` (uses a `TestStore` with `terminalClient.events` yielding a single fake `.paneReady` then finishing, asserts the `.engineEvent` action is received) and `onLaunchCancelsOnFinish` (asserts no leak after the stream ends).

**Observable acceptance.** `make mac-run-app` opens the window, shows an empty two-column layout. The sidebar column is a text placeholder; the detail column says "Select a Worktree". No segfault; no libghostty surface yet. Tests: 37 passing. Quitting cancels the event-subscription effect cleanly (no hang).

**Expected commits.** Two commits: `feat(app): RootFeature scaffold with event stream subscription (TCA Shell M2)` and `feat(app): ContentView with empty NavigationSplitView (TCA Shell M2)`.

### Milestone 3: HierarchySidebarFeature + sidebar navigation

**Goal after this milestone.** The sidebar shows every Space, every Project under each Space, every Worktree under each Project. Clicking a Worktree persists that selection via `HierarchyClient.selectWorktree`; the catalog update lands in `HierarchyManager` and triggers a debounced save. The detail column still says "Select a Worktree" — M4 gives it the tab bar + viewport.

**Work.** Create `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarFeature.swift`:

    @Reducer
    struct HierarchySidebarFeature {
      @ObservableState
      struct State: Equatable {
        var expandedSpaceIDs: Set<SpaceID> = []
        var expandedProjectIDs: Set<ProjectID> = []
      }
      enum Action: Equatable {
        case spaceRowTapped(SpaceID)
        case projectRowTapped(ProjectID)
        case worktreeRowTapped(WorktreeID, projectID: ProjectID, spaceID: SpaceID)
        case toggleSpaceExpansion(SpaceID)
        case toggleProjectExpansion(ProjectID)
      }
      @Dependency(\.hierarchyClient) var hierarchyClient
    }

Row-tap actions call the matching `hierarchyClient.select*` command and update local expansion sets. Toggle actions only mutate local expansion state.

Create `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarView.swift`. The view signature is:

    struct HierarchySidebarView: View {
      @Bindable var store: StoreOf<HierarchySidebarFeature>
      @Environment(HierarchyManager.self) private var hierarchyManager
      var body: some View { … }
    }

The view reads `hierarchyManager.catalog.spaces` directly — this is the core pattern from the design doc. Render as nested `DisclosureGroup`s inside a `List`:

    List {
      ForEach(hierarchyManager.catalog.spaces) { space in
        DisclosureGroup(isExpanded: Binding(…)) {
          ForEach(space.projects) { project in
            DisclosureGroup(isExpanded: Binding(…)) {
              ForEach(project.worktrees) { worktree in
                WorktreeRow(worktree: worktree, isSelected: …) {
                  store.send(.worktreeRowTapped(worktree.id, projectID: project.id, spaceID: space.id))
                }
              }
            } label: { ProjectRow(project: project, …) }
          }
        } label: { SpaceRow(space: space, …) }
      }
    }

Filter `expandedSpaceIDs` and `expandedProjectIDs` against the current catalog on every render (design doc R2: stale IDs).

Mount the sidebar in `ContentView`: replace the placeholder `Text` with `HierarchySidebarView(store: store.scope(state: \.sidebar, action: \.sidebar))`. Add `Scope(state: \.sidebar, action: \.sidebar) { HierarchySidebarFeature() }` to `RootFeature.body`.

Add `apps/mac/codans/Tests/HierarchySidebarFeatureTests.swift` with 3 tests: `worktreeRowTappedCallsSelectWorktree` (TestStore with stubbed `hierarchyClient.selectWorktree` closure that records its argument), `toggleSpaceExpansionFlipsExpandedSet`, `expandedSetsPruneStaleIDsOnCatalogChange`.

**Observable acceptance.** Seed a catalog via a throwaway debug hook (or `prowl send` into the app's shell: `codans space create test`; but `codans` isn't live yet — see M6 for the real seed path, or just use `hierarchyClient.createSpace` from a `.task { }` closure in a dev build flag). Launch: sidebar shows the seeded Space → Project → Worktree tree. Click a Worktree row; `~/.config/codans/catalog.json` updates its `selectedWorktreeID` within 500 ms (debounced). Tests: 40 passing.

**Expected commits.** Two commits: `feat(app): HierarchySidebarFeature + tests (TCA Shell M3)` and `feat(app): HierarchySidebarView — Space/Project/Worktree tree (TCA Shell M3)`.

### Milestone 4: WorktreeDetailFeature + TabBar + SplitViewport + PaneHostView wiring

**Goal after this milestone.** Selecting a Worktree fills the detail column with a horizontal tab bar on top and a split viewport below. Clicking "New Tab" creates a Tab; clicking a Tab button swaps the viewport; "New Pane" inside a Tab creates a Pane and renders a live libghostty shell via the shipped `PaneHostView`. Splitting horizontally / vertically adds a second pane. Closing the last Pane leaves an empty viewport placeholder — the Tab persists.

**Work.** Create three features under `apps/mac/codans/App/Features/`:

1. `WorktreeDetail/WorktreeDetailFeature.swift` — composes `TabBarFeature` + `SplitViewportFeature` via `Scope`. State holds placeholders; actions route. No logic of its own beyond composition.
2. `TabBar/TabBarFeature.swift` — actions: `newTabButtonTapped`, `tabButtonTapped(TabID)`, `closeButtonTapped(TabID)`. Each dispatches to `hierarchyClient.createTab / selectTab / closeTab` using the current selection read from the snapshot. Reducer returns no-op `.none` effects; state is empty (TabBar is a thin controller over the catalog).
3. `SplitViewport/SplitViewportFeature.swift` — actions: `newPanelButtonTapped(atPanelID: PaneID?, direction: SplitTree<PaneID>.NewDirection)`, `closePanelButtonTapped(PaneID)`, `focusPanelRequested(PaneID)`, `resizeSplitRequested(path: SplitTree<PaneID>.Path, ratio: Double)`. Each forwards to `hierarchyClient.*` + `terminalClient.ensureSurface` / `closeSurface`.

Create matching views under the same directories. `TabBarView` is a horizontal `ScrollView` of `Button`s + a `+` button. `SplitViewportView` is recursive over `SplitTree.Node`:

    func renderNode(_ node: SplitTree<PaneID>.Node, tab: Tab) -> some View {
      switch node {
      case .leaf(let paneID):
        panelView(for: paneID, in: tab)
      case .split(let split):
        splitBody(split: split, tab: tab)
      }
    }

`panelView(for:)` resolves the live `PaneSurface` via `terminalEngine.surface(for: paneID)` (shipped API). If the surface exists, return `PaneHostView(surface: surface)`; otherwise return an `EmptyView` — M5 is responsible for creating surfaces on tab activation.

`splitBody` uses an `HSplitView` or `VSplitView` (AppKit-backed `NSSplitView` via a thin `NSViewRepresentable`) with two children. Wrap the split ratio in a `Binding` that sends `resizeSplitRequested` on change.

Mount into `ContentView` by replacing the detail placeholder `Text` with:

    WorktreeDetailView(
      store: store.scope(state: \.detail, action: \.detail),
      selection: hierarchyManager.activeSelection
    )

`activeSelection` is a small helper on `HierarchyManager` (add to shipped code if it doesn't already exist) that returns `(spaceID, projectID, worktreeID, tabID)?` reading from the catalog's `selectedSpaceID → …` chain. Detail renders `EmptyView` when `activeSelection == nil`.

Add tests for each sub-feature — three per feature is enough: one for the happy path, one for the failing-call path (client throws / returns nil), and one for state invariants.

**Observable acceptance.** Seed a Space → Project → Worktree → Tab with no panes. Click the Worktree: detail column shows an empty tab bar + a "new tab" button. Click "New Pane" inside a Tab: a live shell appears. Split right: a second pane appears horizontally. Type in each independently. Close the right pane: back to one pane. Close the last pane: detail shows "No panes in this tab; New Pane". Tests: 49 passing.

**Expected commits.** Three commits: `feat(app): WorktreeDetailFeature composition (TCA Shell M4)`, `feat(app): TabBarFeature + TabBarView (TCA Shell M4)`, `feat(app): SplitViewportFeature + recursive SplitViewportView (TCA Shell M4)`.

### Milestone 5: Lazy surface lifecycle

**Goal after this milestone.** Switching to a Worktree with five Tabs spins up surfaces only for the active Tab's Panes, not for the other four Tabs. Switching Tabs inside the Worktree is a single-frame operation: the previous Tab's surfaces are frozen (not destroyed); the incoming Tab's surfaces are created if missing. Closing a Pane immediately destroys its surface. Idle CPU with ten Tabs and one visible Pane must be ≈ 0%.

**Work.** In `SplitViewportFeature.reducer` (or a small coordinator reducer layer above it — to be decided at implementation time), react to `.detail(.tabActivated(TabID))` by iterating the incoming Tab's panes and calling `terminalClient.ensureSurface` for each. React to `.engineEvent(.tabActivated(TabID))` (the same event, source of truth) for symmetric handling when the catalog flips selection from a non-UI path.

Do **not** destroy outgoing-Tab surfaces on deactivation. Product spec NFR "Tab switch < 16ms" would suffer from reopening surfaces; keep them alive until explicit close. Memory cost is bounded (NFR: <50 MB per idle Pane; typical active session ≤ 20 Panes).

Make `TerminalEngine.ensureSurface` robust to re-entry: the shipped implementation already checks for an existing surface and returns it. M5 tests exercise that path.

Add `apps/mac/codans/Tests/SplitViewportLazyLifecycleTests.swift`: seed a Tab with two Panes; simulate `.tabActivated`; assert `ensureSurface` was called twice (once per Pane, via a recording `TerminalClient.testValue`). Tab deactivation test: assert `closeSurface` was **not** called.

Update `RootFeature.handleEvent(event:)` to route `.tabActivated` into the detail feature.

**Observable acceptance.** Launch with a seeded catalog containing one Worktree, five Tabs, two Panes per Tab (all persisted from a prior session). Only two libghostty surfaces are alive at launch (the active Tab's panes). `Activity Monitor` shows ~0% CPU at idle. Switching Tabs spawns the incoming surfaces within one frame (visible in a frame capture). Tests: 52 passing.

**Expected commits.** Two commits: `feat(app): lazy surface creation on tab activation (TCA Shell M5)` and `test(app): lifecycle regression tests (TCA Shell M5)`.

### Milestone 6: Creation modals + empty-Tab placeholder + MainView cleanup

**Goal after this milestone.** Every mutation has a GUI entry point. Clicking "New Space" in the sidebar root opens a sheet with a name field. "Add Project" opens a folder picker + name field. "New Worktree" opens a sheet with branch name, path (defaulted to `<repo-root>-worktrees/<branch>`), and an "also run `git worktree add`" toggle. Destructive operations (remove Space / Project / Worktree / Tab) prompt with an `@Presents` alert. Empty-Tab state shows a centered "New Pane" button. `MainView` + `SingleSurfaceHost` are deleted.

**Work.** Add `@Presents` children to the relevant feature states:

    @ObservableState struct State: Equatable {
      @Presents var newSpaceSheet: NewSpaceFeature.State?
      @Presents var addProjectSheet: AddProjectFeature.State?
      @Presents var newWorktreeSheet: NewWorktreeFeature.State?
      @Presents var confirmRemoveAlert: AlertState<ConfirmRemoveAction>?
    }

Each new sub-feature is small: a draft-name field + a confirm action that sends `hierarchyClient.createX` and dismisses. `AddProjectFeature` uses the `FileImporter` modifier + `GitWorktreeCLI.discoverGitRoot` (shipped) to auto-detect whether the picked folder is a git repo. `NewWorktreeFeature` pre-fills the path using `Project.worktreesDirectory ?? "\(project.rootPath)-worktrees/\(branch)"`; if a matching path already exists, disambiguate with a short UUID suffix (same rule as exec-plan 0002 M6).

Add destructive confirmation via `AlertState`:

    state.confirmRemoveAlert = AlertState {
      TextState("Remove Worktree \"\(worktree.name)\"?")
    } actions: {
      ButtonState(role: .destructive, action: .confirm(.worktree(worktreeID, projectID))) { TextState("Remove") }
      ButtonState(role: .cancel) { TextState("Cancel") }
    }

The confirm action routes to `hierarchyClient.removeWorktree`.

Add an empty-Tab placeholder: when `activeTab.panes.isEmpty`, `SplitViewportView` renders a centered `VStack { Text("No panes"); Button("New Pane") { store.send(.newPanelButtonTapped(atPanelID: nil, direction: .right)) } }`.

Delete `apps/mac/codans/App/MainView.swift` and `apps/mac/codans/App/MainView+SingleSurfaceHost.swift` (M5's helper). Run `grep -r MainView apps/mac/codans` to verify no remaining references. Remove `SingleSurfaceHostTests.swift`.

Add `apps/mac/codans/Tests/CreationModalsTests.swift` covering each sheet's submit path and the destructive-alert confirm / cancel flows.

**Observable acceptance.** Fresh install (no `catalog.json`). Launch: sidebar is empty. Click "New Space" button (toolbar): sheet opens; enter "work"; click Create. Sidebar shows the Space. Click "Add Project"; pick a git repo; Project appears with an auto-created default Worktree. Click "New Worktree" on that Project; enter "exp/test"; submit. `git -C <repo> worktree list` lists it. Right-click the Worktree → Remove → confirm alert → `git worktree list` no longer shows it. Quit. Relaunch. Every Space / Project / Worktree / Tab / Pane is present; shells are freshly started; split geometry matches. Tests: 60 passing.

**Expected commits.** Three commits: `feat(app): creation sheets for Space/Project/Worktree/Tab (TCA Shell M6)`, `feat(app): destructive confirmation alerts (TCA Shell M6)`, `chore(app): delete MainView + SingleSurfaceHost — shell is self-sufficient (TCA Shell M6)`.

## Concrete Steps

Run every command from the repository root (`/Users/wanggang/dev/00/codans`) unless otherwise noted. Each milestone follows the same verification ritual: build, lint, test, manual smoke (where relevant).

### Per-milestone verification

    make mac-generate
    make mac-build
    make mac-lint
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/codans.xcworkspace \
                      -scheme codans | xcbeautify | tail -5
    # Expected tail: "Test run with N tests in M suites passed after …"

### M2 smoke (visible shell)

    make mac-run-app &
    sleep 3
    # Expected: window opens with two empty columns; no segfault.
    pkill -f Codans

### M6 end-to-end smoke (fresh install)

    mv ~/.config/codans/catalog.json ~/.config/codans/catalog.json.bak 2>/dev/null || true
    make mac-run-app
    # In the app: toolbar "New Space" → "work"; "Add Project" → pick repo;
    # "New Worktree" → "exp/tca-shell"; "New Tab" → "New Pane"; split right.
    git -C /Users/wanggang/dev/00/codans worktree list
    # Expected: exp/tca-shell listed at <repo>-worktrees/exp/tca-shell
    # Quit, relaunch, verify layout restored.

## Validation and Acceptance

After all six milestones land, a contributor can perform the following and observe the exact outputs:

1. `make mac-bootstrap && make mac-generate && make mac-build && make mac-run-app`. The app window opens within 1 s.
2. The sidebar is empty on first launch. Click "New Space" from the toolbar; enter a name; submit. The Space appears in the sidebar.
3. Click "Add Project"; pick a git repository folder. The Project appears; `Project.gitRoot` is non-nil and a default Worktree is auto-created on the current branch.
4. Select the Worktree. The detail column shows an empty tab bar and a placeholder "No panes in this Tab". Click "New Tab"; a Tab appears and is selected. Click "New Pane"; a live libghostty shell renders.
5. Split the Pane horizontally. Two panes are alive and independently focused.
6. Cmd-Q the app. Relaunch. Every Space / Project / Worktree / Tab / Pane is present; shells are freshly started; split geometry matches exactly.
7. All test schemes pass:

        xcodebuild test -scheme codans  # expected: 60+ tests pass

8. `make mac-lint` is clean.
9. `grep -r SingleSurfaceHost\\\|MainView apps/mac/codans/` returns no matches (shell is self-sufficient).

Failure on any of the above blocks sign-off; the plan is not complete until all nine are green.

## Idempotence and Recovery

Every milestone is designed to be re-runnable without state leakage.

- **Regenerate workspace.** `make mac-generate` is a pure function of `Project.swift` + `Tuist/Package.swift`; safe to repeat.
- **Clean build.** `make mac-clean-build` (or `rm -rf apps/mac/Derived && make mac-generate && make mac-build`) resets DerivedData without touching sources.
- **Reset catalog.** `mv ~/.config/codans/catalog.json ~/.config/codans/catalog.json.bak` forces a fresh hierarchy on next launch. Shipped load path (M2 of exec-plan 0002) backs broken files automatically, so this is rarely needed manually.
- **Drop a stuck worktree.** If M6 smoke leaves orphan git worktrees: `git -C /Users/wanggang/dev/00/codans worktree list` to enumerate, then `git worktree remove <path> --force` to drop.
- **Revert to pre-shell state.** If the TCA shell is unstable, revert `CodansApp.body` to mount `MainView()`; all feature files remain but are unreachable. One-commit revert.

No step modifies system-wide state (no `sudo`, no `xcode-select`, no global Git config, no PATH mutation).

## Artifacts and Notes

Notes from the pre-plan prototyping / research phase:

- **TCA 1.23.1 confirmed compatible.** Both reference projects (`supacode`, `supaterm`) ship `exact: "1.23.1"`; no breaking changes on 1.24 / 1.25 that would block us.
- **Event-stream consumer pattern.** supacode routes `terminalClient.events()` into `AppFeature.Action.terminalEvent(TerminalClient.Event)` via a long-running `Effect.run` cancelled by `CancelID`. We adopt the same shape for our single `RootFeature.Action.engineEvent(TerminalEvent)` case. Subscription is re-armable: if the effect is cancelled and re-armed, `TerminalEngine.events()` returns a fresh subscriber stream thanks to the M4.4 `SubscriberRegistry`.
- **Environment vs Dependency injection.** SwiftUI `@Environment(HierarchyManager.self)` propagates the manager to views without passing through TCA state. `@Dependency(\.hierarchyClient)` propagates it to reducers. Both reach the same shipped object; the split keeps reducer code free of SwiftUI environment concerns and vice-versa.
- **NavigationSplitView on macOS 13+ floor.** Product spec pins the floor at macOS 13 Ventura; `NavigationSplitView` requires macOS 13+ — no back-compat required.
- **PaneHostView already complete.** The shipped `PaneHostView` in `App/PaneHostView.swift` accepts a `PaneSurface` and renders its `view`. M4 consumes it unchanged.

## Interfaces and Dependencies

The following types, modules, and signatures must exist by plan completion. Names are binding — later plans and features will reference them.

**External dependencies added by this plan** (in `apps/mac/Tuist/Package.swift`):

- `swift-composable-architecture` pinned to `1.23.1` (matching supacode / supaterm).
- No other new external deps.

**`apps/mac/codans/App/Clients/`** (TCA dependency-injection bridge):

    struct HierarchyClient: Sendable {
      var createSpace: @MainActor @Sendable (_ name: String) -> SpaceID
      var renameSpace: @MainActor @Sendable (_ id: SpaceID, _ name: String) throws -> Void
      var removeSpace: @MainActor @Sendable (_ id: SpaceID) throws -> Void
      var addProject: @MainActor @Sendable (_ spaceID: SpaceID, _ name: String, _ rootPath: String, _ gitRoot: String?) throws -> ProjectID
      var removeProject: @MainActor @Sendable (_ projectID: ProjectID, _ spaceID: SpaceID) throws -> Void
      var createWorktree: @MainActor @Sendable (_ projectID: ProjectID, _ spaceID: SpaceID, _ name: String, _ path: String, _ branch: String?) throws -> WorktreeID
      var removeWorktree: @MainActor @Sendable (_ worktreeID: WorktreeID, _ projectID: ProjectID, _ spaceID: SpaceID) throws -> Void
      var selectSpace: @MainActor @Sendable (_ id: SpaceID?) -> Void
      var selectProject: @MainActor @Sendable (_ id: ProjectID?, _ inSpace: SpaceID) -> Void
      var selectWorktree: @MainActor @Sendable (_ id: WorktreeID?, _ inProject: ProjectID, _ inSpace: SpaceID) -> Void
      var createTab: @MainActor @Sendable (_ worktreeID: WorktreeID, _ projectID: ProjectID, _ spaceID: SpaceID, _ name: String?) throws -> TabID
      var closeTab: @MainActor @Sendable (_ id: TabID, _ worktreeID: WorktreeID, _ projectID: ProjectID, _ spaceID: SpaceID) throws -> Void
      var selectTab: @MainActor @Sendable (_ id: TabID?, _ worktreeID: WorktreeID, _ projectID: ProjectID, _ spaceID: SpaceID) -> Void
      var openPanel: @MainActor @Sendable (_ tabID: TabID, _ worktreeID: WorktreeID, _ projectID: ProjectID, _ spaceID: SpaceID, _ workingDirectory: String, _ initialCommand: String?) throws -> PaneID
      var splitPanel: @MainActor @Sendable (_ paneID: PaneID, _ direction: SplitTree<PaneID>.NewDirection, _ tabID: TabID, _ worktreeID: WorktreeID, _ projectID: ProjectID, _ spaceID: SpaceID, _ workingDirectory: String, _ initialCommand: String?) throws -> PaneID
      var closePanel: @MainActor @Sendable (_ paneID: PaneID, _ tabID: TabID, _ worktreeID: WorktreeID, _ projectID: ProjectID, _ spaceID: SpaceID) throws -> Void
      var focusPanel: @MainActor @Sendable (_ paneID: PaneID, _ tabID: TabID, _ worktreeID: WorktreeID, _ projectID: ProjectID, _ spaceID: SpaceID) throws -> Void
      var resizeSplit: @MainActor @Sendable (_ path: SplitTree<PaneID>.Path, _ ratio: Double, _ tabID: TabID, _ worktreeID: WorktreeID, _ projectID: ProjectID, _ spaceID: SpaceID) throws -> Void
      var snapshot: @MainActor @Sendable () -> Catalog
      /// Coarse selection-change stream. Emits a tuple of the currently
      /// selected (space, project, worktree) whenever any of those IDs
      /// changes in the catalog. Downstream reducers (C6 inbox scoping,
      /// C7 GitViewerFeature, C8 editor-settings scoping) subscribe to
      /// react on worktree switches without holding a reference to the
      /// @Observable HierarchyManager. Emitted coarsely — one event per
      /// change, deduped against the last snapshot.
      var selectionChanges: @MainActor @Sendable () -> AsyncStream<HierarchySelection>
    }

    struct HierarchySelection: Equatable, Sendable {
      let spaceID: SpaceID?
      let projectID: ProjectID?
      let worktreeID: WorktreeID?
    }
    extension HierarchyClient: DependencyKey {
      static let liveValue: HierarchyClient
      static let testValue: HierarchyClient
    }
    extension DependencyValues {
      var hierarchyClient: HierarchyClient { … }
    }

    struct TerminalClient: Sendable {
      var sendInput: @MainActor @Sendable (_ paneID: PaneID, _ text: String) -> Void
      var setFocus: @MainActor @Sendable (_ paneID: PaneID, _ focused: Bool) -> Void
      var retryPanel: @MainActor @Sendable (_ paneID: PaneID) -> Bool
      var ensureSurface: @MainActor @Sendable (_ paneID: PaneID, _ tabID: TabID, _ worktreeID: WorktreeID, _ projectID: ProjectID, _ spaceID: SpaceID) throws -> Void
      var closeSurface: @MainActor @Sendable (_ paneID: PaneID) -> Void
      var events: @MainActor @Sendable () -> AsyncStream<TerminalEvent>
    }
    extension TerminalClient: DependencyKey { … }
    extension DependencyValues { var terminalClient: TerminalClient { … } }

**`apps/mac/codans/App/Features/Root/`**:

    @Reducer struct RootFeature {
      @ObservableState struct State: Equatable {
        var sidebar: HierarchySidebarFeature.State
        var detail:  WorktreeDetailFeature.State
        @Presents var confirmRemoveAlert: AlertState<ConfirmRemoveAction>?
      }
      enum Action: Equatable {
        case onLaunch
        case engineEvent(TerminalEvent)
        case sidebar(HierarchySidebarFeature.Action)
        case detail(WorktreeDetailFeature.Action)
        case confirmRemoveAlert(PresentationAction<ConfirmRemoveAction>)
      }
    }

**`apps/mac/codans/App/Features/HierarchySidebar/`**:

    @Reducer struct HierarchySidebarFeature {
      @ObservableState struct State: Equatable {
        var expandedSpaceIDs: Set<SpaceID> = []
        var expandedProjectIDs: Set<ProjectID> = []
        @Presents var newSpaceSheet: NewSpaceFeature.State?
        @Presents var addProjectSheet: AddProjectFeature.State?
        @Presents var newWorktreeSheet: NewWorktreeFeature.State?
      }
      // actions: spaceRowTapped, projectRowTapped, worktreeRowTapped,
      //          toggleSpaceExpansion, toggleProjectExpansion, + sheet actions
    }

**`apps/mac/codans/App/Features/WorktreeDetail/`**, `TabBar/`, `SplitViewport/`: parallel shape — each with a `@Reducer struct` + `@ObservableState` value + action enum. Signatures sketched in M4 above.

**Tuist target changes**:

- `codans` target gains `.external(name: "ComposableArchitecture")` dependency.
- `codansTests` target indirectly inherits it via the app dependency.
- No new targets required (all features compile into the app).

**Files deleted by plan completion**:

- `apps/mac/codans/App/MainView.swift`
- `apps/mac/codans/Tests/SingleSurfaceHostTests.swift`
