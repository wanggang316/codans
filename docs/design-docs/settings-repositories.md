# Design Doc: Settings Window — Repositories Subtree (T4)

**Status:** Deprecated — superseded by [project-settings.md](./project-settings.md) (2026-04-24)
**Author:** Gump (agent: feat/settings-repositories)
**Date:** 2026-04-21
**Product spec:** [ui-settings-window.md](../product-specs/ui-settings-window.md)
**Prior-art design:** [settings-base.md](./settings-base.md)

## Context and Scope

T1 landed the Settings window shell (6d4af57): independent `Window(id: "settings")`,
`NavigationSplitView` with the six global sections plus a `Repositories`
disclosure tree (one row per open Project, each expanding to `General`
and `Hooks`). The two Repository-scoped detail panes
(`RepositoryGeneralSettingsView`, `RepositoryHooksSettingsView`) are
frozen-signature placeholders whose bodies read
`Text("TODO: supplied by T4 …")`. The window's detail switch in
`SettingsWindowView` is a frozen contract — T4 replaces only the
two pane bodies, never the switch itself.

T4 fills those two pane bodies to satisfy spec M11 and M12:

- **M11 — Repository General.** Two controls: (a) per-Project default
  editor override, with `Use global default` as the default choice
  (cleared = no override); (b) per-Project worktree base directory
  override with a path picker + clear button.
- **M12 — Repository Hooks.** Read-only merged list of hooks that fire
  against the current Project, each row tagged `Global` or `Repository`
  depending on whether its scope binds it to one of this Project's
  worktrees. A `Reveal hooks.json in Finder` escape hatch is the only
  edit path — v1 does not add in-window hook editing.

Per T1 Decision D1, per-Project user data (`Project.defaultEditor`,
`Project.worktreesDirectory`) stays in `catalog.json`, reached through
`HierarchyClient`. `Settings.repositories: [ProjectID: RepositorySettings]`
remains a reserved-empty slot. T4 does **not** move data between files.

Reference files (read for this design):

- `apps/mac/codans/App/Features/Settings/Panes/RepositoryGeneralSettingsView.swift`,
  `RepositoryHooksSettingsView.swift` — placeholder bodies T4 replaces.
- `apps/mac/codans/App/Features/Settings/SettingsWindowFeature.swift`,
  `SettingsWindowView.swift`, `Sidebar/SettingsSidebarView.swift` — T1 shell.
- `apps/mac/codans/App/Features/Settings/SettingsStore.swift` — writer of
  settings.json (v2); not touched here except via read-only reads of descriptors/general.
- `apps/mac/codans/App/Features/Editor/EditorFeature.swift` — already owns
  descriptor discovery + `.setProjectOverride(projectID:spaceID:editorID:)`.
- `apps/mac/codans/App/Clients/HierarchyClient.swift`,
  `apps/mac/codans/Runtime/HierarchyManager.swift` — mutate Catalog;
  exposes `setDefaultEditor(_,for:in:)` today; T4 adds `setWorktreesDirectory`.
- `apps/mac/codans/Hooks/HookConfigStore.swift`,
  `apps/mac/CodansCore/Hooks/HookConfig.swift`,
  `apps/mac/CodansCore/Hooks/HookSubscription.swift` — hooks.json reader +
  `HookSubscription.Scope` cases that drive Global/Repository classification.
- `apps/mac/CodansCore/Project.swift` — carries `defaultEditor: String?`,
  `worktreesDirectory: String?`, and the `worktrees: [Worktree]` list the
  hook classification rule walks.
- `apps/mac/codans/App/Clients/FinderClient.swift` — reveal escape hatch.

Adjacent work:

- **T2** (Notifications pane) and **T3** (Developer pane) run in parallel.
  T3 is tasked with authoring `Panes/HookMergeView.swift`, a shared
  read-only hooks table that T4 reuses for M12. Contract TBD; see
  Open Questions / QUESTION below.

## Goals and Non-Goals

### Goals

- Replace `RepositoryGeneralSettingsView` body with controls implementing
  spec M11 — default editor override + worktree base directory override —
  persisted through `HierarchyClient` / catalog.json, live-reactive to
  the `HierarchyManager` `@Observable` surface.
- Replace `RepositoryHooksSettingsView` body with a read-only merged list
  (spec M12) that tags each hook row as `Global` or `Repository`
  according to its scope, plus a Reveal-in-Finder affordance that
  creates `hooks.json` on demand if it does not exist (spec Acceptance
  Criteria).
- Introduce a narrow `RepositorySettingsFeature` TCA reducer whose unit
  tests cover both panes' write paths, the hook-classification rule,
  and the window's pruning behavior when a Project disappears mid-edit.
- Extend `HierarchyClient` with
  `setRepositoryWorktreeBaseDirectory(projectID:, path:)` — **projectID-only**
  signature (no spaceID argument) so the Settings pane doesn't have to
  reach into the catalog shape. Add a matching
  `setRepositoryDefaultEditor(projectID:, editorID:)` so both M11
  writes share one signature style.
- Add `HierarchyManager.setWorktreesDirectory(_:for:)` — the underlying
  mutator the new client closure forwards to.
- Preserve the frozen T1 contracts: `SettingsSection` enum, detail
  switch in `SettingsWindowView`, `SettingsStore` shape, `Settings` v2
  schema, `RepositorySettings` reserved-empty struct.

### Non-Goals

- No changes to `Project`, the `Catalog` Codable, or the on-disk
  `catalog.json` schema. `Project.defaultEditor` and
  `Project.worktreesDirectory` already exist as `String?`s and already
  survive round-trip.
- No changes to `Settings.repositories` — T4 does **not** populate
  `RepositorySettings` with fields. Per-Repo user data stays in
  catalog.json per D1.
- No in-window hook editing (enable/disable/add/remove). Spec M12 is
  read-only; N3 is Nice-to-have.
- No orphan GC of catalog overrides when a Project is removed — Open
  Question #3 in the spec, out of scope for T4.
- No changes to `EditorFeature` reducer or `EditorClient` dependency.
  T4 consumes the descriptors snapshot already fetched by the window's
  `general: EditorFeature.State`, and writes overrides through the
  new HierarchyClient closure (not through
  `EditorFeature.setProjectOverride` — see Alternatives / A2).
- No contract change to `SettingsSection`. No spaceID parameter added
  to any SettingsSection case.
- No changes to T2 (Notifications) or T3 (Developer) surfaces beyond
  consuming whatever `HookMergeView` T3 publishes (see Open Questions).

## Design

### Overview

T4 introduces one reducer — `RepositorySettingsFeature` — keyed by
`ProjectID`, held on `SettingsWindowFeature.State` as an
`IdentifiedArrayOf<RepositorySettingsFeature.State>` named
`repositoryPanes`. When the user selects a Repository-scoped sidebar
row, the window reducer ensures a `RepositorySettingsFeature.State`
entry exists for that `ProjectID` (lazily instantiated on first access).
When the catalog drops a Project (existing `.projectsChanged` action),
the window reducer also prunes any matching `repositoryPanes` entry
alongside the existing selection-fallback logic.

Both pane views — `RepositoryGeneralSettingsView` and
`RepositoryHooksSettingsView` — scope off the same
`RepositorySettingsFeature` store for the current `ProjectID`. One
reducer handles both panes because:

1. The two panes share the same lifecycle (one Project, one state entry).
2. Hooks load is async and worth unit-testing in TCA style.
3. Editor/worktree writes and hook load both depend on the same
   `@Environment(HierarchyManager.self)` reads, so consolidating them
   avoids two different feature wiring stories.

The two HierarchyClient closures T4 adds —
`setRepositoryDefaultEditor(projectID:, editorID:)` and
`setRepositoryWorktreeBaseDirectory(projectID:, path:)` — take
`projectID` only. The live bridge resolves the containing `SpaceID`
inside `HierarchyManager` (existing catalog scan; cheap). This keeps
the Settings-side code from leaking the multi-space catalog shape,
which is not a Settings concern.

The central trade-off is **reuse EditorFeature vs. isolate Repository
writes in a dedicated reducer.** T1 already drives M4's global editor
picker through a scoped `EditorFeature` and exposes
`.setProjectOverride(projectID:spaceID:editorID:)`. Reusing that
single-purpose action from T4 would save ~80 lines of duplicated
reducer glue. Rejected because (a) EditorFeature currently requires
SpaceID which Settings cannot supply without leaking catalog shape
(see Goals), (b) reusing it couples the two panes' open/close lifecycle
to the window's `general` substate which is shared across Repositories,
and (c) tests for the Repository write paths would end up exercising
EditorFeature's own action plumbing as a side effect. The dedicated
reducer is cheap to write and exact-scope. See Alternatives A2.

### System Context Diagram

```
┌─────────────────────────────────────────────────────────────┐
│ Settings Window Scene                                       │
│                                                             │
│   SettingsSidebarView  ◀──  hierarchyManager (@Observable)  │
│         │                                                   │
│         ▼ selection = .repositoryGeneral(pid)               │
│   SettingsWindowView  ──┐                                   │
│                         ▼                                   │
│   RepositoryGeneralSettingsView ◀─ scope on projectID ──┐   │
│   RepositoryHooksSettingsView   ◀───────────────────────┤   │
│                                                         │   │
│                  StoreOf<RepositorySettingsFeature>   ──┘   │
│                              │                              │
│         ┌────────────────────┼─────────────────────┐        │
│         ▼                    ▼                     ▼        │
│   HierarchyClient       HookConfigClient      FinderClient  │
│   .setRepositoryDefault (new)                  .reveal     │
│   .setRepositoryWork…   .load                               │
│         │                    │                     │        │
│         ▼                    ▼                     ▼        │
│   HierarchyManager      HookConfigStore      NSWorkspace    │
│   (catalog.json writer) (hooks.json reader)                 │
└─────────────────────────────────────────────────────────────┘

Read paths (for picker options + classification):
  hierarchyManager.catalog.spaces[*].projects     — project snapshot
  settingsWindowFeature.general.descriptors       — editor list (from EditorFeature)
  hookConfigClient.load()                         — hooks.json subscriptions
```

### API Design

#### `RepositorySettingsFeature` (new reducer)

```swift
@Reducer
struct RepositorySettingsFeature {
  @ObservableState
  struct State: Equatable, Identifiable {
    let projectID: ProjectID            // stable identifier; never mutates
    var hooksLoad: HooksLoad = .idle
    var lastWriteFailure: String?       // sticky until next successful write

    var id: ProjectID { projectID }

    enum HooksLoad: Equatable {
      case idle
      case loading
      case loaded([HookRow])              // HookRow — T3's frozen public type
      case failed(String)
    }
  }

  enum Action: Equatable {
    // General pane — M11
    case setDefaultEditorOverride(EditorID?)
    case setWorktreeBaseDirectory(String?)
    case writeFailed(String)

    // Hooks pane — M12
    case onHooksAppear
    case hooksLoaded(Result<[HookRow], LoadError>)
    case revealHooksJSONRequested
  }

  @Dependency(HierarchyClient.self) var hierarchyClient
  @Dependency(HookConfigClient.self) var hookConfigClient
  @Dependency(FinderClient.self) var finderClient

  var body: some Reducer<State, Action> { /* ... */ }
}
```

Key behaviors:

- `setDefaultEditorOverride(nil)` clears the override (M11.1 "Use
  global default"). Writes through
  `hierarchyClient.setRepositoryDefaultEditor(projectID:, editorID:)`.
  On error, `writeFailed(reason)` records the message for the banner;
  on success, `lastWriteFailure` is cleared.
- `setWorktreeBaseDirectory(nil)` clears the override (M11.2 Clear button).
  Writes through
  `hierarchyClient.setRepositoryWorktreeBaseDirectory(projectID:, path:)`.
- `onHooksAppear` kicks off a `.run` effect that calls
  `hookConfigClient.load()`, classifies the subscriptions against the
  current `HierarchyManager.catalog` snapshot (classification rule in
  Data Storage § Hook classification), and maps each classified pair
  into a `HookRow` via `HookRowBuilder.make(from:, source:)` — T3's
  shared derivation helper (see T3 contract under Open Questions R1).
- `revealHooksJSONRequested` falls through to
  `finderClient.reveal(HookConfig.defaultURL().path)`. An effect
  wrapped in a `.run` that first writes an empty `HookConfig` through
  `hookConfigClient.ensureExists()` if the file is missing — spec
  Acceptance Criteria: "用户点击 Reveal hooks.json 而本地尚无该文件，
  则创建一个默认空文件并在 Finder 中显示它." The view wires this
  action through
  `HookMergeView.TrailingAction(title: "Reveal hooks.json in Finder",
  systemImage: "folder", handler: { store.send(.revealHooksJSONRequested) })`
  — the button lives inside `HookMergeView`, not alongside it. No
  parallel reveal button elsewhere in `RepositoryHooksSettingsView`.

The feature is intentionally small (~140 LoC reducer + ~60 LoC helpers).
No child feature composition, no presentation state, no timers.

#### `HierarchyClient` — two new closures

```swift
/// Sets or clears the per-Project editor override. Internally resolves
/// the containing SpaceID from the current catalog; throws
/// HierarchyError.notFound when no space owns the Project.
var setRepositoryDefaultEditor:
  @MainActor @Sendable (ProjectID, EditorID?) throws -> Void

/// Sets or clears the per-Project worktree base directory. Same
/// space-resolution + not-found semantics.
var setRepositoryWorktreeBaseDirectory:
  @MainActor @Sendable (ProjectID, String?) throws -> Void
```

Rationale for the projectID-only signature over mirroring the existing
`(ProjectID, SpaceID, …)` style:

- Settings panes never carry a SpaceID — `SettingsSection` is explicitly
  project-keyed and the frozen contract (T1 design) commits to that.
  Reaching into `hierarchyManager.catalog` from the Settings code to
  find a space leaks catalog shape into Settings.
- `HierarchyManager` already owns a `findProjectIndices(projectID:, spaceID:)`
  helper that is trivially adapted into a "scan all spaces, find the
  owning space" variant. Putting that lookup in the manager (where
  multi-space invariants already live) is correct separation.
- The existing `setDefaultEditor(_, for: ProjectID, in: SpaceID)` stays
  as-is for `EditorFeature.setProjectOverride` callers that DO have a
  SpaceID (WorktreeHeader "Open in" dropdown). No breaking change.

The testValue stubs for both new closures use `unimplemented(...)`.

#### `HierarchyManager` — one new mutator

```swift
/// Sets or clears the per-Project worktree base directory override.
/// `nil` clears the override; subsequent worktree creation falls back
/// to the global default. Project not found → HierarchyError.notFound.
/// Unchanged value is a silent no-op. Persists via the debounced
/// store.scheduleSave pipeline.
func setWorktreesDirectory(_ path: String?, for projectID: ProjectID) throws {
  guard let (sIdx, pIdx) = findProjectAnySpace(projectID) else {
    throw HierarchyError.notFound("Project \(projectID)")
  }
  guard catalog.spaces[sIdx].projects[pIdx].worktreesDirectory != path else { return }
  catalog.spaces[sIdx].projects[pIdx].worktreesDirectory = path
  store.scheduleSave(catalog)
}
```

`findProjectAnySpace` is the scan-all-spaces variant. A sibling method
`setDefaultEditorAnySpace(projectID:, editorID:)` is added alongside —
the existing `setDefaultEditor(_, for:, in:)` stays as a pure delegate
to the two-ID form.

#### `HookConfigClient` — new TCA dependency

`HookConfigStore` is already a `@MainActor` class with `load()` /
`save()` / `scheduleSave()` / `flush()`. T4 wraps it in a narrow
TCA dependency so the reducer's load effect is injectable in tests:

```swift
nonisolated struct HookConfigClient: Sendable {
  /// Load current hooks.json. Returns `.empty` if the file is missing
  /// (HookConfigStore already guarantees this).
  var load: @MainActor @Sendable () async throws -> HookConfig

  /// Create an empty hooks.json at the default path when it does not
  /// exist. No-op when the file is already present. Used before Reveal
  /// so Finder always opens something.
  var ensureExists: @MainActor @Sendable () async throws -> Void
}
```

The live wiring at `AppState.bringUp()` hands the shared
`HookConfigStore` instance into the client closures. No parallel
instance, no cache duplication.

### Data Storage

T4 reads from three existing stores and writes to one. No new on-disk
schema, no migration, no touching `settings.json`.

| Source            | Purpose                                 | Written by T4? |
|-------------------|-----------------------------------------|----------------|
| `catalog.json`    | Project.defaultEditor, worktreesDirectory | Yes (via HierarchyClient) |
| `hooks.json`      | HookConfig.subscriptions                | No (read-only) |
| `settings.json`   | GeneralSettings.defaultEditorID (fallback), AppearancePreference (N/A) | No |

#### Hook classification rule

Each `HookSubscription.Scope` case is mapped to a `HookSource` as
follows, evaluated against the target Project's `worktrees`:

```
.anyPanel                               → .global
.paneID(_)                             → .global   (panes are ephemeral)
.panelLabel(_)                          → .global
.tabID(_)                               → .global   (tabs are ephemeral)
.tabLabel(_)                            → .global
.worktreeID(wtID)
    if project.worktrees.contains(wtID) → .repository
    else                                → .global
.worktreePathGlob(pattern)
    if fnmatch(pattern, project.rootPath) ||
       project.worktrees.any { fnmatch(pattern, $0.path) }
                                        → .repository
    else                                → .global
```

`fnmatch` maps to `NSString.range(of:options: .regularExpression)` with
POSIX-glob-to-regex translation, consistent with how
`HookExecutor` evaluates path globs today (verified in
`apps/mac/codans/Hooks/HookExecutor.swift` — spot check reveals
`pathMatches` helper using the same primitive).

Classification is a pure helper — its only output is `HookSource`:

```swift
// In RepositorySettingsFeature (or an adjacent file-private helper).
static func classify(_ subscription: HookSubscription, for project: Project) -> HookSource
```

After classification the reducer turns each `(subscription, source)`
pair into T3's public `HookRow` value via
`HookRowBuilder.make(from: subscription, source: source)`. T4 does
not inline any of the row fields — all derivation lives in
`HookRowBuilder`, which is the single source of truth for the
`HookRow` shape shared with T3's Developer pane. The frozen derivation
(authored by T3, reused verbatim) is:

- `displayName` — `command` if `count ≤ 60`, else `command.prefix(57) + "…"`.
  Rendered monospaced by `HookMergeView`.
- `eventLabel` — `event.rawValue`.
- `matchSummary` — `matchPattern` (truncated) if present; else
  `"scope: <kind>"` when scope is not `.anyPanel`; else `nil`.
- `enabled` — `!subscription.disabled`.

T4 does **not** re-derive these fields — using `HookRowBuilder.make`
keeps the Developer pane (T3, M6.2) and the Repository pane (T4, M12)
visually identical except for the source-tag column, which
`HookMergeView` toggles via its `showsSourceTag: Bool` parameter
(T4 passes `true`).

**Trade-off on paneID/tabID.** A subscription scoped to a specific
pane/tab ID *could* belong to a Repository (the pane is inside a
worktree that belongs to this Project). Classifying it as `.global`
is pragmatic: pane/tab IDs are not stable across app restarts — a
subscription scoped by ID is likely an internal-namespace hook (C6
notifications) or user-authored debug scaffolding. A future version
can walk `Project.worktrees[*].tabs[*].panes[*]` to classify these
exactly, but spec M12 does not require it and doing so introduces a
non-trivial catalog-traversal cost on every hooks-pane render. We
prefer the simple rule; if users report misclassification, upgrade
later.

#### No settings.json writes

Per Goals, T4 does not populate `Settings.repositories[projectID]`.
The reserved-empty `RepositorySettings` struct remains. The pre-save
garbage-collector in `SettingsStore.scheduleSave` already drops empty
entries, so if T4's tests or future waves accidentally touch
`mutateRepository` the file stays clean.

### Component Boundaries

```
apps/mac/
└── codans/
    └── App/
        ├── Features/
        │   └── Settings/
        │       ├── RepositorySettingsFeature.swift        (NEW)
        │       ├── SettingsWindowFeature.swift            (modified: +repositoryPanes)
        │       ├── SettingsWindowView.swift               (modified: scope detail switch)
        │       ├── Panes/
        │       │   ├── RepositoryGeneralSettingsView.swift (body replaced)
        │       │   ├── RepositoryHooksSettingsView.swift   (body replaced)
        │       │   └── HookMergeView.swift                 (T3-owned; not created by T4)
        │       └── Sidebar/SettingsSidebarView.swift       (unchanged)
        └── Clients/
            ├── HierarchyClient.swift        (modified: +2 closures)
            └── HookConfigClient.swift       (NEW)

apps/mac/codans/Runtime/
└── HierarchyManager.swift                   (modified: +setWorktreesDirectory,
                                                          +findProjectAnySpace helper,
                                                          +setDefaultEditorAnySpace sibling)

apps/mac/codans/Tests/
├── Settings/
│   └── RepositorySettingsFeatureTests.swift  (NEW)
├── HierarchyClientTests.swift               (extend)
└── HierarchyManagerTests.swift              (extend)
```

Dependency directions:

- `RepositorySettingsFeature` depends on `HierarchyClient`,
  `HookConfigClient`, `FinderClient` (all TCA-injected). It does NOT
  reference `HierarchyManager` / `SettingsStore` directly.
- The two pane views consume `StoreOf<RepositorySettingsFeature>` plus
  `@Environment(HierarchyManager.self)` (for the Project snapshot the
  picker renders) and `SettingsStore` (for the editor `descriptors`
  list lifted from `window.general.descriptors` — a `Bindable` scope
  suffices, no direct store reference needed). This matches T1's
  pattern where `SettingsGeneralView` takes both a `StoreOf<EditorFeature>`
  and the `SettingsStore` reference.
- `HookConfigClient`'s live wiring references the shared
  `HookConfigStore` built in `AppState.bringUp()`. No new instance of
  `HookConfigStore` — single-reader invariant preserved.

Contract preservation:

- `SettingsSection` enum — unchanged.
- `SettingsWindowView` detail switch — unchanged shape; T4 only changes
  what the `RepositoryGeneralSettingsView(projectID:)` and
  `RepositoryHooksSettingsView(projectID:)` call-sites pass down
  (adds a `store:` parameter scoped from the window's new
  `repositoryPanes` IdentifiedArray).
- `SettingsStore` API + `Settings` v2 schema — unchanged.
- `SettingsWindowFeature.State.selection` + `general` — unchanged. Only
  `repositoryPanes` is added.

#### SettingsWindowFeature state extension

```swift
@Reducer
struct SettingsWindowFeature {
  @ObservableState
  struct State: Equatable {
    var selection: SettingsSection?
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

  var body: some Reducer<State, Action> {
    Scope(state: \.general, action: \.general) { EditorFeature() }
    Reduce { state, action in
      switch action {
      case .selectionChanged(let next):
        state.selection = next
        // Lazy-instantiate a repository pane entry when the user selects one.
        if case .repositoryGeneral(let pid) = next ?? .general {
          ensureRepositoryPane(&state, pid)
        } else if case .repositoryHooks(let pid) = next ?? .general {
          ensureRepositoryPane(&state, pid)
        }
        return .none
      // ...
      case .projectsChanged(let currentIDs):
        // Existing selection-fallback logic unchanged. Also drop panes for
        // disappeared projects so stale state does not re-surface if the
        // Project is re-added later (freshly loaded classification is safer
        // than stale classification).
        state.repositoryPanes.removeAll { !currentIDs.contains($0.projectID) }
        // ...existing selection-fallback...
        return .none
      case .repositoryPane:
        return .none
      }
    }
    .forEach(\.repositoryPanes, action: \.repositoryPane) {
      RepositorySettingsFeature()
    }
  }
}
```

The detail view scopes into the per-project store:

```swift
case .repositoryGeneral(let projectID):
  if let paneStore = store.scope(
    state: \.repositoryPanes[id: projectID],
    action: \.repositoryPane[id: projectID]
  ) {
    RepositoryGeneralSettingsView(projectID: projectID, store: paneStore)
  } else {
    // Degenerate: selection for a Project that just disappeared from the catalog.
    // projectsChanged already queued a selection fallback, but SwiftUI may render
    // one frame in between. Render an empty view; the next tick resets selection.
    EmptyView()
  }
```

### Cross-cutting notes

- **Spec M10 ("展开后两个子行已冻结")**: side effect — because the
  sidebar's DisclosureGroup is owned by T1, T4 does not modify the
  sidebar. Tap on a Repository row still expands + selects General;
  subsequent selections route through `.selectionChanged`.
- **Spec M16 ("关闭清空选中")**: `windowClosed` action already clears
  selection. Repository pane state survives (per M16 "各分段内容 …
  与上次一致"). The `projectsChanged` pruning only kicks in when a
  Project disappears — Repository pane state is NOT cleared on close.

## Alternatives Considered

### A1. No reducer — direct `@Dependency` + `@State` inside the views

Drop `RepositorySettingsFeature` entirely. Each pane view uses
`@Dependency(HierarchyClient.self)` + `@State` for hook-load
state + `.task { await load() }` for the hooks fetch.

- Pros: ~200 fewer LoC; no IdentifiedArray plumbing on the window state;
  simpler view files.
- Cons: (a) master's brief explicitly asks for a Repository-settings
  reducer with unit tests; (b) testing async load + classification
  without TCA means doing it through XCTest MainActor plumbing or
  ViewInspector, both noisier than `TestStore`; (c) the write-failure
  banner ("Last write failed: …") needs a sticky state slot somewhere
  — `@State` works but the failure is a cross-pane concern (same
  message on General when setting editor fails and when setting
  worktree dir fails), which `@State` doesn't share cleanly.
- Verdict: rejected. The reducer is small enough that the extra
  plumbing pays for itself in testability.

### A2. Reuse `EditorFeature.setProjectOverride` from the Repository pane

`EditorFeature` already has `.setProjectOverride(projectID:, spaceID:, editorID:)`.
The Repository General pane could scope into the window's `general`
substate and send that action.

- Pros: no new HierarchyClient closure; single source of truth for
  "this is how you write a per-Project editor override."
- Cons: (a) requires the pane to know a `SpaceID`, which it cannot
  supply from `SettingsSection.repositoryGeneral(ProjectID)` without
  reaching into `HierarchyManager.catalog` from the view layer —
  breaks the existing dependency direction (views don't scan the
  catalog, reducers do); (b) couples Repository panes' open/close
  lifecycle to the `general` substate, which today is window-global —
  an in-flight Repository override effect can't be scoped down for
  testing without rewriting EditorFeature; (c) the setter has no
  clear→nil semantics when Finder is *not* selected — it's ambiguous
  whether "nil" means "use global default" or "use Finder". M11
  requires three distinct states: Use global default (nil),
  Finder (explicit), any installed editor. Reusing the existing
  `.setProjectOverride(nil)` forces the view to reinvent "Finder vs
  unset" signaling outside the action payload.
- Verdict: rejected. The new HierarchyClient closure is two lines of
  bridge code and keeps semantics clean.

### A3. Two separate reducers — `RepositoryGeneralFeature` + `RepositoryHooksFeature`

Split state ~50/50 between the two panes so each pane scopes to its
own feature.

- Pros: each reducer has a single concern and is ~60 LoC; tests are
  smaller; accidentally mixing state between panes becomes impossible.
- Cons: doubles the `SettingsWindowFeature.State` wiring (two
  IdentifiedArrays instead of one); Project lifecycle pruning has to
  happen in two places; write-failure banner becomes per-pane (but
  no cross-pane reuse of the slot — fine either way); the two panes
  ALREADY share a Project identity, so keying two arrays by the same
  ProjectID is redundant storage.
- Verdict: rejected as marginally worse. Keep a single combined
  reducer; split later if the state grows (e.g., if M12 gains
  enable/disable editing per N3).

### A4. Classify hooks on the reducer side vs inside HookMergeView

T4 classifies each subscription as `.global` / `.repository` inside
`onHooksAppear` and hands pre-classified rows to `HookMergeView`.
Alternative: give HookMergeView the raw `[HookSubscription]` plus
the `Project` and let it classify.

- Pros of in-view classification: HookMergeView becomes a
  self-contained primitive T3 can also drop into Developer pane
  without external state.
- Cons: T3's Developer pane (M6.2) is *not* per-Project and has no
  `Project` object to classify against — it renders the raw hook list
  with name / enabled / match summary. A shared component that forces
  classification into every call site wastes cycles where the source
  tag is meaningless.
- Verdict: rejected. Classification is a T4-specific concern.
  HookMergeView takes pre-classified rows; Developer can pass rows all
  tagged `.global` or render an adjacent but simpler list. See Open
  Questions for the final HookMergeView API.

### A5. Store per-Repo editor override on `Settings.repositories` instead of the catalog

This is T1 Alternative A1 — hoist `Project.defaultEditor` and
`Project.worktreesDirectory` from catalog.json into
`Settings.repositories[projectID]`.

- Already rejected by T1 (D1). T4 inherits the decision verbatim.
  Re-listed here so readers see the traceability.

## Cross-Cutting Concerns

### Testing strategy

- `RepositorySettingsFeatureTests` (new, TCA `TestStore`):
  - `setDefaultEditorOverride(id)` invokes HierarchyClient with
    `(projectID, id)` and clears `lastWriteFailure` on success.
  - `setDefaultEditorOverride(nil)` invokes with `(projectID, nil)`.
  - `setDefaultEditorOverride` on a throwing client records the failure.
  - `setWorktreeBaseDirectory` — three cases (set, clear, failure)
    mirroring the above.
  - `onHooksAppear` with a mocked `HookConfigClient.load` returning
    three subscriptions — one `.anyPanel` (global), one
    `.worktreeID(wtInProject)` (repository), one
    `.worktreePathGlob("/somewhere/else/*")` (global) — verifies the
    correct classification.
  - `onHooksAppear` with a throwing client records `.failed(...)`.
  - `revealHooksJSONRequested` calls `ensureExists` then
    `FinderClient.reveal` in that order.
- `HierarchyManagerTests` extension:
  - `setWorktreesDirectory(nonNil)` mutates the catalog field and
    schedules a save.
  - `setWorktreesDirectory(nil)` clears the field.
  - Setting the same value is a no-op (no save).
  - Unknown ProjectID throws `.notFound`.
  - `setDefaultEditorAnySpace` parity cases (mirror
    `setWorktreesDirectory` — same not-found + idempotence invariants).
- `HierarchyClientTests` extension:
  - `setRepositoryDefaultEditor` / `setRepositoryWorktreeBaseDirectory`
    `liveValue` wiring forwards to the manager.
- Pure-function test: the `classify(subscription:, for: Project)`
  helper gets its own focused test covering all seven `Scope` cases.
- No snapshot/UI tests. Pane views are straightforward SwiftUI; manual
  QA covers the spec Acceptance Criteria (§ Verification in ExecPlan).

### Error handling

- HierarchyClient writes are `throws`. Pane view catches → reducer
  dispatches `.writeFailed(reason)`. View renders a small inline
  `Label(message, systemImage: "exclamationmark.triangle.fill")`
  styled `.foregroundStyle(.orange)`, consistent with the
  `AddCustomEditorSheet` error pattern in `SettingsGeneralView`.
- Hook load failure surfaces as an in-pane error state with a `Retry`
  button that re-dispatches `.onHooksAppear`. The pane does not block
  the rest of the Settings window.
- `hooks.json` broken-file backup is already handled by
  `HookConfigStore.load()` — T4 sees `.empty` when the file is corrupt,
  same as any other consumer. No additional handling needed.

### Security / privacy

- No new secrets stored. All data already in `catalog.json` (0600 mode,
  existing `AtomicFileStore` invariant) or `hooks.json` (same).
- Directory picker for worktree base directory uses `NSOpenPanel` with
  `canChooseDirectories = true, canChooseFiles = false`. No sandboxing
  implications beyond the existing app's file-access requirements.
- Hook classification operates on locally-stored subscriptions only;
  no network I/O, no IPC.

### Observability

- `RepositorySettingsFeature` uses `Logger(subsystem:
  "com.gumpw.codans.settings", category: "repository-pane")`. Logs a line
  per write success/failure and per hook load outcome.
- No new metrics. Settings-window interactions are infrequent and
  user-initiated.

### Rollback

- No migration, no schema change. Reverting T4 restores the placeholder
  bodies; `catalog.json`'s `defaultEditor` and `worktreesDirectory`
  values written while T4 was active remain valid — they were already
  user-editable via WorktreeHeader in prior versions.
- No feature flag. T4 is UI-only under a window that already opens
  cleanly; if a regression surfaces, the pane view body can be
  reverted to `Text("TODO: supplied by T4 …")` in a single commit.

## Risks

- **R1: HookMergeView availability at Execute time.** Resolved by
  master's CONTRACT_NOTIFY — T3 Design is APPROVE and `HookMergeView`'s
  public surface (`HookRow`, `HookSource`,
  `HookMergeView.init(rows:emptyStateTitle:emptyStateMessage:showsSourceTag:trailingAction:)`,
  `TrailingAction`, `HookRowBuilder.make(from:source:)`) is frozen.
  T4 Design and Plan run on paper and do not require the T3 symbols to
  exist yet, but Execute does — and T4 deliberately creates **no
  local stub** of `HookMergeView.swift` in this worktree. Execute
  gating: after master APPROVEs T4's PLAN, T4 responds
  `PLAN_APPROVED_WAITING_FOR_T3` and holds; master pushes `EXECUTE_GREEN`
  only after T3's PR lands on `feature/settings-base`, at which point
  T4 rebases and starts Execute against the live T3 symbols. If T3
  stalls, T4 pushes `BLOCKED: waiting on T3 HookMergeView`. This
  mirrors master's instructed sequencing in the REVISE reply and
  avoids a forked API that rebase has to reconcile later.
- **R2: `findProjectAnySpace` ambiguity when two spaces share a
  ProjectID.** `ProjectID` is a random UUID, collisions have
  ~zero probability, but the manager's internal scan returns the first
  match. Mitigation: assert at the top of `findProjectAnySpace` that
  at most one space contains the ProjectID (debug-only
  `assertionFailure`). Production callers get first-match behavior,
  same as existing two-ID helpers.
- **R3: Repository pane state leaks for a Project that was removed
  and re-added.** `projectsChanged` now prunes `repositoryPanes` —
  a re-added Project gets a fresh `.idle` state. Risk of accidentally
  pruning while still mid-write: the effect is already in-flight,
  its completion dispatches to a now-absent state ID — TCA
  `.forEach` with IdentifiedAction silently drops actions whose ID is
  missing. This matches the existing behavior for `general` state
  when WorktreeHeader overrides race window lifecycle.
- **R4: Large `worktrees` lists balloon hook classification cost.**
  Classification walks `project.worktrees[*]` for glob matching.
  Worst case: 100 subscriptions × 50 worktrees × 2 string matches =
  10k regex calls on pane render. Mitigation: classification happens
  once per `.onHooksAppear`, not on every view render; results are
  cached in `state.hooksLoad = .loaded([HookRow])`. Re-classification
  only on explicit reload.
- **R5: NSOpenPanel usage from inside a TCA reducer crosses the
  actor / dependency boundary.** NSOpenPanel must run on the main
  thread and returns synchronously. Mitigation: the picker runs in
  the **view** (`.fileImporter` modifier or a `Button` that presents
  NSOpenPanel on tap), and the resulting path is dispatched into the
  reducer as `setWorktreeBaseDirectory(newPath)`. The reducer never
  touches AppKit directly — consistent with how `FinderClient`
  pushes AppKit behind a dependency wrapper.

## Open Questions

All three Design-time open questions resolved — see Decisions below.

### Decisions

- **D1 (CONTRACT_NOTIFY + REVISE round 1, 2026-04-21 — master):**
  `HookMergeView` public API frozen per T3's approved Design. T4
  consumes `HookRow`, `HookSource`, `HookMergeView`, `TrailingAction`,
  and `HookRowBuilder.make(from:source:)` verbatim from
  `apps/mac/codans/App/Features/Settings/Panes/HookMergeView.swift`.
  The T4 reducer's own types are strictly (a) a pure
  `classify(_:, for:) -> HookSource` helper and (b) a `HooksLoad`
  enum whose `.loaded` payload is `[HookRow]` — T3's public type, not
  a locally nested one. Repository Hooks pane passes
  `showsSourceTag: true` and a
  `TrailingAction(title: "Reveal hooks.json in Finder",
  systemImage: "folder", handler: …)`; no parallel reveal button
  outside `HookMergeView`. T4 creates no stub; Execute gates on T3's
  PR merging to `feature/settings-base` (see R1 for the handshake).
- **D2 (REVISE round 1 — master):** Worktree base directory picker uses
  SwiftUI `.fileImporter(isPresented:, allowedContentTypes: [.folder])`
  for v1. NSOpenPanel is not introduced pre-emptively; if manual QA
  finds that seeding the picker with the current override path is
  needed, a follow-up can switch to NSOpenPanel inside a small view
  wrapper without touching the reducer.
- **D3 (REVISE round 1 — master):** Write-failure banner is a single
  `lastWriteFailure: String?` on `RepositorySettingsFeature.State`,
  shared across editor-override and worktree-base writes in the
  General pane. Cleared on the next successful write, overwritten on
  the next failure — same pattern as
  `EditorFeature.lastProjectOverrideFailure`.
