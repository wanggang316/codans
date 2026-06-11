# ExecPlan: Settings Window — Repositories Subtree (T4)

**Status:** Superseded by [project-settings.md](./project-settings.md) (2026-04-25)
**Author:** Gump (agent: feat/settings-repositories)
**Date:** 2026-04-21

This is a living document. The Progress, Surprises & Discoveries, Decision
Log, and Outcomes & Retrospective sections must be kept up to date as work
proceeds.

## Purpose

After this change, when a user opens the Settings window (⌘,) and expands a
Repository row in the sidebar, the **General** sub-section will present a
working "Default editor override" picker (Use global default / Finder / each
installed editor) and a "Worktree base directory override" file picker + Clear
button, both persisted to `catalog.json` through `HierarchyClient`. The
**Hooks** sub-section will render a read-only merged list of hooks that
currently fire for that Project — each row tagged Global or Repository —
with a "Reveal hooks.json in Finder" escape hatch. Everything else in the
Settings window stays exactly as T1 delivered it.

The frozen T1 contracts (`SettingsSection` enum, `SettingsWindowView` detail
switch, `SettingsStore` / `Settings` v2 shape, `RepositorySettings`
reserved-empty) do not move. Per-Project fields (`Project.defaultEditor`,
`Project.worktreesDirectory`) stay on the Catalog per T1 Decision D1.

## Progress

Each step lands as a single `/commit`. Steps 1–6 are code commits; Step 7 is
manual QA. Nothing is pushed to the remote during Steps 1–7. The push and PR
open happen once, at Final, only after master sends `EXECUTE_GREEN` and the
branch has been rebased onto the post-T3 `feature/settings-base` tip.

- [ ] Step 0 — Wait-for-T3 gate (no code; master handshake)
- [ ] Step 1 — `HierarchyManager.setWorktreesDirectory` + `findProjectAnySpace` + `setDefaultEditorAnySpace` sibling + `HierarchyManagerTests` extension
- [ ] Step 2 — `HierarchyClient` + 2 closures (live + test + fatalError stubs) + `HierarchyClientTests` extension
- [ ] Step 3 — `HookConfigClient` TCA dependency + live wiring in `CodansApp`
- [ ] Step 4 — `RepositorySettingsFeature` reducer + `classify` pure helper + `RepositorySettingsFeatureTests` + `RepositoryHookClassifyTests`
- [ ] Step 5 — `SettingsWindowFeature.State.repositoryPanes` + `.forEach` composition + `projectsChanged` pruning + `SettingsWindowView` detail-switch scope (plus `SettingsWindowFeatureTests` extension)
- [ ] Step 6 — `RepositoryGeneralSettingsView` + `RepositoryHooksSettingsView` body replacements (consume `HookMergeView` and related T3 symbols)
- [ ] Step 7 — Manual QA walk of spec Acceptance Criteria for Repository General / Repository Hooks; `make format` + `make lint` idempotent style pass
- [ ] Final — push + `gh pr create --base feature/settings-base`

## Surprises & Discoveries

(None yet)

## Decision Log

(None yet — Design Decisions D1/D2/D3 already recorded in
`docs/design-docs/settings-repositories.md` and not duplicated here.)

## Outcomes & Retrospective

(To be filled at Final completion.)

## Context and Orientation

Related documents:

- Product spec: `docs/product-specs/ui-settings-window.md` — Must-haves M10,
  M11, M12 and their Acceptance Criteria bullets under *Repository General*
  and *Repository Hooks*.
- Design doc (approved): `docs/design-docs/settings-repositories.md` —
  Architecture, API shapes, classification rule, alternatives rejected.
- Prior design (approved + implemented): `docs/design-docs/settings-base.md`
  and `docs/exec-plans/settings-base.md` — the T1 landing that froze
  contracts this plan builds on. Do not alter.
- Architecture: `docs/architecture.md` — Persistence invariants
  (atomic-rename + 500 ms debounce) apply to every write path touched here.
- Golden rules: `docs/golden-rules.md` — rules 2 (validate boundaries), 3
  (shared utilities), 8 (small commits).

Key source files this plan touches:

- `apps/mac/codans/Runtime/HierarchyManager.swift` — the `@MainActor`
  Catalog owner. Gains `setWorktreesDirectory(_, for:)`,
  `setDefaultEditorAnySpace(_, for:)`, and a private
  `findProjectAnySpace(_:)` helper (Step 1). Today it already owns
  `setDefaultEditor(_, for:, in:)` which we leave intact.
- `apps/mac/codans/App/Clients/HierarchyClient.swift` — the TCA
  dependency struct. Gains two projectID-only closures
  (`setRepositoryDefaultEditor`, `setRepositoryWorktreeBaseDirectory`) with
  live bridges, fatalError-backed liveValue stubs, and unimplemented
  testValue stubs (Step 2).
- `apps/mac/codans/App/Clients/HookConfigClient.swift` — new file;
  narrow TCA dependency wrapping the shared `HookConfigStore` so the
  reducer's load effect is injectable (Step 3).
- `apps/mac/codans/App/Features/Settings/RepositorySettingsFeature.swift`
  — new reducer (Step 4). Holds `projectID` + `hooksLoad` +
  `lastWriteFailure`; exposes actions documented in the Design doc API
  section.
- `apps/mac/codans/App/Features/Settings/SettingsWindowFeature.swift` —
  the T1 window reducer. Gains
  `repositoryPanes: IdentifiedArrayOf<RepositorySettingsFeature.State>`,
  a `.repositoryPane(IdentifiedActionOf<…>)` action case, a `.forEach`
  composition, and the extra pruning branch inside `projectsChanged`
  (Step 5). Do not change `selection`, `general`, or the `windowClosed`
  branch.
- `apps/mac/codans/App/Features/Settings/SettingsWindowView.swift` —
  the detail switch. Only the two Repository cases change; they now scope
  into `\.repositoryPanes[id: projectID]` and fall back to `EmptyView()`
  on the 1-frame gap between Project-removed and selection-reset (Step 5).
  All six global-section cases stay byte-identical.
- `apps/mac/codans/App/Features/Settings/Panes/RepositoryGeneralSettingsView.swift`
  and `…/RepositoryHooksSettingsView.swift` — the two placeholder pane
  views. Step 6 replaces their bodies while keeping the `struct …: View
  { let projectID: ProjectID; … }` outer shape the T1 detail switch
  depends on (adds a `store:` parameter in addition to `projectID`).
- `apps/mac/codans/App/Features/Settings/Panes/HookMergeView.swift` —
  **owned by T3, not T4.** This plan references `HookMergeView`,
  `HookRow`, `HookSource`, `TrailingAction`, and `HookRowBuilder.make` as
  imports from the same module. T4 does not create a stub; the Execute
  gate in Step 0 ensures T3 has merged before Step 6 runs.

Terms of art:

- **Global section** / **Repository section** — sidebar row categories
  defined in the product spec Vocabulary.
- **Frozen contract** — a symbol or signature T1 committed and other waves
  must not change. For T4 the frozen surfaces are: `SettingsSection`, the
  detail-switch cases in `SettingsWindowView`, and `SettingsStore` /
  `Settings` v2 / `RepositorySettings`.
- **T3 frozen API** — the public symbols in
  `.../Panes/HookMergeView.swift` that T3 Design (APPROVE 2026-04-21)
  committed: `HookRow`, `HookSource`, `HookMergeView`, `TrailingAction`,
  `HookRowBuilder`. See Interfaces and Dependencies below.
- **Execute gate** — the handshake defined in the Design doc R1 and in
  master's APPROVE reply: after `PLAN_APPROVED_WAITING_FOR_T3`, we hold
  until master pushes `EXECUTE_GREEN`.
- **Project snapshot** — the live read of
  `hierarchyManager.catalog.spaces[*].projects.first(where: { $0.id == pid })`
  used in the pane views to source picker selection defaults. The
  Catalog is `@Observable`, so reads under `body` re-render on change.
- **HookSource** — T3's two-case enum tagging whether a subscription is
  scoped to the target Project's worktrees (`.repository`) or fires for
  any context (`.global`). Classification rule is in
  `docs/design-docs/settings-repositories.md § Data Storage / Hook
  classification`.

## Plan of Work

The work is ordered bottom-up so each step compiles and tests cleanly in
isolation: first the Catalog-side mutator (Step 1), then the TCA bridge
(Step 2), then the Hook-side bridge (Step 3), then the feature reducer that
consumes both bridges (Step 4), then the window-level composition (Step 5),
and finally the pane view bodies (Step 6). Each step is a single `/commit`.
This ordering also matches the order master laid out in APPROVE.

Step 0 is an **out-of-code handshake gate** required by master: after
`PLAN_READY` / APPROVE, T4 must reply `PLAN_APPROVED_WAITING_FOR_T3`, then
hold until `EXECUTE_GREEN`. Steps 1–7 and Final only happen after
`EXECUTE_GREEN` and a clean rebase onto the post-T3
`feature/settings-base` tip. Step 0 is not a commit.

### Step 0 — Wait-for-T3 gate

No code. After master APPROVEs this PLAN, the agent replies
`PLAN_APPROVED_WAITING_FOR_T3` (in the prowl channel) and stops. Master
will push `EXECUTE_GREEN` once T3's PR has merged to
`feature/settings-base`.

On receiving `EXECUTE_GREEN`:

```
git fetch origin feature/settings-base
git rebase origin/feature/settings-base
ls apps/mac/codans/App/Features/Settings/Panes/HookMergeView.swift
grep -n 'public struct HookMergeView' apps/mac/codans/App/Features/Settings/Panes/HookMergeView.swift
grep -n 'public enum HookRowBuilder' apps/mac/codans/App/Features/Settings/Panes/HookMergeView.swift
```

Expect: `HookMergeView.swift` exists; the two greps each return one line.
If either miss, push `BLOCKED: waiting on T3 HookMergeView` and stop; do
not proceed to Step 1.

Rationale: eliminates any possibility of a local HookMergeView stub
diverging from T3's real file. Design doc R1 and D1 both commit to this
sequencing.

### Step 1 — HierarchyManager internal mutators

Scope: add three items to
`apps/mac/codans/Runtime/HierarchyManager.swift`, and extend
`apps/mac/codans/Tests/HierarchyManagerTests.swift`.

Add the private helper first. Near the existing
`findProjectIndices(projectID:, spaceID:)` private func (around line 649),
add:

```swift
/// Locates the Project across all Spaces. Returns the first match —
/// ProjectIDs are UUIDs and collisions are effectively zero, but in
/// debug builds assert at most one space contains the id.
private func findProjectAnySpace(_ projectID: ProjectID) -> (Int, Int)? {
  var found: (Int, Int)? = nil
  for (sIdx, space) in catalog.spaces.enumerated() {
    if let pIdx = space.projects.firstIndex(where: { $0.id == projectID }) {
      assert(found == nil, "Project \(projectID) appears in multiple spaces")
      found = (sIdx, pIdx)
    }
  }
  return found
}
```

Then add two mutators that forward to the helper:

```swift
/// Sets or clears the per-Project worktree base directory. `nil` clears.
/// Silent no-op on unchanged value; throws `.notFound` on missing Project.
/// Persists through the shared debounced `store.scheduleSave(catalog)`.
func setWorktreesDirectory(_ path: String?, for projectID: ProjectID) throws {
  guard let (sIdx, pIdx) = findProjectAnySpace(projectID) else {
    throw HierarchyError.notFound("Project \(projectID)")
  }
  guard catalog.spaces[sIdx].projects[pIdx].worktreesDirectory != path else { return }
  catalog.spaces[sIdx].projects[pIdx].worktreesDirectory = path
  store.scheduleSave(catalog)
}

/// Sibling of `setDefaultEditor(_:for:in:)` that takes only a ProjectID.
/// Used by the Settings Repository General pane which has no SpaceID in
/// scope. Throws `.notFound` on missing Project; unchanged-value no-op.
func setDefaultEditorAnySpace(_ editorID: EditorID?, for projectID: ProjectID) throws {
  guard let (sIdx, pIdx) = findProjectAnySpace(projectID) else {
    throw HierarchyError.notFound("Project \(projectID)")
  }
  guard catalog.spaces[sIdx].projects[pIdx].defaultEditor != editorID else { return }
  catalog.spaces[sIdx].projects[pIdx].defaultEditor = editorID
  store.scheduleSave(catalog)
}
```

Do not touch the existing two-ID `setDefaultEditor(_, for:, in:)` — the
WorktreeHeader dropdown still calls it.

Tests — extend
`apps/mac/codans/Tests/HierarchyManagerTests.swift` (follow the file's
existing pattern; each test constructs a manager with one Space + one
Project fixture):

- `setWorktreesDirectory_setsValue_schedulesSave` — asserts the project's
  `worktreesDirectory` is the new path and `store.saveCount` went up.
- `setWorktreesDirectory_clearsValue` — pre-seeds a path, clears with
  `nil`, asserts the field is `nil`.
- `setWorktreesDirectory_unchangedValue_isNoOp` — seeds same path, asserts
  no save scheduled.
- `setWorktreesDirectory_unknownProject_throwsNotFound`.
- `setDefaultEditorAnySpace_setsAndClears_schedulesSave`.
- `setDefaultEditorAnySpace_unchangedValue_isNoOp`.
- `setDefaultEditorAnySpace_unknownProject_throwsNotFound`.

Verification:

```
cd apps/mac
make generate
xcodebuild -workspace codans.xcworkspace -scheme codans \
  -configuration Debug test -only-testing:codansTests/HierarchyManagerTests \
  -destination 'platform=macOS' | xcbeautify
```

Expect: `** TEST SUCCEEDED **` with the new tests passing.

Commit message:
`feat(hierarchy): add projectID-only mutators for settings pane`

### Step 2 — HierarchyClient two new closures

Scope: edit
`apps/mac/codans/App/Clients/HierarchyClient.swift` and extend
`apps/mac/codans/Tests/HierarchyClientTests.swift`.

In the struct body, add two closures (place them next to
`setDefaultEditor` around line 96–99):

```swift
var setRepositoryDefaultEditor:
  @MainActor @Sendable (_ projectID: ProjectID, _ editorID: EditorID?) throws -> Void

var setRepositoryWorktreeBaseDirectory:
  @MainActor @Sendable (_ projectID: ProjectID, _ path: String?) throws -> Void
```

In the `live(manager:)` factory, forward both to the new manager methods:

```swift
setRepositoryDefaultEditor: { projectID, editorID in
  try manager.setDefaultEditorAnySpace(editorID, for: projectID)
},
setRepositoryWorktreeBaseDirectory: { projectID, path in
  try manager.setWorktreesDirectory(path, for: projectID)
},
```

In the `liveValue` static add the two corresponding
`fatalError("HierarchyClient.liveValue not configured")` stubs. In
`testValue` add two `unimplemented("HierarchyClient.<name>")` stubs. Keep
the ordering consistent with the struct declaration so the liveValue /
testValue initializers continue to compile with positional arguments (or
switch the HierarchyClient init to a named-argument call if positional
gets unwieldy — the struct already uses an all-named init, so naming
these is fine).

Tests — extend `HierarchyClientTests.swift` with two cases:

- `setRepositoryDefaultEditor_forwardsToManager` — stands up a real
  `HierarchyManager` + `HierarchyClient.live(manager:)`, adds a Project,
  invokes `.setRepositoryDefaultEditor(projectID, "vscode")`, asserts
  `manager.catalog…project.defaultEditor == "vscode"`.
- `setRepositoryWorktreeBaseDirectory_forwardsToManager` — parallel test
  for the worktree-dir path.

Verification:

```
cd apps/mac
xcodebuild -workspace codans.xcworkspace -scheme codans \
  -configuration Debug test -only-testing:codansTests/HierarchyClientTests \
  -destination 'platform=macOS' | xcbeautify
```

Expect: `** TEST SUCCEEDED **`.

Commit message:
`feat(hierarchy): expose repository mutators on HierarchyClient`

### Step 3 — HookConfigClient TCA dependency

Scope: add
`apps/mac/codans/App/Clients/HookConfigClient.swift` (new file) and
wire its `liveValue` in `apps/mac/codans/App/CodansApp.swift`.

File contents (new):

```swift
import ComposableArchitecture
import Foundation
import CodansCore

/// Narrow TCA dependency over `HookConfigStore` — the T4 Repository
/// Hooks pane reducer reads hooks.json through these closures so the
/// effect is injectable in tests. Wrapper only; no cache, no parallel
/// store instance.
nonisolated struct HookConfigClient: Sendable {
  /// Load current hooks.json. Returns `.empty` if the file is missing or
  /// its contents are invalid — matches `HookConfigStore.load()`.
  var load: @MainActor @Sendable () async throws -> HookConfig

  /// Create an empty hooks.json at the default path if it does not
  /// already exist. Idempotent. Used before Reveal so Finder always
  /// opens something.
  var ensureExists: @MainActor @Sendable () async throws -> Void
}

extension HookConfigClient {
  @MainActor
  static func live(store: HookConfigStore, fileURL: URL = HookConfig.defaultURL()) -> HookConfigClient {
    HookConfigClient(
      load: { [weak store] in
        guard let store else { return .empty }
        return try store.load()
      },
      ensureExists: { [weak store] in
        guard let store else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
          try store.save(.empty)
        }
      }
    )
  }
}

extension HookConfigClient: DependencyKey {
  static let liveValue: HookConfigClient = HookConfigClient(
    load: { fatalError("HookConfigClient.liveValue not configured; wire via .withDependencies at app startup") },
    ensureExists: { fatalError("HookConfigClient.liveValue not configured") }
  )

  static let testValue: HookConfigClient = HookConfigClient(
    load: unimplemented("HookConfigClient.load", placeholder: .empty),
    ensureExists: unimplemented("HookConfigClient.ensureExists")
  )
}

extension DependencyValues {
  var hookConfigClient: HookConfigClient {
    get { self[HookConfigClient.self] }
    set { self[HookConfigClient.self] = newValue }
  }
}
```

Wiring in `CodansApp.swift`: locate the existing `.withDependencies`
block that binds `HierarchyClient.live(manager:)` and add an adjacent
binding `$0.hookConfigClient = .live(store: appState.hookConfigStore)`.
(The `hookConfigStore` field already exists on `AppState` for C3 hook
plumbing — grep confirms.) No changes to `bringUp()` signature.

No dedicated test file for the client — its two closures are thin
forwards that are exercised indirectly by `RepositorySettingsFeatureTests`
(Step 4) with an overriding `.withDependencies`.

Verification:

```
cd apps/mac
make generate
xcodebuild -workspace codans.xcworkspace -scheme codans \
  -configuration Debug build -destination 'platform=macOS' | xcbeautify
```

Expect: `** BUILD SUCCEEDED **`. The app target compiles with the new
dependency wired.

Commit message:
`feat(hooks): add HookConfigClient TCA dependency`

### Step 4 — RepositorySettingsFeature + classify helper + tests

Scope: add
`apps/mac/codans/App/Features/Settings/RepositorySettingsFeature.swift`
(new) and
`apps/mac/codans/Tests/Settings/RepositorySettingsFeatureTests.swift`
(new directory under Tests).

`RepositorySettingsFeature.swift` contents (prose summary — the exact
signatures are in *Interfaces and Dependencies* below):

- `@Reducer struct RepositorySettingsFeature` with
  `@ObservableState struct State: Equatable, Identifiable`
  holding `projectID: ProjectID`, `hooksLoad: HooksLoad`,
  `lastWriteFailure: String?`. `id: ProjectID { projectID }`.
- `enum HooksLoad: Equatable { case idle, loading, loaded([HookRow]), failed(String) }`.
  `HookRow` is T3's public type imported from the same module
  (same target so no `import` needed).
- `enum Action: Equatable` with cases listed in Interfaces.
- `@Dependency(HierarchyClient.self) var hierarchyClient`,
  `@Dependency(HookConfigClient.self) var hookConfigClient`,
  `@Dependency(FinderClient.self) var finderClient`.
- Body is one `Reduce` that handles each action per the Design doc.
  Write paths wrap the client call in `.run { send in do { try ...; await send(.writeSucceeded) } catch { await send(.writeFailed(String(describing: error))) } }`.
  The success branch clears `lastWriteFailure`; the failure branch
  overwrites it. `.writeSucceeded` is internal to the reducer (case in
  Action) — the sticky `lastWriteFailure` slot is cleared synchronously
  from within the reducer on success, matching
  `EditorFeature.lastProjectOverrideFailure`.
- `onHooksAppear` sets `hooksLoad = .loading` and fires a `.run` that
  calls `hookConfigClient.load()`, snapshots the target `Project` via
  the injected `hierarchyManager` **capture** — see note below — then
  calls `classify(_:for:)` and wraps each `(subscription, source)` pair
  with `HookRowBuilder.make(from:source:)`. Dispatches
  `.hooksLoaded(.success([HookRow]))` or `.hooksLoaded(.failure(…))`.
- Hierarchy snapshot pattern: the reducer doesn't hold a `HierarchyManager`.
  Instead `onHooksAppear` reads the Project snapshot through a new
  `HierarchyClient.snapshot()` call (already exists on the client as
  `@MainActor @Sendable () -> Catalog`) wrapped in `await MainActor.run`.
  Finds the target Project by ID; if absent, emits
  `.hooksLoaded(.failure(.projectGone))` — reuses the
  failed-selection fallback. This keeps `RepositorySettingsFeature` off
  the `HierarchyManager` direct-dependency list.
- `classify` is a pure nonisolated static function:
  `static func classify(_ subscription: HookSubscription, for project: Project) -> HookSource`.
  It walks the project's worktrees per the rule in the Design doc's Hook
  classification table. Path-glob matching uses
  `NSString.range(of:options: .regularExpression)` after translating
  `*` → `.*`, `?` → `.`, anchoring start/end. Keep this helper `static`
  and file-private so the test can import it (target-internal by
  default, which is fine).
- `revealHooksJSONRequested` chains
  `hookConfigClient.ensureExists()` → `finderClient.reveal(path)` inside
  one `.run` effect.

Test file `Tests/Settings/RepositorySettingsFeatureTests.swift`:

- `setDefaultEditorOverride_success_clearsFailure` — `TestStore` with
  overridden `hierarchyClient.setRepositoryDefaultEditor = { _, _ in }`.
  Send `.setDefaultEditorOverride("vscode")`; expect the internal
  `.writeSucceeded` action and `lastWriteFailure == nil`.
- `setDefaultEditorOverride_failure_recordsMessage` — override throws;
  expect `.writeFailed("...")` and `lastWriteFailure` set.
- `setDefaultEditorOverride_nil_clearsOverride` — asserts the closure is
  called with `nil`.
- `setWorktreeBaseDirectory_success` / `_failure` / `_nil_clears` — three
  parallel tests.
- `onHooksAppear_classifiesAndBuildsRows` — seeds `hookConfigClient.load`
  with three subscriptions (one `.anyPanel`, one
  `.worktreeID(wtInProject)`, one
  `.worktreePathGlob("/elsewhere/**")`); seeds `hierarchyClient.snapshot`
  with a Project containing one worktree whose id == wtInProject;
  asserts `.hooksLoaded(.success([...]))` with sources
  `[.global, .repository, .global]` in that order, and that the
  generated `HookRow.displayName` / `.eventLabel` / etc. match
  `HookRowBuilder.make(from:, source:)` for each input. (This implicitly
  checks we're using the T3 builder, not re-deriving.)
- `onHooksAppear_loadFailure_setsFailedState` — override `.load` to
  throw; expect `.hooksLoaded(.failure(...))` and
  `hooksLoad == .failed(...)`.
- `onHooksAppear_projectRemoved_setsFailedState` — seed `snapshot` with
  a catalog that does NOT contain the target projectID; expect the
  `.projectGone` failure branch.
- `revealHooksJSONRequested_callsEnsureThenReveal` — records a
  `[String]` of call order; asserts `["ensureExists", "reveal:<path>"]`.

Pure-function tests in the same file (or a sibling
`RepositoryHookClassifyTests.swift` if we want separation — I'll keep
them in the same file to minimize noise):

- `classify_anyPanel_isGlobal`.
- `classify_panelID_isGlobal`.
- `classify_tabLabel_isGlobal`.
- `classify_worktreeID_inProject_isRepository`.
- `classify_worktreeID_notInProject_isGlobal`.
- `classify_worktreePathGlob_matchesRoot_isRepository`.
- `classify_worktreePathGlob_matchesWorktreePath_isRepository`.
- `classify_worktreePathGlob_noMatch_isGlobal`.

Verification:

```
cd apps/mac
make generate
xcodebuild -workspace codans.xcworkspace -scheme codans \
  -configuration Debug test \
  -only-testing:codansTests/RepositorySettingsFeatureTests \
  -destination 'platform=macOS' | xcbeautify
```

Expect `** TEST SUCCEEDED **`; every new test case passing.

Commit message:
`feat(settings): add RepositorySettingsFeature reducer + classify`

### Step 5 — Wire feature into the window shell

Scope: modify
`apps/mac/codans/App/Features/Settings/SettingsWindowFeature.swift`,
`.../SettingsWindowView.swift`, and extend
`apps/mac/codans/Tests/SettingsWindowFeatureTests.swift`.

In `SettingsWindowFeature`:

- Add `var repositoryPanes: IdentifiedArrayOf<RepositorySettingsFeature.State> = []`
  to `State`.
- Add `case repositoryPane(IdentifiedActionOf<RepositorySettingsFeature>)`
  to `Action`.
- In `body`, after the existing `Scope(state: \.general, …)`, add
  `.forEach(\.repositoryPanes, action: \.repositoryPane) { RepositorySettingsFeature() }`.
  Place it on the composed reducer tail so the `.forEach` sits outside
  the `Reduce { ... }` block.
- Inside the `.selectionChanged(let next)` branch, when `next` is
  `.repositoryGeneral(pid)` or `.repositoryHooks(pid)`, ensure a
  `RepositorySettingsFeature.State(projectID: pid)` entry exists in
  `state.repositoryPanes` (if missing, append with the initial state).
  Idempotent: re-selecting the same pane does not reset state.
- Inside `.projectsChanged(let currentIDs)`, after the existing
  selection-fallback switch, add
  `state.repositoryPanes.removeAll { !currentIDs.contains($0.projectID) }`.
- Ignore `.repositoryPane` at the reducer level
  (`case .repositoryPane: return .none`) — the `.forEach` handles the
  child reducer automatically.

In `SettingsWindowView`, change only the two Repository cases in the
`detailView(for:)` switch. Before:

```swift
case .repositoryGeneral(let projectID):
  RepositoryGeneralSettingsView(projectID: projectID)
case .repositoryHooks(let projectID):
  RepositoryHooksSettingsView(projectID: projectID)
```

After:

```swift
case .repositoryGeneral(let projectID):
  if let paneStore = store.scope(
    state: \.repositoryPanes[id: projectID],
    action: \.repositoryPane[id: projectID]
  ) {
    RepositoryGeneralSettingsView(
      projectID: projectID,
      store: paneStore,
      settingsStore: settingsStore
    )
  } else {
    EmptyView()
  }
case .repositoryHooks(let projectID):
  if let paneStore = store.scope(
    state: \.repositoryPanes[id: projectID],
    action: \.repositoryPane[id: projectID]
  ) {
    RepositoryHooksSettingsView(projectID: projectID, store: paneStore)
  } else {
    EmptyView()
  }
```

The six global-section cases above and below these two lines stay
byte-identical. `settingsStore` is the existing `SettingsStore` the
window view already carries (it's passed to `SettingsGeneralView` for
Appearance). The Repository General pane needs access to
`settings.general.defaultEditorID` (for the "Use global default" caption
/ resolution display) and `window.general.descriptors` (for the picker
options) — see Step 6 for how the view reads them.

Tests — extend `SettingsWindowFeatureTests.swift`:

- `selectingRepositoryGeneral_ensuresPaneState` — sends
  `.selectionChanged(.repositoryGeneral(pid))`, expects
  `state.repositoryPanes` contains one entry with
  `projectID == pid`.
- `selectingRepositoryHooks_ensuresPaneState` — same shape.
- `selectingSamePaneTwice_doesNotResetState` — drive a mutation on the
  pane (e.g. overlay `lastWriteFailure`), re-send `.selectionChanged`
  for the same pid, assert the `lastWriteFailure` is preserved.
- `projectsChanged_prunesRemovedProjectPanes` — seeds two pane entries,
  sends `.projectsChanged` with only one id, asserts the other entry
  is removed.

Verification:

```
cd apps/mac
make generate
xcodebuild -workspace codans.xcworkspace -scheme codans \
  -configuration Debug test \
  -only-testing:codansTests/SettingsWindowFeatureTests \
  -destination 'platform=macOS' | xcbeautify
```

Expect `** TEST SUCCEEDED **` including the four new cases.

Commit message:
`feat(settings): compose RepositorySettingsFeature into window shell`

### Step 6 — Replace the two pane view bodies

Scope: rewrite
`apps/mac/codans/App/Features/Settings/Panes/RepositoryGeneralSettingsView.swift`
and `…/RepositoryHooksSettingsView.swift`.

#### RepositoryGeneralSettingsView

Signature becomes:

```swift
struct RepositoryGeneralSettingsView: View {
  let projectID: ProjectID
  @Bindable var store: StoreOf<RepositorySettingsFeature>
  let settingsStore: SettingsStore
  @Environment(HierarchyManager.self) private var hierarchyManager
  @State private var showingFileImporter = false
}
```

Body layout (SwiftUI `ScrollView { VStack(alignment: .leading, spacing:
28) { ... } .padding(24) }`, mirroring `SettingsGeneralView`):

1. **Header.** Project name via `hierarchyManager.catalog…project.name`,
   rendered as `Text(name).font(.title2.bold())`, with a caption
   subtitle "Overrides apply only to this Repository." Fall-through if
   the project is not found: render an empty view; `projectsChanged`
   will re-select General on the next tick.
2. **Default editor override section.**
   - Heading: `Text("Default editor").font(.headline)`.
   - Caption: `Text("Use global default unless overridden for this Repository.").font(.caption).foregroundStyle(.secondary)`.
   - `Picker("Default editor", selection: overrideBinding)`:
     - Tag `Optional<EditorID>.none` (nil) labeled "Use global default".
     - Tag `.some(EditorRegistry.finderID)` labeled "Finder".
     - `ForEach` over installed descriptors (read from
       `settingsStore` — **wait** — descriptors live on
       `window.general.descriptors`, not on `SettingsStore`. To avoid a
       `@Dependency(EditorClient.self)` call from the view, pass a
       `descriptors: [EditorDescriptor]` parameter into the view from
       `SettingsWindowView` — it already scopes `general` and can
       forward `generalState.descriptors`). Update Step 5's view code to
       pass `descriptors: store.state.general.descriptors` into
       `RepositoryGeneralSettingsView(…)`.
   - `overrideBinding`:
     - `get:` reads `hierarchyManager.catalog…project.defaultEditor`
       (as `EditorID?`).
     - `set:` dispatches `store.send(.setDefaultEditorOverride(newValue))`.
3. **Worktree base directory override section.**
   - Heading + caption mirror the editor section.
   - Current value row: `Text(currentPath ?? "Use global default")`
     styled `.monospaced` when non-nil, `.secondary` when nil.
   - HStack: `Button("Choose…") { showingFileImporter = true }` and
     `Button("Clear") { store.send(.setWorktreeBaseDirectory(nil)) }`.
     Disable Clear when current value is already nil.
   - `.fileImporter(isPresented: $showingFileImporter,
     allowedContentTypes: [.folder], allowsMultipleSelection: false)`
     handler on success dispatches
     `store.send(.setWorktreeBaseDirectory(url.path))` (the first URL
     from the result). On cancel / failure, no-op.
4. **Inline write-failure banner.** Shown only when
   `store.state.lastWriteFailure != nil`. `Label(message,
   systemImage: "exclamationmark.triangle.fill")` styled
   `.foregroundStyle(.orange)` + `.font(.caption)`. Matches
   `SettingsGeneralView` error pattern.

#### RepositoryHooksSettingsView

Signature:

```swift
struct RepositoryHooksSettingsView: View {
  let projectID: ProjectID
  @Bindable var store: StoreOf<RepositorySettingsFeature>
}
```

Body:

- `.task { await store.send(.onHooksAppear).finish() }` — triggers
  load on first appearance; TCA's `store.send(_:).finish()` pattern
  awaits all related effects so switching away re-triggers if
  `hooksLoad == .idle`.
- Switch on `store.state.hooksLoad`:
  - `.idle` / `.loading` — `ProgressView("Loading hooks…")` centered.
  - `.loaded(let rows)`:
    ```swift
    HookMergeView(
      rows: rows,
      emptyStateTitle: "No hooks configured for this Repository.",
      emptyStateMessage: "Hooks you add to hooks.json will appear here, tagged Global or Repository.",
      showsSourceTag: true,
      trailingAction: TrailingAction(
        title: "Reveal hooks.json in Finder",
        systemImage: "folder",
        handler: { store.send(.revealHooksJSONRequested) }
      )
    )
    ```
  - `.failed(let message)` — `VStack` with the message + a Retry button
    that sends `.onHooksAppear` again.

No secondary Reveal button outside `HookMergeView` (per Design D1).

#### Update `SettingsWindowView` detail switch (from Step 5)

Revisit the scope block: forward `descriptors` and `settingsStore`:

```swift
case .repositoryGeneral(let projectID):
  if let paneStore = store.scope(state: \.repositoryPanes[id: projectID],
                                 action: \.repositoryPane[id: projectID]) {
    RepositoryGeneralSettingsView(
      projectID: projectID,
      store: paneStore,
      settingsStore: settingsStore
    )
  } else {
    EmptyView()
  }
```

The `descriptors` read inside the view will go through `@Environment`
or a new parameter — refined during Step 6 implementation. Prefer
adding `descriptors: [EditorDescriptor]` as an explicit parameter and
reading it from `store.state.general.descriptors` in
`SettingsWindowView.detailView(for:)`; fall back to an `@Environment`
only if Swift complains about a parameter of non-Equatable type (it
won't — `EditorDescriptor` is `Equatable`).

No new tests in this step — the view bodies are straightforward SwiftUI
wiring over tested state + actions. Manual QA covers them in Step 7.

Verification:

```
cd apps/mac
make generate
xcodebuild -workspace codans.xcworkspace -scheme codans \
  -configuration Debug test -destination 'platform=macOS' | xcbeautify
```

Expect `** TEST SUCCEEDED **` across every scheme (codans,
CodansCore, CodansKit, codans). No new tests pass/fail, but prior steps stay
green.

Commit message:
`feat(settings): implement Repository General and Repository Hooks panes`

### Step 7 — Manual QA + lint/format

No code commits unless QA finds a regression. Walk each spec Acceptance
Criteria bullet that touches Repository panes, using
`apps/mac/make run-app`:

1. Open ⌘,; expand a Repository row; confirm the two child rows render
   with T1's icons (T1 behavior, sanity).
2. On `.repositoryGeneral`:
   - Default editor picker shows Use global default / Finder /
     installed editors.
   - Set to a concrete editor; restart app; re-open Settings; selection
     persists.
   - Set to "Use global default"; restart; selection shows "Use global
     default"; externally opening the Project falls back to the global
     default (use ⌘E in the main window to cross-verify).
3. On worktree base directory:
   - Click Choose…; select a folder in `.fileImporter`; path appears.
     Restart; path persists.
   - Click Clear; path goes blank. Restart; still blank.
4. On `.repositoryHooks`:
   - With a clean hooks.json (empty or unseen): pane shows the empty
     state title/message from HookMergeView.
   - With one `.anyPanel` hook in hooks.json: row appears tagged
     `Global`.
   - Add a hook with `scope: { kind: "worktreePathGlob", value: "<project-rootPath>/**"}`;
     row appears tagged `Repository` after re-opening the pane.
   - Click `Reveal hooks.json in Finder`; Finder opens with the file
     selected. Delete the file; click Reveal again; file is recreated
     empty and Finder selects it.
5. Spec Acceptance on selection fallback: close Project A in main
   window while viewing its Repository General pane; sidebar selection
   drops back to global General.
6. Close Settings + reopen: General is the default detail pane (M16 —
   T1 behavior, not regressed).

Then run:

```
cd apps/mac
make format
make lint
```

Expect `swift-format` idempotent (no diff) and `swiftlint` zero new
violations. If either emits changes, commit as
`style(settings): swift-format + swiftlint` (the only optional commit
in this step).

If any QA step fails, file it under *Surprises & Discoveries*, open a
sub-step 7a/7b with the fix, commit as `fix(settings): …`.

### Final — push + open PR

After Steps 1–7 all land and the working tree is clean:

```
git push -u origin feat/settings-repositories
gh pr create --base feature/settings-base \
  --title "feat(settings): Repository General + Repository Hooks panes (T4)" \
  --body-file - <<'EOF'
## Summary

- Replace `RepositoryGeneralSettingsView` body with controls for
  per-Project default editor override (Use global default / Finder /
  installed editor) and worktree base directory override
  (`.fileImporter` + Clear). Persistence goes through
  `HierarchyClient` to `catalog.json`.
- Replace `RepositoryHooksSettingsView` body with a merged read-only
  hooks list rendered by T3's `HookMergeView`, source-tagged
  Global / Repository. Reveal hooks.json in Finder is the only edit
  path (spec M12).
- Add `RepositorySettingsFeature` reducer + pure `classify` helper
  (units tested). Window shell (`SettingsWindowFeature.State`) gains
  `repositoryPanes: IdentifiedArrayOf<...>` + `.forEach` composition
  + `projectsChanged` pruning branch.
- `HierarchyClient` exposes `setRepositoryDefaultEditor` and
  `setRepositoryWorktreeBaseDirectory` (projectID-only). Manager gets
  `setWorktreesDirectory` + `setDefaultEditorAnySpace` via a new
  `findProjectAnySpace` helper.
- Introduce `HookConfigClient` TCA dependency around the shared
  `HookConfigStore`.

## Design & Plan

- Product spec: `docs/product-specs/ui-settings-window.md` (M10–M12)
- Design doc: `docs/design-docs/settings-repositories.md`
- ExecPlan: `docs/exec-plans/settings-repositories.md`

## Frozen contracts respected

- T1 D1 — `Project.defaultEditor` / `Project.worktreesDirectory` stay
  on catalog.json; `Settings.repositories` remains reserved-empty.
- T3 frozen API — `HookMergeView`, `HookRow`, `HookSource`,
  `TrailingAction`, `HookRowBuilder.make` imported verbatim.
- `SettingsSection`, `SettingsWindowView` detail switch, `SettingsStore`
  shape, `Settings` v2 — unchanged.

## Test plan

- [x] `xcodebuild test` on codans scheme — RepositorySettingsFeatureTests,
      HierarchyManagerTests (extended), HierarchyClientTests (extended),
      SettingsWindowFeatureTests (extended) all green.
- [x] Manual QA walk across spec Acceptance Criteria for Repository
      General / Repository Hooks (see ExecPlan §Outcomes).
- [x] `make format` idempotent; `make lint` clean.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
```

Push the PR URL back via prowl: `PR_READY: <url>`.

## Concrete Steps

Working directory for all commands: `apps/mac/` (repository root:
`/Users/wanggang/.worktree/repos/codans/feat/settings-repositories`).

### Generate Tuist project

```
make generate
```

Expected tail: `Project generated at …`. No errors. Run after each code
commit that adds/removes a file; no need to run when only editing.

### Build sanity check

```
xcodebuild -workspace codans.xcworkspace -scheme codans \
  -configuration Debug build -destination 'platform=macOS' | xcbeautify
```

Expected: `** BUILD SUCCEEDED **`.

### Full test matrix (run before Final)

```
xcodebuild -workspace codans.xcworkspace -scheme codans \
  -configuration Debug test -destination 'platform=macOS' | xcbeautify
xcodebuild -workspace codans.xcworkspace -scheme CodansCoreTests \
  -configuration Debug test -destination 'platform=macOS' | xcbeautify
xcodebuild -workspace codans.xcworkspace -scheme CodansKitTests \
  -configuration Debug test -destination 'platform=macOS' | xcbeautify
xcodebuild -workspace codans.xcworkspace -scheme tcTests \
  -configuration Debug test -destination 'platform=macOS' | xcbeautify
```

Expected: each scheme ends with `** TEST SUCCEEDED **`.

### Format + lint

```
make format
make lint
```

Expected: `swift format` idempotent (no diff after a second run);
`swiftlint` emits no new violations relative to the T1 baseline.

### Run the app for manual QA

```
make run-app
```

## Validation and Acceptance

System-level acceptance phrased as user-observable behaviour, mirroring
the spec:

**Repository General — default editor override.** User opens
Settings → expands a Repository → General. Observable: the picker lists
"Use global default" (default), "Finder", and every built-in + custom
editor currently installed. Selecting a concrete editor persists to
`catalog.json`; closing and re-opening Settings shows the same
selection. Selecting "Use global default" clears the override — the
next external open of that Project falls back to the global default
editor configured in global General.

**Repository General — worktree base directory.** User clicks
Choose…, selects a folder via `.fileImporter`. Observable: the path
appears below the button. Quitting and relaunching the app shows the
same path. Clicking Clear empties the display and future worktree
creation uses the global default again. The `catalog.json` on disk
contains `"worktreesDirectory": "<path>"` or has the key absent after
Clear.

**Repository Hooks — classification.** Seed hooks.json with three
subscriptions: one `.anyPanel`, one scoped
`.worktreeID(<id-of-worktree-in-project-A>)`, one
`.worktreePathGlob("<project-A.rootPath>/**")`. Open Settings →
Project A → Hooks. Observable: three rows, in the file order, with
source tags `[Global, Repository, Repository]` respectively. Switching
to Project B (which does not contain those worktrees) shows all three
as Global.

**Repository Hooks — reveal hatch.** With no hooks.json on disk: click
"Reveal hooks.json in Finder". Observable: Finder opens with
`~/.config/codans/hooks.json` selected; the file is a valid
`{"version": 1, "subscriptions": []}` document.

**Test matrix green.** `xcodebuild test` across all four schemes
ends with `** TEST SUCCEEDED **`. The new test counts:
`RepositorySettingsFeatureTests` contributes ≥ 14 passes (7 action
tests + 7 classify tests). `HierarchyManagerTests` gains 7 passes.
`HierarchyClientTests` gains 2. `SettingsWindowFeatureTests` gains 4.

**Write-failure banner.** Temporarily override
`HierarchyClient.setRepositoryDefaultEditor` via a local build to
throw; open Repository General; pick an editor. Observable: the orange
exclamation banner appears with the error text. Revert the override;
pick again; banner disappears after the successful write.

## Idempotence and Recovery

Each step is implemented by editing or adding files — both inherently
idempotent under git. If a step lands but verification fails, the
recovery path is `git reset --hard HEAD~1` to drop the step's commit,
diagnose the failure, and re-attempt. Do **not** `--amend` — per
project CLAUDE.md: create NEW commits rather than amending, so a
failed pre-commit hook never silently rewrites a prior commit.

Step 0's rebase is the only operation that rewrites local history. If
the rebase produces conflicts (it should not — T4's worktree and T3's
worktree touch disjoint files by Design), abort with
`git rebase --abort` and push
`BLOCKED: waiting on T3 HookMergeView (rebase conflicts: <files>)`.
Do not resolve conflicts against T3's file — that would risk
accidentally modifying the frozen contract surface.

No destructive commands land in this plan. Remote interactions are one
push + one `gh pr create` at Final. The PR is targeted to
`feature/settings-base`, not `main`; no production branch is touched.

If the T3 rebase in Step 0 succeeds but
`ls apps/mac/codans/App/Features/Settings/Panes/HookMergeView.swift`
returns nothing, the rebase picked up the wrong tip. Run
`git log --oneline -5 origin/feature/settings-base` to identify the
actual HEAD, and push `BLOCKED: … (feature/settings-base HEAD
does not contain HookMergeView)`.

If migration fixtures from prior waves cause test flakes
(`HOME=/tmp/tctest-…`), run `rm -rf /tmp/tctest-*` and rerun — this
plan does not write to those paths but prior-wave tests might leak.

## Artifacts and Notes

### Expected catalog.json after Step 6 manual QA

With Project A having both overrides set:

```jsonc
{
  "version": 1,
  "spaces": [
    {
      "id": "...",
      "projects": [
        {
          "id": "...",
          "name": "A",
          "rootPath": "/Users/me/dev/a",
          "defaultEditor": "vscode",
          "worktreesDirectory": "/Users/me/worktrees/a",
          "worktrees": [ /* ... */ ]
        }
      ]
    }
  ]
}
```

Clearing both overrides yields the same object without the two
override keys (per existing `Project` Codable defaults).

### Example HookMergeView invocation (Step 6)

```swift
HookMergeView(
  rows: [
    HookRowBuilder.make(from: anyPanelHook, source: .global),
    HookRowBuilder.make(from: worktreeIDHook, source: .repository),
  ],
  emptyStateTitle: "No hooks configured for this Repository.",
  emptyStateMessage: "Hooks you add to hooks.json will appear here, tagged Global or Repository.",
  showsSourceTag: true,
  trailingAction: TrailingAction(
    title: "Reveal hooks.json in Finder",
    systemImage: "folder",
    handler: { store.send(.revealHooksJSONRequested) }
  )
)
```

## Interfaces and Dependencies

The following types and signatures must exist at the end of the plan.
Consumers (manual QA, other waves) depend on these verbatim.

In
`apps/mac/codans/Runtime/HierarchyManager.swift`:

    func setWorktreesDirectory(_ path: String?, for projectID: ProjectID) throws
    func setDefaultEditorAnySpace(_ editorID: EditorID?, for projectID: ProjectID) throws
    private func findProjectAnySpace(_ projectID: ProjectID) -> (Int, Int)?

In
`apps/mac/codans/App/Clients/HierarchyClient.swift`:

    var setRepositoryDefaultEditor:
      @MainActor @Sendable (_ projectID: ProjectID, _ editorID: EditorID?) throws -> Void
    var setRepositoryWorktreeBaseDirectory:
      @MainActor @Sendable (_ projectID: ProjectID, _ path: String?) throws -> Void

In
`apps/mac/codans/App/Clients/HookConfigClient.swift` (new):

    nonisolated struct HookConfigClient: Sendable {
      var load: @MainActor @Sendable () async throws -> HookConfig
      var ensureExists: @MainActor @Sendable () async throws -> Void
    }
    extension HookConfigClient: DependencyKey {
      static let liveValue: HookConfigClient
      static let testValue: HookConfigClient
    }
    extension DependencyValues {
      var hookConfigClient: HookConfigClient { get set }
    }

In
`apps/mac/codans/App/Features/Settings/RepositorySettingsFeature.swift`
(new):

    @Reducer
    struct RepositorySettingsFeature {
      @ObservableState
      struct State: Equatable, Identifiable {
        let projectID: ProjectID
        var hooksLoad: HooksLoad = .idle
        var lastWriteFailure: String? = nil
        var id: ProjectID { projectID }
        enum HooksLoad: Equatable {
          case idle, loading
          case loaded([HookRow])        // T3 public HookRow
          case failed(String)
        }
      }
      enum Action: Equatable {
        case setDefaultEditorOverride(EditorID?)
        case setWorktreeBaseDirectory(String?)
        case writeSucceeded
        case writeFailed(String)
        case onHooksAppear
        case hooksLoaded(Result<[HookRow], LoadFailure>)
        case revealHooksJSONRequested
        enum LoadFailure: Error, Equatable { case projectGone, io(String) }
      }
      static func classify(_ subscription: HookSubscription, for project: Project) -> HookSource
    }

In
`apps/mac/codans/App/Features/Settings/SettingsWindowFeature.swift`
(modified):

    @ObservableState struct State: Equatable {
      var selection: SettingsSection? = nil
      var general: EditorFeature.State = .init()
      var repositoryPanes: IdentifiedArrayOf<RepositorySettingsFeature.State> = []
      // ...
    }
    enum Action: Equatable {
      case selectionChanged(SettingsSection?)
      case general(EditorFeature.Action)
      case windowClosed
      case projectsChanged(Set<ProjectID>)
      case repositoryPane(IdentifiedActionOf<RepositorySettingsFeature>)
    }

Symbols consumed from T3's frozen API (imported from the same target —
no Swift `import` required):

    public struct HookRow: Identifiable, Hashable, Sendable {
      public let id: UUID
      public let displayName: String
      public let eventLabel: String
      public let matchSummary: String?
      public let enabled: Bool
      public let source: HookSource
    }
    public enum HookSource: Hashable, Sendable { case global, repository }
    public struct HookMergeView: View {
      public init(
        rows: [HookRow],
        emptyStateTitle: String = "No hooks configured.",
        emptyStateMessage: String? = nil,
        showsSourceTag: Bool = false,
        trailingAction: TrailingAction? = nil
      )
    }
    public struct TrailingAction: Equatable {
      public let title: String
      public let systemImage: String?
      public let handler: @MainActor () -> Void
    }
    public enum HookRowBuilder {
      public static func make(from subscription: HookSubscription, source: HookSource) -> HookRow
    }

External libraries used (no new dependencies):

- `ComposableArchitecture` — `@Reducer`, `@ObservableState`,
  `IdentifiedArrayOf`, `IdentifiedActionOf`, `.forEach`, `TestStore`,
  `@Dependency`, `DependencyKey`, `unimplemented`.
- `SwiftUI` — `Picker`, `Button`, `.fileImporter`, `Label`, `VStack`,
  `ScrollView`, `Bindable`, `@Environment`, `@State`.
- `Observation` (`@Observable`) — only for existing consumers
  (`HierarchyManager`, `SettingsStore`). No new `@Observable` types.
- `Foundation` — `URL`, `NSString` regex primitives for path-glob
  matching inside `classify`.

No new SPM packages, no Tuist `Project.swift` edits (the Tuist
`buildableFolders` already cover `codans/App/Clients/`,
`codans/App/Features/Settings/`, `codans/Tests/Settings/`;
verified in T1 Step 0 and unchanged since).
