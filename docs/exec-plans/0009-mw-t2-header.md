# ExecPlan: Main-Window T2 — Header Row (branch label + bell + Open-in split + GV toggle)

**Status:** Draft
**Author:** Gump (T2 sub-agent, via Claude)
**Date:** 2026-04-21

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this change, every selected Worktree shows a Header row above the terminal Tab bar with (a) a read-only `⎇ branch` label, (b) a notification bell that badges the *catalog-resolvable* global unread count and opens a popover grouped by Project → Worktree, (c) a split button that opens the Worktree in the default editor on the primary click and reveals the full editor picker on the caret, and (d) a Git Viewer toggle bound to the persisted `Worktree.gitViewerVisible` flag. The old legacy `WorktreeHeaderOpenButton` dropdown and the `ContentView` toolbar inspector toggle are removed in the same PR; there is exactly one visibility source of truth for the Git Viewer column. End-users can now see completed-agent notifications without opening a sidebar, hand a worktree off to their editor in one click, and toggle the Git Viewer from the Header.

## Progress

- [ ] M1 — `NotificationInbox.totalUnread(in:)` pure helper in CodansCore + unit tests
- [ ] M2 — `InboxClient.markReadForWorktree` + `HierarchyClient.setWorktreeGitViewerVisible` closures (liveValue + testValue) + client wiring tests
- [ ] M3 — `EditorFeature.resolveDefault` static helper + unit test; legacy dropdown label continues to work via the new helper (deletion happens in M5)
- [ ] M4 — `WorktreeHeaderFeature` reducer (State, Action, delegate, effects) + `WorktreeHeaderFeatureTests` via TestStore; no view yet
- [ ] M5 — Header SwiftUI views (`WorktreeHeaderView`, `HeaderBellView`, `HeaderBellPopover`, `HeaderOpenSplitButton`, `HeaderGitViewerToggle`) + previews; mount in `WorktreeDetailView`; delete `WorktreeHeaderOpenButton.swift`; update `docs/architecture.md` entry
- [ ] M6 — `RootFeature` integration: Scope + delegate routing + `resolveGVVisible` helper; delete `RootFeature.State.inspectorVisible` + `.inspectorVisibilityToggled`; remove `ContentView` toolbar inspector item; rebind `ContentView` detail column to `resolveGVVisible(selection)`
- [ ] M7 — Full local verification (lint + all test schemes); push `feat/mw-header`; open PR to `feature/main-window`; post `PR_READY`

## Surprises & Discoveries

(None yet)

## Decision Log

- **D1**: Scope hierarchy keeps the bell subscription inside `WorktreeHeaderFeature` rather than reusing `InboxSidebarFeature`'s subscription. Rationale: the bell popover needs Worktree-scoped `markRead` on row-tap plus worktree selection chaining; the sidebar feature's row-tap emits `.deeplinkRequested(PaneID)` for pane focus, which is a different verb.
- **D2**: `ContentView` continues to render the Git Viewer as the 3rd column in an `HStack` (no overlay conversion in T2). The visibility predicate switches from `store.inspectorVisible` to a catalog-derived `resolveGVVisible(selection)` helper in `ContentView`. T3 replaces the entire `HStack` shape with a trailing overlay; see design doc §Coordination with T3 for the locked diff range.
- **D3**: `WorktreeHeaderOpenButton.swift` is deleted in M5 (zero tests reference it; `grep -r WorktreeHeaderOpenButton apps/mac/codans/Tests` returns nothing). The new `HeaderOpenSplitButton` covers the picker + Project-override sub-menu.
- **D4**: `NotificationInbox.totalUnread(in:)` is defined alongside the T0 aggregation helpers in `NotificationInboxAggregation.swift`, not on `InboxStore`. Keeps aggregation pure / Sendable / testable without MainActor plumbing.
- **D5** (execution-time divergence from Plan M3, 2026-04-21): Plan M3 described the "override-configured-but-missing-from-descriptors" path as resolving to `.finder` (treat a stale override id as "user wants this specific one, it's gone"). During execution, the helper was implemented with **cascade-to-global** instead. Reason: the pre-T2 `WorktreeHeaderOpenButton.currentDefaultLabel` uses cascade (override → global → Finder), and preserving that UX means a removed custom-editor override does not strand users on Finder when a global is set — the stale override id just yields to the global default. `EditorFeatureTests.resolveDefaultCascadesThroughMissingOverrideToGlobal` replaces the `ReturnsFinderWhenMissing` case; the design doc §API Design § `resolveDefault` note now documents the cascade semantics. Noted explicitly because this diverged from Plan without a prior QUESTION/CLARIFY round — future divergences recorded the same way should pause to surface the choice first.
- **D6** (execution-time, 2026-04-21, per master REVISE round 2): `WorktreeHeaderFeature.State` exposes `unreadCount(in: Catalog) -> Int` instead of caching the count in a stored field. Reason: catalog-only mutations (e.g. removing a Worktree that orphans an unread notification) previously required an extra dispatched signal (`.catalogChanged`) from `RootFeature.selectionChanged` to invalidate the cache. That path missed catalog mutations outside of selection changes (user removes a non-selected Worktree → orphan count persists). Switching to a computed accessor that takes the caller's catalog at read time lets views consume the live `@Environment(HierarchyManager.self).catalog` and guarantees badge updates on any observable catalog mutation — SwiftUI's own observation drives the redraw. `.catalogChanged` action and its `RootFeature.selectionChanged` dispatch removed.

## Outcomes & Retrospective

(To be filled at milestone completion)

## Context and Orientation

Related documents:

- Product spec: `docs/product-specs/ui-main-window-redesign.md`
- Design doc: `docs/design-docs/mw-t2-header.md`
- T0 foundation ExecPlan: `docs/exec-plans/0008-mw-t0-foundation.md`
- Architecture doc: `docs/architecture.md`

Key source files (post-T0 state):

- `apps/mac/CodansCore/Notifications/NotificationInboxAggregation.swift` — Hosts the four T0 helpers (`unreadCount(forWorktree:in:)`, two `hasUnread`, `notifications(forWorktree:in:)`). Adds `totalUnread(in:)` (M1).
- `apps/mac/CodansCore/Catalog.swift` — Source of `panelWorktreeIndex()`, `paneIDs(inWorktree:)`, `worktreeID(forPane:)`. No changes.
- `apps/mac/codans/Notifications/InboxStore.swift` — Hosts `markRead(forWorktree:in:)` + `dismissAll` (T0). No changes.
- `apps/mac/codans/App/Clients/InboxClient.swift` — TCA bridge over `InboxStore`. Grows one closure (`markReadForWorktree`) in M2.
- `apps/mac/codans/App/Clients/HierarchyClient.swift` — TCA bridge over `HierarchyManager`. Grows one closure (`setWorktreeGitViewerVisible`) in M2.
- `apps/mac/codans/App/Features/Editor/EditorFeature.swift` — Today holds `currentDefaultLabel` resolution logic inside `WorktreeHeaderOpenButton.swift`. M3 lifts it into `EditorFeature.resolveDefault`.
- `apps/mac/codans/App/Features/WorktreeHeader/WorktreeHeaderOpenButton.swift` — Legacy dropdown. Deleted in M5.
- `apps/mac/codans/App/Features/WorktreeDetail/WorktreeDetailView.swift` — Hosts the ad-hoc `worktreeHeader(address:)` `HStack`. M5 rewrites to mount `WorktreeHeaderView`.
- `apps/mac/codans/App/Features/Root/RootFeature.swift` — Gains `worktreeHeader` Scope and delegate routing in M6; loses `inspectorVisible` + `.inspectorVisibilityToggled`.
- `apps/mac/codans/App/ContentView.swift` — Loses the second `ToolbarItem` and rebinds the GV column to `resolveGVVisible(selection)` in M6.

Terminology:

- **Orphan notification** — an `AgentNotification` whose `paneID` is no longer present in the current catalog (pane closed / worktree removed). Per design, orphans are excluded from both the bell badge count and the popover's rendered rows.
- **Catalog-resolvable unread** — an unread, non-dismissed `AgentNotification` whose `paneID` still resolves to a Worktree in the catalog.
- **Primary / caret** — the two halves of the Open-in split button. Primary dispatches the default editor open; caret opens the picker menu.

## Plan of Work

Vertical slices, one complete path per milestone. Every milestone is independently buildable + testable + commit-ready. The order respects dependencies: pure helpers (M1) → client closures (M2) → reducer helper (M3) → feature reducer (M4) → views (M5) → wire-up + removals (M6) → verify + ship (M7).

### Milestone 1: `NotificationInbox.totalUnread(in:)`

Add the catalog-resolvable global-unread helper that the bell badge consumes. Pure extension on `NotificationInbox`; mirrors the T0 pattern of walking `panelWorktreeIndex()` once per call with a doc-comment telling render-hot callers to cache a snapshot-scoped index.

Edit `apps/mac/CodansCore/Notifications/NotificationInboxAggregation.swift`:

- Add `public func totalUnread(in catalog: Catalog) -> Int`. Body walks `catalog.panelWorktreeIndex()` once, reduces `notifications.reduce(into: 0)` counting entries where `isUnread` is true **and** the index lookup for the entry's `paneID` is non-nil (filters orphans). Doc-comment: *"Render-hot paths should cache a snapshot-scoped index. Counts unread, non-dismissed notifications whose pane resolves to some Worktree in the given catalog. Shared by the Header bell badge and intended as the canonical 'total resolvable unread' accessor. Orphans (paneID not in catalog) are excluded, matching the popover grouping's rendering policy so badge count and popover row count never diverge."*

Edit `apps/mac/CodansCoreTests/NotificationInboxAggregationTests.swift`:

- Add `func testTotalUnreadInCatalogExcludesOrphans()` — build a `Catalog` with one Worktree holding one Pane, then an inbox with (1) one unread whose `paneID` is that pane, (2) one unread orphan, (3) one read entry in-catalog, (4) one dismissed entry in-catalog. Assert `inbox.totalUnread(in: catalog) == 1`.
- Add `func testTotalUnreadEmpty()` — empty inbox → 0.
- Add `func testTotalUnreadAllReadOrDismissed()` — several read/dismissed entries → 0.

Acceptance: `xcodebuild test -scheme CodansCore -destination 'platform=macOS'` passes with three new cases green; no other test file churn.

### Milestone 2: Client closure extensions

Expose the two store-level operations the Header feature dispatches through. Both follow the existing `InboxClient` / `HierarchyClient` shape: `@MainActor @Sendable` closure, `liveValue` binds to the live store, `testValue` is `unimplemented(...)` with an appropriate placeholder.

Edit `apps/mac/codans/App/Clients/InboxClient.swift`:

- Add closure field `var markReadForWorktree: @MainActor @Sendable (_ worktreeID: WorktreeID, _ catalog: Catalog) -> Void` with a doc-comment linking to `InboxStore.markRead(forWorktree:in:)`.
- Extend `InboxClient.live(inbox:settings:)` with `markReadForWorktree: { wtID, catalog in inbox.markRead(forWorktree: wtID, in: catalog) }`.
- Extend `liveValue` fatalError stub and `testValue` unimplemented stub.

Edit `apps/mac/codans/App/Clients/HierarchyClient.swift`:

- Add closure field `var setWorktreeGitViewerVisible: @MainActor @Sendable (_ worktreeID: WorktreeID, _ visible: Bool) -> Void`. Doc-comment: *"Silent no-op on unknown worktreeID; persists through the standard debounced `store.scheduleSave(catalog)` pipeline per T0 §D5. Consumed by T2's Header GV toggle."*
- Extend `HierarchyClient.live(manager:)` with `setWorktreeGitViewerVisible: { id, vis in manager.setWorktreeGitViewerVisible(worktreeID: id, visible: vis) }`.
- Extend `liveValue` fatalError stub and `testValue` unimplemented stub.

Edit `apps/mac/codans/Tests/HierarchyClientTests.swift` (if exists and already smokes the live bridge):

- Add a round-trip: create a catalog with one worktree, call the new closure via the live client, assert `manager.catalog` reflects `gitViewerVisible == true` then `false` on toggle.

Edit `apps/mac/codans/Tests/NotificationsTests/InboxStoreTests.swift` (or a sibling for `InboxClient` if one exists):

- If there is no `InboxClient` bridging test today, add a lightweight one that wires the live client against an in-memory `InboxStore`, appends a notification with a known paneID, builds a catalog placing that pane under a worktree, invokes `markReadForWorktree`, and asserts `inbox.notifications[0].readAt != nil`.

Acceptance: all three test schemes (`CodansCore`, `codans`, any app-level smoke) build and pass; lint unchanged.

### Milestone 3: `EditorFeature.resolveDefault`

Hoist the resolution chain out of the legacy dropdown so both the split button and the legacy dropdown (still live until M5) consume one source of truth.

Edit `apps/mac/codans/App/Features/Editor/EditorFeature.swift`:

- Add an enum inside `EditorFeature`: `enum ResolvedDefault: Equatable { case editor(EditorDescriptor); case finder }`.
- Add static helper:
  ```
  static func resolveDefault(
    projectOverride: EditorID?,
    globalDefault: EditorID?,
    descriptors: [EditorDescriptor]
  ) -> ResolvedDefault
  ```
  Logic mirrors the existing `currentDefaultLabel` chain: project override → global default → Finder. A resolved descriptor must also appear in the `descriptors` list (i.e. the helper only returns `.editor` for an in-catalog descriptor so missing-CLI editors never become the default).

Edit `apps/mac/codans/App/Features/WorktreeHeader/WorktreeHeaderOpenButton.swift` (still alive through M5):

- Rewrite `currentDefaultLabel` to call `EditorFeature.resolveDefault(...)` and format the returned `ResolvedDefault` into the existing label string. Pure refactor — label output is byte-identical.

Edit `apps/mac/codans/Tests/EditorFeatureTests.swift`:

- Add `testResolveDefaultPrefersProjectOverride()` — override ID matches an installed descriptor → `.editor(descriptor)`.
- Add `testResolveDefaultFallsBackToGlobal()` — override nil, global matches an installed descriptor → `.editor(global descriptor)`.
- Add `testResolveDefaultReturnsFinderWhenMissing()` — override ID not in descriptors → `.finder` (does not silently fall through to global; the resolver treats a configured-but-missing override as "user wants this specific one, it's gone").
- Add `testResolveDefaultReturnsFinderWhenNothingConfigured()` — both inputs nil → `.finder`.

Acceptance: `xcodebuild test -scheme codans` passes with four new `EditorFeatureTests` cases green; legacy dropdown renders the same label on manual inspection.

### Milestone 4: `WorktreeHeaderFeature` reducer + tests

Reducer alone, no view. Delivers the observable surface the M5 views consume and the delegate contract M6 wires into `RootFeature`.

Add `apps/mac/codans/App/Features/WorktreeHeader/WorktreeHeaderFeature.swift` — see §Interfaces and Dependencies below for the full surface. Highlights:

- `State`: `inbox: NotificationInbox`, `unreadCount: Int`, `popoverOpen: Bool`.
- Actions: `.onAppear`, `.inboxUpdated(NotificationInbox)`, `.catalogChanged`, `.popoverToggled(Bool)`, `.dismissAllTapped`, `.notificationTapped(spaceID, projectID, worktreeID)`, `.openDefaultEditorTapped(worktreePath, projectID)`, `.openEditorTapped(editorID, worktreePath, projectID)`, `.customEditorsTapped`, `.gitViewerToggled(worktreeID, currentVisibility)`, `.setProjectDefaultEditorTapped(spaceID, projectID, editorID?)`, and delegate variants `.delegate(.openEditor(editorID?, worktreePath, projectID))`, `.delegate(.showCustomEditorsSettings)`, `.delegate(.setProjectOverride(projectID, spaceID, editorID?))`.
- `.onAppear` starts a cancellable subscription to `inboxClient.observe()` and emits `.inboxUpdated` on each snapshot.
- `.inboxUpdated` stores the inbox, then re-computes `unreadCount = inbox.totalUnread(in: hierarchyClient.snapshot())`.
- `.catalogChanged` re-computes `unreadCount` against the fresh catalog snapshot (no state mutation beyond that).
- `.notificationTapped` effect chain: `try? hierarchyClient.selectSpace(spaceID)` → `try? hierarchyClient.selectProject(projectID, spaceID)` → `try? hierarchyClient.selectWorktree(worktreeID, projectID, spaceID)` → `inboxClient.markReadForWorktree(worktreeID, hierarchyClient.snapshot())` → `.send(.popoverToggled(false))`. Exceptions are logged via `Logger(subsystem: "com.gumpw.codans.header", category: "bell")` and swallowed — stale rows no-op.
- `.dismissAllTapped` calls `inboxClient.clearAll()` then `.send(.popoverToggled(false))`.
- `.openDefaultEditorTapped` emits `.delegate(.openEditor(editorID: nil, ...))`.
- `.openEditorTapped` emits `.delegate(.openEditor(editorID: ..., ...))`.
- `.gitViewerToggled` calls `hierarchyClient.setWorktreeGitViewerVisible(worktreeID, !currentVisibility)`.
- `.customEditorsTapped` emits `.delegate(.showCustomEditorsSettings)`.
- `.setProjectDefaultEditorTapped` emits `.delegate(.setProjectOverride(...))`.

Add `apps/mac/codans/Tests/WorktreeHeaderFeatureTests.swift` with a TestStore-based suite:

- `testInboxUpdatedRecomputesUnread()` — inject catalog fixture + inbox with two catalog-resolvable unreads, send `.inboxUpdated`, assert `state.unreadCount == 2`.
- `testInboxUpdatedExcludesOrphansFromBadge()` — inbox with one valid unread + one orphan unread, send `.inboxUpdated`, assert `state.unreadCount == 1`. **Parity case called out in the design doc §Testing.**
- `testCatalogChangedRecomputesUnread()` — after `inboxUpdated` places 2 in badge, simulate catalog change (override the `hierarchyClient.snapshot` to return a catalog where one pane went orphan), send `.catalogChanged`, assert badge drops to 1.
- `testNotificationTappedChainsSelectionAndMarksRead()` — use a recording `HierarchyClient` + `InboxClient`; assert the four closures fire in order; assert `state.popoverOpen == false`.
- `testDismissAllTappedCallsClearAll()` — assert `inboxClient.clearAll` was invoked; popover closes.
- `testGitViewerToggledDispatchesFlip()` — recording `HierarchyClient.setWorktreeGitViewerVisible`; assert it fires with `!currentVisibility`.
- `testOpenDefaultEditorEmitsDelegate()` — assert `.delegate(.openEditor(nil, path, projectID))`.
- `testOpenEditorByIDEmitsDelegate()` — assert `.delegate(.openEditor(editorID, path, projectID))`.
- `testCustomEditorsEmitsDelegate()` — assert `.delegate(.showCustomEditorsSettings)`.
- `testSetProjectDefaultEmitsDelegate()` — assert `.delegate(.setProjectOverride(...))`.

Acceptance: `xcodebuild test -scheme codans` passes all new cases; no regression in existing suites. The reducer compiles without any view consumer yet.

### Milestone 5: Header SwiftUI views + mount + legacy deletion

Deliver the user-visible surface. Six new SwiftUI files, one file rewrite, one file deletion, one architecture doc update.

Add `apps/mac/codans/App/Features/WorktreeHeader/WorktreeHeaderView.swift`:

- Top-level row: `HStack(spacing: 10)` with
  - `Label(worktree.branch ?? worktree.name, systemImage: "point.3.connected.trianglepath.dotted")` on the left (read-only; the spec calls for `⎇` — `point.3.connected.trianglepath.dotted` is the closest SF Symbol already in use by the current header strip; keep for visual continuity with T0 state).
  - `Spacer(minLength: 8)`.
  - `HStack(spacing: 6) { HeaderBellView; HeaderOpenSplitButton; HeaderGitViewerToggle }` on the right.
- Padding `horizontal: 10, vertical: 6` — matches the current strip.
- Receives `store: StoreOf<WorktreeHeaderFeature>`, `editorStore: StoreOf<EditorFeature>`, and the `Address` (space/project/worktree/path).

Add `apps/mac/codans/App/Features/WorktreeHeader/HeaderBellView.swift`:

- `Button { store.send(.popoverToggled(true)) } label: { Image(systemName: "bell") .overlay(badge) }`. Badge is a `Text("\(store.unreadCount)")` in a small capsule, hidden when `unreadCount == 0`.
- `.popover(isPresented: $store.popoverOpen.toToggleBinding()) { HeaderBellPopover(store: store) }`. (We bind `popoverOpen` through a small helper to dispatch `.popoverToggled` on dismiss.)
- `.accessibilityLabel("Notifications, \(store.unreadCount) unread")`.
- Preview: zero-unread state + 5-unread state.

Add `apps/mac/codans/App/Features/WorktreeHeader/HeaderBellPopover.swift`:

- Reads `@Environment(HierarchyManager.self).catalog` at render time.
- Builds `[(Project, [(Worktree, [AgentNotification])])]` projection using `catalog.panelWorktreeIndex()`; drops orphans; filters to `isUnread` only (so the popover matches the badge policy exactly — design doc §Badge/popover parity).
- Header: `HStack { Text("Notifications").font(.headline); Spacer(); Button("Dismiss all") { store.send(.dismissAllTapped) } }`.
- Body: `List` of section-per-project with rows per notification. Row tap → `store.send(.notificationTapped(space, project, worktree))`.
- Empty state: `Text("No notifications").foregroundStyle(.secondary)`.
- Preview: empty state + populated state (two projects, three notifications).

Add `apps/mac/codans/App/Features/WorktreeHeader/HeaderOpenSplitButton.swift`:

- `HStack(spacing: 0)` of primary `Button` + caret `Menu`.
- Primary `Button`:
  - Label: `Image(systemName: "arrow.up.right.square") + Text("Open in \(defaultDisplayName)")`.
  - `defaultDisplayName` derived via `EditorFeature.resolveDefault(projectOverride: hierarchyManager.catalog.defaultEditor(forProject:...), globalDefault: editorStore.state.globalDefault, descriptors: editorStore.state.descriptors)`.
  - Action: `store.send(.openDefaultEditorTapped(worktreePath, projectID))`.
- Caret `Menu { pickerContent } label: { Image(systemName: "chevron.down") }`:
  - Section "Open in": each descriptor renders a button with `(not installed)` secondary label when `!isInstalled` and `.disabled(!isInstalled)`. Finder descriptor always enabled. Click dispatches `store.send(.openEditorTapped(editorID, worktreePath, projectID))`.
  - Divider + Section "Set default for this Project": mirror of current dropdown behavior. Dispatches `store.send(.setProjectDefaultEditorTapped(...))`.
  - Divider + "+ Custom editors…" button → `store.send(.customEditorsTapped)`.
- `.task { editorStore.send(.onAppear) }` on the split button root so descriptors + settings load on first render (same as the legacy dropdown).
- Preview: all installed / VS Code installed + Cursor missing / nothing installed (Finder only).

Add `apps/mac/codans/App/Features/WorktreeHeader/HeaderGitViewerToggle.swift`:

- `Button { store.send(.gitViewerToggled(worktreeID, currentVisibility)) } label: { Image(systemName: "doc.text.magnifyingglass").foregroundStyle(currentVisibility ? Color.accentColor : .primary) }`.
- `currentVisibility` is read from the catalog via `@Environment(HierarchyManager.self)`.
- `.help(currentVisibility ? "Hide Git Viewer" : "Show Git Viewer")`.
- `.accessibilityLabel(currentVisibility ? "Hide Git Viewer" : "Show Git Viewer")`.
- Preview: on + off states.

Rewrite `apps/mac/codans/App/Features/WorktreeDetail/WorktreeDetailView.swift`:

- Replace `worktreeHeader(address:)` with `WorktreeHeaderView(store: headerStore, editorStore: editorStore, address: address)`. `headerStore` is a new parameter on `WorktreeDetailView` — threaded in by `ContentView` in M6.

Delete `apps/mac/codans/App/Features/WorktreeHeader/WorktreeHeaderOpenButton.swift`. (`grep -r WorktreeHeaderOpenButton apps/mac/codans/Tests` confirmed zero test references before start; re-confirm at execution time.)

Update `docs/architecture.md`:

- Change the row for `codans/App/Features/WorktreeHeader/` to: *"Header row above the terminal Tab bar (T2). `WorktreeHeaderFeature` owns bell + split-button + GV-toggle state; subscribes to `InboxClient.observe()` for the badge. Views: `WorktreeHeaderView` + `HeaderBellView`/`HeaderBellPopover` + `HeaderOpenSplitButton` + `HeaderGitViewerToggle`."*

Acceptance: app builds; manually select a Worktree, verify Header row renders with all four controls; bell popover opens + shows the empty state; Open-in primary button dispatches (fails silently without M6 wire-up — expected; reducer emits the delegate into the void until M6).

### Milestone 6: `RootFeature` integration + `ContentView` rebinding

Wire M4's reducer into the root, bridge delegates into existing features, and retire the stale `inspectorVisible` path.

Edit `apps/mac/codans/App/Features/Root/RootFeature.swift`:

- Add `var worktreeHeader: WorktreeHeaderFeature.State = .init()` to `State`.
- Add `case worktreeHeader(WorktreeHeaderFeature.Action)`.
- Add `Scope(state: \.worktreeHeader, action: \.worktreeHeader) { WorktreeHeaderFeature() }`.
- Handle delegates in the main `Reduce`:
  - `.worktreeHeader(.delegate(.openEditor(editorID: nil, worktreePath: path, projectID: pid)))` → resolve the editor via `EditorFeature.resolveDefault(projectOverride: catalog.overrideFor(pid), globalDefault: state.editor.globalDefault, descriptors: state.editor.descriptors)`. If `.editor(descriptor)`, `return .send(.editor(.openRequested(editorID: descriptor.id, worktreePath: path, projectID: pid)))`. If `.finder`, return `.send(.editor(.openRequested(editorID: "finder", worktreePath: path, projectID: pid)))` (the built-in Finder descriptor ID — confirm exact constant in `EditorRegistry`).
  - `.worktreeHeader(.delegate(.openEditor(editorID: id, ...)))` for non-nil `id` → `.send(.editor(.openRequested(editorID: id, ...)))`.
  - `.worktreeHeader(.delegate(.showCustomEditorsSettings))` → `.send(.settingsSheetShown)`.
  - `.worktreeHeader(.delegate(.setProjectOverride(...)))` → `.send(.editor(.setProjectOverride(...)))`.
- In `.selectionChanged`, emit `.send(.worktreeHeader(.catalogChanged))` alongside the existing git-viewer forward. Rationale: selection-change is the coarse "catalog may have shifted" signal the header needs to recompute its badge.
- Delete `var inspectorVisible: Bool = false`, `case inspectorVisibilityToggled`, and the corresponding reducer branch.

Edit `apps/mac/codans/App/ContentView.swift`:

- Remove the second `ToolbarItem(placement: .primaryAction)` (the inspector toggle button).
- Replace `if store.inspectorVisible { Divider(); GitViewerView(...) }` with:
  ```swift
  if resolveGVVisible(store.selection) {
    Divider()
    GitViewerView(store: store.scope(state: \.gitViewer, action: \.gitViewer))
      .frame(minWidth: 420, idealWidth: 480)
  }
  ```
  where `resolveGVVisible(_ selection: HierarchySelection) -> Bool` reads `hierarchyManager.catalog` and returns the selected worktree's `gitViewerVisible`, defaulting to `false` on unresolved selections. Defined as a `private func` on `ContentView`.
- Thread `headerStore: store.scope(state: \.worktreeHeader, action: \.worktreeHeader)` into `WorktreeDetailView`.
- Pipe `store.send(.worktreeHeader(.onAppear))` inside the existing `.task`.

Edit `apps/mac/codans/App/Features/WorktreeDetail/WorktreeDetailView.swift`:

- Accept `headerStore: StoreOf<WorktreeHeaderFeature>`. Forward into `WorktreeHeaderView`.

Edit `apps/mac/codans/Tests/RootFeatureTests.swift`:

- Add case: `testDelegateOpenEditorNilResolvesAndForwards()` — send `.worktreeHeader(.delegate(.openEditor(nil, ...)))` with a populated `EditorFeature.State.descriptors` + `globalDefault`; assert it re-emits `.editor(.openRequested(editorID: <resolved>, ...))`.
- Add case: `testDelegateShowCustomEditorsOpensSettingsSheet()` — assert `state.settingsSheet != nil`.
- Add case: `testDelegateSetProjectOverrideForwards()` — assert `.editor(.setProjectOverride(...))` is emitted.
- Remove any test referencing `inspectorVisible` / `.inspectorVisibilityToggled`.

Acceptance: `xcodebuild test -scheme codans` passes; manual walkthrough of the feature acceptance from the design doc §Goals works:

1. Open app, select a Worktree with unread notifications → bell badge shows correct count.
2. Click a popover row → Worktree is selected + that Worktree's unread disappears.
3. Dismiss all → badge → 0.
4. Primary "Open in" → opens default editor (or Finder if not configured).
5. Caret picker disables missing editors with tooltip.
6. GV toggle flips the 3rd column on/off; state persists after switching Worktrees and back.
7. The old toolbar inspector button no longer exists.

### Milestone 7: Verification, push, PR

Full lint pass + all three test schemes + push + open PR targeting `feature/main-window`.

Commands:

- `make -C apps/mac lint` — zero errors.
- `xcodebuild test -scheme CodansCore -destination 'platform=macOS'` — green.
- `xcodebuild test -scheme codans -destination 'platform=macOS'` — green.
- `xcodebuild test -scheme CodansCoreTests -destination 'platform=macOS'` (or whichever split the repo uses) — green.
- `git push -u origin feat/mw-header`.
- `gh pr create --base feature/main-window --title "T2: Header row — branch label + notification bell + Open-in split + GV toggle" --body-file <heredoc>`.

PR description must list:

- T0 contracts consumed: `NotificationInbox.totalUnread/unreadCount/hasUnread`, `InboxStore.markRead(forWorktree:in:)` / `dismissAll`, `HierarchyManager.setWorktreeGitViewerVisible`, `Worktree.gitViewerVisible`.
- Removed surface: `WorktreeHeaderOpenButton.swift`, `RootFeature.State.inspectorVisible` + `.inspectorVisibilityToggled`, `ContentView` toolbar inspector item.
- T3 coordination note: the ContentView Git Viewer is still a 3rd column guarded by `resolveGVVisible`; T3 converts the column to a trailing overlay.

Post `PR_READY: <pr_url> | <=500-char summary` to master.

## Concrete Steps

Run each milestone as its own commit cluster. Between milestones, run `/commit` with an English message in the convention of the repo (`feat(header): …`, `refactor(editor): …`, `test(header): …`, `chore(arch): …`).

Representative commit titles per milestone (adapt wording to actual diff):

- M1: `feat(core): add NotificationInbox.totalUnread(in:) for catalog-resolvable badge count`
- M2: `feat(clients): add InboxClient.markReadForWorktree + HierarchyClient.setWorktreeGitViewerVisible`
- M3: `refactor(editor): hoist default-editor resolution into EditorFeature.resolveDefault`
- M4: `feat(header): add WorktreeHeaderFeature reducer + TestStore coverage`
- M5: `feat(header): add Header views (bell, Open-in split, GV toggle); drop legacy WorktreeHeaderOpenButton`
- M6: `feat(shell): wire WorktreeHeaderFeature into RootFeature; retire inspectorVisible`
- M7: `chore: local verification passed` (no diff commit expected; just the push + PR)

Working directory for xcodebuild commands: `/Users/wanggang/.worktree/repos/codans/feat/mw-header/apps/mac`.

Expected test deltas:

- M1: `CodansCoreTests` +3 cases.
- M2: `codans Tests` +1–2 cases (`HierarchyClientTests` round-trip; optional `InboxClient` round-trip).
- M3: `EditorFeatureTests` +4 cases.
- M4: `WorktreeHeaderFeatureTests` +10 cases (new file).
- M6: `RootFeatureTests` +3 cases; removal of any `inspectorVisible` case.

## Validation and Acceptance

Behavior acceptance (must be observable in a live build):

1. Launch app with at least one unread notification bound to an in-catalog Pane. The Header bell badge renders the correct count. Add an unread notification whose PaneID does not exist in any catalog (orphan) — the badge count does **not** change.
2. Open the bell popover. The rendered rows group by Project → Worktree and the row count equals the badge count.
3. Click a popover row. The Sidebar selection follows the row; the chosen Worktree's unread notifications are cleared from the popover on next render; the badge decreases accordingly.
4. Click "Dismiss all". The badge drops to 0 and the popover shows "No notifications".
5. Click the Open-in primary. The Worktree opens in the resolved default editor (Finder if nothing is configured); a success or failure toast appears (driven by the existing `editor.lastOpenResult` path).
6. Open the Open-in caret picker. Installed editors are enabled; missing editors are disabled with a tooltip "`<id>` CLI (`<binary>`) not found on PATH" (or the existing per-error string). Finder is enabled. "+ Custom editors…" opens the Settings sheet.
7. Click the Git Viewer toggle. The third column appears (via T2's `resolveGVVisible` + existing `HStack`); its visibility persists after switching Worktrees.
8. Verify that the old gear-less toolbar Picker (inspector toggle) is gone. Only the Settings cog remains in the toolbar.

Automated acceptance: `make -C apps/mac lint` + all three test schemes green. Running only `xcodebuild test -scheme codans` is insufficient — `CodansCore` hosts M1's tests.

## Idempotence and Recovery

Every milestone's file-level work is repeatable (re-running the edits yields the same source). Git-level recovery: each milestone lands as one commit; `git reset --soft HEAD~1` retires the commit while keeping the working tree, for rework. Do not force-push until PR is open and master has ACK'd.

Risk mitigations:

- If M2's `HierarchyClient.testValue` placeholder signature diverges from the T0 pattern, verify by comparing the diff against `setDefaultEditor`'s `testValue` line.
- If M6's `resolveGVVisible` proves to need equality checks against a stale selection (re-render thrash), memoize via `@State private var lastResolved` — but defer until a repro is visible.
- If the Finder descriptor's `EditorID` constant is non-obvious, look up `EditorRegistry.finder` and pin it behind a named constant on `EditorFeature`.

## Artifacts and Notes

Reviewer orientation:

- Design doc `docs/design-docs/mw-t2-header.md` holds all the trade-off rationale; this ExecPlan is the mechanical build order.
- `docs/exec-plans/0008-mw-t0-foundation.md` is the prior T0 plan; reference it for the contracts we consume and the filename-collision / ghostty-cache surprises that might resurface in the `feat/mw-header` worktree (see `Surprises & Discoveries` of 0008).

Example target signatures (see §Interfaces and Dependencies below for the full list).

## Interfaces and Dependencies

In `apps/mac/CodansCore/Notifications/NotificationInboxAggregation.swift`, define:

```swift
extension NotificationInbox {
  public func totalUnread(in catalog: Catalog) -> Int
}
```

In `apps/mac/codans/App/Clients/InboxClient.swift`, extend:

```swift
nonisolated struct InboxClient: Sendable {
  // existing closures…
  var markReadForWorktree: @MainActor @Sendable (_ worktreeID: WorktreeID, _ catalog: Catalog) -> Void
}
```

In `apps/mac/codans/App/Clients/HierarchyClient.swift`, extend:

```swift
nonisolated struct HierarchyClient: Sendable {
  // existing closures…
  var setWorktreeGitViewerVisible: @MainActor @Sendable (_ worktreeID: WorktreeID, _ visible: Bool) -> Void
}
```

In `apps/mac/codans/App/Features/Editor/EditorFeature.swift`, define:

```swift
extension EditorFeature {
  enum ResolvedDefault: Equatable {
    case editor(EditorDescriptor)
    case finder
  }

  static func resolveDefault(
    projectOverride: EditorID?,
    globalDefault: EditorID?,
    descriptors: [EditorDescriptor]
  ) -> ResolvedDefault
}
```

In `apps/mac/codans/App/Features/WorktreeHeader/WorktreeHeaderFeature.swift`, define:

```swift
@Reducer
struct WorktreeHeaderFeature {
  @ObservableState
  struct State: Equatable {
    var inbox: NotificationInbox = .empty
    var unreadCount: Int = 0
    var popoverOpen: Bool = false
  }

  enum Action: Equatable {
    case onAppear
    case inboxUpdated(NotificationInbox)
    case catalogChanged
    case popoverToggled(Bool)
    case dismissAllTapped
    case notificationTapped(spaceID: SpaceID, projectID: ProjectID, worktreeID: WorktreeID)
    case openDefaultEditorTapped(worktreePath: String, projectID: ProjectID?)
    case openEditorTapped(editorID: EditorID, worktreePath: String, projectID: ProjectID?)
    case customEditorsTapped
    case gitViewerToggled(worktreeID: WorktreeID, currentVisibility: Bool)
    case setProjectDefaultEditorTapped(spaceID: SpaceID, projectID: ProjectID, editorID: EditorID?)
    case delegate(Delegate)

    enum Delegate: Equatable {
      case openEditor(editorID: EditorID?, worktreePath: String, projectID: ProjectID?)
      case showCustomEditorsSettings
      case setProjectOverride(projectID: ProjectID, spaceID: SpaceID, editorID: EditorID?)
    }
  }

  nonisolated enum CancelID: Sendable { case observe }

  @Dependency(InboxClient.self) var inboxClient
  @Dependency(HierarchyClient.self) var hierarchyClient
}
```

Final file layout under `apps/mac/codans/App/Features/WorktreeHeader/`:

```
WorktreeHeaderFeature.swift     (new — reducer)
WorktreeHeaderView.swift        (new — row container)
HeaderBellView.swift            (new — bell + badge)
HeaderBellPopover.swift         (new — grouped list + dismiss all + empty)
HeaderOpenSplitButton.swift     (new — primary + caret menu)
HeaderGitViewerToggle.swift     (new — GV button)
WorktreeHeaderOpenButton.swift  (deleted in M5)
```

And `apps/mac/codans/Tests/WorktreeHeaderFeatureTests.swift` hosts the TestStore suite.
