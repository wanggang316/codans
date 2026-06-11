# Design Doc: Main-Window Redesign — T2 Header Row

**Status:** Draft
**Author:** Gump (T2 sub-agent, via Claude)
**Date:** 2026-04-21

## Context and Scope

The main-window redesign (`docs/product-specs/ui-main-window-redesign.md`, §Header in Detail) requires a Header row above the terminal Tab bar in the Detail column, carrying four user-visible controls:

1. A read-only `⎇ branch` label on the left.
2. A notification bell with an unread badge + popover grouped by Project → Worktree.
3. An "Open in …" split button (primary action + caret picker).
4. A Git Viewer overlay toggle.

T0 (merged) shipped the contracts this task consumes:

- `NotificationInbox.unreadCount(forWorktree:in:)` / `hasUnread(forProject:in:)` / `notifications(forWorktree:in:)` aggregation helpers.
- `InboxStore.markRead(forWorktree:in:)` + `dismissAll()`.
- `Worktree.gitViewerVisible: Bool` + `HierarchyManager.setWorktreeGitViewerVisible(worktreeID:visible:)`.
- `RootFeature.State.inbox` and `.sidebarMode` reserved for the bell popover (no current dispatch).
- `ContentView` sidebar-mode Picker already removed.

The existing Worktree-header strip in `WorktreeDetailView.worktreeHeader(address:)` (branch label + path + `WorktreeHeaderOpenButton` dropdown) is the starting point. `ContentView` also carries a toolbar button for `RootFeature.inspectorVisibilityToggled` that toggles a non-persistent `inspectorVisible: Bool` state; T3 will replace that with an overlay bound to `Worktree.gitViewerVisible`. T2 adds the Header GV toggle that already writes to the persisted per-Worktree flag; the old toolbar button is removed in this PR so there is no split source of truth during the T2 → T3 gap (see §Cross-Cutting Concerns → Git Viewer toggle coordination).

T1 (Sidebar) and T3 (Git Viewer overlay + shortcuts) proceed in parallel on sibling branches; T2 stays out of `HierarchySidebar*` and `GitViewer*` except for the toolbar-item removal mentioned above.

## Goals and Non-Goals

### Goals

- Render Header above the Tab bar with the four controls, laid out per the spec's ASCII.
- Bell badge count = global unread across every Worktree in the catalog, computed via `NotificationInbox.totalUnread(in: catalog)` so the badge shares exactly the same `PaneID → WorktreeID` resolution policy as the popover grouping (orphans excluded from both). Tracked live via `InboxClient.observe()`.
- Bell popover groups unread-and-non-dismissed notifications by Project → Worktree, each row showing the notification title; empty state "No notifications"; top-right "Dismiss all" action.
- Clicking a row selects the row's Worktree (via `HierarchyClient.selectWorktree`, cascading through `selectSpace` / `selectProject`) and marks every notification whose pane resolves to that Worktree as read.
- "Dismiss all" calls `InboxStore.dismissAll()` through `InboxClient`.
- "Open in …" primary button dispatches the default-editor open through the existing `EditorFeature.openRequested`; caret opens a picker listing all `EditorDescriptor`s (built-in + custom), disables `!isInstalled` entries with a tooltip, and shows a "+ Custom editors…" row that opens the Settings sheet at the editor section.
- Git Viewer toggle flips `Worktree.gitViewerVisible` via the hierarchy client and visually reflects the live catalog value.
- Unit tests via `TestStore` cover: badge count tracking, row-tap (markRead for that Worktree + selectWorktree), dismiss-all, open primary (default editor open), open picker disabled-state for missing editor, GV toggle dispatch + state reflection.
- Lint + full test scheme stays green.

### Non-Goals

- Sidebar redesign (T1).
- Git Viewer overlay rendering / 3-column → 2-column + overlay conversion (T3).
- Keyboard shortcuts for bell, Open-in, and GV toggle (T3 owns the global-shortcut surface; the popover's own arrow-key navigation is a SwiftUI default).
- Branch rename / checkout (spec Won't-Have).
- Changes to `EditorService` installation probing logic.
- Per-Space last-active-Worktree UX changes (T0 wired; T1 drives restoration).

## Design

### Overview

Introduce one new TCA feature, `WorktreeHeaderFeature`, scoped from `RootFeature` alongside `editor` and `detail`. The feature owns:

- Cached `NotificationInbox` snapshot (last value from `InboxClient.observe()`).
- Catalog is **not** cached in state. The Project → Worktree grouping and the badge both read `@Environment(HierarchyManager.self).catalog` at render time. For reducer-internal needs (e.g. `markReadForWorktree` at row-tap) the feature pulls `hierarchyClient.snapshot()`.
- `popoverOpen: Bool` — local UI state.
- `unreadCount(in catalog: Catalog) -> Int` — **computed**, not a cached field. Returns `inbox.totalUnread(in: catalog)`. Views call it with the live `hierarchyManager.catalog`; reducers call it with `hierarchyClient.snapshot()` when they need a point-in-time value. Returning a computed value rather than caching means any catalog mutation (including ones unrelated to selection changes — e.g. removing a non-selected Worktree) invalidates the badge via ordinary SwiftUI observation of the `@Observable` `HierarchyManager`, without the reducer needing a parallel `.catalogChanged` dispatch. `NotificationInbox.totalUnread(in:)` is the shared implementation — it walks `panelWorktreeIndex()` once and excludes orphans so badge count and popover row count never diverge.

Actions are:

- `.onAppear` — starts the `InboxClient.observe()` stream, cancellable on disappear.
- `.inboxUpdated(NotificationInbox)` — caches the inbox snapshot. No per-action badge recompute is needed: the badge is computed at view render time via `State.unreadCount(in: hierarchyManager.catalog)`.
- `.popoverToggled(Bool)` — pure UI.
- `.notificationTapped(worktreeID: WorktreeID, spaceID: SpaceID, projectID: ProjectID)` — calls `hierarchyClient.selectSpace` → `selectProject` → `selectWorktree`; then calls `inboxClient.markReadForWorktree(worktreeID, catalog)`; closes popover.
- `.dismissAllTapped` — calls `inboxClient.clearAll()`; closes popover.
- `.openDefaultEditorTapped(worktreePath: String, projectID: ProjectID)` — delegate up: `.delegate(.openRequested(editorID: nil, worktreePath:projectID:))`. Parent forwards into `EditorFeature.openRequested` with the resolved default. Resolution is the same chain already in `WorktreeHeaderOpenButton.currentDefaultLabel` (Project override → global default → Finder). We lift that resolution into a static helper on `EditorFeature` so both the split-button and the existing dropdown stay on one source of truth.
- `.openEditorTapped(editorID: EditorID, ...)` — delegate up to `EditorFeature.openRequested`.
- `.customEditorsTapped` — delegate up: parent presents the Settings sheet.
- `.gitViewerToggled(worktreeID: WorktreeID, currentVisibility: Bool)` — calls `hierarchyClient.setWorktreeGitViewerVisible(worktreeID, !currentVisibility)` (new client closure added in this PR; see §API Design).

Views:

- `WorktreeHeaderView` — top-level row hosting branch label + right cluster; replaces the ad-hoc `HStack` currently inlined in `WorktreeDetailView.worktreeHeader(address:)`. Receives the scoped `StoreOf<WorktreeHeaderFeature>` and the scoped `StoreOf<EditorFeature>`.
- `HeaderBellView` — bell icon + unread badge; presents popover on tap.
- `HeaderBellPopover` — rendered inside the popover; consumes cached inbox + live `@Environment(HierarchyManager.self).catalog` to build the Project → Worktree grouping. Empty state + Dismiss all button.
- `HeaderOpenSplitButton` — two visually-adjacent parts. Left half is a `Button` bound to the resolved default editor (dispatches through the header feature's `openDefaultEditorTapped`); right half is a `Menu` whose label is a `chevron.down` caret and whose content mirrors today's `WorktreeHeaderOpenButton.openInMenu` plus the "+ Custom editors…" row. The Project-override "Set default for this Project" sub-menu is kept — it is already a real side effect consumer (`EditorFeature.setProjectOverride`) and removing it would regress today's UX.
- `HeaderGitViewerToggle` — SF Symbol button (`doc.text.magnifyingglass`). Reads `Worktree.gitViewerVisible` from the catalog snapshot (via `@Environment(HierarchyManager.self)`); click dispatches `gitViewerToggled`. When `visible == true` the button renders in `.accentColor` to show the "on" state.

Old path removal (in this PR — closed loop, no follow-up debt):

- `WorktreeDetailView.worktreeHeader(address:)` is replaced by `WorktreeHeaderView(...)`.
- `apps/mac/codans/App/Features/WorktreeHeader/WorktreeHeaderOpenButton.swift` is **deleted**. Its only call site (`WorktreeDetailView.worktreeHeader`) is rewritten to mount `HeaderOpenSplitButton`, which supersedes it. The resolution chain previously held in `WorktreeHeaderOpenButton.currentDefaultLabel` moves to `EditorFeature.resolveDefault` (see §API Design) and is consumed by both the split button's label and the primary-action dispatch. No tests currently target the old button (grep confirms zero test files reference it); nothing to migrate. `docs/architecture.md` entry for `codans/App/Features/WorktreeHeader/` is updated to name the new surface.
- `ContentView` toolbar's inspector toggle (the second `ToolbarItem`) is removed. `RootFeature.State.inspectorVisible` and the `inspectorVisibilityToggled` action are deleted because they would otherwise diverge from `Worktree.gitViewerVisible`. `ContentView`'s `if store.inspectorVisible { GitViewerView(...) }` branch becomes `if resolveGVVisible(selection) { GitViewerView(...) }`, where `resolveGVVisible` is a `ContentView`-scoped helper that reads the selected Worktree's `gitViewerVisible` from `hierarchyManager.catalog`. The 3-column `HStack` shape stays untouched in T2; T3 converts it to an overlay.

### System Context Diagram

```
                         RootFeature (TCA)
       ┌───────────────────┼──────────────────┐
       │                   │                  │
       ▼                   ▼                  ▼
WorktreeHeaderFeature   EditorFeature   HierarchySidebarFeature
  │        │              ▲                      (T1)
  │        │              │
  │        │  delegate .openRequested
  │        └──────────────┘
  │
  │  InboxClient.observe()            HierarchyClient.selectWorktree/
  │  InboxClient.markReadForWorktree  HierarchyClient.setWorktreeGitViewerVisible
  ▼  InboxClient.clearAll             HierarchyClient.snapshot
┌──────────────┐                ┌──────────────┐
│ InboxStore   │                │ HierarchyMgr │
└──────────────┘                └──────────────┘
```

`WorktreeHeaderView` is mounted inside `WorktreeDetailView` at the same place the old header strip sits, so no change to the outer `NavigationSplitView` structure.

### API Design

#### New `WorktreeHeaderFeature`

```
state
  inbox: NotificationInbox
  unreadCount: Int          (derived on inboxUpdated)
  popoverOpen: Bool

actions (local)
  .onAppear
  .inboxUpdated(NotificationInbox)
  .popoverToggled(Bool)
  .dismissAllTapped
  .notificationTapped(spaceID, projectID, worktreeID)
  .openDefaultEditorTapped(worktreePath, projectID)
  .openEditorTapped(editorID, worktreePath, projectID)
  .customEditorsTapped
  .gitViewerToggled(worktreeID, currentVisibility)
  .setProjectDefaultEditorTapped(spaceID, projectID, editorID?)   // mirror of today's sub-menu

actions (delegate, consumed by RootFeature)
  .delegate(.openEditor(editorID: EditorID?, worktreePath: String, projectID: ProjectID?))
  .delegate(.showCustomEditorsSettings)
  .delegate(.setProjectOverride(projectID, spaceID, editorID?))
```

Dependencies: `InboxClient`, `HierarchyClient`. No `EditorClient` (delegate up).

#### `NotificationInbox` extension (CodansCore)

Add a pure helper next to the existing `unreadCount(forWorktree:in:)`:

```
public func totalUnread(in catalog: Catalog) -> Int
```

One walk of `panelWorktreeIndex()` summing `isUnread` entries whose pane resolves into the catalog. Shared by the bell badge and — internally — by any future aggregation caller. Kept as a pure extension on `NotificationInbox` (not on `InboxStore`) so it stays Sendable / MainActor-free and directly unit-testable alongside the T0 helpers.

#### `InboxClient` extension

Add one closure:

```
var markReadForWorktree: @MainActor @Sendable (_ worktreeID: WorktreeID, _ catalog: Catalog) -> Void
```

`liveValue` wires to `InboxStore.markRead(forWorktree:in:)`. `testValue` uses `unimplemented(...)`. T0's InboxClient `markRead(ids:)` stays for fine-grained callers; the new closure is the worktree-scoped wrapper the bell popover needs.

#### `HierarchyClient` extension

Add one closure:

```
var setWorktreeGitViewerVisible: @MainActor @Sendable (_ worktreeID: WorktreeID, _ visible: Bool) -> Void
```

`liveValue` wires to `manager.setWorktreeGitViewerVisible(worktreeID:visible:)`. Silent no-op semantics (no throw) match the manager's contract.

#### `RootFeature` integration

- New `Scope(state: \.worktreeHeader, action: \.worktreeHeader)`.
- `case .worktreeHeader(.delegate(.openEditor(...)))` → `.send(.editor(.openRequested(editorID: resolvedEditorID, worktreePath, projectID)))`. For `editorID: nil` (primary button), resolution is via a new `EditorFeature.State.resolvedDefaultID(forProject:catalog:)` pure helper.
- `case .worktreeHeader(.delegate(.showCustomEditorsSettings))` → `.send(.settingsSheetShown)` (existing root action).
- `case .worktreeHeader(.delegate(.setProjectOverride(...)))` → `.send(.editor(.setProjectOverride(...)))`.
- `inspectorVisible` + `inspectorVisibilityToggled` removed; `ContentView` switches to `if resolveGVVisible(state, selection) { GitViewerView(...) }` where `resolveGVVisible` reads the selected Worktree's `gitViewerVisible` from `hierarchyManager.catalog`. The resolution is a `ContentView`-scoped `@State`-less computed property.

#### Default editor resolution helper

Move the resolution chain out of `WorktreeHeaderOpenButton.currentDefaultLabel` and into `EditorFeature`:

```
static func resolveDefault(
  projectOverride: EditorID?,
  globalDefault: EditorID?,
  descriptors: [EditorDescriptor]
) -> ResolvedDefault // .editor(EditorDescriptor) | .finder
```

Both the existing dropdown and the new split-button consume this.

**Cascade-on-missing semantics** (clarified after execution, see ExecPlan D5): if the project override is set to an id that is not in `descriptors` (e.g. the custom editor was removed), resolution cascades to the global default and only falls to `.finder` when neither override nor global resolves. This matches the pre-T2 dropdown's behavior and avoids stranding users on Finder when a global default is configured.

### Data Storage

No new persistence. All reads go through the existing `Catalog` + `NotificationInbox` snapshots. All writes land in pre-existing stores (`InboxStore`, `HierarchyManager`).

### Component Boundaries

```
apps/mac/codans/App/Features/WorktreeHeader/
  WorktreeHeaderFeature.swift     (NEW — reducer + State + Action + delegate)
  WorktreeHeaderView.swift        (NEW — row; mounts inside WorktreeDetailView)
  HeaderBellView.swift            (NEW — bell + badge + popover host)
  HeaderBellPopover.swift         (NEW — grouped list + Dismiss all + empty state)
  HeaderOpenSplitButton.swift     (NEW — primary button + caret menu; consumes
                                   EditorFeature.resolveDefault for the label and
                                   dispatches .openEditorTapped/.setProjectDefault…
                                   through the header feature's delegate)
  HeaderGitViewerToggle.swift     (NEW — SF Symbol button bound to gitViewerVisible)
  WorktreeHeaderOpenButton.swift  (DELETED — superseded by HeaderOpenSplitButton.
                                   No tests reference it; removal is local.)
```

PR-level diff summary (for reviewer orientation):

- **Added**: six files above + `WorktreeHeaderFeatureTests.swift` + `InboxClient` closure + `HierarchyClient` closure + `NotificationInbox.totalUnread(in:)` extension + test cases in `EditorFeatureTests` for `resolveDefault`.
- **Modified**: `WorktreeDetailView.swift`, `ContentView.swift`, `RootFeature.swift`, `InboxClient.swift`, `HierarchyClient.swift`, `EditorFeature.swift` (add `resolveDefault` static + keep existing behavior), `docs/architecture.md` (WorktreeHeader entry).
- **Deleted**: `WorktreeHeaderOpenButton.swift`.

Dependency directions:

- `WorktreeHeaderFeature` → `InboxClient`, `HierarchyClient`. Never imports `EditorClient`.
- `WorktreeHeaderView` → scoped `StoreOf<WorktreeHeaderFeature>`, scoped `StoreOf<EditorFeature>` (for current-default label + descriptors), `@Environment(HierarchyManager.self)`.
- `HeaderBellPopover` → header-feature state only. Catalog is read from `@Environment(HierarchyManager.self)` so the popover picks up catalog mutations immediately.
- Split-button's "Set default for this Project" sub-menu continues to send through the header feature → delegate → `EditorFeature.setProjectOverride`.

## Alternatives Considered

### A. No new feature — views reach into `EditorFeature` / `RootFeature.State.inbox` directly

Rejected. The bell needs its own inbox subscription (so the badge is live even when `state.inbox` is not hydrated per T0 doc), and the GV toggle plus notification row-tap both need a reducer-owned single entry point so TestStore can prove the effect. Putting all of that inside `EditorFeature` muddies its single responsibility; putting it inside `RootFeature` bloats the root reducer and makes sub-testing awkward.

### B. Reuse `InboxSidebarFeature` as the popover's engine

Considered. `InboxSidebarFeature` already subscribes to `InboxClient.observe()` and caches notifications + unread count, which is most of what we need. Rejected because its row-tap semantics (`.deeplinkRequested(PaneID)`) target pane focus, not Worktree selection + markRead for all Worktree notifications. We would also inherit the "filter chip" state (`.all / .unread / ...`) which has no corresponding control in the popover. Forking a focused feature is cheaper than bending a mis-shaped one.

### C. Let the Header's GV toggle route through `RootFeature.inspectorVisibilityToggled`

Rejected. That flag is non-persistent and global; the spec requires per-Worktree persistence (`Worktree.gitViewerVisible`, already shipped by T0). Using it would double-book state. We remove it in this PR.

### D. Custom split-button via `NSButton` / private AppKit to get the pixel-perfect split-button look

Rejected. SwiftUI's `Button` + `Menu` composed side-by-side is close enough to the spec's sketch and keeps preview/testability simple. The caret is a separate `Menu` rather than `Menu(primaryAction:)` because we want independent hit-targets (clicking "Open in ▾" text on the left must always fire the default; clicking the caret never does).

### E. Put "+ Custom editors…" in the Settings cog (spec Won't-Have path)

Rejected. Spec removes the gear from the chrome, and the picker's "+ Custom editors…" entry is a spec-listed Must-Have for surfacing custom-editor management. Opening the existing Settings sheet from the picker row keeps the single surface (no new editor-management screen).

## Cross-Cutting Concerns

### Testing

- `WorktreeHeaderFeatureTests`: TestStore-based coverage for each action; uses `.dependency(\.inboxClient, .testValue)` + `.dependency(\.hierarchyClient, .testValue)` with overrides for the closures exercised in each test.
  - `inboxUpdated` drives `unreadCount` via `NotificationInbox.totalUnread(in:)` — feed a catalog fixture + inbox with two unread notifications, assert `unreadCount == 2`.
  - **Badge/popover parity**: construct a catalog with one known Worktree + one unread notification whose `paneID` belongs to that Worktree, plus one unread notification whose `paneID` is **not** in the catalog (orphan). Feed both through `inboxUpdated`; assert `state.unreadCount == 1` and assert the popover-feeding projection (the view-model function that buckets by Project → Worktree) returns exactly one row. Guards the "badge = rendered rows" invariant.
  - `notificationTapped` drives `selectSpace` / `selectProject` / `selectWorktree` and `markReadForWorktree`.
  - `dismissAllTapped` drives `clearAll`.
  - `openDefaultEditorTapped` emits `.delegate(.openEditor(nil, ...))`.
  - `gitViewerToggled` drives `setWorktreeGitViewerVisible(_, !current)`.
  - `customEditorsTapped` emits `.delegate(.showCustomEditorsSettings)`.
- `EditorFeatureTests`: add a case for the new `resolveDefault` static helper (project override / global default / Finder fallback).
- `NotificationInboxAggregationTests` (CodansCoreTests): add a case for the new `totalUnread(in:)` extension — two unread + one orphan yields 2; dismissed/read entries excluded.
- SwiftUI previews in `HeaderBellView.swift`, `HeaderOpenSplitButton.swift`, `HeaderGitViewerToggle.swift` for empty-state / unread-state / installed-vs-missing / visible-vs-hidden.
- Snapshot tests are out of scope per "snapshot/preview" phrasing in the task brief — the repo already uses SwiftUI previews; we keep that.

### Observability

No new telemetry events in this PR. Existing editor-open success/failure toasts via `store.editor.lastOpenResult` keep working unchanged.

### Coordination with T3

T3 will:

- Replace `ContentView`'s `HStack { detail; Divider; GitViewerView }` with an overlay presentation.
- Add global keyboard shortcuts for bell, Open-in, and GV toggle.

T2's surface contract toward T3:

- `HierarchyClient.setWorktreeGitViewerVisible` is the single mutation entry point.
- `Worktree.gitViewerVisible` is the single visibility source of truth.
- The Header GV button dispatches the flip; T3 wires the overlay presentation to the same flag.

The PR description explicitly calls out the removed toolbar item so T3 does not re-introduce one.

#### T3's locked ContentView diff range

To minimise rebase conflict surface with T3, T2 commits to leaving the GV-visible read path at exactly one call site in `ContentView`:

```swift
// ContentView.body, inside the .detail trailing closure (after T2):
HStack(spacing: 0) {
  WorktreeDetailView(...)
  if resolveGVVisible(selection) {              // ← T3 edits THIS line only
    Divider()
    GitViewerView(store: store.scope(...))      // ← and adjusts the sibling
  }                                             //   presentation (Divider+view)
}
```

T3's contract is narrowly: **replace the `HStack { WorktreeDetail; if resolveGVVisible(...) { Divider; GitViewerView } }` with `WorktreeDetail.overlay(alignment: .trailing) { if resolveGVVisible(...) { GitViewerView } }` (or SwiftUI equivalent), and add global keyboard shortcuts.** No new state, no new reducer action, no change to `resolveGVVisible`, no touching `WorktreeHeaderFeature` / `HierarchyClient` / `InboxClient`. If T3 needs overlay-specific state (e.g. drag-to-resize width), that state lives inside T3's own new feature and does not reach back into `RootFeature`.

Everything else — the Header row, the GV toggle button, the `gitViewerVisible` persistence, the `resolveGVVisible` helper, the `RootFeature` action surface — is T2's PR and frozen for T3's consumption.

### Error handling

- `notificationTapped` chains three mutations. `selectSpace` is non-throwing; `selectProject` / `selectWorktree` can throw if IDs stale. We catch and swallow (log via `Logger(subsystem: "com.gumpw.codans.header", category: "bell")`) — the popover was rendered from a cached snapshot, so staleness is possible and not user-actionable. Stale row just no-ops.
- `markReadForWorktree` is idempotent (InboxStore checks `readAt == nil`). Safe to call on stale selection.
- Editor open failures already flow through `EditorFeature.openFailed` → `store.editor.lastOpenResult` → toast. No new path.

### Accessibility

- Bell button: `.accessibilityLabel("Notifications, \(unreadCount) unread")`.
- Popover rows: `.accessibilityLabel("\(projectName) — \(branchName): \(title)")`.
- Split-button primary: `.accessibilityLabel("Open in \(defaultName)")`.
- Split-button caret: `.accessibilityLabel("Choose editor")`.
- GV toggle: `.accessibilityLabel(visible ? "Hide Git Viewer" : "Show Git Viewer")`.
- Branch label: `.accessibilityLabel("Current branch: \(branch)")`; `.accessibilityAddTraits(.isStaticText)`.

## Risks

1. **Inbox snapshot vs catalog race.** The popover's Project → Worktree grouping is computed from `(inboxSnapshot, catalogSnapshot)`. The inbox updates via `observe()`, the catalog via `HierarchyManager`'s `@Observable`. If a notification's pane is moved between tabs between the inbox yield and catalog render, the row may briefly appear under a stale Worktree or fall into an "orphaned" bucket. Mitigation: compute grouping at render time via `@Environment(HierarchyManager.self).catalog`, not at `.inboxUpdated` time. Orphans (panes no longer in the catalog) are excluded via `panelWorktreeIndex()`'s `nil` lookup — same policy as the T0 aggregation helpers. The badge count and the popover row count share this single `PaneID → WorktreeID` index: both are derived from `NotificationInbox.totalUnread(in: catalog)` / `notifications(forWorktree:in: catalog)`, so an orphan never inflates the badge past the number of rows the popover actually renders.
2. **Dismiss-all wipes per-Worktree markRead opportunities.** `dismissAll()` sets `dismissedAt` for every entry, which makes `isUnread` false for everything. This is the spec behavior and matches the popover's top-right action. Documented in the popover button's tooltip.
3. **Default-editor resolution drift between dropdown and split-button.** Mitigated by hoisting the resolution into `EditorFeature.resolveDefault` and unit-testing it. If resolution ever changes (e.g. a per-Worktree override is added), both surfaces pick it up by call-site update in one place.
4. **ContentView GV visibility read path.** Replacing `store.inspectorVisible` with a catalog-derived flag in `ContentView` means the 3-column layout shows/hides on catalog mutations (including selection changes that flip the flag back to its persisted value for the new Worktree). That is the spec behavior per T0 (§Visibility persists across selections). Mitigation: verify manually by selecting two Worktrees with different `gitViewerVisible` values; add a `RootFeatureTests` case that asserts the resolved flag follows selection + mutation.
5. **Popover layering over terminal input focus.** Opening the popover does not retire the focused pane's first-responder status; dismissing the popover must not leave the focus in the popover. Mitigation: we rely on SwiftUI's default `.popover` focus behavior; if it misbehaves, T3's keyboard-shortcut work can follow up with `.focusEffectDisabled()` on popover contents.
