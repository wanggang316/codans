# Design Doc: Tab Bar Uplift

**Status:** Approved
**Author:** Gump (via Claude)
**Date:** 2026-04-24

## Context and Scope

The terminal Tab bar is the horizontal row of per-tab chips that sits between the main-window Header and the Pane viewport. Today it is a minimal placeholder:

- `TabBarView` renders an `HStack(spacing: 4)` of chips (text + close `xmark`) plus a trailing `+` button. Active tab shows a `RoundedRectangle(cr: 4)` accent-tinted background; no hover state, no underline indicator, no truncation discipline.
- `TabBarFeature` dispatches exactly three actions — `newTabButtonTapped`, `tabButtonTapped`, `closeButtonTapped` — each a one-line forward through `HierarchyClient`.
- `Tab` (`apps/mac/CodansCore/Tab.swift`) is pure data: `id / name? / splitTree / panes`.
- `HierarchyManager` already owns `createTab / closeTab / selectTab / moveTab(offset:)` plus `runningPaneCount(worktreeID:)`.
- No rename, no right-click menu, no drag reorder, no keyboard shortcuts for tab operations, no overflow handling (too-many tabs clip), no trailing split affordance, no focus memory when switching tabs, no per-pane busy visualization.

The main-window spec (`docs/product-specs/ui-main-window-redesign.md`) explicitly freezes the Tab bar at its current behavior ("the terminal Tab bar and split Panes below the Header behave as they do today; no regressions"). This doc scopes an independent UX uplift on top of that baseline. It does not modify the Header, Sidebar, Git Viewer overlay, or pane-split mechanics.

## Goals and Non-Goals

### Goals

- Render a production-quality Tab bar: visible active indicator (top underline), three-state chip backgrounds (idle / hover / press-or-active), hover-revealed close button, single-line truncation with adaptive width, flush inter-tab dividers.
- Support every common tab operation: new / close / close-others / close-to-right / close-all / rename / reorder-by-drag / middle-click-close / right-click context menu.
- Add standard macOS keyboard shortcuts — `⌘T` new, `⌘W` close, `⌥⌘1`–`⌥⌘9` select by index, `⌘⇧[` / `⌘⇧]` previous / next — wired through `TabBarFeature` via the main menu. `⌘1`–`⌘9` is already bound to Space switching (see `MainWindowCommands`); `⌃⌘1`–`⌃⌘9` is bound to Worktree jumping in the sidebar. The `⌥⌘N` namespace is free and fits the "deeper level → deeper modifier" pattern already in use.
- Scroll horizontally when the bar overflows, with left/right gradient shadows indicating clipped content, and auto-scroll the selected tab into view on selection change.
- Trailing accessory cluster: `+` (new tab), split-right, split-down. The split buttons show a small popover preview of the tab's current pane tree after a short hover delay.
- Remember per-tab last-focused pane, so switching tabs restores the user's focus instead of defaulting to the first pane.
- Expose a read path for per-tab "busy" status (`dirty`) so the chip can show a spinner when any pane inside the tab is running a tracked command. Writer side lands with C3 hooks — this PR scaffolds the read contract only.
- Component files are factored out of `TabBarView` so styling constants, states, and interactions each live in their own type. Every new visible state gets a `TestStore`-backed unit test.

### Non-Goals

- Icon field on `Tab` or an SF Symbol picker. Tabs remain text-only for now.
- Title / icon lock semantics (`isTitleLocked`, `isIconLocked`) — these only matter when automated writers (shell OSC sequences, hooks) compete with user edits, and no such writer exists pre-C3. Deferred to the hooks design.
- Tab overview / grid picker (the existing `pane.toggleTabOverview` command-palette entry stays a stub). Can be done later without rework.
- Per-tab notification badges. Notifications aggregate at Worktree-level on the Header (see `mw-t2-header`), not on individual tabs.
- Pinning tabs, duplicating tabs, tab groups, tearing a tab off into its own window.
- Multi-window tab portability.
- Changing `Tab`'s persistence shape beyond optional additive fields (`name` already exists). No catalog-file migration.

## Design

### Overview

Three layered changes, each landable independently:

1. **UI refactor (no behavior change).** Break `TabBarView` into ~8 small view types, extract `TabBarMetrics` + `TabBarColors` constants, introduce the three-state chip background. Feature API, data model, and persisted catalog are untouched.
2. **Interaction layer (in-place, no model change).** Right-click context menu, drag-to-reorder, middle-click-close, keyboard shortcuts, overflow horizontal scroll, trailing split buttons with hover popover, auto-scroll-to-selected. New `HierarchyClient` closures fan out to existing or new `HierarchyManager` methods (`renameTab`, `reorderTabs`, `closeOtherTabs`, `closeTabsToRight`, `closeAllTabs`).
3. **Runtime state additions (data contracts, UI binding only).** Two new maps on `HierarchyManager`:
   - `lastFocusedPaneByTab: [TabID: PaneID]` — restored on `selectTab`.
   - `paneRunning: [PaneID: Bool]` — computed `tabIsDirty(TabID)` derived from membership. Writer methods (`markPaneRunning`, `markPaneIdle`) exist but are called by nobody until C3 hooks land; the chip binding always reflects the live map.

Each layer has its own exit criteria and can ship as a separate PR. Nothing in layer 1 depends on layer 2 or 3; layer 2 does not depend on layer 3.

### System Context Diagram

```
                 ┌──────────────────────────────────────────────┐
                 │               WorktreeDetail                 │
                 │                                              │
                 │   ┌────────────── Header ──────────────────┐ │
                 │   │ ⎇ branch   [bell] [Open ▾] [GitView◯] │ │
                 │   └────────────────────────────────────────┘ │
                 │   ┌────────────── Tab Bar ─────────────────┐ │
                 │   │ ┌Tab 1┐┌Tab 2 • ┐┌Tab 3┐     + ⇥ ⇥    │ │ ← this doc
                 │   └────────────────────────────────────────┘ │
                 │   ┌────────────── SplitViewport ───────────┐ │
                 │   │            Pane  │  Pane               │ │
                 │   │                  ├──────────           │ │
                 │   │                  │  Pane               │ │
                 │   └────────────────────────────────────────┘ │
                 └──────────────────────────────────────────────┘

  ┌─────────────────┐     ┌───────────────────┐     ┌──────────────────┐
  │  TabBarFeature  │────→│  HierarchyClient  │────→│ HierarchyManager │
  │  (TCA reducer)  │     │ (DI boundary)     │     │  (Observable)    │
  └─────────────────┘     └───────────────────┘     └──────────────────┘
         ↑                                                   │
         │ reads via HierarchyManager env.                   │ owns:
         └───────────────────────────────────────────────────┤  Catalog (persisted)
                                                             │  lastFocusedPaneByTab
                                                             │  paneRunning
                                                             ▼
                                                     ┌───────────────┐
                                                     │  CatalogStore │
                                                     │ (debounced)   │
                                                     └───────────────┘
```

### Visual Spec

All numbers are guidance; final values land during layer 1.

| Axis | Value | Rationale |
|---|---|---|
| Bar height | 32 pt | Matches the Header row height for vertical rhythm. |
| Chip height | 28 pt | Leaves 2 pt of top breathing room for the active underline. |
| Chip min width | 120 pt | Any less and titles truncate at a single glyph. |
| Chip max width | 220 pt | Prevents one long title from starving siblings. |
| Chip width | `floor((barWidth − trailing) / tabCount)` clamped to `[min, max]` | Responsive division; overflow triggers scroll. |
| Inter-chip spacing | 0 pt (+ 1 pt divider) | Flush chips with thin separator read as a single continuous bar. |
| Chip padding (H) | 8 pt both sides | Label + close-button breathing room. |
| Active underline | 2 pt top edge, `Color.accentColor` | High-contrast, non-animated indicator. |
| Idle bg | `Color.clear` | Tab bar inherits material. |
| Hover bg | `Color.primary.opacity(0.06)` | Subtle, respects dark mode. |
| Press / active bg | `Color(NSColor.controlBackgroundColor)` | Matches native macOS controls. |
| Close button | 16 × 16 pt circle, `xmark` SF Symbol, visible only on chip hover or focus | Keeps the chip uncluttered at rest. |
| Divider | 1 pt × 16 pt, centered, `separatorColor` at 70 % | Inserted between idle/hover chips; hidden adjacent to the active chip. |
| Chip corner radius | 6 pt top corners; 0 pt bottom corners | Reads as a "folder tab" silhouette without looking card-like. |
| Transition | `easeInOut(0.10s)` for hover/press, `spring(response: 0.3, dampingFraction: 0.85)` for reorder | Snappy, not soupy. |

Dirty indicator: a 12 × 12 pt progress spinner (`ProgressView().controlSize(.mini)`) is rendered in place of a leading bullet; when not dirty the slot collapses. Single-line title uses `.lineLimit(1)` with `.truncationMode(.middle)`.

### Component Boundaries

Split `apps/mac/codans/App/Features/TabBar/` into:

```
TabBar/
├── TabBarFeature.swift                 (unchanged skeleton + new actions)
├── TabBarView.swift                    (container: material, overflow, trailing)
├── Views/
│   ├── TabChipView.swift               (one chip; owns hover + focus state)
│   ├── TabChipLabel.swift              (title + optional spinner)
│   ├── TabChipCloseButton.swift        (circle + xmark, hover-revealed)
│   ├── TabChipBackground.swift         (state → fill + underline)
│   ├── TabBarRowView.swift             (HStack + drag-reorder gesture)
│   ├── TabBarOverflowScroll.swift      (ScrollView + gradient shadows)
│   ├── TabBarTrailingAccessories.swift (+, split-right, split-down)
│   ├── TabChipContextMenu.swift        (right-click menu items)
│   ├── TabChipMiddleClickView.swift    (NSViewRepresentable — middle-click)
│   └── SplitPreviewPopoverView.swift   (hover preview of the active tab tree)
└── Style/
    ├── TabBarMetrics.swift             (numeric constants)
    └── TabBarColors.swift              (semantic color tokens)
```

Dependency direction is one-way: `TabBarView` → `Views/*` → `Style/*`. `Views/*` files never reach into each other horizontally except for composition. `Style/*` has no SwiftUI view types. Views read the catalog only through `@Environment(HierarchyManager.self)` and dispatch exclusively to `store.send(…)` — no view reaches into `HierarchyClient` directly.

### API Design — HierarchyClient additions

Closures added to `HierarchyClient` (each a one-line forward to `HierarchyManager`):

```
renameTab(_ id: TabID,
          _ inWorktree: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID,
          _ name: String?) throws -> Void

reorderTabs(_ inWorktree: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID,
            _ orderedIDs: [TabID]) throws -> Void

closeOtherTabs(keeping id: TabID,
               _ inWorktree: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID) throws -> Void

closeTabsToRight(of id: TabID,
                 _ inWorktree: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID) throws -> Void

closeAllTabs(_ inWorktree: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID) throws -> Void

selectAdjacentTab(direction: TabAdjacency,
                  _ inWorktree: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID) throws -> TabID?

// Runtime state (C3-driven writer; always-safe reader).
tabIsDirty(_ id: TabID) -> Bool
lastFocusedPane(in tabID: TabID) -> PaneID?
```

Error policy matches the existing client: `.notFound(...)` for unknown IDs, silent no-ops for unchanged state (no save scheduled). Every mutation persists via the shared debounced `CatalogStore.scheduleSave(catalog)` pipeline — except the two runtime maps, which are non-persistent by design.

`TabAdjacency` is a simple enum (`previous / next`) with wrap-around semantics; returns the resolved `TabID?` so the caller can sequence a follow-up `selectTab` without a second lookup.

### API Design — TabBarFeature actions

New TCA actions, each a one-line forward through the client:

```
enum Action: Equatable {
  // existing
  case newTabButtonTapped(...)
  case tabButtonTapped(TabID, ...)
  case closeButtonTapped(TabID, ...)

  // added
  case renameSubmitted(TabID, name: String?, ...)
  case contextMenuCloseOthers(TabID, ...)
  case contextMenuCloseToRight(TabID, ...)
  case contextMenuCloseAll(...)
  case dragReorderEnded(orderedIDs: [TabID], ...)
  case middleClicked(TabID, ...)
  case shortcutSelectIndex(Int, ...)          // ⌘1..⌘9
  case shortcutSelectAdjacent(TabAdjacency, ...)
  case shortcutNewTab(...)
  case shortcutCloseTab(...)
  case trailingSplit(direction: SplitDirection, ...)
}
```

Reducer stays stateless. All side effects are synchronous `try?` calls into `HierarchyClient`; errors are logged via `Logger("com.gumpw.codans.tab-bar")` and swallowed (tab-bar failures are rare and dead-end).

### Data Storage

**`Tab`**: unchanged. `name: String?` already exists; rename writes the field as-is (or `nil` to clear). The `icon`, `isDirty`, `isTitleLocked`, `isIconLocked` fields are deliberately *not* added — re-visit when C3 hooks land.

**Catalog persistence**: no schema change. `CatalogStore` continues to encode `Tab` as today. No migration; existing `catalog.json` on user disks remains forward- and backward-compatible.

**Runtime-only maps** (added to `HierarchyManager`, not persisted):

```
private var lastFocusedPaneByTab: [TabID: PaneID] = [:]
private var paneRunning: [PaneID: Bool] = [:]

func markPaneRunning(_ paneID: PaneID)
func markPaneIdle(_ paneID: PaneID)
func tabIsDirty(_ tabID: TabID) -> Bool
func lastFocusedPane(in tabID: TabID) -> PaneID?
func setLastFocusedPane(_ paneID: PaneID?, in tabID: TabID)
```

`selectTab` calls `runtime.focusSurfaceView(for:)` using `lastFocusedPane(in:)` when present, falling back to the leftmost pane of the split tree. `closePane` clears the entry; `closeTab` clears the bucket.

### Interactions

| Interaction | Trigger | Handler |
|---|---|---|
| Select tab | Click chip | `tabButtonTapped`; restores last-focused pane. |
| New tab | Click `+`, `⌘T` | `shortcutNewTab` / `newTabButtonTapped`. |
| Close tab | Click `xmark`, middle-click, `⌘W` | `closeButtonTapped` / `middleClicked` / `shortcutCloseTab`. |
| Rename | Right-click → Rename | `renameSubmitted` after inline `TextField` commit or `Esc`. |
| Select adjacent | `⌘⇧[` / `⌘⇧]` | `shortcutSelectAdjacent(.previous / .next)`; wraps. |
| Select by index | `⌥⌘1`..`⌥⌘9` | `shortcutSelectIndex(N)`; no-op past the last tab. (`⌘1..⌘9` is already Space-switch; `⌃⌘1..⌃⌘9` is already Worktree-jump.) |
| Reorder | Drag chip | `dragReorderEnded(orderedIDs:)` once on drop; live preview via local `@State` offset. |
| Context menu | Right-click chip | Items: Rename, Close, Close Others (disabled when single), Close to the Right (disabled when last), Close All. |
| Split right / down | Trailing accessory button; `⌘D` / `⌘⇧D` (wired via main menu → `PaneActionRouter`) | Forwards to existing `splitPane` on the active pane. |
| Split preview | Hover trailing split button for ≥ 350 ms | Renders a miniature of the current tab's `SplitTree` in an `.popover`; dismisses on exit. |
| Overflow scroll | Many tabs exceed bar width | Horizontal `ScrollView` without indicators; 16 pt gradient shadows on each edge when `contentOffset != 0` / `!= max`. |
| Auto-scroll to selected | `selectedTabID` change | `ScrollViewReader.scrollTo(id, anchor: .center)` with `easeInOut(0.15s)`. |

### Cross-Cutting Concerns

**Keyboard discoverability.** All shortcuts are declared in `MainMenuCommands` so they appear in the menu bar. The context menu lists each destructive item's shortcut in the trailing gutter. This gives first-time users two non-exclusive paths to every action.

**Accessibility.**
- Each chip is a `Button` with `accessibilityLabel = "Tab: \(title)"` and trait `.isSelected` on the active one.
- Close button has its own accessibility label `"Close tab \(title)"`.
- Drag-reorder via keyboard uses VoiceOver actions `"Move left"` / `"Move right"` tied to the `moveTab(offset:)` API.
- Dirty spinner is redundant — the word `(running)` is appended to the accessibility label when `tabIsDirty`.

**Observability.** A single `Logger("com.gumpw.codans.tab-bar")` logs structured events for create / close / rename / reorder. No personally identifying info — titles are logged at `.private(mask: .hash)` since users may embed paths or hostnames.

**Testing strategy.**
- `TabBarFeatureTests`: `TestStore`-backed cases per new action. Mock `HierarchyClient` asserts the forwarded call shape.
- `HierarchyManagerTests`: `renameTab`, `reorderTabs`, `closeOtherTabs`, `closeTabsToRight`, `closeAllTabs` (invariant: surviving tabs' `selectedTabID` stays valid). `setLastFocusedPane` + `selectTab` focus-restoration.
- Snapshot tests for chip visual states (idle / hover / press / active / dirty) gated behind the existing `SNAPSHOT_TESTING` scheme flag.
- Manual smoke: 20-tab overflow scroll, drag reorder, right-click, middle-click, all shortcuts.

**Rollout.** No feature flag. Layered PRs:
1. Layer 1 (UI refactor, no behavior change) — safe to ship behind zero gates; the only user-visible change is chip styling.
2. Layer 2 (interactions + new client APIs) — additive; existing callers keep working.
3. Layer 3 (runtime maps) — additive; writers are dormant until C3 hooks land.

**Back-out.** Each layer reverts cleanly. Layer 3's writer methods can sit unused indefinitely without affecting layer 1 or 2 behavior.

## Alternatives Considered

### Alt A — Put `isDirty`, `isTitleLocked`, `isIconLocked` on `Tab` now

*Trade-off:* matches an eventual richer data model, fewer migrations later.
*Rejected because:* those fields only earn their keep when automated title / icon writers exist. Before C3 hooks ship there is no competing writer to lock out and no hook event to flip `isDirty`. Adding persisted fields now means catalog-format churn for bytes that are always their defaults, plus a wider Swift surface to keep consistent. Add them alongside the writer, not before.

### Alt B — Make `Tab.splitTree` hold live `PaneView` instances instead of `PaneID`

*Trade-off:* removes the "ID → runtime view" dictionary indirection; operations on the tree could mutate views in place.
*Rejected because:* `Tab` is `Codable` and persisted verbatim in `catalog.json`. Embedding `NSView` subclasses forces a separate persistence shape and couples the core data model to AppKit/SwiftUI types — which would block future contexts like a headless CLI preview or remote UI. The current ID-indirection pattern costs one dictionary lookup per render; negligible at realistic tab counts.

### Alt C — Drive tab-bar logic from a dedicated `@Observable TabBarState` instead of `HierarchyManager`

*Trade-off:* decouples tab-bar from the global hierarchy tree; narrower test surface.
*Rejected because:* tabs are hierarchy-scoped (per Worktree). Adding a parallel state container means two sources of truth for the same data and synchronization hazard around create / close / select. The current pattern — views read `HierarchyManager`, reducers forward through `HierarchyClient` — already scales; the marginal cost of more closures on `HierarchyClient` is lower than the ongoing cost of reconciling two stores.

### Alt D — Implement drag-reorder by exchanging `moveTab(offset:)` calls on every pointer tick

*Trade-off:* reuses the existing API; no new method.
*Rejected because:* `moveTab(offset:)` triggers a persist-save each call. A drag produces dozens of ticks per second — the debounced `scheduleSave` absorbs most of them, but the view must still animate on reducer state change, which introduces reorder flicker when two consecutive ticks cross the same midpoint. Capturing one absolute-order snapshot on drop (`reorderTabs(orderedIDs:)`) is cheaper, simpler to unit-test, and matches how the catalog actually wants to be mutated.

### Alt E — Animate active-tab background fill instead of a top underline

*Trade-off:* feels native to macOS controls (matches how some iOS tabs read).
*Rejected because:* a filled background competes with the per-chip hover state — hovering any chip would visually approximate "selected", muting the selection signal. A thin colored underline keeps the hover vocabulary clean and reads at a glance in dense bars.

## Risks

| Risk | Mitigation |
|---|---|
| Drag-reorder collides with chip-click detection and swallows taps. | Gesture uses a 3 pt movement threshold before entering reorder mode; under that threshold the tap dispatches normally. Covered by a targeted UI test with scripted pointer events. |
| Keyboard shortcuts conflict with in-app or Ghostty bindings (`⌘T`, `⌘W`, and any `⌘N` pattern are common terminal shortcuts). | `⌘1..⌘9` and `⌃⌘1..⌃⌘9` are already taken by Space and Worktree respectively, so tab index is placed on `⌥⌘1..⌥⌘9` (verified free). All tab-bar shortcuts are declared in the main menu; Ghostty's `keybind` registry routes menu shortcuts to the first responder only when not bound to a built-in action. If `⌘T` / `⌘W` conflict with a Ghostty default in staging, the tab-bar binding takes precedence (matches native-app expectation) and the Ghostty binding is either deduplicated in our config or surfaced as a preference. |
| Overflow scroll renders under the trailing accessory cluster, clipping the last chip. | Trailing accessories are pinned outside the `ScrollView` inside the container `HStack`. The scroll region's trailing gradient shadow starts exactly at the accessory boundary. Manual smoke test with 1, 5, 20, 50 tabs in the PR description. |
| Hover popover for split preview fires on accidental cursor sweep. | 350 ms hover delay and cancellation on pointer exit; popover is non-modal and never steals focus. |
| `lastFocusedPaneByTab` holds stale IDs after a pane closes via an external path (hook, runtime crash). | `closePane` and `tearDownWorktreeSurfaces` remove the entry; `selectTab` falls back to the tree's leftmost leaf when the stored pane is gone. Unit test exercises the race: close the stored pane, then switch tabs away and back. |
| Rename inline field steals typing focus mid-terminal-input. | Rename opens only via the right-click context menu — never on chip hover, click, or double-click. Committing or pressing `Esc` returns focus to the previously focused pane via `runtime.focusSurfaceView`. Covered by a TCA test. |
| C3 hooks land and start writing `paneRunning` at high frequency, saturating view updates. | `paneRunning` map mutations on `HierarchyManager` are already `@Observable`; SwiftUI batches reads. If profiling shows contention, gate writes to `markPaneRunning` / `markPaneIdle` behind idempotency checks (no-op when the value is unchanged) — the write path is the only call site touching the map. |
