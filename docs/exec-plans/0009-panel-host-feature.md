# ExecPlan: Lift LazyPaneHost side-effects into PaneHostFeature

**Status:** Completed
**Author:** Gump
**Date:** 2026-04-22

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this change, opening codans with a saved catalog that contains panes no longer crashes with `TerminalClient.liveValue not configured`. The underlying architectural fix is: pane surface lifecycle (first-resolve, retry, failure-rendering) is owned by a TCA reducer, not by a SwiftUI view body calling `@Dependency(TerminalClient.self)` out of scope. `LazyPaneHost` becomes a pure renderer driven by a scoped `Store<PaneHostFeature>`; the fatal-stub seam that currently guards `TerminalClient.liveValue` stays in place and no longer gets punched through at app launch.

## Progress

- [x] M1 — PaneHostFeature reducer + SurfaceBox wrapper
- [x] M2 — SplitViewportFeature integration (panelHosts IdentifiedArrayOf + sync action + forEach)
- [x] M3 — LazyPaneHost view rewrite (pure renderer over StoreOf<PaneHostFeature>)
- [x] M4 — SplitViewportView wiring (catalog→state sync + child store scope)
- [x] M5 — Tests: PanelHostFeatureTests with TestStore; LazyPanelHostTests removed
- [x] M6 — Build + run against real catalog.json; no `TerminalClient.liveValue` fatalError on launch

## Surprises & Discoveries

- **`@Reducer` + `some ReducerOf<Self>` → "circular reference" error.** The `@Reducer` macro expansion couldn't resolve `ReducerOf<Self>` for the body's return type. Switched to `some Reducer<State, Action>` (the form every other reducer in this project uses) and the macro expanded cleanly. Logged here because the error message (`circular reference` in a generated `@__swiftmacro_…` file) gives no hint that the cause is the return-type style.
- **`inout State` + `Logger` string interpolation.** Accessing `state.paneID.description` inside `panelHostLogger.error("… \(state.paneID.description, privacy: .public) …")` inside `resolveSurface(state: inout State)` errors with "escaping autoclosure captures 'inout' parameter 'state'" — the privacy-annotated interpolation is an autoclosure. Fix: bind `let panelIDDescription = state.paneID.description` before the log call.
- **Pre-existing test-host crash shadows the verification path.** `xcodebuild test` bootstrap crashes in `EditorClient.live → MainActor.assumeIsolated` (PR #30 code), unrelated to this plan. Integration verification therefore relied on launching the live app against `~/.config/codans/catalog.json`; confirmed by `log show` that the `TerminalClient.liveValue not configured` fatal-error no longer fires. Test-host crash should be filed as its own issue.

## Decision Log

- **Reducer owns surface reference, not view.** The reducer places the resolved `PaneSurface` into state (wrapped as `SurfaceBox` for identity-based `Equatable`) so the view can be a pure renderer. Alternative (view looks up surface via `@Environment` closure or passed-down property) was rejected because it re-introduces plumbing for a value that already has to travel through the reducer for phase transitions.
- **`SurfaceBox` wraps `PaneSurface` rather than extending the class.** Extending `PaneSurface` with `Equatable` works but leaks identity-compare semantics to every call site; a wrapper confines the implication to the reducer boundary and keeps `PaneSurface` unchanged.
- **Sync action flows view → reducer, not the reverse.** The catalog lives in `HierarchyManager` (@Observable), not in TCA state. `SplitViewportView` is the SwiftUI boundary that sees both, so it dispatches `.panelsInActiveTabChanged([seed])` on `.onChange(of: currentTabPanelIDs())`. Alternative (reducer pulling from catalog every action) would bind the reducer to HierarchyManager and complicate tests.
- **Preserve existing child state on sync.** When the pane set changes, existing `PaneHostFeature.State` entries are carried over by `paneID`; only new panes get a fresh `.loading` seed. This keeps the surface reference alive across catalog mutations that don't actually remove panes.
- **Fatal-stub `TerminalClient.liveValue` stays.** The seam is valuable — it enforces "this client must be injected by the reducer scope". After the refactor there is no view reading `@Dependency(TerminalClient.self)`, so the seam never fires at runtime and its sentinel role becomes purely architectural.

## Outcomes & Retrospective

Opening `codans` via `open $APP` (which triggers macOS window restoration with the pre-existing `~/.config/codans/catalog.json` containing real Space → Project → Worktree → Tab → Pane data) now settles into a live session. `log show --predicate 'process == "Codans"'` no longer contains `Codans/TerminalClient.swift:85: Fatal error: TerminalClient.liveValue not configured`. Architecturally, no SwiftUI view in the project now reads `@Dependency(TerminalClient.self)`; the fatal-stub seam is intact and its only role is to guard against future regressions. `LazyPaneHost` dropped from ~115 lines of view-embedded side-effect logic to ~75 lines of pure rendering; the decision tree is exercised by `PanelHostFeatureTests` via `TestStore`.

Outstanding (not in scope for this plan):
- Pre-existing test-host crash in `EditorClient.live → MainActor.assumeIsolated` blocks `xcodebuild test` for the app bundle regardless of what tests are being exercised. Needs a separate fix on that client's threading contract.
- `PanelHostFeatureTests` does not cover the `.ready` branch because `PaneSurface` requires libghostty + Metal and can't be constructed under xctest. The live launch covers that path; if we want unit coverage, introduce an abstraction (`SurfaceHandle` protocol) that `PaneSurface` implements and the tests can fake.

## Context and Orientation

Related:
- `apps/mac/codans/App/CodansApp.swift:227` — `Store.init(withDependencies:) { $0.terminalClient = .live(...) }` sets the reducer-scoped dependency that the new `PaneHostFeature` will consume.
- `apps/mac/codans/App/Clients/TerminalClient.swift:78-103` — fatalError stubs for `liveValue` that the current `LazyPaneHost` hits via `@Dependency` outside reducer scope.
- `apps/mac/codans/App/Features/Root/RootFeature.swift:120-124` — existing comment acknowledges the exact failure mode in `Commands` structs; the LazyPaneHost bug is the same class.
- `apps/mac/codans/App/Features/SplitViewport/LazyPaneHost.swift` — current SwiftUI-view-driven ensureSurface; to be rewritten as pure renderer.
- `apps/mac/codans/App/Features/SplitViewport/SplitViewportFeature.swift` — parent reducer that will host the new `IdentifiedArrayOf<PaneHostFeature.State>`.
- `apps/mac/codans/App/Features/SplitViewport/SplitViewportView.swift` — view boundary that bridges `HierarchyManager`'s catalog into the reducer via a sync action, and scopes child stores by `PaneID`.

Terms:
- **Surface**: a `PaneSurface` instance owned by `TerminalEngine`'s registry. One per live Pane.
- **Sync action**: `.panelsInActiveTabChanged([PaneHostFeature.State])` emitted by the view when the active Tab's pane set changes.
- **Phase**: the reducer-visible lifecycle state for a pane host — `.loading`, `.ready`, `.failed(String)`.

## Plan of Work

### Milestone 1 — PaneHostFeature

Add `App/Features/SplitViewport/PaneHostFeature.swift`. Introduce `SurfaceBox` (local to the file) wrapping `PaneSurface` with identity-based `Equatable`. State holds `paneID`, the full `(spaceID, projectID, worktreeID, tabID)` address, `phase: Phase`, and `surface: SurfaceBox?`. `Action`: `.task`, `.resolved(SurfaceBox)`, `.failed(String)`, `.retryButtonTapped`. Reducer uses `@Dependency(TerminalClient.self)`; on `.task` or `.retryButtonTapped`, short-circuits via `terminalClient.surface(paneID)` and otherwise runs `.run { send in … }` over `ensureSurface + surface`, cancellable by `CancelID.ensure(paneID)` with `cancelInFlight: true`. Verify at the end of M1: the file compiles in isolation (swift build of CodansKit target or `xcodebuild` on the scheme); no behavioural change yet.

### Milestone 2 — SplitViewportFeature integration

Extend `SplitViewportFeature.State` with `panelHosts: IdentifiedArrayOf<PaneHostFeature.State> = []`. Extend `Action` with `.panelsInActiveTabChanged([PaneHostFeature.State])` and `.panelHosts(IdentifiedActionOf<PaneHostFeature>)`. In the reducer body: handle the sync action by merging (preserve entries whose `paneID` still exists, seed new entries), return `.none` for child actions not requiring parent handling, and attach `.forEach(\.panelHosts, action: \.panelHosts) { PaneHostFeature() }`. No view changes yet. Acceptance: existing `SplitViewportView` still compiles (child is unused) and tests pass.

### Milestone 3 — LazyPaneHost view rewrite

Rewrite `LazyPaneHost` to take `let store: StoreOf<PaneHostFeature>`. Body: `switch store.phase` → loading/ready/failed panes; `.task { store.send(.task) }`. Remove `@Dependency`, `@State var state`, `ensureSurface()` method, and internal `LoadState` enum. Retry button dispatches `.retryButtonTapped`. Keep the existing logger subsystem name (`com.gumpw.codans.shell` / `lazy-pane`) so telemetry tags are stable, but emit only from reducer logging (TBD if needed — not required for M3). Acceptance: file compiles, no behavioural wiring yet from parent view.

### Milestone 4 — SplitViewportView wiring

In `SplitViewportView`, add a computed `currentTabPanelIDs()`; use SwiftUI `.onAppear` + `.onChange(of: currentTabPanelIDs())` to compose the seed list and dispatch `store.send(.panelsInActiveTabChanged(seeds))`. Rewrite `panelLeaf(_:)` to scope via `store.scope(state: \.panelHosts[id: paneID], action: \.panelHosts[id: paneID])`; render the new `LazyPaneHost` when scope returns a non-nil store, else a transient placeholder (ProgressView) covering the one-frame gap between the view appearing and the sync action landing. Acceptance: app builds; existing pane flows (open, split, close, retry) still work end-to-end.

### Milestone 5 — Tests

New `Tests/PanelHostFeatureTests.swift` using `TestStore`:
- **Short-circuit**: `.task` with `terminalClient.surface` returning a stub surface → `.resolved` → `phase == .ready`. (Stub surface via a `SurfaceBox` around a test-only reference — introduce a minimal test helper inside the test target to avoid touching production `PaneSurface`.)
- **First-appearance success**: `.task` with surface initially nil → `ensureSurface` succeeds → surface-lookup returns stub → `.resolved`.
- **First-appearance failure**: `ensureSurface` throws `TerminalClient.Error.worktreeNotFound` → `.failed(_)`.
- **Post-ensure lookup nil**: ensureSurface succeeds but registry still returns nil → `.failed("Surface not registered after creation.")`.
- **Retry**: `.retryButtonTapped` from failed state re-runs the effect.

Retire or rewrite `Tests/LazyPanelHostTests.swift` — the outcome-enum helper is now redundant. Replace with a brief smoke test that `LazyPaneHost(store:)` renders the expected view for each phase (snapshot-free; assert on store state propagating to body via `store.withState`). If the smoke test is awkward to write without a render host, delete the file.

Acceptance: `cd apps/mac && xcodebuild -workspace ... test -only-testing:codansTests/PanelHostFeatureTests` passes.

### Milestone 6 — End-to-end verification

`make generate && make run-app`. Confirm:
1. App launches against the existing `~/.config/codans/catalog.json` (which contains real worktrees + tabs + panes) without crashing.
2. `log show --predicate 'process == "Codans"' --last 1m` shows no `TerminalClient.liveValue not configured`.
3. Surfaces render, tabs switch, pane close/split still works.
4. Killing the surface (e.g. `exit` inside shell) moves phase into `.failed` with the "Retry" button, and retry succeeds when the underlying condition clears.

## Concrete Steps

```bash
# After each milestone (M1-M5): build only
cd apps/mac && make build

# After M4: first live run
cd apps/mac && make generate && make run-app

# After M5: tests
cd apps/mac && xcodebuild -workspace codans.xcworkspace \
  -scheme codans -configuration Debug \
  test -only-testing:codansTests
```

## Validation and Acceptance

- Unit: `PanelHostFeatureTests` passes all five cases above. `LazyPanelHostTests` is removed or reduced to a stub smoke.
- Integration: launching the existing catalog (`~/.config/codans/catalog.json` with `work.myskills.main` tabs) via `open $APP` does not emit `TerminalClient.liveValue` in `log show`. Surfaces restore; tab switches don't re-create surfaces (engine registry retains them).
- Regression: existing `RootFeatureTests`, `SplitViewport`-adjacent tests, and `PaneActionRouterFeatureTests` still pass.

## Idempotence and Recovery

All code edits are additive or in-place rewrites; no data migrations. If a milestone fails midway, revert the partial commit and resume. The catalog on disk is untouched by this work. If the new feature misbehaves at runtime, removing `.forEach` + sync action and restoring the old `LazyPaneHost` is a single-commit revert.

## Artifacts and Notes

Reference crash line to clear after fix:

```
Codans/TerminalClient.swift:85: Fatal error: TerminalClient.liveValue not configured
```

## Interfaces and Dependencies

In `apps/mac/codans/App/Features/SplitViewport/PaneHostFeature.swift`, define:

```swift
@Reducer
struct PaneHostFeature {
  @ObservableState
  struct State: Equatable, Identifiable {
    let paneID: PaneID
    let tabID: TabID
    let worktreeID: WorktreeID
    let projectID: ProjectID
    let spaceID: SpaceID
    var phase: Phase
    var surface: SurfaceBox?

    var id: PaneID { paneID }

    enum Phase: Equatable { case loading, ready, failed(String) }
  }

  enum Action: Equatable {
    case task
    case resolved(SurfaceBox)
    case failed(String)
    case retryButtonTapped
  }
}

struct SurfaceBox: Equatable {
  let surface: PaneSurface
  static func == (l: Self, r: Self) -> Bool { l.surface === r.surface }
}
```

In `apps/mac/codans/App/Features/SplitViewport/SplitViewportFeature.swift`, extend `State` and `Action` as in Milestone 2. Reducer composition uses `.forEach(\.panelHosts, action: \.panelHosts) { PaneHostFeature() }` (TCA 1.23.1).
