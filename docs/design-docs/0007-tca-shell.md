# Design Doc: 0007 — TCA Shell

**Status:** Approved
**Author:** Gump (with Claude)
**Date:** 2026-04-20
**Approved:** 2026-04-20 by Gump

## Context and Scope

Exec-plan 0002 (C1+C2, closed 2026-04-20) shipped the terminal engine and the five-level hierarchy (Space → Project → Worktree → Tab → Pane) end-to-end. `TerminalEngine`, `CatalogStore`, `HierarchyManager`, and `GhosttyRuntime` / `PaneSurface` are live and tested. The app launches with a single hardcoded libghostty shell.

What's missing is the TCA application shell that wraps those primitives into a usable macOS app: a sidebar that lets the user navigate Space / Project / Worktree, a tab bar per Worktree, a split viewport that renders `SplitTree<PaneID>`, and the `*Client` dependency-key bridges that every future feature will inject.

Three downstream capabilities are blocked on this shell:
- **C6** (agent-notification inbox sidebar)
- **C7** (git diff/history viewer, docked in a content or inspector slot)
- **C8** (editor settings, modal or sidebar slot)

Each of those needs a host `RootFeature` to inject into and a place to put views — today there's no composition point.

Architecture has already mandated the hybrid TCA + `@Observable` split (see [architecture.md § State Management](../architecture.md#state-management-hybrid-tca--observable)) and the two-client surface (see [0001-terminal-and-hierarchy.md § API Design](0001-terminal-and-hierarchy.md)). This doc concretises that specification: how TCA features compose, where state lives, and how views wire up.

## Goals and Non-Goals

**Goals**
- A minimal working `RootFeature` that composes sub-features for sidebar / tab bar / split view.
- `HierarchyClient` and `TerminalClient` `DependencyKey`s with `liveValue`, `testValue`, and `previewValue` — the bridge every C6/C7/C8 feature will depend on.
- `NavigationSplitView` topology — sidebar column + detail column. Inspector slot reserved but not populated.
- Selection persists: picking a Worktree or a Tab survives restart via `CatalogStore`.
- Lazy surface creation: switching to an empty Worktree does not spin up surfaces; switching to the active Tab does.
- Subscribe `RootFeature` to `TerminalEngine.events()` so lifecycle events (paneExited, tabAutoClosed, paneCrashed) update UI state.
- 2+ sub-feature unit tests each using `TestStore` with fake clients.

**Non-Goals**
- Drag-and-drop reorder of Spaces / Projects / Worktrees / Tabs / Panes.
- Keyboard-driven navigation (`Cmd+1` / `Cmd+Shift+]` / etc.) — wire the menubar, no keybindings yet.
- Advanced focus management (returning focus after modal dismissal, shift-tab semantics).
- Per-Space multi-window (architecture.md Q2 is still open; ship single-window-per-Space for v1).
- Command palette — exists in supacode and supaterm but is a separate feature.
- Settings / preferences UI — the hierarchy edit surface is enough; settings lands with C8.
- CommandPaletteFeature, UpdatesFeature (Sparkle), Deeplink routing — separate plans.
- Any C6 / C7 / C8 content — those slot *into* this shell but are not defined here.

## Design

### Overview

The shell is a thin TCA composition layer over the shipped `HierarchyManager` and `TerminalEngine`. The key trade-off is **where mutable hierarchy state lives when the UI needs to read it**. Both reference projects (supacode and supaterm) settled the same way and we adopt it:

1. `HierarchyManager` remains the single `@Observable` writer of `Catalog`. It is *not* duplicated into TCA state.
2. TCA feature state stores *selection* (which Space / Project / Worktree / Tab is active — which is already persisted in the catalog) and *transient UI state* (modal presentations, alerts, search query). Structural data is read directly from `HierarchyManager.catalog` at render time.
3. SwiftUI views receive the `HierarchyManager` via `@Environment` and read its `@Observable` properties; TCA sub-features hold no reference to it and send all mutations through `HierarchyClient` commands.
4. `TerminalEngine.events()` is subscribed once in `RootFeature.onLaunch` and yielded to the reducer as `.engineEvent(TerminalEvent)`. Downstream features react by sending their own actions.

The central reason for this split: TCA state must be `Equatable` and value-typed; storing a live `Catalog` (with stable UUIDs but mutable nesting) in `@ObservableState` means every mutation produces diff work, and we would duplicate `HierarchyManager` as the source of truth. Better to keep one writer and let TCA hold the *view-specific* residue.

### System Context Diagram

```
  ┌─────────────────────── WindowGroup ──────────────────────┐
  │  ContentView @Environment(HierarchyManager)              │
  │  ┌──────────────────── RootFeature ──────────────────┐   │
  │  │  StoreOf<RootFeature>                             │   │
  │  │  ├─ sidebar: HierarchySidebarFeature.State        │   │
  │  │  ├─ detail:  WorktreeDetailFeature.State          │   │
  │  │  ├─ inspector: InspectorFeature.State?  (deferred)│   │
  │  │  └─ presentations: alerts, sheets                 │   │
  │  └───────────────────────────────────────────────────┘   │
  │                                                          │
  │  NavigationSplitView                                     │
  │   ┌──────────────────┬─────────────────────────────┐     │
  │   │  SidebarView     │  WorktreeDetailView         │     │
  │   │  (reads Hier.    │  ├─ TabBarView              │     │
  │   │   catalog;       │  ├─ SplitViewportView       │     │
  │   │   commands via   │  │   (recursively renders   │     │
  │   │   HierClient)    │  │    SplitTree<PaneID>)   │     │
  │   │                  │  └─ PaneHostView(surface)  │     │
  │   └──────────────────┴─────────────────────────────┘     │
  └──────────────────────────────────────────────────────────┘
          │                             │
          ▼                             ▼
  HierarchyClient.send(cmd) ──▶ HierarchyManager (@Observable)
                                    │
          TerminalClient.events ◀───┤ (subscribes to TerminalEngine.events())
                                    ▼
                              TerminalEngine (@MainActor)
                                    │
                              GhosttyRuntime + PaneSurface[]
```

### API Design

Two `DependencyKey`-conforming function structs, paralleling supacode's `TerminalClient`:

**HierarchyClient** — structural mutations + catalog read snapshot. All commands return `Void` or an optional ID (for creation); errors arrive back via the event stream (`hierarchyMutated` for success; sheet/alert actions for user-visible failures). Methods are `@MainActor @Sendable` and narrow; the `liveValue` forwards each command to the matching `HierarchyManager` method.

- Commands: `createSpace(name)`, `selectSpace(SpaceID?)`, `addProject(spaceID, name, rootPath, gitRoot?)`, `removeProject(spaceID, projectID)`, `createWorktree(spaceID, projectID, name, path, branch)`, `removeWorktree(spaceID, projectID, worktreeID)`, `selectWorktree(spaceID, projectID, worktreeID?)`, `createTab(…)`, `closeTab(…)`, `selectTab(…, tabID?)`, `openPanel(…)`, `splitPanel(paneID, direction, …)`, `closePanel(…)`, `focusPanel(paneID, …)`, `resizeSplit(path, ratio, …)`.
- Reads: `snapshot() -> Catalog` (immutable copy, handy for tests and `Equatable` feature state); hot-path UI reads do not go through this — they use `HierarchyManager` directly via environment.

**TerminalClient** — input, focus, retry, and the engine event stream. Commands are `@MainActor @Sendable`.

- Commands: `sendInput(paneID, text)`, `setFocus(paneID, focused)`, `retryPanel(paneID) -> Bool`, `ensureSurface(paneID, worktreeID)`, `closeSurface(paneID)`.
- Events: `events() -> AsyncStream<TerminalEvent>` — same `TerminalEvent` type already in `CodansCore`. Root reducer subscribes once via an `Effect.run` on `.onLaunch`.

The split between the two clients mirrors their concerns: `HierarchyClient` is tree topology; `TerminalClient` is per-Pane runtime. Both compose the same `HierarchyManager` + `TerminalEngine` pair on the `liveValue` side — but separation lets features depend on only the half they need and keeps test setups small.

### Data Storage

No new persistence. `CatalogStore` (shipped) already owns `~/.config/codans/catalog.json`. Selection state (`selectedSpaceID`, `selectedProjectID` per Space, `selectedWorktreeID` per Project, `selectedTabID` per Worktree) is already in `Catalog` and persists via `HierarchyManager.scheduleSave`. The TCA shell relies on this — picking a Worktree in the sidebar calls `HierarchyClient.selectWorktree` which mutates the catalog and schedules a debounced save.

Transient UI state (sheet presentations, alert presentations, sidebar collapse, search query) lives only in TCA `@ObservableState` and is not persisted in v1. If a future plan wants restoration of e.g. "last sidebar collapse state", it lands in `settings.json` via a separate `SettingsClient`.

### Component Boundaries

Feature layout under `apps/mac/codans/App/Features/`:

| Feature | Responsibility | Depends on |
|---|---|---|
| `Root/RootFeature.swift` | Composes sub-features; subscribes to `terminalClient.events()`; owns top-level modal presentations | `HierarchyClient`, `TerminalClient`, all sub-features |
| `HierarchySidebar/HierarchySidebarFeature.swift` | Sidebar navigation state (expanded projects, selection, rename alert); dispatches `HierarchyClient.select*` + `.create*` | `HierarchyClient` |
| `WorktreeDetail/WorktreeDetailFeature.swift` | Wraps the active-Worktree column; composes `TabBarFeature` + `SplitViewportFeature` | `HierarchyClient` |
| `TabBar/TabBarFeature.swift` | Tab bar for current Worktree; create/close/rename/select | `HierarchyClient` |
| `SplitViewport/SplitViewportFeature.swift` | Split-tree rendering; split/close/focus/resize | `HierarchyClient`, `TerminalClient` |
| `Inspector/InspectorFeature.swift` | Reserved slot for C7 / C6; default empty | future |

Client-layer files under `apps/mac/codans/App/Clients/`:

| Client | File | `liveValue` wires to |
|---|---|---|
| `HierarchyClient` | `HierarchyClient.swift` | `HierarchyManager` |
| `TerminalClient` | `TerminalClient.swift` | `TerminalEngine` (and `HierarchyManager` for `ensureSurface`'s Worktree lookup) |

SwiftUI views:

| View | File | Key behaviours |
|---|---|---|
| `ContentView` | `ContentView.swift` | `NavigationSplitView` host; reads `HierarchyManager` from environment; hosts `StoreOf<RootFeature>` |
| `HierarchySidebarView` | `HierarchySidebar/HierarchySidebarView.swift` | `List` with disclosure groups; per-row context menu |
| `WorktreeDetailView` | `WorktreeDetail/WorktreeDetailView.swift` | Composes `TabBarView` + `SplitViewportView` |
| `TabBarView` | `TabBar/TabBarView.swift` | Horizontal button strip + "new tab" action |
| `SplitViewportView` | `SplitViewport/SplitViewportView.swift` | Recursive function walking `SplitTree.Node`; leaves become `PaneHostView` |

`MainView` (shipped in M5 with its direct `SingleSurfaceHost`) is replaced: `CodansApp.body` swaps to `ContentView`. `SingleSurfaceHost` goes away once `RootFeature` subscribes the real event stream and drives `TerminalClient.ensureSurface` for the active tab's leaves.

Dependency rule: feature files must not `import` each other across peer directories. Composition happens through `RootFeature`'s scopes. Sub-features communicate via `Effect` and parent-level delegate actions — not by one sub-feature's state referencing another's.

## Alternatives Considered

### A1. TCA owns the full `Catalog` state

Store the entire `Catalog` in `RootFeature.State` as `@ObservableState`. `HierarchyManager` becomes a pure data structure (no `@Observable`); TCA reducers mutate the catalog directly and `CatalogStore.scheduleSave` is called from an effect.

- **Pros:** single source of truth, single paradigm, TCA TestStore can verify every mutation.
- **Cons:** `Catalog` is nested 5 levels deep (Space → Project → Worktree → Tab → Pane); every pane-open or split-resize mutates a deeply nested struct which TCA must Equatable-diff. More importantly, `HierarchyManager` is already shipped, tested, and integrated with `TerminalEngine`, `CatalogStore`, and `GhosttyRuntime` — replacing it would mean rewriting all three to accept a new source-of-truth paradigm. The architecture invariant "`HierarchyManager` is the single writer of the tree" was picked for a reason; inverting it here is a large refactor with no downstream benefit the chosen approach doesn't already give us (selection is persisted; tests can use `HierarchyClient.testValue`).
- **Rejected.**

### A2. Pure SwiftUI (no TCA)

Drive the whole shell with `@Observable` + SwiftUI bindings; skip TCA entirely.

- **Pros:** less ceremony, no client boilerplate, the hybrid-state boundary disappears.
- **Cons:** product spec and architecture already mandate TCA for feature flows (settings, deeplink, command palette, git viewer). C6 / C7 / C8 will each want testable reducers with deterministic effects — modal dismissal, async git scans, deeplink confirmation sheets. Going SwiftUI-only now means rewriting when those features land. Also loses the established `DependencyKey`/`testValue` pattern that supacode and supaterm use to unit-test features without spinning up real ghostty runtimes.
- **Rejected.**

### A3. One big reducer (flat state, no sub-features)

Keep `HierarchySidebar` / `TabBar` / `SplitViewport` as views that send actions directly into `RootFeature`; no nested reducers.

- **Pros:** simpler file layout, avoids `Scope` boilerplate, easier to wire a shared action.
- **Cons:** C6 / C7 / C8 each want to compose *inside* one of these sub-areas (C6 inbox in the sidebar, C7 git viewer in the detail column, C8 editor settings as a detail subview). If the shell is flat, those additions force all future features to contribute actions to the monolithic `RootFeature`, bloating it and making unit tests coarse. Accepted TCA idiom is "compose by responsibility"; both reference projects follow it.
- **Rejected.**

## Cross-Cutting Concerns

**Testing strategy.** Every sub-feature ships with a `TestStore`-based test file. Each injects `HierarchyClient.testValue` / `TerminalClient.testValue` with unimplemented closures that the test overrides per-case. Sub-feature tests assert action dispatch, effect cancellation, and state updates. Integration tests stay in `CodansRuntimeTests` covering the composition end-to-end with a fake runtime.

**Observability.** `os.Logger` categories already exist (`com.gumpw.codans.*`); the shell adds `com.gumpw.codans.shell` for reducer-level logging and reuses existing `com.gumpw.codans.persistence` / `.runtime` categories. No new logger surfaces.

**Event stream lifecycle.** `RootFeature.onLaunch` arms an `Effect.run { send in for await event in terminalClient.events() { send(.engineEvent(event)) } }`. The effect is cancellable via a `CancelID.events`. On `onQuit` the effect is cancelled and `TerminalEngine.finishEventStream` is called — shipped M4 behaviour supports idempotent finish.

**Backpressure.** The engine already uses `.bufferingNewest(256)` per subscriber. Root is a fast consumer (reducer dispatch is cheap), so drops should not occur in practice; drops when they happen are safe because pane scrollback retains history.

**Error handling.** Client commands do not throw at the boundary — they swallow `HierarchyError` and surface a `.hierarchyError(String)` action that the root reducer can translate into an `@Presents alert`. The rationale mirrors supacode: TCA effects are more ergonomic when commands return `Void`, and user-visible errors are a presentation concern anyway.

**Migration path.** `CodansApp.body` flips from `MainView` to `ContentView`; `SingleSurfaceHost` is deleted once `RootFeature` drives the same path through `TerminalClient.ensureSurface`. No user-visible state migration required — the catalog schema is unchanged.

**Rollback plan.** If the TCA shell is unstable, revert `CodansApp.body` to mount `MainView`; all TCA work stays behind its own files and does not mutate the shipped runtime. A single-commit revert is enough.

## Risks

**R1 — HierarchyManager reads racing with TCA state.** Views read `hierarchyManager.catalog` during render while the reducer sends a mutation command. SwiftUI is MainActor-isolated and `HierarchyManager` is `@MainActor @Observable`, so reads are safe, but intermediate frames may paint a partially-updated tree.
*Mitigation:* structural mutations always complete synchronously on the MainActor (no `await`); render happens on the next frame; tests assert `hierarchyMutated` emits before any subsequent operation.

**R2 — TCA state referring to IDs that HierarchyManager has removed.** E.g. user deletes a Worktree while its ID is still in `HierarchySidebarFeature.State.expandedWorktreeIDs`.
*Mitigation:* sub-features filter their `[ID]` sets against the current catalog on every render (view-side) and on `hierarchyMutated` receipt (reducer-side). Supacode does this for `expandedRepositoryIDs`; we adopt the same guard.

**R3 — Split view re-render storms.** `SplitViewportView` re-evaluates on every catalog change. An agent emitting many `hierarchyMutated` signals could thrash.
*Mitigation:* `HierarchyMutationScope` (shipped M4.1) gives views scope-limited invalidation keys; `SplitViewportView` diff-checks on tab ID + split tree hash and no-ops when the tree is identical. Pre-M5.2 instrumentation already confirmed structural mutations fire on the order of Hz, not kHz.

**R4 — Tab with no Panes.** `closePanel` on the only Pane leaves an empty Tab (per M2 contract). The split viewport must render a sensible empty state.
*Mitigation:* `SplitViewportView` shows a centered placeholder with "New Pane" button; does not auto-close the Tab. Product behaviour matches the catalog's persisted state.

**R5 — `@Dependency` propagation into `NSViewRepresentable`.** `PaneHostView` is an `NSViewRepresentable`; SwiftUI dependency injection inside `makeNSView` is subtle.
*Mitigation:* `PaneHostView` is given the `PaneSurface` directly by its parent TCA feature (already the shipped pattern); no `@Dependency` lookup inside the representable. Looking up the surface by `PaneID` is a synchronous call on `TerminalEngine`, invoked from the view's parent which has environment access.

**R6 — TCA adds 10+ second cold compile time.** swift-composable-architecture + swift-dependencies + Sharing + Perception can inflate initial build significantly.
*Mitigation:* accepted cost. Same framework both reference projects ship with; cold-build target is CI-only, incremental builds are fast.

## Open Questions

1. **Inspector slot lifecycle.** Do we wire the inspector column into `NavigationSplitView` now (empty, toggleable) or add it when C7 or C6 arrives? *Leaning:* add it now but default hidden — cheaper than editing the root view each time a new feature arrives.
2. **Per-Space window count.** Architecture.md Q2 is still open; for v1 the shell ships single-window. When multi-window lands, `RootFeature` becomes `@Reducer` per-window with a shared `HierarchyManager`. Not scope here.
3. **Scrollback clipboard-copy vs terminal selection.** Shipped `GhosttySurfaceView` has no copy/paste path; once `CommandPaletteFeature` or a standard copy action lands, the TCA shell must offer a menu-item hook. Deferred.
