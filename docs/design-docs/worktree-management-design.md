# Design Doc: Worktree Management (T-WORKTREE)

**Status:** Draft
**Author:** Gump (T-WORKTREE child agent)
**Date:** 2026-04-21
**Spec:** [worktree-management.md](../product-specs/worktree-management.md)
**Parent branch:** `feature/hierarchy-management` · **Working branch:** `feat/worktree-mgmt`

## Context and Scope

codans already has a sidebar tree (Space → Project → Worktree), a data-only
`HierarchyManager.createWorktree` / `removeWorktree`, a minimal `GitWorktreeCLI`
(direct `git worktree` shell-out with porcelain parsing), and a stub
"Add Worktree" sheet wired at `HierarchySidebarView.swift:78-83`. Remove goes
through a confirmation dialog but does not touch git.

The product spec extends this into a full lifecycle: creation with base-ref
and streaming file-copy, discovery of CLI-created worktrees, archive/unarchive
soft-hide, safe/force remove, prune, and terminal-safety checks. The
implementation mirrors supacode's established patterns (it runs the same
open-source `git-wt` helper, the same `createWorktreeStream` shape, the same
archived-worktree UX) so we inherit UX polish and operational corners they've
already debugged. The bundled helper becomes a git submodule at
`apps/mac/ThirdParty/git-wt/` and is resource-bundled into the app via Tuist.

## Goals and Non-Goals

### Goals

- Create a Worktree through a sheet with live branch-name validation, a
  base-ref dropdown defaulting to the project's default remote branch,
  optional fetch-origin, and optional copy-ignored / copy-untracked with
  streaming progress.
- Keep the catalog and on-disk git worktrees reconciled: worktrees created on
  the CLI appear automatically; directories deleted outside the app are
  marked stale and offered for prune.
- Archive a Worktree as a soft-hide (metadata-only) that closes its
  tabs/panels but leaves files and git refs untouched; unarchive restores it
  in place.
- Safe-remove with an actionable error (names the uncommitted files, offers
  force-upgrade); force-remove with a distinct confirmation; terminate
  attached terminal processes before the directory is deleted (W-Q3).
- Prune from the Project `⋯` menu with a summary toast.
- Bundle `git-wt` reproducibly — submodule + Tuist wiring so
  `Bundle.main.url(forResource: "wt", subdirectory: "git-wt")` resolves in
  both debug and release builds.

### Non-Goals

- Commit / rebase / merge / push UI inside the app (terminal-first, per spec
  §Out of Scope).
- Worktree from a detached commit without a branch.
- Multi-worktree bulk operations.
- Archive script / hook (v1 is metadata-only; C3 hook is a future item —
  W-Q6).
- In-place worktree path relocation after creation.
- Changing the `Project.worktreesDirectory` default — that field is edited by
  T-PROJECT's Project-options sheet (W-Q4); we only consume it.

## Design

### Overview

We introduce **`GitWorktreeClient`** — a `Sendable` struct of async closures
(the TCA dependency shape already used for `HierarchyClient` /
`GitServiceClient`) that wraps the bundled `git-wt` script and a few
complementary `git` invocations. It is the only surface that spawns git
processes for worktree operations; the existing `GitWorktreeCLI` actor is
kept for its internal callers but is no longer the primary path for the UI
and is only used to back the discovery fallback (see **Alternatives**).

The sidebar gains two new features (both TCA reducers + SwiftUI sheets):
**`CreateWorktreeFeature`** (replaces the stub at
`HierarchySidebarView.swift:78-83`) and **`ArchivedWorktreesFeature`**
(opened from the Project `⋯` menu). Both are presented by the existing
`HierarchySidebarFeature` so the sidebar stays the single owner of
sidebar-scoped sheet state — symmetric with how the rename-project and
remove-confirmation sheets are hosted today.

`HierarchyManager` gains three small new mutations —
`setWorktreeArchived`, `reconcileDiscoveredWorktrees`, and a
`createWorktree`-signature extension that takes an optional `branch` +
keeps the existing append-to-catalog semantics but no longer synthesizes
paths. The manager stays pure state; the *git work* (shell-out, streaming,
prune) is done by `GitWorktreeClient` inside the feature's `Effect` and only
then is the catalog mutated.

Discovery and reconcile are exposed to **T-PROJECT** through a single
`HierarchyClient` closure, `reconcileDiscoveredWorktrees(projectID:, spaceID:)`.
T-PROJECT schedules *when* to call it (on Project add, on window-focus
reconcile); we own *what* it does.

The on-disk `archived` bit is stored in-place on `Worktree` (W-Q1). Codable
`decodeIfPresent ?? false` preserves read compatibility with existing
catalogs, and `encodeIfPresent`-style omission when `false` keeps on-disk
catalogs round-trip-identical for unarchived worktrees — the same pattern
the codebase already applies for `gitViewerVisible`.

The central trade-off: **do we add a new `GitWorktreeClient` or grow the
existing `GitWorktreeCLI`?** We add the new client. The existing actor is a
raw `/usr/bin/git` shell with porcelain parsing; the spec requires the
bundled `git-wt` script (for JSON listing, base-dir handling, streaming
copies), which is a different binary with different invocation semantics.
Co-locating both in one actor would muddle the "what tool are we using"
contract and force the spec-critical streaming/create path through an actor
that currently has no streaming primitives. A second client at the same
layer keeps each surface focused. The old actor becomes the fallback for
discovery when the bundled `wt` script cannot be located (dev builds
without the submodule checked out — `verify-git-wt.sh` will surface this at
build time, not runtime).

### System Context Diagram

```
         ┌───────────────────────────────┐
         │    HierarchySidebarView       │
         │  (Create / Archived sheets,   │
         │   context menus, toasts)      │
         └──────────────┬────────────────┘
                        │ TCA actions
                        ▼
        ┌──────────────────────────────┐
        │  HierarchySidebarFeature +   │
        │  Create/Archived sub-features│
        └────┬────────────────────┬────┘
             │                    │
             │ hierarchyClient    │ gitWorktreeClient
             ▼                    ▼
  ┌──────────────────┐   ┌──────────────────────┐
  │ HierarchyManager │   │  GitWorktreeClient   │
  │ (catalog state)  │   │  (async closures)    │
  └────────┬─────────┘   └──────────┬───────────┘
           │                         │ spawns
           │ schedules               ▼
           │ save                 ┌──────────────┐
           ▼                      │  wt script   │
   ┌──────────────┐               │  /usr/bin/git│
   │ CatalogStore │               └──────┬───────┘
   │ (catalog.json│                      │
   └──────────────┘                      ▼
                                  ┌──────────────┐
                                  │ on-disk git  │
                                  │  worktrees   │
                                  └──────────────┘
```

### API Design

#### `GitWorktreeClient`

Async closures, `Sendable`. All IO runs off the main actor; callers await.
Errors surface as `GitWorktreeError` so features map them to user-facing
banners / alerts. Path arguments are `URL` to force call-sites to decide
whether they're file URLs.

```
struct GitWorktreeClient: Sendable {
  // Listing / discovery
  var lsWorktrees: (_ repoRoot: URL) async throws -> [GitWtEntry]

  // Branch / ref queries
  var localBranchNames:       (_ repoRoot: URL) async throws -> Set<String>
  var branchRefs:             (_ repoRoot: URL) async throws -> [String]
  var defaultRemoteBranchRef: (_ repoRoot: URL) async throws -> String?
  var isValidBranchName:      (_ repoRoot: URL, _ name: String) async -> Bool

  // Create (streaming)
  var createWorktreeStream: (_ spec: CreateSpec)
    -> AsyncThrowingStream<CreateEvent, Error>

  // Remove / prune
  var removeWorktree: (_ repoRoot: URL, _ path: URL, _ force: Bool)
    async throws -> Void
  var pruneWorktrees: (_ repoRoot: URL) async throws -> Int

  // Fetch
  var fetchRemote: (_ repoRoot: URL, _ remote: String) async throws -> Void

  // Uncommitted-change diagnostics (for safe-remove error surface)
  var changedFiles: (_ worktreeRoot: URL) async throws -> [String]
}

struct CreateSpec: Sendable {
  var repoRoot: URL
  var baseDirectory: URL
  var name: String            // pre-sanitized branch → directory name
  var branch: String          // full branch name (may contain `/`)
  var baseRef: String         // e.g. "origin/main"
  var fetchOrigin: Bool
  var copyIgnored: Bool
  var copyUntracked: Bool
}

enum CreateEvent: Sendable {
  case progressLine(String)           // stream line, rendered verbatim in sheet
  case finished(worktreePath: URL)
}

enum GitWorktreeError: Error, Equatable, Sendable {
  case executableMissing                     // wt script not bundled
  case branchExists(String)
  case invalidBranchName(String)
  case refNotFound(String)
  case fetchFailed(String)
  case uncommittedChanges(files: [String])   // surfaces to safe-remove UI
  case worktreeLocked(String)
  case commandFailed(command: String, stderr: String)
}
```

Key shape decisions:

- **Closures, not a protocol.** Matches `HierarchyClient`,
  `GitServiceClient`, `EditorClient` — all the app's other cross-feature
  seams use the closures-as-struct pattern. A protocol here would break
  symmetry and force a separate `testValue` class hierarchy.
- **Stream for create, async throws for everything else.** Only create has
  progress worth rendering (the copy-ignored path can run >30s on big
  trees). Everything else is bounded and short; a one-shot `async throws`
  avoids boilerplate.
- **Typed errors for the UI-visible cases, opaque `commandFailed`
  otherwise.** Safe-remove needs `uncommittedChanges(files:)` to format the
  inline "3 uncommitted files in <path>" message and upgrade to force. The
  rest of the exit paths round-trip the git command + stderr so the banner
  can surface the real message without us attempting to parse every failure
  mode.

#### New `HierarchyClient` closures (appended to end of file)

Per the hard constraint ("append new closures at file end"):

```
// Worktree — archive / remove / reconcile additions
var setWorktreeArchived: @MainActor @Sendable (
  _ worktreeID: WorktreeID, _ archived: Bool
) -> Void

var reconcileDiscoveredWorktrees: @MainActor @Sendable (
  _ projectID: ProjectID, _ inSpace: SpaceID
) async -> Void

// Create/remove now take richer options. Existing create/remove closures
// are kept for back-compat but become thin wrappers that default to the
// legacy semantics. Adding new richly-parameterized siblings avoids a
// breaking signature change for existing call sites (T-PROJECT tests).
var createWorktreeWithGit: @MainActor @Sendable (
  _ projectID: ProjectID, _ inSpace: SpaceID,
  _ branch: String, _ directoryName: String, _ path: String
) throws -> WorktreeID

var removeWorktreeWithGit: @MainActor @Sendable (
  _ worktreeID: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID,
  _ force: Bool
) async throws -> Void

// Running-terminal probe for W-Q3 confirmation copy.
var runningPanelCount: @MainActor @Sendable (_ worktreeID: WorktreeID) -> Int
```

Rationale — why *these* closures, not one god-closure that takes a
`CreateSpec`: the HierarchyClient's contract is "sync, main-actor catalog
mutation with deterministic error classes." Pushing git work behind it would
force the whole surface async and bind every call-site's error handling to
`GitWorktreeError`. Instead, features orchestrate: run `gitWorktreeClient`
async to do the git work → on success, call `hierarchyClient` to update the
catalog. `createWorktreeWithGit` is the catalog-append step only; it is
synchronous and knows nothing about base refs or copy flags.

#### `CreateWorktreeFeature` (reducer)

State tracks the live branch-name validation result, the base-ref dropdown
state, and the streaming progress buffer. The reducer sequences:

1. On presentation, fetch `localBranchNames` and `branchRefs` +
   `defaultRemoteBranchRef` (all in parallel), populate the dropdown,
   default `baseRef` to `defaultRemoteBranchRef` (W-Q2).
2. As the user types, debounce ~150 ms then run
   `isValidBranchName` + check `localBranchNames.contains(lowercased)`;
   surface inline errors.
3. On Create, run optional fetch, then consume the stream, render each
   `.progressLine` in the sheet's log area, and on `.finished(path)` call
   `hierarchyClient.createWorktreeWithGit` to append the catalog row,
   `selectWorktree`, open a Tab, then dismiss the sheet.
4. Any thrown error leaves the sheet open with the error banner and
   re-enables Create.

Mirrors supacode's `WorktreeCreationPromptFeature` one-to-one for the form
logic; the streaming-output buffer is new (supacode displays it too but from
a different view hierarchy).

#### `ArchivedWorktreesFeature` (reducer)

Presents a list grouped by nothing (single-project scope — opened per
Project) of that Project's archived worktrees with Unarchive / Remove
buttons per row. On first-ever archive in a session, shows a confirmation
alert explaining the soft-hide semantics; a session-scoped flag suppresses
it thereafter (spec "Archive confirmation"). Rehydrate state each time the
sheet opens — no standing subscription; the catalog is read live from
`HierarchyManager.catalog` through the environment, matching the sidebar's
pattern.

### Data Storage

`Worktree` gains one field:

```
public var archived: Bool
```

Codable:

- `init(from:)`: `try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false`.
- `encode(to:)`: emit only when `true` (`if archived { try container.encode(true, forKey: .archived) }`).

This pattern is already established in `Worktree.gitViewerVisible`
(file `CodansCore/Worktree.swift:60-66`) — existing catalogs round-trip
identically until a user archives their first worktree. A unit test in
`CodansCoreTests` asserts a pre-0007 fixture decodes with `archived ==
false`, encodes back with no `archived` key, and a fixture with
`"archived": true` round-trips.

No separate `archivedWorktrees` array per Project. A separate array would
duplicate `Worktree` as a whole (we need branch, path, createdAt, id to
render archived rows) and fork the uniqueness / selection invariants. The
in-place flag is smaller, removes one cross-collection sync, and matches
the T0 convention of "state lives where the object lives."

No schema-version bump. `CatalogStore`'s save pipeline is tolerant of
field additions; the add-only migration plus the two test fixtures above
are the whole migration story.

### Component Boundaries

```
CodansCore/
  Worktree.swift             ← add `archived`; owner: T-WORKTREE

codans/Git/
  GitWorktreeClient.swift    ← NEW; app-layer, depends on Bundle + Process
  GitWorktreeCLI.swift       ← unchanged; fallback for non-bundled builds

codans/Runtime/
  HierarchyManager.swift     ← add setWorktreeArchived,
                               reconcileDiscoveredWorktrees,
                               runningPanelCount helper
                               (all MainActor, no git I/O)

codans/App/Clients/
  HierarchyClient.swift      ← APPEND new closures (at file end, per scope
                               contract); keep existing closures intact

codans/App/Features/HierarchySidebar/
  HierarchySidebarView.swift ← REPLACE lines 78-83 stub with
                               CreateWorktreeSheet presentation; append
                               ArchivedWorktrees sheet + Prune toast;
                               augment Worktree context menu with Archive
                               + main-checkout guard
  HierarchySidebarFeature.swift ← compose sub-features (Create, Archived,
                                  Prune, ArchiveConfirm)
  CreateWorktreeFeature.swift  ← NEW reducer + state
  CreateWorktreeSheet.swift    ← NEW view
  ArchivedWorktreesFeature.swift ← NEW reducer + state
  ArchivedWorktreesSheet.swift   ← NEW view

apps/mac/ThirdParty/git-wt/  ← NEW submodule
apps/mac/.gitmodules         ← NEW entry (at repo root; see below)
apps/mac/scripts/verify-git-wt.sh  ← NEW pre-build verification
apps/mac/scripts/embed-git-wt.sh   ← NEW post-build copy into .app/Resources/git-wt/

Project.swift (Tuist)        ← add pre-script (verify), post-script
                               (embed-git-wt), add inputPaths/outputPaths
```

Dependency direction: features → clients → managers/shell. No feature
touches `GitWorktreeClient` and `HierarchyClient` in the same action
closure without the sidebar feature composing them; no client calls another
client. `GitWorktreeClient` is purely nonisolated async; it never touches
`@Observable` state.

### Discovery / Reconcile — contract with T-PROJECT

T-PROJECT owns the scheduler (*when* to reconcile); we own the callee.

- **Signature:** `reconcileDiscoveredWorktrees(projectID:inSpace:) async`
- **Contract:**
  1. Read the Project's `gitRoot`. Skip if nil (non-git Project).
  2. Call `gitWorktreeClient.lsWorktrees(gitRoot)`.
  3. For each on-disk entry not already in the Project's `worktrees` list
     (match by canonicalized absolute path), append a new `Worktree` with
     `archived = false`, derive `name` from the branch (or the directory's
     last component for detached HEAD), set `branch` from the entry,
     schedule save.
  4. For each catalog entry whose path no longer exists on disk **and**
     is not in the `git worktree list` output, mark stale (we expose a
     `stale: Bool` computed flag in the view layer rather than a stored
     field — stale state is derived per render from the live git state).
  5. Discovery never deletes catalog rows; prune (user-initiated) is the
     only deletion path, preserving "never leave catalog and disk out of
     sync silently."
- **Idempotency:** repeated calls return the same result. Race with a
  parallel `createWorktreeWithGit`: the call is serialized through the
  main actor so appends and reconciles do not interleave mid-mutation.
- **No throwing:** swallow `GitWorktreeError` internally and log. This call
  is a background sync, not a user action; we must not crash the app if
  `wt` misbehaves on a corrupt worktree.

### Tuist / submodule wiring

Mirrors supacode's `verify-git-wt.sh` + `embed-runtime-assets.sh` split,
trimmed to just the git-wt concern (we don't have the theme/CLI embedding
those scripts also handle).

1. `.gitmodules` at repo root gets:
   ```
   [submodule "apps/mac/ThirdParty/git-wt"]
     path = apps/mac/ThirdParty/git-wt
     url = https://github.com/khoi/git-wt.git
   ```
2. `apps/mac/scripts/verify-git-wt.sh`: a pre-build script that asserts
   `${SRCROOT}/ThirdParty/git-wt/wt` exists and is executable, emitting a
   clear `git submodule update --init` hint otherwise.
3. `apps/mac/scripts/embed-git-wt.sh`: a post-build script that `cp -f`s
   the `wt` script into `${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/git-wt/wt`
   and `chmod +x`es it. `inputPaths` = source `wt`; `outputPaths` =
   destination path, so Xcode tracks change-based incremental rebuilds.
4. `Project.swift` edits, scoped to the `codans` app target only:
   ```
   .target(
     name: "codans",
     ...,
     scripts: [
       .pre(script: "\"${SRCROOT}/scripts/verify-git-wt.sh\"",
            name: "Verify git-wt",
            basedOnDependencyAnalysis: false),
       .post(script: "\"${SRCROOT}/scripts/embed-git-wt.sh\"",
             name: "Embed git-wt",
             inputPaths: ["$(SRCROOT)/ThirdParty/git-wt/wt"],
             outputPaths: ["$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/git-wt/wt"],
             basedOnDependencyAnalysis: false),
     ],
     ...
   )
   ```
5. Runtime resolution: `Bundle.main.url(forResource: "wt", withExtension: nil, subdirectory: "git-wt")`.
   If `nil`, `GitWorktreeClient` throws `.executableMissing`; the sidebar
   surfaces a clear error (and CI never reaches this path because the
   pre-script fails the build first).

We do **not** add `git-wt` as a Tuist `resources` entry; that would try to
copy the whole submodule (its README, tests, etc.) into the bundle. The
post-build script copies only the `wt` script — supacode learned this the
hard way and the script-based embed keeps the bundle clean.

## Alternatives Considered

### A. Grow `GitWorktreeCLI` instead of adding `GitWorktreeClient`

`GitWorktreeCLI` is an actor with `run(arguments:cwd:)` helpers and
porcelain-list parsing. We could add `createWorktreeStream`, `prune`,
`fetchRemote` etc. to it.

Rejected: the actor's current methods synchronously buffer entire stdout
into a `String`; adding streaming means introducing `FileHandle` read
handlers and `AsyncStream` plumbing that doesn't fit the actor shape
naturally, and retrofitting callers. More importantly the actor shells out
to `/usr/bin/git` directly — the spec requires the bundled `git-wt` script
for JSON listing / base-dir semantics / streaming copy, which is a
different executable with different flag conventions. Mixing both in one
type obscures which tool a given operation actually uses. A second client
co-located in `codans/Git/` is cheaper to keep correct.

### B. Archive as a separate `[Worktree]` array on `Project`

Rejected (W-Q1). A parallel array forks invariants — the same worktree would
need ID-level de-duplication across `worktrees` and `archivedWorktrees`,
and the `selectedWorktreeID` resolver would need to look across both. The
`archived: Bool` in-place flag integrates with existing filters:
`project.worktrees.filter { !$0.archived }` is one line; every current
sort/fold collapses naturally. Read compat via `decodeIfPresent ?? false` is
trivial. supacode itself stores archive state in a sidebar bucket separate
from worktrees, but that's because its worktrees come from git + they
layered an independent sidebar schema on top — we don't have that detour.

### C. Put creation + discovery in `HierarchyManager` directly

Have the manager shell out to `wt` / `git` when `createWorktree` /
`reconcileDiscoveredWorktrees` are called.

Rejected: `HierarchyManager` is `@MainActor` `@Observable`. Spawning
processes and consuming `AsyncStream` from a main-actor method would block
the UI unless we thread careful `Task.detached` escapes, and every callsite
would need to learn async semantics. The manager is also unit-tested with
an in-memory `CatalogStore`; adding `Process` dependencies breaks that
fixture. Keeping the manager pure-state and putting git behind a client
matches how the codebase treats every other external integration (editor,
Finder, inbox).

### D. Stream creation as `AsyncSequence<String>` (just lines)

Rejected. The consumer needs to know when the create *finished* and needs
the resulting worktree path; a line stream alone conflates
"progress line" with "final path." A typed `CreateEvent` with
`.progressLine` vs `.finished(path:)` is explicit and prevents parsing the
final stdout line to guess the path.

### E. Global `ArchivedWorktreesDetailView`-style surface

supacode has a single app-wide archived-worktrees sheet (navigated-to from
the menu bar). We could do the same — one sheet showing every Project's
archived worktrees grouped.

Rejected for v1: our sidebar is Project-scoped and the `⋯` menu already
sits at the Project level; a cross-project archive surface would need a
separate entry point that has no obvious home (our menu bar surface is
lighter than supacode's). Per-Project sheet keeps the navigation local and
avoids the cross-cutting UI nav doc we'd otherwise need. We can revisit if
users want it.

## Cross-Cutting Concerns

### Error surfacing

- **Create failures** → inline in sheet, Create button re-enabled. For
  `branchExists` / `invalidBranchName` we pre-validate before running
  create so the sheet never attempts the call.
- **Safe-remove failures** → detect `uncommittedChanges(files:)`
  specifically; render a dialog "3 files have uncommitted changes in
  <relativePath>: a.swift, b.swift, …" with a primary "Force Remove"
  button and a secondary "Cancel."
- **Discovery failures** → swallowed + logged (never crash a reconcile).
  A future observability pass can route these to the inbox.

### Running-terminal safety (W-Q3)

On Remove (safe or force), after confirming intent, check
`hierarchyClient.runningPanelCount(worktreeID)`. If > 0, show a second
confirmation: "This will terminate N running processes in <worktree>." On
confirm, iterate the Worktree's Panels and `runtime.closeSurface(for:)`
each (which hard-kills the ghostty surface); *then* run
`removeWorktree`. If the first close raises (shouldn't, but defensively),
abort the remove with a banner. This matches `HierarchyManager.closeTab`'s
existing teardown order and keeps the catalog update as the last step.

We add `runningPanelCount` (not `hasRunningPanels`) so the copy can say
"3 running processes" instead of a plural-ambiguous "running processes."

### Main-checkout guard

Computed in the view: `worktree.path == project.rootPath` (for non-gitRoot
projects, the only worktree *is* the main checkout — same rule applies).
The context menu hides Archive and Remove items for that row; a second
guard in `HierarchyManager.setWorktreeArchived` / the remove path throws
`HierarchyError.invariantViolation("Cannot archive/remove main checkout")`
in case the UI is ever bypassed.

### Branch-name sanitization (W-Q5)

`sanitizeBranchName(_ branch:)` — pure function in
`GitWorktreeClient.swift`: replaces `/` with `-`, strips characters macOS
filesystems reject (`\0`, `/` already handled, `:`). Collision detection:
before creation, compute the directory name and test
`FileManager.fileExists(atPath:)` at `<worktreesDirectory>/<sanitized>`.
If it exists, reject with a clear sheet error that names the collision
("A folder named `feature-a` already exists in this Project's worktree
directory. Choose a different branch name."). No auto-suffixing.

### Testing

Three test layers:

1. **Unit (`CodansCoreTests`)** — `Worktree` Codable round-trip for
   the `archived` field; pre-0007 fixture decodes with `archived == false`.
2. **Unit (`codansTests`)** — `GitWorktreeClient`:
   - argument builder (`makeCreateArguments`) for all flag combinations;
   - JSON decode of `wt ls --json` into `[GitWtEntry]` with bare-repo
     filter;
   - branch-name sanitization cases (`feature/a` → `feature-a`,
     `weird:name` → `weirdname`);
   - error mapping — a fake `ProcessRunner` that returns a scripted stderr
     produces the right `GitWorktreeError` case.
3. **Integration (`codansTests/Integration`)** — a temp git repo
   (`/tmp/codans-wt-<uuid>`, teardown in `addTeardownBlock`) goes
   through create → lsWorktrees → archive → unarchive → removeWorktree.
   Uses the real bundled `wt` if `Bundle.main` resolves it; otherwise the
   integration test is skipped (`XCTSkip("wt script not bundled in test
   target")`). Force-remove path uses a worktree with an uncommitted file
   and asserts safe-remove fails with `.uncommittedChanges` then force
   succeeds.

Manual verification checklist added to the PR body:

- [ ] Create Worktree on a real repo, no copy flags → succeeds <3 s.
- [ ] Create with `--copy-ignored` on codans itself (node_modules
      absent, so it's small; use a JS project for large-copy manual).
- [ ] Create with an invalid branch name → Create button disabled, error
      visible.
- [ ] `git worktree add` on CLI → focus window → worktree appears in
      sidebar within reconcile cycle.
- [ ] Archive → worktree disappears from main list, appears in Archived.
- [ ] Unarchive → returns to main list.
- [ ] Remove with uncommitted files → safe-remove error names files,
      Force button upgrades.
- [ ] Main-checkout row → context menu lacks Archive/Remove.
- [ ] Prune after external `rm -rf` → toast reports correct count.

## Risks

| Risk | Mitigation |
|---|---|
| `wt` script not bundled in a user's dev build → runtime crash. | Pre-build `verify-git-wt.sh` fails the Xcode build with a clear `git submodule update --init` message. `GitWorktreeClient` still throws `.executableMissing` defensively; the sidebar surfaces the error. |
| `wt ls --json` output format drifts in a future upstream release → silent discovery break. | Pin the submodule to a specific commit SHA. Bump deliberately. `GitWtEntry` decoder tolerates extra keys (default JSONDecoder behavior) but fails loudly if required keys vanish — which is the correct signal. |
| Streaming create hangs (user's repo has a massive `node_modules`). | Sheet keeps Cancel enabled throughout; cancel sends SIGTERM to the spawned process via `Task.cancel()` propagation through the `AsyncThrowingStream`'s `onTermination`. A no-progress-in-30s banner is a future polish, not v1. |
| Hard-killing terminal processes on force-remove loses unsaved user work. | Confirm dialog explicitly names the process count; the "uncommitted changes" surface already warns about uncommitted files separately. Terminal content is transient by design — we don't persist terminal scroll-back across sessions today. |
| Reconcile races with Create (user creates a worktree as reconcile is running). | Both paths go through the main actor for catalog writes; the git-side operations are independent. Worst case: reconcile sees the just-created worktree *and* it's already in the catalog → our path-canonicalization match correctly dedupes. Test covers this. |
| Archive + force-remove from the archived sheet double-fires catalog updates. | The remove path unconditionally calls `HierarchyManager.removeWorktree` which works whether the target is archived or not. No special-case archived-remove. |
| T-PROJECT schedules `reconcileDiscoveredWorktrees` during app teardown. | Method is a simple async function; Task cancellation propagates through. No teardown-specific handling needed. |

## Open Items / Future

- **Archive hook (C3)** — spec W-Q6. When C3 gains a `worktree.archived`
  lifecycle event we'll publish it from `setWorktreeArchived`. Out of
  scope for v1.
- **Worktree "stale" UI indicator** — spec hints at it; v1 offers Prune
  without a distinct stale-row style. Can come in a follow-up polish pass.
- **Rename branch in-place** — spec nice-to-have. `GitWorktreeClient` has
  the shape for `renameBranch` but we leave it unbuilt until the sheet
  design is clear.
