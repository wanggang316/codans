# ExecPlan: Tab Bar Uplift

**Status:** Completed
**Author:** Gump (via Claude)
**Date:** 2026-04-24

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this change, a codans user can:

- See a polished Tab bar — an active tab is marked by a 2-pt accent underline, hover reveals a three-state background, the close button hides at rest, dividers sit between chips, and titles truncate gracefully instead of pushing neighbors off-screen.
- Right-click any tab and choose **Rename / Close / Close Others / Close to the Right / Close All**. Rename opens an inline `TextField`, commit with `Return`, cancel with `Esc`; focus returns to the previously focused pane afterwards.
- Reorder tabs by dragging a chip; the final order lands with a single atomic write.
- Press `⌘T` (new tab), `⌘W` (close current), `⌥⌘1`–`⌥⌘9` (select by index), `⌘⇧[` / `⌘⇧]` (previous / next). Middle-clicking a chip closes it.
- Open many tabs beyond the window width: the bar scrolls horizontally with edge gradient shadows, and the selected tab always scrolls into view.
- Start a new split from the Tab bar via trailing `+R` / `+D` buttons. Hovering either for ≥ 350 ms shows a miniature preview of the active tab's pane tree.
- Switch tabs and land back on the pane that was last focused in the target tab, instead of always snapping to the leftmost pane.
- See (future-ready, no writers yet) a running-command spinner in the tab chip whenever any pane inside the tab is marked busy. The wiring is in place so C3 hooks can flip the state without UI work.

The spec freeze on the Tab bar (`docs/product-specs/ui-main-window-redesign.md` — "the terminal Tab bar and split Panes below the Header behave as they do today; no regressions") is scoped to the Header / Sidebar / Git Viewer overlay redesign. This plan is an independent uplift that stays behind that boundary.

## Progress

Timestamp format: `YYYY-MM-DD`. Update as each item closes.

### M1 — UI refactor (no behavior change)

- [x] T1.1 Extract `TabBarMetrics` and `TabBarColors` under `App/Features/TabBar/Style/`. (2026-04-24, `8c7c7e5`)
- [x] T1.2 Split `TabBarView` into `TabBarView` (container) + `TabBarRowView` (HStack) + `TabChipView` (one chip) + `TabChipLabel` + `TabChipCloseButton` + `TabChipBackground`. Pure refactor, pre-split visuals preserved. (2026-04-24, `135a980`)
- [x] T1.3 Three-state chip background (idle / hover / active+press) with 2-pt top underline on the active chip; hover-revealed close button; thin divider between idle chips. (2026-04-24, `72db8d2`)
- [x] T1.4 Snapshot test suite — `TabChipSnapshotTests` in `apps/mac/codans/Tests/` — covers the five chip background states + a row composite. Dirty case deferred to M3 (lands with the writer). (2026-04-24, `013fc4c`)
- [x] T1.5 `TabBarFeatureTests` remains green on the two deterministic cases; `make build` succeeds; `swiftlint` clean on every new Tab-bar file. Pre-existing `GhosttyThemeCatalog` + `newTabButtonCallsCreateTab` suite-level flake are baseline issues (see Surprises). (2026-04-24)

### M2 — Interactions (right-click, drag, middle-click, shortcuts, overflow, trailing splits)

- [x] T2.1 `HierarchyManager` + `HierarchyClient` gain `renameTab`, `reorderTabs`, `closeOtherTabs`, `closeTabsToRight`, `closeAllTabs`, `selectAdjacentTab(direction:)`. (2026-04-24, `87c1359`)
- [x] T2.2 `TabBarFeature` gains matching actions + middle-click alias. HierarchyClient scaffolding wired through live / liveValue / testValue. (2026-04-24, `c7b621d`)
- [x] T2.3 Right-click context menu (`TabChipContextMenu`) — Rename / Close / Close Others (disabled single-tab) / Close to the Right (disabled last-tab) / Close All. (2026-04-24, `14c5c54`)
- [x] T2.4 Inline rename `TextField`: Return commits via `onRenameCommit` (empty-after-trim → nil), Esc discards, focus auto-returns to previously focused pane. (2026-04-24, `edaf740`)
- [x] T2.5 Drag-to-reorder via `.onDrag` / `DropDelegate`; single `dragReorderEnded` dispatch on drop; spring settle animation. (2026-04-24, `ba25da9`)
- [x] T2.6 Middle-click via `TabChipMiddleClickView` (NSViewRepresentable with buttonNumber == 2 hit-test gate); left/right clicks fall through to SwiftUI. (2026-04-24, `239f179`)
- [x] T2.7 `TabBarOverflowScroll` — horizontal ScrollView + 16-pt edge gradient shadows (only when overflowing) + auto-scroll-to-selected. GeometryReader + PreferenceKey used instead of macOS 15's `onScrollGeometryChange` to honour the macOS 14 deployment target. (2026-04-24, `bd35440`)
- [x] T2.8 Trailing `+` / split-right / split-down with 350-ms hover preview popover showing a recursive miniature of the active tab's split tree. Splits anchor off the leftmost leaf — upgrades to last-focused pane when M3 lands. (2026-04-24, `184dbe7`)
- [x] T2.9 Main-menu shortcuts in a new `MainWindowCommands` group: `⌘T` / `⌘W` / `⌘⇧[` / `⌘⇧]` / `⌥⌘1..⌥⌘9`. Root resolver actions match the ⌘E / ⌘⇧G pattern. (2026-04-24, `045814b`)
- [x] T2.10 Tests: 11 new `HierarchyManagerTests` cases, 8 new `TabBarFeatureTests` cases + fix for the in-suite new-tab flake, 6 new `RootFeatureTests` cases. (2026-04-24, `572bdc3`)
- [x] T2.11 Smoke script documented in the PR description. Manual UI verification is owner-gated — the agent session does not exercise the running app; see "Retrospective — M2" below for the script.

### M3 — Runtime state: focus memory + dirty read path

- [x] T3.1 `HierarchyManager` adds `lastFocusedPaneByTab: [TabID: PaneID]` + `runningPanes: Set<PaneID>`; five new helpers (`setLastFocusedPane`, `lastFocusedPane(in:)`, `markPaneRunning`, `markPaneIdle`, `tabIsDirty`). `closePane` / `closeTab` / `tearDownWorktreeSurfaces` / `focusPane` touch the maps where appropriate. (2026-04-24, `58257b0`)
- [x] T3.2 `selectTab` routes `runtime.focusSurfaceView` on the restored last-focused pane (or leftmost leaf fallback) after persisting the selection. (2026-04-24, shipped in the same commit as T3.1)
- [x] T3.3 `HierarchyClient` exposes `tabIsDirty`, `lastFocusedPane`, plus dormant `markPaneRunning` / `markPaneIdle` closures. `liveValue` uses safe no-op defaults for reads so unconfigured DI does not crash production; `testValue` keeps unimplemented stubs for test hygiene. (2026-04-24, `ace020f`)
- [x] T3.4 `TabChipLabel` gains `isDirty`; when true, a 12×12 mini `ProgressView` leads the label. `TabBarRowView` threads a `(TabID) -> Bool` lookup; `TabBarView` binds that lookup to `@Observable HierarchyManager.tabIsDirty(_:)` so hook flips propagate via SwiftUI observation. (2026-04-24, shipped in the same commit as T3.3)
- [x] T3.5 `HierarchyManagerTests` adds five cases: `selectTabRestoresLastFocusedPane`, `selectTabFallsBackToLeftmostLeafWhenRememberedPaneClosed`, `closePaneClearsLastFocusedAndRunningEntries`, `closeTabClearsRuntimeMapsForAllPanes`, `tabIsDirtyReflectsAnyRunningPane`. `FakeHierarchyRuntime` now records `focusSurfaceView` calls so focus-restoration assertions can inspect the call history. (2026-04-24)

## Surprises & Discoveries

- **Shortcut collision on `⌘1..⌘9`** (plan-time, 2026-04-24): `MainWindowCommands.swift:60-65` already binds `⌘N` to `switchToSpaceAtIndex(N)` (1..9); `HierarchySidebarView.swift:39` reserves `⌃⌘N` for worktree jumps. The design doc originally proposed `⌘1..⌘9` for tab index. Resolved in the Decision Log as **D1**: tab index moves to `⌥⌘1..⌥⌘9`, and the design doc was updated before this plan was finalized.

- **Baseline lint violations pre-date M1** (2026-04-24): `make -C apps/mac lint` surfaces ~13 violations in files outside the Tab-bar scope (`GitHub/`, `HierarchySidebarView`, `Ghostty*.swift`, `PaneSurface`, etc.). None of my new Tab-bar files introduce violations; the baseline is red independently. Matches T0 M7 precedent — escalated in commit messages but not fixed here.
- **Baseline Ghostty-theme tests fail** (2026-04-24): `GhosttyThemeCatalogTests` reports 9 failing cases (`emptyDirectoryYieldsEmptyArrays`, `alphabeticalSortUsesLocalizedStandardCompare`, `singleDarkThemeClassifiedAsDark`, …). All assert against the Ghostty theme directory contents and are orthogonal to the Tab bar — same-arch baseline on an untouched `TabBarMetrics.swift` commit reproduces the failures. Recorded as baseline.
- **`newTabButtonCallsCreateTab` is a suite-order flake** (2026-04-24): Running the case in isolation passes; running all three `TabBarFeatureTests` together records an `HierarchyClient.snapshot` unimplemented-issue on the new-tab case because the test does not stub the post-`createTab` snapshot/openPane chain. Predates this milestone — stash + rerun on a pre-T1.2 tree shows the same symptom. M2's broader test sweep will patch the stub when it adds the new action coverage.
- **`Tab` name shadowing with SwiftUI.Tab**: SwiftUI's `TabView` ecosystem exposes a `Tab` type that collides with `CodansCore.Tab` in implicit-import scope. Addressed by fully-qualifying to `CodansCore.Tab` in `TabBarRowView`; the original `TabBarView` already hit + handled this shadow, so the pattern is established.
- **Tuist `buildableFolders` requires child paths** (2026-04-24): Adding `App/Features/TabBar/Style/` and `App/Features/TabBar/Views/` did *not* need a Project.swift edit — the top-level `"codans/App"` entry is folder-referenced and picks up new subdirectories recursively for non-test targets. But the test target explicitly lists its subfolders (`Tests/Hooks`, `Tests/Socket`, …), so I kept `TabChipSnapshotTests.swift` flat under `Tests/` rather than creating a `Tests/Snapshots/` subfolder that would have required a Project.swift edit.
- **Disk exhaustion on `/tmp` mid-session** (2026-04-24): Tool runtime's task output directory on `/private/tmp` ran out of space during the M1 verification pass, blocking Bash entirely. Unblocked by the user after a host-side cleanup. Not repro-able from the plan steps alone — an environmental hiccup, not a signal about the code.

## Decision Log

- **D1** (plan-time, 2026-04-24): Tab index shortcut is `⌥⌘1..⌥⌘9`, not `⌘1..⌘9`. Reason: `⌘1..⌘9` is already Space switching (`MainWindowCommands`) and `⌃⌘1..⌃⌘9` is already Worktree jumping (`HierarchySidebarView`). The "deeper level → deeper modifier" pattern gives tabs the next available namespace. Design doc updated.
- **D2** (plan-time, 2026-04-24): Tab-bar keyboard shortcuts are dispatched from `MainWindowCommands` via **Root-level resolver actions** (e.g. `.newTabForCurrentWorktree`, `.selectTabAtIndexForCurrentWorktree(Int)`), matching the established pattern for `⌘E` (`openDefaultForCurrentWorktreeRequested`) and `⌘⇧G` (`gitViewerToggledForCurrentWorktree`). The Root reducer snapshots `hierarchyClient.snapshot()`, resolves `(space, project, worktree)`, and forwards to `TabBarFeature` via the existing `WorktreeDetailFeature → .tabBar` scope. `TabBarFeature` stays TCA-pure; `Commands` never touches `HierarchyClient` directly (the `liveValue` there fatalErrors).
- **D3** (plan-time, 2026-04-24): Drag reorder dispatches `dragReorderEnded(orderedIDs: [TabID])` **once on drop**, not on each pointer tick. Reason: `CatalogStore.scheduleSave` is debounced, but a per-tick reducer action still recomputes SwiftUI layout and can flicker across midpoints. One atomic write matches how the catalog wants to be mutated and keeps the invariant check (`orderedIDs == Set(existing.tabs.map(\.id))`) in one place.
- **D4** (plan-time, 2026-04-24): `paneRunning` is a **runtime-only map on `HierarchyManager`**, not a persisted `Tab` field. Reason: running state is wall-clock-live — it must be rewritten on every app launch anyway, so persisting it would either leak stale spinners or force an always-zero save-path. Adding a writer closure (`markPaneRunning`) with no caller in this PR keeps the contract symmetric for C3.
- **D5** (M2-T2.7, 2026-04-24): Edge-shadow visibility uses a `GeometryReader` + `PreferenceKey` pair, **not** `onScrollGeometryChange`. Reason: `onScrollGeometryChange` requires macOS 15 and the project targets macOS 14. The preference-key shim is slightly noisier (one layout pass per scroll tick) but correct and backward-compatible.
- **D6** (M2-T2.8, 2026-04-24): Trailing split buttons anchor off the **leftmost leaf** of the active tab's split tree rather than a user-focused pane. Reason: focus tracking (`lastFocusedPaneByTab`) lands in M3; adding it here would widen M2 scope and make the milestone uglier to revert. Documented as an M3 upgrade.
- **D7** (M2-T2.8, 2026-04-24): `TabBarFeature` **does** own `trailingSplitRequested`, even though the plan had implied T2.9 would own any new cross-layer actions. Reason: the button is chrome inside the tab bar, so the action domain is still "tab bar stuff." Defining it on `RootFeature` would have meant a resolver that could only be called from inside the bar — an awkward split.
- **D8** (M3-T3.1, 2026-04-24): `runningPanes` is a **`Set<PaneID>`** rather than the plan's `[PaneID: Bool]`. Absence is the natural "idle" signal and `contains` is the only read shape; a dictionary would force a `.filter { $0.value }` walk on every `tabIsDirty` call for no upside.
- **D9** (M3-T3.3, 2026-04-24): `HierarchyClient.liveValue` uses **safe default-false / nil returns** for `tabIsDirty` / `lastFocusedPane` (plus no-op writers for `markPaneRunning` / `markPaneIdle`), instead of the project-wide `fatalError("HierarchyClient.liveValue not configured")` pattern. Reason: these are dormant read paths. An uncontrolled production caller (e.g. a background-rendered chip during shutdown) should stay inert rather than trap; wrong DI wiring is already caught by `testValue`'s unimplemented stubs.
- **D10** (M3-T3.4, 2026-04-24): Chip-dirty observation hangs off the **`@Observable HierarchyManager` via `TabBarView`**, not the `HierarchyClient` closure. Reason: clients are plain closures — SwiftUI cannot track observation through them. Binding the `(TabID) -> Bool` lookup at the TabBarView layer (which already owns an `@Environment(HierarchyManager.self)`) preserves observation so a future hook writer flipping `runningPanes` re-renders the chip automatically.
- **D11** (post-review, 2026-04-25): `closeTabsToRight(of:)` now explicitly reseats `selectedTabID = id` after the doomed-suffix loop. Reason: when the user's active tab was inside the doomed range, `closeTab`'s auto-advance landed on `tabs.first` rather than the pivot — surprising UX. Mirrors `closeOtherTabs`. Two regression cases on `HierarchyManagerTests`.
- **D12** (post-review, 2026-04-25): `selectAdjacentTab(direction:...)` now routes through `selectTab(...)` after computing the new id, instead of writing `selectedTabID` directly. Reason: writing the field bypassed the M3 focus-restoration block, so `⌘⇧[` / `⌘⇧]` switched tabs without restoring the remembered pane. Test: `selectAdjacentTabRestoresLastFocusedPaneOnTarget`.

## Outcomes & Retrospective

### M1 — 2026-04-24 — shipped on `feature/tab-and-pane`

**Shipped:**
- `TabBarMetrics` + `TabBarColors` centralize the chip visual tokens (`App/Features/TabBar/Style/`).
- `TabBarView` split into a thin container + `TabBarRowView` + `TabBarTrailingAccessories` + `TabChipView` + `TabChipLabel` + `TabChipCloseButton` + `TabChipBackground` (`App/Features/TabBar/Views/`).
- Chip visuals: three-state background (idle / hover / press-or-active), 2-pt accent-tinted active underline, top-only 6-pt corners, middle-truncated single-line title, hover-revealed close button, flush chip layout with dividers suppressed adjacent to the active chip, responsive min/max width clamp (120–220 pt).
- `TabChipSnapshotTests` — 5 background-state cases + 1 row-composite case, gated behind `TC_RUN_SNAPSHOT_TESTS=1` + per-call `recordMode`.
- All five M1 tasks landed as independent commits (`8c7c7e5` → `013fc4c`).

**Gaps / deferred:**
- Responsive width division across the bar (floor/clamp per chip count) deferred to M2-T2.7 where the overflow scroll lands.
- Snapshot reference PNGs not committed — the first record pass needs a reliable window-host harness on CI; M2 or follow-up.
- Dirty-state visuals in the chip label — deferred to M3 alongside the runtime writer.
- Pre-existing baseline test / lint failures (see Surprises) not addressed; out of scope per plan.

**Lessons:**
- `make build` (which hits `-workspace`) is the canonical green-gate; raw `xcodebuild -project` misses the Tuist-managed SPM products and fails on `ArgumentParser`. `make clean` also deletes `Tuist/Package.resolved`, so recovery needs `tuist install` before `tuist generate`.
- SwiftUI's `UnevenRoundedRectangle` + `Rectangle` overlay gives a cleaner "folder tab with accent stripe" than a single-corner radius trick and avoids a custom shape.
- Press state on the chip is exposed via a `ButtonStyle` that reflects `configuration.isPressed` into a parent binding; the alternative (custom gesture) fights SwiftUI's tap detection and tends to swallow clicks.

### M2 — 2026-04-24 — shipped on `feature/tab-and-pane`

**Shipped:**
- Manager / client API surface: `renameTab`, `reorderTabs`, `closeOtherTabs`, `closeTabsToRight`, `closeAllTabs`, `selectAdjacentTab` — all exposed through `HierarchyClient` with the matching live / liveValue / testValue scaffolding. `TabAdjacency` enum lives in `CodansCore`.
- `TabBarFeature.Action`: six new cases (renameSubmitted, contextMenuCloseOthers, contextMenuCloseToRight, contextMenuCloseAll, dragReorderEnded, middleClicked) plus `trailingSplitRequested(direction:...)` for the trailing split buttons. Reducer stays stateless; every case is a one-line forward or resolver.
- Chip interactions: right-click context menu (Rename / Close / Close Others [disabled single-tab] / Close to the Right [disabled last-tab] / Close All), inline `TextField` rename (Return commits, Esc discards), middle-click close (NSViewRepresentable bridge), drag-to-reorder (single `dragReorderEnded` dispatch on drop, spring settle).
- Row-level: `TabBarOverflowScroll` wraps the chip row with a hidden-scrollbar horizontal ScrollView, 16-pt leading/trailing gradient shadows that fade in only when the row overflows either edge, and a `ScrollViewReader.scrollTo(id, anchor: .center)` on `activeTabID` changes (easeInOut 0.15s). Trailing accessories (`+` / split-right / split-down) stay pinned outside the scroll.
- Trailing splits: clicking either split button resolves the leftmost leaf of the active tab and forwards through the existing `splitPane` client. Hovering either for 350 ms pops a miniature preview of the active tab's split tree (recursive GeometryReader + proportional frames).
- Main-menu shortcuts: `⌘T` (new tab), `⌘W` (close active tab), `⌘⇧[` / `⌘⇧]` (previous / next with wrap-around), `⌥⌘1..⌥⌘9` (select by index). All items disable when no Worktree is selected. The tab-index namespace dodges `⌘1..⌘9` (Space) and `⌃⌘1..⌃⌘9` (Worktree).
- Tests: `HierarchyManagerTests` gains 11 cases; `TabBarFeatureTests` gains 8 cases plus a stub fix that stabilizes the pre-existing `newTabButtonCallsCreateTab` in-suite flake noted in the M1 retrospective; `RootFeatureTests` gains 6 cases for the four resolver actions.

**Manual smoke script** (owner to run before merge):

1. Open 1 / 5 / 20 / 50 tabs via `⌘T`; confirm the row scrolls, edge gradients show, and the active chip auto-scrolls into view when using `⌘⇧]`.
2. Drag the leftmost chip to the middle of the row; release; order persists; spring settle is smooth.
3. Right-click any chip; exercise all five menu items, including the disable states (single-tab → Close Others disabled; last-tab → Close to the Right disabled).
4. Right-click → Rename…; type a new title, press Return; commit persists. Open a fresh Rename; press Esc; title unchanged and focus lands back in the previously focused pane.
5. Middle-click a chip; it closes without the context menu flashing.
6. `⌥⌘1..⌥⌘9` select Nth tab (no-op past `count`). `⌘1..⌘9` still switches Space; `⌃⌘1..⌃⌘9` still jumps Worktree (regression check).
7. Hover either trailing split button for >350 ms; preview popover shows a miniature of the active tab's tree. Click → new split lands on the leftmost leaf.

**Gaps / deferred:**
- Trailing split buttons anchor off the leftmost leaf rather than the user-focused pane; M3 upgrades the anchor selection once `lastFocusedPaneByTab` lands.
- `onScrollGeometryChange` is macOS 15+; the PreferenceKey-based shim is correct but less efficient. Revisit when the deployment target bumps.
- Snapshot reference PNGs still not committed — M3's focus wiring or a dedicated CI step will record them with a deterministic host window.
- `selectionChangedMirrorsActiveTabFromSnapshot` + `gitViewerOverlayVisibleTracksSelectionAgainstCatalog` baseline flakes in `RootFeatureTests` remain untouched; unrelated to M2 scope.

**Lessons:**
- `NSItemProvider`'s `loadObject` callback invokes off-main; non-Sendable TCA closures must be typed `@MainActor @Sendable` and called via `Task { @MainActor in … }` to compile clean under Swift 6 strict concurrency.
- SwiftUI `.contextMenu` + `@FocusState`-driven `TextField` is the cheapest path to inline rename; alternative (`.alert` / sheet) fights the chip's own hover/press state.
- Hover-delayed popovers want `Task.sleep` + cancellation on `.onHover(false)` rather than `DispatchWorkItem`; the async path composes with SwiftUI lifecycle without manual invalidation bookkeeping.
- Static vars can't live inside generic types; a file-private `let` constant works for "coordinate space name"-style sentinels without the generic-storage rules kicking in.

### M3 — 2026-04-24 — shipped on `feature/tab-and-pane`

**Shipped:**
- Two runtime-only maps on `HierarchyManager`: `lastFocusedPaneByTab` (focus memory) and `runningPanes` (dirty set). Neither is persisted — wall-clock state that rebuilds each launch.
- Five helpers: `setLastFocusedPane`, `lastFocusedPane(in:)`, `markPaneRunning`, `markPaneIdle`, `tabIsDirty(_:)`. Teardown paths (`closePane`, `closeTab`, `tearDownWorktreeSurfaces`) clear their entries; `focusPane` remembers the pane.
- `selectTab` restores focus automatically — routes `runtime.focusSurfaceView` on the remembered pane, falls back to the leftmost leaf when the memory is stale or absent.
- `HierarchyClient` gains four closures (`tabIsDirty`, `lastFocusedPane`, `markPaneRunning`, `markPaneIdle`); live / liveValue / testValue scaffolding in place.
- `TabChipLabel` renders a mini `ProgressView` in a 12×12 leading slot when `isDirty`. `TabBarRowView` accepts a `(TabID) -> Bool` lookup; `TabBarView` binds it to `hierarchyManager.tabIsDirty(_:)` so SwiftUI observation propagates future hook writes.
- Five new `HierarchyManagerTests` cases cover focus restoration (happy + stale), teardown cleanup (closePane + closeTab), and dirty signal propagation. `FakeHierarchyRuntime` now records `focusSurfaceView` calls so these assertions are inspectable.

**Gaps / deferred:**
- No production writer calls `markPaneRunning` / `markPaneIdle` today. The C3 hooks plan lands the writer when `command_started` / `command_finished` events ship.
- Focus restoration is synchronous — `runtime.focusSurfaceView` hits AppKit inside the same call as the catalog mutation. The existing `focusSurfaceView` implementation is a no-op in tests and best-effort in production; no backpressure logic needed today.
- Trailing split buttons still anchor off the leftmost leaf rather than the remembered pane. A one-line upgrade lands when the next follow-up touches them.

**Lessons:**
- `@Observable` tracking only fires for properties read through the observed instance in a view body. Reading through a plain closure (e.g. a TCA client) bypasses observation, so dirty-signal UI has to dereference the manager directly.
- Runtime-state teardown is easy to miss — `closePane`, `closeTab`, and `tearDownWorktreeSurfaces` all needed bookkeeping updates. Centralizing the "clear-on-teardown" pass in dedicated helpers would cut the diff but add indirection; the inline updates are shorter in the happy path.
- `Set` beats `[Key: Bool]` for "membership is the state" patterns — one less `.filter { $0.value }` per read and no "stored false" edge case to reason about.

### Post-review fixes — 2026-04-25 — `3a3263d` + `06e6a20`

Code-reviewer pass surfaced one Important behavioral bug and a handful of polish items. Resolved in two commits and folded into the Decision Log as D11 + D12.

**Important fix:**
- `closeTabsToRight` now reseats `selectedTabID = id` after the doomed-suffix loop (D11). Without this the auto-advance lands on `tabs.first` when the active tab was inside the suffix. Two new regression cases.

**Notable fix:**
- `selectAdjacentTab` routes through `selectTab` so the M3 focus-restoration block fires for the keyboard shortcut path (D12). One new regression case.

**Polish (commit `06e6a20`):**
- `TabBarOverflowScroll`'s coordinate-space sentinel marked `private` and renamed lowerCamel.
- `tabIsDirty(_:)` early-returns when `runningPanes.isEmpty` so chip renders skip the catalog walk in steady state (which is everything until C3 hooks ship a writer).
- `ChipDropDelegate.performDrop` gains a comment locking in "drop into target's slot" semantics.

**Acknowledged but not fixed** (out of scope or already documented):
- `⌘T` / `⌘W` collide with Ghostty's terminal-internal bindings. Menu binding wins on the responder chain — confirmed by review. Documented as a follow-up issue (Ghostty config note for users), not a code change.
- `liveValue` safe defaults for the four new read closures stand (Decision D9). Review concurred this is appropriate — DI failures still trap on the next mutation closure.

## Context and Orientation

Related documents:

- Design doc: `docs/design-docs/tab-bar.md` — read in full before touching code. Contains the visual spec table, component-boundary diagram, API sketches, alternatives, and risks.
- Product spec: `docs/product-specs/ui-main-window-redesign.md` — §Layout Overview shows where the Tab bar sits. Relevant for confirming we don't regress the Header / Sidebar / Git Viewer contracts.
- Architecture doc: `docs/architecture.md`.
- Related exec plans:
  - `docs/exec-plans/0007-tca-shell.md` — TCA module boundaries this plan respects.
  - `docs/exec-plans/mw-t3-gitviewer-overlay-shortcuts.md` — reference implementation for the Root-level shortcut resolver pattern used in D2.
  - `docs/exec-plans/panel-to-pane-rename.md` — vocabulary: we say "pane", never "panel".

Key source files:

- `apps/mac/codans/App/Features/TabBar/TabBarView.swift` — today's 78-line container. M1 splits it.
- `apps/mac/codans/App/Features/TabBar/TabBarFeature.swift` — current 55-line reducer with three actions. M2 adds new actions here.
- `apps/mac/codans/App/Features/WorktreeDetail/WorktreeDetailView.swift:82` — `tabBarRow(address:)` that mounts `TabBarView`; unchanged except for replacing `.padding(.horizontal, 8).padding(.vertical, 4)` with the container's own padding after M1.
- `apps/mac/codans/App/Features/WorktreeDetail/WorktreeDetailFeature.swift:14,19,24` — existing `Scope(state: \.tabBar, action: \.tabBar)` wiring. Untouched.
- `apps/mac/codans/App/Clients/HierarchyClient.swift` — add six closures in M2 + three in M3 (see Interfaces section).
- `apps/mac/codans/Runtime/HierarchyManager.swift` — add five methods in M2 (`renameTab`, `reorderTabs`, `closeOtherTabs`, `closeTabsToRight`, `closeAllTabs`, `selectAdjacentTab`) + five in M3 (focus memory + dirty). `moveTab(offset:)` at line 875 already exists; keep it for menu-driven moves.
- `apps/mac/codans/App/Commands/MainWindowCommands.swift` — add the five new tab shortcuts as a new `CommandGroup`. Keep the existing `CommandGroup(after: .newItem)` untouched.
- `apps/mac/codans/App/Features/Root/RootFeature.swift` — add Root-level resolver actions (see D2) alongside `openDefaultForCurrentWorktreeRequested` (line 138).
- `apps/mac/codans/Tests/TabBarFeatureTests.swift` — extend with every new action; mock `HierarchyClient` to assert the forwarded call shape.
- `apps/mac/codans/Tests/HierarchyManagerTests.swift` — extend with new manager methods + invariants.
- `apps/mac/codans/Tests/Snapshots/` — new suite `TabChipSnapshotTests.swift` (folder may not exist yet; Tuist's `buildableFolders` recurses, so no project edit needed).

### Terms of art

- **Chip**: one rendered tab. Not the `Tab` model — `TabChipView` is the SwiftUI view that renders a `Tab` for the current bar.
- **Idle / hover / active / press**: the four chip states. Only one chip is `active` at a time (the selected tab). `press` and `active` share the same background; `press` is transient on click.
- **Dirty**: any pane inside the tab is marked running. Rendered as a mini progress spinner in the label's leading position. Dormant in M3 — no writer yet.
- **Resolver action**: a Root-level TCA action that snapshots the catalog, resolves `(space, project, worktree, activeTab)`, and forwards to a child feature. Established pattern — see `openDefaultForCurrentWorktreeRequested` in `RootFeature.swift:138`.
- **Runtime-only map**: a dictionary on `HierarchyManager` that is not encoded into `Catalog`, so not persisted across launches. Cleared on teardown of the entity it keys on.
- **Trailing accessory cluster**: the fixed-position buttons at the right of the Tab bar. Do not scroll with chips; sit outside `TabBarOverflowScroll`.

Orientation: the three milestones align with the design doc's three layers and are independent by construction. M1 is a pure UI refactor — same behavior, new views — so it lands first without any risk to behavior. M2 adds client / feature surface and the new user-visible interactions; it depends on M1 for the view types it attaches gestures to. M3 adds runtime state the UI reads; it does not require M2 (the only binding is `TabChipLabel.isDirty` which is a pure read), so M3 can ship before or after M2 depending on reviewer bandwidth. Recommended merge order is M1 → M2 → M3 for PR readability, but an alternate M1 → M3 → M2 is also safe. Never merge M2 without M1.

## Plan of Work

### Milestone 1 — UI refactor (no behavior change)

**Scope.** Break `TabBarView` into eight focused view types plus two style modules. Produce the production visual vocabulary (underline, three-state backgrounds, hover close button, dividers, truncated labels). Do not add a single new user-visible action. At the end of M1 every existing `TabBarFeatureTests` case still passes and the bar behaves exactly as before, but looks production-quality.

**Work.**

1. Create `apps/mac/codans/App/Features/TabBar/Style/TabBarMetrics.swift` as an `enum TabBarMetrics` with `static let barHeight: CGFloat = 32`, `chipHeight: CGFloat = 28`, `chipMinWidth: CGFloat = 120`, `chipMaxWidth: CGFloat = 220`, `chipHorizontalPadding: CGFloat = 8`, `activeUnderlineHeight: CGFloat = 2`, `closeButtonSize: CGFloat = 16`, `dividerWidth: CGFloat = 1`, `dividerHeight: CGFloat = 16`, `chipCornerRadius: CGFloat = 6`, `hoverDelay: Duration = .milliseconds(350)`, `reorderMovementThreshold: CGFloat = 3`. Enum not struct — no initialization.
2. Create `apps/mac/codans/App/Features/TabBar/Style/TabBarColors.swift` as `enum TabBarColors` with static `Color` properties: `idleBg = .clear`, `hoverBg = Color.primary.opacity(0.06)`, `activeBg = Color(nsColor: .controlBackgroundColor)`, `activeUnderline = .accentColor`, `divider = Color(nsColor: .separatorColor).opacity(0.7)`, `closeButtonFg = Color.primary.opacity(0.7)`.
3. Create `apps/mac/codans/App/Features/TabBar/Views/TabChipBackground.swift` — a pure view that takes `isActive: Bool`, `isHovering: Bool`, `isPressing: Bool` and draws `RoundedRectangle(cornerRadius: TabBarMetrics.chipCornerRadius)` with top-only corners, the correct background fill per state, plus a `Rectangle()` of `TabBarMetrics.activeUnderlineHeight` at `.top` alignment when `isActive`. Top-only corners: `UnevenRoundedRectangle(topLeadingRadius: cr, topTrailingRadius: cr)` (iOS 16+ / macOS 13+).
4. Create `apps/mac/codans/App/Features/TabBar/Views/TabChipCloseButton.swift`. Takes `isHovering: Bool`, `isActive: Bool`, `action: () -> Void`. Renders a 16×16 circle with an `xmark` SF Symbol, visible only when `isHovering || isActive`. Uses `.buttonStyle(.borderless)` and explicit `.help("Close tab")`. Opacity transition `easeInOut(0.10s)`.
5. Create `apps/mac/codans/App/Features/TabBar/Views/TabChipLabel.swift`. Takes `title: String`, `isDirty: Bool` (default `false` — rendered path-only in M1). Renders `HStack(spacing: 4)`: if `isDirty`, a `ProgressView().controlSize(.mini).frame(width: 12, height: 12)` leading; otherwise no leading element. Trailing: `Text(title).lineLimit(1).truncationMode(.middle).font(.system(size: 12, weight: .regular))`.
6. Create `apps/mac/codans/App/Features/TabBar/Views/TabChipView.swift`. Composes background + label + close button. Owns `@State private var isHovering = false` and `@State private var isPressing = false`. Wraps content in `.onHover { isHovering = $0 }` and a minimal press-tracking button style. No context menu, no drag gesture, no middle-click in M1 — those come in M2. Dispatches tap to `onSelect: () -> Void` and close-button to `onClose: () -> Void`; both are closures passed from the parent (avoids importing `ComposableArchitecture` here).
7. Create `apps/mac/codans/App/Features/TabBar/Views/TabBarRowView.swift`. An `HStack(spacing: 0)` that iterates the tabs, interleaves `Divider()` (1-pt × 16-pt, colored per `TabBarColors.divider`) between adjacent non-active chips, and returns a `.frame(maxWidth: .infinity, alignment: .leading)`. Computes per-chip width: `floor((containerWidth − trailingWidth) / tabCount)` clamped to `[chipMinWidth, chipMaxWidth]`. Container width is read via `GeometryReader`.
8. Create `apps/mac/codans/App/Features/TabBar/Views/TabBarTrailingAccessories.swift`. In M1, render only the `+` button (`Image(systemName: "plus")`, `.buttonStyle(.borderless)`, dispatches new-tab action). Split-right and split-down buttons + hover preview come in M2.
9. Rewrite `apps/mac/codans/App/Features/TabBar/TabBarView.swift` as a thin container: reads `Worktree.tabs` from `HierarchyManager`, mounts `TabBarRowView` + `TabBarTrailingAccessories`, passes closures that send `store.send(.tabButtonTapped)` / `.closeButtonTapped` / `.newTabButtonTapped`. Height fixed to `TabBarMetrics.barHeight`; top edge flush with the pane area.
10. Update `apps/mac/codans/App/Features/WorktreeDetail/WorktreeDetailView.swift:82-93` (`tabBarRow(address:)`) — replace the outer `.padding(.horizontal, 8).padding(.vertical, 4)` with zero padding (the new `TabBarView` owns its own internal padding).
11. Create `apps/mac/codans/Tests/Snapshots/TabChipSnapshotTests.swift` — five cases covering idle / hover / active / active+hover / dirty (dirty uses `isDirty: true` via the view's `init`; M1 does not flip this from the client). Use the project's existing snapshot-testing harness if present; otherwise gate the file behind `#if canImport(SnapshotTesting)` so it's opt-in.

**Acceptance.** `make -C apps/mac lint` clean. `xcodebuild test -scheme codans` green — `TabBarFeatureTests` unchanged, new `TabChipSnapshotTests` green. Visual: open the app, switch tabs, hover chips, close a chip. Behavior identical to `main`; visuals match the design-doc spec.

### Milestone 2 — Interactions

**Scope.** Extend the API surface (`HierarchyManager`, `HierarchyClient`, `TabBarFeature`, `MainWindowCommands`), then attach UI handlers: right-click menu, inline rename, drag-to-reorder, middle-click close, overflow horizontal scroll with auto-scroll-to-selected, trailing split buttons with hover preview, main-menu keyboard shortcuts. Each sub-step is landable as its own commit.

**Work.**

1. `HierarchyManager` — append under the existing `// MARK: - Tab mutations` section (around line 516):
   - `renameTab(_:in:in:in:name:)` — writes `tabs[idx].name = name` (optional, `nil` clears). Unchanged value → silent no-op.
   - `reorderTabs(in:in:in:orderedIDs:)` — validates `Set(orderedIDs) == Set(existing.tabs.map(\.id))`; otherwise throws `.invariantViolation("tab reorder set mismatch")`. Writes the new order.
   - `closeOtherTabs(keeping:in:in:in:)` — iterates siblings and calls the existing `closeTab` path (same runtime-teardown semantics).
   - `closeTabsToRight(of:in:in:in:)` — same iteration pattern, bounded by `tabs.firstIndex(where: { $0.id == id })`.
   - `closeAllTabs(in:in:in:)` — equivalent to `closeOtherTabs` + final `closeTab` of the pivot, i.e. every tab is closed.
   - `selectAdjacentTab(direction:in:in:in:)` — wraps at ends. Returns the newly selected `TabID?` (nil when the Worktree has zero tabs).
2. `HierarchyClient` — add six closures matching the manager methods above, plus unimplemented stubs in `testValue` and fatal stubs in `liveValue`, plus live bindings in `.live(manager:gitWorktreeClient:)`. Update the client signature block comment.
3. `TabBarFeature` — add actions in this order (each a one-line client forward):
   - `renameSubmitted(TabID, name: String?, inWorktree:..., inProject:..., inSpace:...)`
   - `contextMenuCloseOthers(TabID, ...)`, `contextMenuCloseToRight(TabID, ...)`, `contextMenuCloseAll(inWorktree:..., inProject:..., inSpace:...)`
   - `dragReorderEnded(orderedIDs: [TabID], inWorktree:..., inProject:..., inSpace:...)`
   - `middleClicked(TabID, ...)` — forwards to `closeTab`.
   - `shortcutNewTab(...)`, `shortcutCloseActive(...)`, `shortcutSelectIndex(Int, ...)`, `shortcutSelectAdjacent(TabAdjacency, ...)`.
4. Create `apps/mac/codans/App/Features/TabBar/Views/TabChipContextMenu.swift` — a `ViewModifier` or `@ViewBuilder` that attaches `.contextMenu { … }` with Rename / Close / Close Others (disabled when `tabs.count <= 1`) / Close to the Right (disabled when the chip is the last tab) / Close All. Each item dispatches the matching `TabBarFeature.Action`. Rename opens an inline `TextField` via a per-chip `@State var editingTitle: String?` owned by `TabChipView`; commit sends `renameSubmitted`, `Esc` resets `editingTitle` to nil.
5. Create `apps/mac/codans/App/Features/TabBar/Views/TabChipMiddleClickView.swift` — `NSViewRepresentable` wrapping a bespoke `NSView` override of `otherMouseUp(with:)` (middle-mouse-button up). Exposes an `onMiddleClick: () -> Void` closure. Attach as a background to `TabChipView`.
6. In `TabBarRowView`, add a `DragGesture(minimumDistance: TabBarMetrics.reorderMovementThreshold)` that translates pointer deltas into chip-order updates locally (`@State var draggingOffset: [TabID: CGFloat]`), and on `.onEnded` computes the final ordered IDs and dispatches `dragReorderEnded`. Use `withAnimation(.spring(response: 0.3, dampingFraction: 0.85))` for the drop.
7. Create `apps/mac/codans/App/Features/TabBar/Views/TabBarOverflowScroll.swift` — wraps `TabBarRowView` in a horizontal `ScrollView(.horizontal, showsIndicators: false)` + `ScrollViewReader`. On `.onChange(of: activeTabID)` calls `proxy.scrollTo(activeTabID, anchor: .center)` inside `withAnimation(.easeInOut(duration: 0.15))`. Tracks `contentOffset` via `.onScrollGeometryChange` (macOS 14+; fall back to reading a `GeometryReader` on the inner HStack if the host macOS is lower — project currently pins Xcode 26.0, so the newer API is available). Renders two 16-pt `LinearGradient`-filled rectangles as overlays: left fade visible when `contentOffset > 0`, right fade when `contentOffset < maxOffset`.
8. Extend `TabBarTrailingAccessories` — add split-right (`Image(systemName: "rectangle.split.2x1")`) and split-down (`Image(systemName: "rectangle.split.1x2")`) buttons. Each dispatches to the existing `PaneActionRouter` via a closure on the parent (or directly via `HierarchyClient.splitPane` if the active pane is resolvable). Create `apps/mac/codans/App/Features/TabBar/Views/SplitPreviewPopoverView.swift` — a miniature of the current `Tab.splitTree` rendered with scaled-down rectangles labelled by initial pane command. Trigger with `.onHover { hovering in if hovering { Task { try? await Task.sleep(for: TabBarMetrics.hoverDelay); showPreview = true } } else { showPreview = false } }` + `.popover(isPresented: $showPreview) { SplitPreviewPopoverView(...) }`. Cancellable via `.task` identity or a debounce boolean.
9. `RootFeature` — add resolver actions beside `openDefaultForCurrentWorktreeRequested`:
   - `newTabForCurrentWorktree`
   - `closeActiveTabForCurrentWorktree`
   - `selectTabAtIndexForCurrentWorktree(Int)`
   - `selectAdjacentTabForCurrentWorktree(TabAdjacency)`

   Each snapshots `hierarchyClient.snapshot()`, resolves the active worktree, and forwards to the nested `.worktreeDetail(.tabBar(…))` action tree (or calls `HierarchyClient` directly when the target `TabBarFeature.Action` carries the `(worktree, project, space)` triplet — both patterns are acceptable; pick the one that does not duplicate ID-threading code).

10. `MainWindowCommands` — add a new `CommandGroup(after: .newItem)` **below** the existing one (or extend the existing one), containing: `New Tab` (`⌘T`), `Close Tab` (`⌘W`), `Previous Tab` (`⌘⇧[`), `Next Tab` (`⌘⇧]`), plus a `ForEach(1...9)` block binding `⌥⌘N` to `selectTabAtIndexForCurrentWorktree(N)`. Each item disabled via `hasActiveWorktree` (already computed on the struct). Update the doc-comment to mention the new bindings and the `⌘1..⌘9` / `⌃⌘1..⌃⌘9` / `⌥⌘1..⌥⌘9` cascade.
11. Extend `TabBarFeatureTests` with one case per new action forwarding the expected `HierarchyClient` call. Extend `HierarchyManagerTests` with:
    - `renameTabWritesName`, `renameTabNoOpOnUnchanged`
    - `reorderTabsAcceptsPermutation`, `reorderTabsRejectsSubset`, `reorderTabsRejectsExtraID`
    - `closeOthersKeepsPivotSelected`, `closeToRightTrimsSuffix`, `closeAllClearsWorktree`
    - `selectAdjacentWrapsAtBothEnds`, `selectAdjacentReturnsNilOnEmpty`
12. Extend `RootFeatureTests` with the four new resolver actions — verify each forwards the right `TabBarFeature.Action` when a worktree is selected, and is a no-op when no worktree is selected.

**Acceptance.** `make -C apps/mac lint` clean. Full test suite green (`xcodebuild test -scheme codans`). Manual smoke script in the PR description passes. In the running app:

- Right-click a chip → context menu has five items with correct enable/disable states.
- Rename: commit persists; `Esc` reverts; terminal regains first-responder status (verify by typing into a pane immediately after commit).
- Drag a chip 5+ positions; release; order update is atomic, no flicker.
- Middle-click a chip → it closes; no context menu briefly flashes.
- Open 30 tabs via `⌘T` repetition; bar scrolls, edge gradients show; active tab auto-scrolls into view when using `⌘⇧]`.
- Hover a split button for a beat → preview popover appears; move pointer off → it dismisses.
- `⌥⌘1..⌥⌘9` select the Nth tab (no-op past `count`). `⌘1..⌘9` still switches Space (existing, unchanged). `⌃⌘1..⌃⌘9` still jumps Worktree.

### Milestone 3 — Runtime state: focus memory + dirty read path

**Scope.** Add non-persisted runtime maps to `HierarchyManager` and expose them through `HierarchyClient`. Restore focused pane on tab switch. Wire the `isDirty` read path into `TabChipLabel`. No writer for `paneRunning` in this PR — the writer lands with the C3 hooks plan.

**Work.**

1. `HierarchyManager`:
   - Private `var lastFocusedPaneByTab: [TabID: PaneID] = [:]`.
   - Private `var paneRunning: [PaneID: Bool] = [:]`.
   - Public `func setLastFocusedPane(_ paneID: PaneID?, in tabID: TabID)` — `nil` clears.
   - Public `func lastFocusedPane(in tabID: TabID) -> PaneID?`.
   - Public `func markPaneRunning(_ paneID: PaneID)` / `markPaneIdle(_ paneID: PaneID)` — writes the map; silent no-op on unchanged value so callers can fire without dedup.
   - Public `func tabIsDirty(_ tabID: TabID) -> Bool` — walks the tab's panes and returns `paneRunning.values.contains(true)` over that slice.
   - Housekeeping: `closePane` removes the pane id from both maps. `closeTab` removes the tab id from `lastFocusedPaneByTab` and every pane of the tab from `paneRunning`. `tearDownWorktreeSurfaces` clears both maps for every affected id.
   - `selectTab` reads `lastFocusedPane(in:)`; if present and the pane still exists, calls `runtime.focusSurfaceView(for: paneID)`; otherwise falls back to the leftmost leaf of `tab.splitTree`.
   - `focusPane` writes `setLastFocusedPane(paneID, in: tabID)` alongside its existing work.
2. `HierarchyClient` — three closures (`tabIsDirty`, `lastFocusedPane`, and dormant `markPaneRunning` / `markPaneIdle`). The passive writer closures are exposed so C3 hooks can bind to them without touching `HierarchyManager` directly.
3. `TabChipLabel` — add `let isDirty: Bool` parameter (already present from M1 with default `false`); now passed in by `TabChipView` as `hierarchyClient.tabIsDirty(tab.id)`. `TabChipView` reads the client via `@Dependency(\.hierarchyClient) var hierarchyClient` (TCA) — or via an explicit prop if we want to keep dependency usage out of view types.
4. Accessibility — append `" (running)"` to the chip's `accessibilityLabel` when dirty. VoiceOver will announce it alongside the title.
5. `HierarchyManagerTests`:
   - `focusRestoresLastFocusedPane` — open two panes in a tab, focus the second, switch tabs, switch back → second pane is focused.
   - `focusFallsBackToLeftmostWhenStoredPaneGone` — stored pane was closed via another path.
   - `closePaneClearsBothMaps`.
   - `closeTabClearsMapsForAllPanes`.
   - `tabIsDirtyReflectsAnyRunningPane` — mark pane A running → tab is dirty; mark idle → clean.
6. Wire a single snapshot case into `TabChipSnapshotTests` for `dirty: true` (already added placeholder in M1; this step verifies it renders the spinner when driven by client state in a live store rather than a fixed `true`).

**Acceptance.** `make -C apps/mac lint` clean. Test suite green. Manual smoke: open two panes in a tab, focus the right one, switch tabs, switch back → the right one is focused and cursor sits there immediately. With `paneRunning` set by a test helper, the chip's spinner renders; in production, spinners never appear (no writer). Reverting to pre-M3 `main` does not leave any broken callers — M3 is purely additive.

## Concrete Steps

All commands run from the repository root unless stated. Environment assumptions: Xcode 26.0+, mise trusted, Ghostty xcframework cache primed (per `CLAUDE.md` Quick Start).

### Before starting any milestone

```bash
# Working tree clean
git status
# Expected:
# On branch <your-branch>
# nothing to commit, working tree clean

# Baseline tests green
make -C apps/mac mac-generate
make -C apps/mac mac-lint
xcodebuild -project apps/mac/codans.xcodeproj -scheme codans \
  -destination 'platform=macOS' test | xcbeautify
# Expected: BUILD SUCCEEDED; 0 failing tests.
```

If the baseline is red, fix or revert before proceeding — do not build new work on a red main.

### After each task commit (all milestones)

```bash
make -C apps/mac mac-lint
xcodebuild -project apps/mac/codans.xcodeproj -scheme codans \
  -destination 'platform=macOS' test | xcbeautify
```

### M2 Task 1 — add five manager methods

Edit `apps/mac/codans/Runtime/HierarchyManager.swift`, append methods after line 596 (`selectTab`). Then:

```bash
xcodebuild -project apps/mac/codans.xcodeproj -scheme codans \
  -destination 'platform=macOS' test -only-testing:Codans-tests/HierarchyManagerTests \
  | xcbeautify
```

Expected: new test cases in `HierarchyManagerTests` added in this same task (see T2.10) all pass.

### M2 Task 10 — add shortcuts

After editing `MainWindowCommands.swift`, launch the app and observe the menu bar:

```bash
make -C apps/mac mac-run-app
```

Menu **File** (or wherever the `CommandGroup(after: .newItem)` lands) should list **New Tab ⌘T**, **Close Tab ⌘W**, **Previous Tab ⌘⇧[**, **Next Tab ⌘⇧]**, **Switch to Tab 1 ⌥⌘1** … **Switch to Tab 9 ⌥⌘9**. All disabled when no Worktree is selected.

### M3 Task 1 — add runtime maps

Edit `HierarchyManager.swift`, run:

```bash
xcodebuild -project apps/mac/codans.xcodeproj -scheme codans \
  -destination 'platform=macOS' test -only-testing:Codans-tests/HierarchyManagerTests \
  | xcbeautify
```

## Validation and Acceptance

- After M1: `git diff main…HEAD -- apps/mac/codans/App/Features/TabBar` shows the split across ten files. The app launches, the bar renders with the new visuals, and every pre-existing test in `TabBarFeatureTests` passes unchanged. `TabChipSnapshotTests` has five green cases.
- After M2: every row in the M2 Acceptance subsection is demonstrable in a fresh app launch. `HierarchyManagerTests` has ≥ 10 new cases; `TabBarFeatureTests` ≥ 8 new cases; `RootFeatureTests` ≥ 4 new cases. `make -C apps/mac mac-lint` clean.
- After M3: switching tabs restores the pane that was focused in the target tab (verified by manual smoke and by `focusRestoresLastFocusedPane`). `tabIsDirty` round-trips through the client in a `TestStore` case. Spinners never render in production because no writer exists yet.

Each milestone is independently verifiable and each commit should be capable of landing on `main` without reverting.

## Idempotence and Recovery

All manager methods accept repeated calls: `renameTab` to the same value is a silent no-op, `reorderTabs` with the current order is a silent no-op, `closeOtherTabs` on an already-single-tab worktree is a silent no-op. Runtime maps tolerate repeated writes (guarded by unchanged-value checks before save).

If a pull mid-milestone introduces conflicts in `HierarchyClient.swift`, `HierarchyManager.swift`, or `MainWindowCommands.swift`, rebase preserves our additions because every change is additive (new methods, new closures, new actions) — never edit existing closures out of order. If `Tab.swift` gains fields in parallel work (e.g. C3 hooks land first and add `isDirty`), reconcile by deleting the runtime map-based `tabIsDirty` reader in M3 and rebinding `TabChipLabel` to `tab.isDirty` — the view surface does not change.

Rollback per milestone:

- M1: revert the TabBar commit chain; the app returns to today's styling. No client or manager surface touched.
- M2: revert commits from T2.10 backwards to T2.1. `HierarchyClient` loses six closures; do a clean build to catch any external caller (there should be none outside `TabBarFeature` and its tests).
- M3: revert commits from T3.5 backwards to T3.1. No persisted state touched; `catalog.json` on user disks is unaffected.

## Artifacts and Notes

Expected file tree at end of plan:

    apps/mac/codans/App/Features/TabBar/
    ├── TabBarFeature.swift                 (reducer + new actions)
    ├── TabBarView.swift                    (thin container)
    ├── Style/
    │   ├── TabBarMetrics.swift
    │   └── TabBarColors.swift
    └── Views/
        ├── TabBarRowView.swift             (HStack + drag)
        ├── TabBarOverflowScroll.swift      (scroll + gradients)
        ├── TabBarTrailingAccessories.swift (+, split-right, split-down)
        ├── TabChipBackground.swift
        ├── TabChipCloseButton.swift
        ├── TabChipContextMenu.swift
        ├── TabChipLabel.swift
        ├── TabChipMiddleClickView.swift
        ├── TabChipView.swift
        └── SplitPreviewPopoverView.swift

Test tree:

    apps/mac/codans/Tests/
    ├── TabBarFeatureTests.swift            (extended)
    ├── HierarchyManagerTests.swift         (extended)
    ├── RootFeatureTests.swift              (extended)
    └── Snapshots/
        └── TabChipSnapshotTests.swift      (new)

No prototyping was needed pre-plan — the visual contract, drag semantics, and focus-memory approach each have direct precedent in the current codebase (shortcut resolver pattern in `mw-t3-gitviewer-overlay-shortcuts`, `@Observable` runtime maps in `HierarchyManager`, NSViewRepresentable bridging in `apps/mac/codans/App/Features/PaneContainer/`).

## Interfaces and Dependencies

### `apps/mac/codans/Runtime/HierarchyManager.swift`

New public methods (append to the existing `HierarchyManager`):

```
// MARK: - Tab mutations (tab-bar uplift)

func renameTab(
  _ id: TabID,
  in worktreeID: WorktreeID, in projectID: ProjectID, in spaceID: SpaceID,
  name: String?
) throws

func reorderTabs(
  in worktreeID: WorktreeID, in projectID: ProjectID, in spaceID: SpaceID,
  orderedIDs: [TabID]
) throws

func closeOtherTabs(
  keeping id: TabID,
  in worktreeID: WorktreeID, in projectID: ProjectID, in spaceID: SpaceID
) throws

func closeTabsToRight(
  of id: TabID,
  in worktreeID: WorktreeID, in projectID: ProjectID, in spaceID: SpaceID
) throws

func closeAllTabs(
  in worktreeID: WorktreeID, in projectID: ProjectID, in spaceID: SpaceID
) throws

func selectAdjacentTab(
  direction: TabAdjacency,
  in worktreeID: WorktreeID, in projectID: ProjectID, in spaceID: SpaceID
) throws -> TabID?

// MARK: - Runtime state (tab-bar uplift)

func setLastFocusedPane(_ paneID: PaneID?, in tabID: TabID)
func lastFocusedPane(in tabID: TabID) -> PaneID?

func markPaneRunning(_ paneID: PaneID)
func markPaneIdle(_ paneID: PaneID)
func tabIsDirty(_ tabID: TabID) -> Bool
```

### `apps/mac/codans/App/Clients/HierarchyClient.swift`

New closures (add nine; match the live / test / liveValue scaffolding in the existing file):

```
var renameTab: @MainActor @Sendable (
  _ id: TabID,
  _ inWorktree: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID,
  _ name: String?
) throws -> Void

var reorderTabs: @MainActor @Sendable (
  _ inWorktree: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID,
  _ orderedIDs: [TabID]
) throws -> Void

var closeOtherTabs: @MainActor @Sendable (
  _ keeping: TabID,
  _ inWorktree: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID
) throws -> Void

var closeTabsToRight: @MainActor @Sendable (
  _ of: TabID,
  _ inWorktree: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID
) throws -> Void

var closeAllTabs: @MainActor @Sendable (
  _ inWorktree: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID
) throws -> Void

var selectAdjacentTab: @MainActor @Sendable (
  _ direction: TabAdjacency,
  _ inWorktree: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID
) throws -> TabID?

var tabIsDirty:         @MainActor @Sendable (_ tabID: TabID) -> Bool
var lastFocusedPane:    @MainActor @Sendable (_ in: TabID) -> PaneID?
var markPaneRunning:    @MainActor @Sendable (_ paneID: PaneID) -> Void
var markPaneIdle:       @MainActor @Sendable (_ paneID: PaneID) -> Void
```

`TabAdjacency` is a new public enum in `CodansCore` alongside `ResizeDirection`:

```
public enum TabAdjacency: Sendable, Equatable {
  case previous
  case next
}
```

### `apps/mac/codans/App/Features/TabBar/TabBarFeature.swift`

Extend `Action` with:

```
case renameSubmitted(
  TabID, name: String?,
  inWorktree: WorktreeID, inProject: ProjectID, inSpace: SpaceID)
case contextMenuCloseOthers(
  TabID, inWorktree: WorktreeID, inProject: ProjectID, inSpace: SpaceID)
case contextMenuCloseToRight(
  TabID, inWorktree: WorktreeID, inProject: ProjectID, inSpace: SpaceID)
case contextMenuCloseAll(
  inWorktree: WorktreeID, inProject: ProjectID, inSpace: SpaceID)
case dragReorderEnded(
  orderedIDs: [TabID],
  inWorktree: WorktreeID, inProject: ProjectID, inSpace: SpaceID)
case middleClicked(
  TabID, inWorktree: WorktreeID, inProject: ProjectID, inSpace: SpaceID)
case shortcutNewTab(
  inWorktree: WorktreeID, inProject: ProjectID, inSpace: SpaceID)
case shortcutCloseActive(
  activeTabID: TabID,
  inWorktree: WorktreeID, inProject: ProjectID, inSpace: SpaceID)
case shortcutSelectIndex(
  Int,
  inWorktree: WorktreeID, inProject: ProjectID, inSpace: SpaceID)
case shortcutSelectAdjacent(
  TabAdjacency,
  inWorktree: WorktreeID, inProject: ProjectID, inSpace: SpaceID)
```

Reducer stays stateless; every case is a single `try?` call into the matching `hierarchyClient` closure.

### `apps/mac/codans/App/Features/Root/RootFeature.swift`

Add alongside `openDefaultForCurrentWorktreeRequested`:

```
case newTabForCurrentWorktree
case closeActiveTabForCurrentWorktree
case selectTabAtIndexForCurrentWorktree(Int)
case selectAdjacentTabForCurrentWorktree(TabAdjacency)
```

Each resolver looks up the current `(space, project, worktree, activeTab)` from `hierarchyClient.snapshot()` and forwards to `.worktreeDetail(.tabBar(...))`. No-op when any level of the selection is `nil`.

### `apps/mac/codans/App/Commands/MainWindowCommands.swift`

Add a second `CommandGroup` (or extend the existing one; both are acceptable):

```
CommandGroup(after: .newItem) {
  Button("New Tab") {
    store.send(.newTabForCurrentWorktree)
  }
  .keyboardShortcut("t", modifiers: .command)
  .disabled(!hasActiveWorktree)

  Button("Close Tab") {
    store.send(.closeActiveTabForCurrentWorktree)
  }
  .keyboardShortcut("w", modifiers: .command)
  .disabled(!hasActiveWorktree)

  Divider()

  Button("Previous Tab") {
    store.send(.selectAdjacentTabForCurrentWorktree(.previous))
  }
  .keyboardShortcut("[", modifiers: [.command, .shift])
  .disabled(!hasActiveWorktree)

  Button("Next Tab") {
    store.send(.selectAdjacentTabForCurrentWorktree(.next))
  }
  .keyboardShortcut("]", modifiers: [.command, .shift])
  .disabled(!hasActiveWorktree)

  Divider()

  ForEach(1...9, id: \.self) { n in
    Button("Switch to Tab \(n)") {
      store.send(.selectTabAtIndexForCurrentWorktree(n))
    }
    .keyboardShortcut(
      KeyEquivalent(Character("\(n)")),
      modifiers: [.command, .option])
    .disabled(!hasActiveWorktree)
  }
}
```

Dependencies used (all already in the repo): SwiftUI, AppKit (for `NSViewRepresentable`), Observation, Foundation, ComposableArchitecture, CodansCore. No new third-party packages.
