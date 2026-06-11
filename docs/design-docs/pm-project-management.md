# Design Doc: Project Management (P1 child branch)

**Status:** Draft
**Author:** Claude (child agent on `feat/project-mgmt`)
**Date:** 2026-04-21

## Context and Scope

`docs/product-specs/project-management.md` defines the full Project lifecycle
(add existing local folder, health, rename, per-Project options, reorder,
remove). Today the sidebar has stub sheets for both Add Project and Add
Worktree (see `HierarchySidebarView.swift:60-71`) and a rename-project sheet
that already works. The data layer in `CodansCore/Project.swift` already
carries `rootPath`, `gitRoot`, `worktreesDirectory`, `defaultEditor`, and
`supportsWorktrees: Bool`; `HierarchyManager` already exposes
`addProject`/`removeProject`/`renameProject`/`setDefaultEditor`. The gap is
entirely user-facing flow plus a reconciliation loop and a health-state
field.

Parallel work on `feat/worktree-mgmt` (T-WORKTREE) owns `Worktree.swift`
(adding an `archived` field) and the Create-Worktree sheet. This doc is
scoped to stay off both surfaces.

Two external references drive the approach:

- **supacode** — `RepositoryPersistenceClient` persists only the root-path
  list and re-derives repository state on launch;
  `Features/Repositories/Views/FailedRepositoryRow.swift` is the failure-row
  UX being adopted; `RepositoriesFeature` reducer contains the
  reconcile / add / remove patterns.
- **Existing Codans code** — `GitWorktreeCLI.discoverGitRoot` +
  `listWorktrees` already exist and are reused as-is.

## Goals and Non-Goals

### Goals

- Replace the Add-Project stub with a real flow: `NSOpenPanel` → classify
  folder (git / non-git) → duplicate-path guard → name draft → commit to
  catalog → initial worktree discovery.
- Give every Project a visible health state (`ready` / `loading` /
  `failed(reason)`) with recovery actions (Retry / Remove).
- Reconcile all Projects on app launch and on window focus, pruning removed
  worktrees and adding newly-observed ones.
- Project Options sheet (from the row `⋯` menu) that edits name, default
  editor, and `worktreesDirectory` override.
- Drag-to-reorder Projects inside a Space with persisted order.
- Suppress worktree-specific UI (`+ Worktree` chrome, branch label in
  header, Git Viewer toggle) on non-git Projects (P-Q4 = a).
- Remove Project confirmation copy makes "Files on disk are not affected"
  unambiguous; the code path remains data-only.
- Never move, copy, or delete files on disk as part of any Project
  operation.

### Non-Goals

- Clone from URL (spec Out-of-Scope).
- `git init` on an empty folder (spec Out-of-Scope).
- Any change to `CodansCore/Worktree.swift` or `Space.swift` — owned by
  other parallel branches.
- Create-Worktree sheet — `worktreesDirectory` override is edited only in
  Project Options (W-Q4 = a); the Create-Worktree sheet is T-WORKTREE's.
- Recently-removed undo toast (nice-to-have, deferred).
- Drag-from-Finder onto sidebar (nice-to-have, deferred).
- Per-Project description / tooltip (nice-to-have, deferred).

## Design

### Overview

The core insight: supacode persists only a flat list of roots and rebuilds
the tree on launch; we inherit the spirit but we already persist the whole
tree in `catalog.json`. So we keep `catalog.json` authoritative for
bookkeeping (`rootPath`, `gitRoot`, `name`, `worktreesDirectory`,
`defaultEditor`, plus child `worktrees` that snapshot what was last known)
and add a **transient** `loadState` computed at runtime by a new
**ProjectReconciler**. No catalog-schema migration; pre-existing catalogs
decode unchanged because the new field never touches `Codable`.

**Boundary with T-WORKTREE (critical).** Worktree discovery and
`project.worktrees` mutation on reconcile are delegated entirely to
`HierarchyClient.reconcileDiscoveredWorktrees(projectID:inSpace:) async`,
owned by the T-WORKTREE branch. Contract recap (from T-WORKTREE's
design):

- **Append-only** — adds newly-discovered worktrees, never removes. A
  worktree path that disappeared from `git worktree list` is *not*
  deleted from the catalog on reconcile. Stale presentation is a
  render-time view decision (T-WORKTREE's UI concern), not a model
  concern.
- **Idempotent** — safe to call repeatedly, with or without actual
  changes since the last call.
- **Swallows errors** — handles its own `GitWorktreeCLI` failures and
  non-git Projects internally; does not `throw`.
- **MainActor-serialized** — scheduled through the catalog's existing
  save pipeline; callers do not need to manage concurrency.

This project-management feature therefore **does not own any
worktree-list mutation code**. Our reconciler's job is reduced to (1)
stat the root path, (2) call the closure, (3) set the load state.

Flow composition:

```
NSOpenPanel ─► AddProjectFeature (validation, name draft, add-time gitRoot)
                    │           (uses GitWorktreeCLI.discoverGitRoot)
                    ▼
            HierarchyClient.addProject (persists row; loadState=.loading)
                    │
                    ▼
            ProjectReconciler.reconcile(projectID, spaceID)
              ├─ setLoadState(.loading)
              ├─ FileManager.fileExists(atPath: rootPath)
              │     └─ missing → setLoadState(.failed(reason:))
              └─ await hierarchyClient.reconcileDiscoveredWorktrees(pid, sid)
                        │  (T-WORKTREE; append-only; swallows errors)
                        ▼
                    setLoadState(.ready)
```

**Reconcile is pulled out of `HierarchyManager`** deliberately —
HierarchyManager is the single authoritative writer for `catalog.json`
and stays free of I/O; the Reconciler is an `actor` in `Runtime/` that
coordinates single-flight scheduling of the closure calls. It does not
import `GitWorktreeCLI` itself.

**Non-git UI suppression** is enforced at the call sites that receive a
Project reference (the three places already identified in the code:
`ProjectHeaderRow` chrome, `WorktreeHeaderView` branch label, Git Viewer
toggle). The existing `Project.supportsWorktrees: Bool` predicate is the
single source of truth — no new flag.

### System Context Diagram

```
 ┌──────────────────────────────────────────────────────────────┐
 │                     Mac App (Codans)                      │
 │                                                              │
 │  ┌────────────────────┐  ┌──────────────────────┐            │
 │  │ HierarchySidebar   │  │ WorktreeHeaderView   │            │
 │  │  (TCA)             │  │  (non-git → hide GV) │            │
 │  │  + AddProject sheet│  └──────────────────────┘            │
 │  │  + ProjectOptions  │                                      │
 │  │    sheet           │                                      │
 │  │  + FailedProjectRow│                                      │
 │  └─────────┬──────────┘                                      │
 │            │ HierarchyClient (ours: +5 closures)             │
 │            │ HierarchyClient (T-WORKTREE: +reconcileDiscoveredWorktrees)
 │            ▼                                                 │
 │  ┌─────────────────────┐   ┌───────────────────┐             │
 │  │ HierarchyManager    │◄──│ ProjectReconciler │             │
 │  │  (catalog.json      │   │  (actor, Runtime/)│             │
 │  │   writer)           │   │  fileExists +     │             │
 │  └──────────┬──────────┘   │  client closure   │             │
 │             │              └────────┬──────────┘             │
 │             │                       │                        │
 │             │                       ▼                        │
 │             │      hierarchyClient.reconcileDiscoveredWorktrees
 │             │              (T-WORKTREE owns; append-only)    │
 │             │                       │                        │
 │             ▼                       │                        │
 │     ~/.config/codans/           │                        │
 │        catalog.json                 ▼                        │
 │                            ┌────────────────┐                │
 │                            │ GitWorktreeCLI │──► /usr/bin/git│
 │                            │ (T-WORKTREE)   │                │
 │                            └────────────────┘                │
 │                                     ▲                        │
 │     AddProjectFeature ──────────────┘ (add-time gitRoot only)│
 │     (uses discoverGitRoot directly)                          │
 │                                                              │
 │     NSApp.didBecomeActive  ──► ProjectReconciler.reconcileAll│
 │     App launch (Root init) ──► ProjectReconciler.reconcileAll│
 └──────────────────────────────────────────────────────────────┘

 NSOpenPanel (FolderPickerClient) ──► AddProjectFeature
```

### API Design

#### Project data-model extension

`CodansCore/Project.swift` grows a transient load-state field. Not
`Codable`; not sent over the engine persistence pipeline. `HierarchyManager`
owns all writes.

```swift
public enum ProjectLoadState: Equatable, Sendable {
  case loading
  case ready
  case failed(reason: String)
}

public struct Project {
  // ...existing fields unchanged...
  public var loadState: ProjectLoadState = .loading   // transient
}
```

Codable is made explicit (mirroring `Worktree.swift`'s pattern): encode /
decode omits `loadState`; decoded Projects always start `.loading` and are
transitioned to `.ready` / `.failed` by the first reconcile pass.

#### HierarchyManager — new mutations (appended; no edits to existing)

```swift
func setProjectLoadState(_ state: ProjectLoadState,
                         projectID: ProjectID,
                         spaceID: SpaceID)
// Transient. NO scheduleSave. Equality-deduped.

func reorderProjects(in spaceID: SpaceID,
                     from source: IndexSet,
                     to destination: Int) throws
// Mirrors SwiftUI ForEach.onMove(from:to:) signature. Persists.

func setProjectWorktreesDirectory(_ path: String?,
                                  projectID: ProjectID,
                                  spaceID: SpaceID) throws
// nil clears override → falls back to ~/.codans/repos/<name>/.
// Persists.

func isPathRegistered(canonical path: String) -> (SpaceID, ProjectID)?
// Walks catalog. Uses canonical form; O(projects).
```

No `replaceWorktrees`. Worktree-list mutation on reconcile is
T-WORKTREE's responsibility, exposed through `HierarchyClient`.

#### HierarchyClient — boundary of ownership

This project-management feature **adds** four closures (all appended to
file end to avoid merge friction with T-WORKTREE):

```swift
var setProjectLoadState: @MainActor @Sendable (
  _ projectID: ProjectID, _ inSpace: SpaceID, _ state: ProjectLoadState
) -> Void

var reorderProjects: @MainActor @Sendable (
  _ inSpace: SpaceID, _ from: IndexSet, _ to: Int
) throws -> Void

var setProjectWorktreesDirectory: @MainActor @Sendable (
  _ projectID: ProjectID, _ inSpace: SpaceID, _ path: String?
) throws -> Void

var isPathRegistered: @MainActor @Sendable (_ canonicalPath: String) ->
  (SpaceID, ProjectID)?
```

And **consumes** one closure owned by T-WORKTREE:

```swift
// Declared and implemented by T-WORKTREE. This feature calls it from
// ProjectReconciler.reconcile. Contract: append-only, idempotent,
// swallows errors, main-actor serialized.
var reconcileDiscoveredWorktrees: @MainActor @Sendable (
  _ projectID: ProjectID, _ inSpace: SpaceID
) async -> Void
```

Until T-WORKTREE's PR lands on `feature/hierarchy-management`, this
feature ships with a **no-op stub** of `reconcileDiscoveredWorktrees` in
`HierarchyClient.liveValue` so the reconciler compiles and the rest of
the feature (Add, Options, health-state-on-missing-folder, reorder,
failed-row, non-git suppression) is demonstrable end-to-end. On rebase
after T-WORKTREE merges, that stub disappears and the real closure takes
its place — call-site changes are zero. Rebase conflict risk is limited
to `HierarchyClient.swift`'s structural members; both branches only
append to file end, so the git merge is mechanical.

#### ProjectReconciler — new actor in `Runtime/`

```swift
actor ProjectReconciler {
  init(hierarchyClient: HierarchyClient,
       clock: any Clock<Duration>)

  func reconcile(projectID: ProjectID, spaceID: SpaceID) async
  func reconcileAll() async          // iterates current snapshot
}
```

Behavior:

1. `setLoadState(.loading)` unless already loading.
2. `FileManager.default.fileExists(atPath: rootPath)`.
   - Missing → `.failed(reason: "Folder no longer exists at <path>")`
     and return.
3. `await hierarchyClient.reconcileDiscoveredWorktrees(projectID,
   spaceID)`. The closure (T-WORKTREE) is responsible for git-vs-non-git
   routing, `GitWorktreeCLI` orchestration, error recovery, and the
   append-only mutation. This feature does not import `GitWorktreeCLI`
   at the reconciler site.
4. `setLoadState(.ready)`.

Note: the Project level has only one failure mode — **root path
missing**. All other error surfaces (git broken, listWorktrees failed,
intermittent filesystem issue) are absorbed inside
`reconcileDiscoveredWorktrees` per its contract. The load state stays
`.ready` in those cases; any staleness is surfaced per-Worktree at the
render layer (T-WORKTREE's concern), not as a Project-level failure.

Single-flight: `inFlight: Set<ProjectID>` guards overlapping reconciles.
Debounce at the caller (`reconcileAll`) only — per-project reconciles
triggered by Retry / Add are eager.

#### AddProjectFeature (new, replaces stub)

Replaces `AddProjectSheet` payload usage on lines 66–71. Own reducer
under `App/Features/HierarchySidebar/AddProjectFeature.swift`.

State:

```
isPresented: Bool
targetSpaceID: SpaceID
pickedPath: String?                  // canonical
pickedIsGit: Bool?                   // nil = not yet validated
duplicate: (SpaceID, ProjectID)?     // set → show "Reveal existing"
nameDraft: String                    // default = last path component
validationError: String?             // inline; non-fatal
isSubmitting: Bool
```

Actions:

| Action                               | Effect |
| ------------------------------------ | ------ |
| `.openPickerTapped`                  | Call `FolderPickerClient.pick()` → `.folderPicked`. |
| `.folderPicked(URL?)`                | Nil → dismiss. Non-nil → canonicalize, set `pickedPath`, call `hierarchyClient.isPathRegistered(canonical:)`, set `duplicate`. |
| `.validationStarted`                 | Run `gitCLI.discoverGitRoot(candidatePath:)`. |
| `.validationResolved(gitRoot:)`      | Set `pickedIsGit`, seed `nameDraft`. |
| `.nameDraftChanged(String)`          | Trim-blank validation. |
| `.revealExistingTapped`              | Delegate up to `RootFeature`: select the duplicate. |
| `.submitTapped`                      | Call `addProject`, kick `ProjectReconciler.reconcile`, dismiss. |
| `.cancelTapped`                      | Dismiss. |

#### ProjectOptionsFeature (new)

State is simple — one sheet at a time, reducer holds a `Target` payload.

```
targetProject: (SpaceID, ProjectID)?
nameDraft: String
defaultEditorDraft: EditorID?
worktreesDirectoryDraft: String      // "" means "use default"
isSaving: Bool
```

Actions: field edits (`.nameChanged`, `.editorChanged`,
`.worktreesDirectoryChanged`), `.saveTapped`, `.cancelTapped`. The save
is a fan-out of `renameProject` + `setDefaultEditor` +
`setProjectWorktreesDirectory`.

Opened from `ProjectHeaderRow`'s `⋯` menu; replaces the current
standalone `renameProjectSheet` for consistency (rename stays a valid
action but now lives inside the options sheet; the separate rename menu
item is retained as a shortcut that still opens this sheet focused on
name). Keeps the tap target familiar.

#### FolderPickerClient (new tiny client)

```swift
struct FolderPickerClient: Sendable {
  var pick: @MainActor @Sendable (_ prompt: String) async -> URL?
}
```

Live value wraps `NSOpenPanel` (directories only, single-select, no
`canChooseFiles`). Test value returns a scripted URL sequence. A separate
client keeps `AddProjectFeature` testable without importing AppKit.

`FinderClient` is *not* reused: it is reveal-only and returns `Void`; the
picker needs a return URL and a different dialog shape.

#### Reconcile triggers (`RootFeature`)

- On root init (post-manager-wire): `await reconciler.reconcileAll()`
  fire-and-forget from a `.task`.
- On `NSApplication.didBecomeActiveNotification`: 2-second debounce via
  the existing `@Dependency(\.continuousClock)` pattern.

### Data Storage

`catalog.json` v1 already carries every persisted Project field this spec
needs. The new `Project.loadState` is **transient** and handled through
hand-rolled `Codable`:

- Decoding never reads the key → decoded Projects start `.loading`.
- Encoding never writes the key → pre-existing catalogs round-trip
  byte-identical for unchanged content.
- No `currentVersion` bump; no migration code.

`worktreesDirectory` and `defaultEditor` are already encoded via
`encodeIfPresent`; the new options sheet just surfaces edits for them.

Canonical path form, used for dedup and isPathRegistered:
`URL(fileURLWithPath: raw).resolvingSymlinksInPath().standardizedFileURL.path`.
This is the form stored as `Project.rootPath` (so identity is preserved
after reboots and symlink rearrangements). The raw user-chosen path is
not preserved separately — we accept the minor UX cost of showing the
resolved path in exchange for a simpler identity story.

### Component Boundaries

| Component | Responsible for | NOT responsible for |
| --- | --- | --- |
| `Project.loadState` (Core) | Transient Project-level health signal | Per-Worktree staleness; persistence |
| `HierarchyManager` | Catalog writes for add / rename / remove / reorder / options | Worktree-list mutation on reconcile (T-WORKTREE) |
| `ProjectReconciler` (Runtime) | Stat rootPath, call T-WORKTREE's closure, set load state, single-flight | `git worktree list`; worktree merging; per-Worktree state |
| `AddProjectFeature` (TCA) | Add-flow state + add-time gitRoot classification via `GitWorktreeCLI.discoverGitRoot` | Worktree enumeration (done by reconciler closure after persist) |
| `FolderPickerClient` | `NSOpenPanel` bridge | Validation |
| `ProjectOptionsFeature` (TCA) | Options sheet state | Persistence — delegates to client |
| `HierarchySidebarView` | Rendering rows, failure rows, reorder | Flow logic; per-Worktree stale display (T-WORKTREE) |
| `WorktreeHeaderView` | Branch label + chrome when supported | Deciding when to show |

Dependency direction: `App/Features` → `App/Clients` → `Runtime` →
`CodansCore`. Views and reducers never import `GitWorktreeCLI`
directly. The ProjectReconciler reaches `HierarchyManager` exclusively
through `HierarchyClient` closures. `GitWorktreeCLI` is used only at
add-time inside `AddProjectFeature` to classify a picked folder as git
or non-git; all reconcile-time git interaction flows through T-WORKTREE's
`reconcileDiscoveredWorktrees` closure.

## Alternatives Considered

### A. `Project.loadState` as persisted `Codable` field

**Rejected.** Requires either (1) bumping `Catalog.currentVersion` and
writing migration, or (2) `decodeIfPresent ?? .loading` + accepting that
`.failed` re-persists on every launch (surprising). Transient is simpler
and matches supacode's "compute on launch" philosophy. The field is
purely a UI concern — persisting a runtime diagnostic across launches
buys nothing.

### B. Separate `[ProjectID: ProjectLoadState]` map in
`HierarchyRuntime` (not on `Project`)

**Rejected.** Correctness-wise it's equivalent, but every consumer
(views, reducers, tests) would need two reads: one for the Project and
one for its state. Co-locating the state on `Project` (transient field)
means a single `Project` value fully describes what the UI renders. The
cost (`Project` is no longer plain-data Codable — we go hand-rolled) is a
one-file change, already the pattern `Worktree.swift` uses for
`gitViewerVisible`.

### C. ProjectReconciler lives inside `HierarchyManager`

**Rejected.** Manager is `@MainActor` + single-writer-of-catalog; adding
subprocess I/O pulls concurrency concerns into the hottest mutation
class. An `actor` alongside `HierarchyRuntime` keeps I/O isolated, and
matches the shape other I/O concerns already take.

### D. ProjectReconciler as a TCA `Feature` / reducer

**Rejected.** Reconciliation has no view state; it's a pure
timer + subprocess choreography. A plain `actor` is a better tool —
TCA's `TestStore` would force synthetic actions for what is naturally a
stream of async effects. The triggers (launch, focus) live in
`RootFeature` and fire-and-forget into the actor.

### E. Reuse `FinderClient` for folder picking

**Rejected.** `FinderClient` today is reveal-only with a `Void` return.
Extending it to also present `NSOpenPanel` mixes two unrelated
affordances and forces the test surface to grow. A 4-line new client is
cleaner.

### F. Own the worktree-merge inside this feature

**Rejected (and reversed after master REVISE 2026-04-21).** An earlier
draft of this design had this feature implementing `replaceWorktrees`
with merge-by-canonical-path and auto-deletion of worktrees missing from
git output. Master corrected the boundary: spec's reconcile semantics
are append-only with render-time staleness, owned by T-WORKTREE.
Implementing the merge here would duplicate the contract, fight
T-WORKTREE's model, and silently auto-delete rows the user expected to
handle via explicit Prune. We delegate to
`hierarchyClient.reconcileDiscoveredWorktrees` instead; staleness UI
lives in views at render time, not in our model.

### G. Reorder via drag-and-drop APIs instead of `ForEach.onMove`

**Rejected** for v1. `List { ForEach { … }.onMove(perform:) }` inside
`.listStyle(.sidebar)` is the idiomatic macOS option and works out of
the box. Custom DnD is available later if we grow cross-Space moves
(explicit Out-of-Scope in v1).

### H. Declare `reconcileDiscoveredWorktrees` on this branch

**Rejected.** The closure is T-WORKTREE's owned surface per the parallel
branch agreement — declaring it here would fork the contract. Instead we
**consume** it, shipping a no-op stub in `HierarchyClient.liveValue` on
this branch until T-WORKTREE merges. Post-rebase the stub is replaced by
the real binding; no call-site changes. This keeps the feature shippable
end-to-end in isolation while respecting ownership.

## Cross-Cutting Concerns

### Non-git UI suppression (P-Q4 = a)

Three consumer sites already threaded in the code:

1. **`ProjectHeaderRow`** (`HierarchySidebarView.swift:498-505`) —
   conditionally render the `+` button: `if project.supportsWorktrees`.
2. **`WorktreeHeaderView.swift:20`** — caller
   (`WorktreeDetailView.swift`) already hands the branch label and
   `gitViewerVisible` in. Add a `supportsWorktrees: Bool` parameter and
   guard both the `Label(branchLabel, …)` and
   `HeaderGitViewerToggle(…)` renders.
3. **`HeaderGitViewerToggle`** — gated by (2); no change inside the
   component.

Single predicate: `project.supportsWorktrees`. No new flag, no cascade
bugs.

### Error handling

The reconciler only owns one failure case: the root path no longer
exists.

- `fileExists == false` → `.failed("Folder no longer exists at …")`.

`reconcileDiscoveredWorktrees` swallows its own errors per contract; it
does not surface git failures to the Project level. Per-Worktree
staleness (e.g. an on-disk worktree that was removed outside codans)
is T-WORKTREE's render-time concern.

The Add Project path has its own localized error surfaces independent
of reconcile: `FolderPickerClient` returning `nil` (user cancelled) and
`isPathRegistered` returning non-nil (duplicate) are inline banner
states on `AddProjectFeature`, not `.failed` Project rows.

All reasons are human strings. We **don't** introduce a structured
`enum FailureReason` yet — UI just renders the string + offers "Retry"
and "Remove".

### Testing strategy

- **HierarchyManagerTests** (unit): `reorderProjects`,
  `setProjectWorktreesDirectory` (empty-string clears),
  `setProjectLoadState` dedup + no-save, `isPathRegistered`
  canonicalization. **No `replaceWorktrees` — this mutation does not
  exist in our scope.**
- **ProjectReconcilerTests** (actor-level, stubbed client): recorder
  asserts the exact call sequence — `setProjectLoadState(.loading)` →
  one of { `setProjectLoadState(.failed)` on missing folder |
  `reconcileDiscoveredWorktrees` + `setProjectLoadState(.ready)` on
  existing folder }. Single-flight dedup test. We **do not** depend on
  a real `git init` fixture here — the closure is a recorder — so the
  test surface is entirely this-branch-local and unchanged after
  T-WORKTREE rebase.
- **AddProjectFeatureTests** (TestStore): happy path → `.submitTapped`,
  duplicate-path branch, non-git branch (scanner returns nil gitRoot),
  cancel path, name-validation edge cases. Scanner is the real
  `GitWorktreeCLI` against a temp-dir `git init` fixture for the
  add-time classification test; a recorder for others.
- **ProjectOptionsFeatureTests** (TestStore): save fans out three
  client calls in order; cancel keeps drafts local.
- **ProjectCodableTests** (round-trip): decode a pre-existing
  `catalog.json` sample without `loadState`, encode back, assert JSON
  dictionaries byte-equal (key-order-insensitive).
- **Manual**: NSOpenPanel flow, failure-row UX on missing folder,
  reorder drag, options sheet, remove-confirmation copy, non-git
  Project running through the three UI suppression sites.

### Observability

Reconciler logs via `os.Logger(subsystem: "codans",
category: "ProjectReconciler")` at `.debug` for start/finish,
`.info` for state transitions, `.error` for failure reasons. No new
telemetry surface; it's a local app.

### Migration

None. `catalog.json` v1 unchanged. Pre-existing catalogs decode; new
Projects start `.loading` and reconcile normally on first launch.

## Risks

### R1 — Reconcile thrash under rapid focus toggles

Focus-change notifications fire on every window-activation click; naive
hook triggers `reconcileDiscoveredWorktrees` per click across every
Project. **Mitigation:** 2-second debounce at the `reconcileAll`
trigger, single-flight per Project inside the actor. Per-project Retry
remains immediate. T-WORKTREE's closure is idempotent by contract so a
missed debounce edge just means one redundant call, not a broken state.

### R2 — Path canonicalization drift (case, symlinks, trailing slash)

macOS APFS is case-insensitive by default but case-preserving; a user
might pick `/Users/me/Repo` after we stored `/Users/me/repo`. **Mitigation:**
`URL.resolvingSymlinksInPath().standardizedFileURL.path` on every boundary
(add, reconcile, lookup). Comparisons and storage always use the canonical
string; the Project displays whatever is in `rootPath` (the canonical
form), so identity is stable.

### R3 — NSOpenPanel + sandboxed builds

Project is non-sandboxed today. If we ever sandbox, `NSOpenPanel` returns
a security-scoped URL and plain-path persistence breaks.
**Mitigation:** keep path-only persistence for now; add a TODO
(`FolderPickerClient`) to wrap
`startAccessingSecurityScopedResource()` + persist a bookmark if
sandboxing lands. Not blocking v1.

### R4 — Slow `reconcileDiscoveredWorktrees` on large repos

The closure (T-WORKTREE) internally runs `git worktree list` which can
take seconds on pathological repos. While the `await` is outstanding,
our reconciler has the Project in `.loading`. **Mitigation:** inline row
spinner (`.loading`) driven by our Project-level state; never block the
window (P-Q3 = inline spinner). Our actor parallelizes across Projects
via `withTaskGroup`. Extra-long runs are T-WORKTREE's tuning concern; we
do not add a timeout on our side because that would race with their
append-only contract.

### R5 — User renames folder on disk between launches

Silent failure would look like "my project vanished." **Mitigation:**
`.failed("Folder no longer exists at <old path>")` + Remove action; we
do not attempt auto-recovery (the spec is explicit: no disk moves).

### R6 — T-WORKTREE merge lag leaves reconciler effectively inert

Until T-WORKTREE's PR lands, `reconcileDiscoveredWorktrees` is a no-op
stub on our branch, so the reconciler does not actually add
newly-discovered worktrees. **Mitigation:** the feature is still fully
demonstrable for Add / Options / failed-path / reorder / non-git
suppression / Remove; worktree discovery is the only gap. Manual test
plan flags which bullets require T-WORKTREE-post-merge to verify. On
rebase, the stub is replaced and `ProjectReconcilerTests` (which use a
recorder closure) pass without modification.

### R7 — T-WORKTREE contract churn

If T-WORKTREE changes the shape of `reconcileDiscoveredWorktrees`
between now and merge (e.g. adds a `force: Bool` parameter, or switches
from `async -> Void` to `async throws`), our reconciler must follow.
**Mitigation:** the reconciler's single call site for this closure is
small (one line inside `reconcile(projectID:spaceID:)`); any shape
change is a one-line diff on rebase. Our stub in `HierarchyClient.swift`
trivially adapts. We monitor T-WORKTREE's branch for contract updates
during the overlap window; master flags divergence.
