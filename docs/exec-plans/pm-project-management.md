# ExecPlan: Project Management — Add / Health / Options / Reorder

**Status:** Draft
**Author:** Claude (child agent on `feat/project-mgmt`)
**Date:** 2026-04-21

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this change, a user can register an existing local folder as a Project, see its health state, edit per-Project defaults, reorder Projects, and remove a Project without touching files on disk. Specifically: clicking `+ Add Project` opens a macOS folder picker; picking a folder classifies it as git-backed or scratch, rejects duplicate paths with a "Reveal existing Project" escape hatch, lets the user edit the name at add-time, and commits it to `catalog.json`. Each Project shows a live health badge (`ready` / `loading` / `failed(reason)`) driven by a reconciler that runs on app launch and on window focus. A Project's `⋯` menu opens an Options sheet that edits name, default editor, and `worktreesDirectory` override. Projects reorder inside a Space via drag. Non-git Projects suppress the `+ Worktree` affordance, the header branch label, and the Git Viewer toggle. Removing a Project unregisters it from `catalog.json` and closes its panes — the repository and its worktree directories stay on disk untouched, and the confirmation copy says so unambiguously.

Worktree-list enumeration on reconcile is **not owned by this feature**. It is delegated to `HierarchyClient.reconcileDiscoveredWorktrees(projectID:inSpace:)`, which T-WORKTREE owns (append-only, idempotent, swallows errors, main-actor serialized). Until T-WORKTREE's PR lands on `feature/hierarchy-management`, this branch ships a no-op stub of that closure in `HierarchyClient.liveValue`; on rebase the stub is replaced and our call sites do not change.

## Progress

- [ ] P0.1 — Project.loadState field + hand-rolled Codable (transient) + round-trip test
- [ ] P0.2 — HierarchyManager: setProjectLoadState / reorderProjects / setProjectWorktreesDirectory / isPathRegistered + unit tests
- [ ] P0.3 — HierarchyClient: four **owned** closures + one **consumed** stub (reconcileDiscoveredWorktrees), all appended to file end
- [ ] P1.1 — FolderPickerClient (new file) + DependencyKey
- [ ] P1.2 — ProjectReconciler actor (Runtime/) + single-flight + debounce + unit tests with recorder client
- [ ] P2.1 — AddProjectFeature reducer + state/action surface + tests (add-time GitWorktreeCLI.discoverGitRoot classification)
- [ ] P2.2 — AddProjectSheet view; replace HierarchySidebarView stub at lines 66-71
- [ ] P3.1 — ProjectOptionsFeature reducer + state/action surface + tests
- [ ] P3.2 — ProjectOptionsSheet view; rewire ⋯ menu Rename / Remove → Options sheet
- [ ] P3.3 — Migrate HierarchySidebarFeatureTests rename cases into ProjectOptions tests; delete orphaned `renameProject*` actions; confirm green
- [ ] P4.1 — RootFeature launch hook runs ProjectReconciler.reconcileAll via `.task`
- [ ] P4.2 — RootFeature didBecomeActive hook debounced 2s
- [ ] P5.1 — Non-git UI suppression: ProjectHeaderRow `+` hidden when !supportsWorktrees
- [ ] P5.2 — WorktreeHeaderView branch label + HeaderGitViewerToggle gated by supportsWorktrees
- [ ] P5.3 — Remove Project confirmation copy updated to "Files on disk are not affected"
- [ ] P6.1 — HierarchySidebarView ForEach.onMove; dispatches reorderProjects
- [ ] P7.1 — FailedProjectRow view + Retry / Remove actions
- [ ] P7.2 — Render failed-state Project sections with FailedProjectRow instead of normal section
- [ ] P8.1 — Local verification: lint + three test schemes green; manual walkthrough
- [ ] P8.2 — Push branch; open PR against `feature/hierarchy-management`; post `PR_READY`
- [ ] P8.3 — (Post-T-WORKTREE-rebase) delete no-op stub, rebase onto real `reconcileDiscoveredWorktrees`, re-run full verification, post `PR_READY` again

## Surprises & Discoveries

(None yet)

## Decision Log

- **D1** (from design doc §A): `Project.loadState` is transient. Hand-rolled `Codable` mirrors the pattern `Worktree.swift` uses for `gitViewerVisible` — decode skips the key, encode never emits it, pre-existing catalogs round-trip byte-identical.
- **D2** (from design doc §C + master REVISE 2026-04-21): Worktree-list mutation on reconcile is **not owned here**. The `ProjectReconciler` calls `HierarchyClient.reconcileDiscoveredWorktrees` (T-WORKTREE) and never touches `project.worktrees` directly. No `replaceWorktrees` method is added. No `ProjectScanner` abstraction is added. The reconciler does not import `GitWorktreeCLI`.
- **D3** (from design doc §E): `FolderPickerClient` is a new tiny client, not an extension of `FinderClient`. Separate because `FinderClient` is reveal-only (`Void` return); the picker needs an async `URL?` return.
- **D4** (from design doc §Boundary with T-WORKTREE + Alt H): `reconcileDiscoveredWorktrees` is **consumed** from `HierarchyClient`, not declared by us. Until T-WORKTREE merges, this branch ships a no-op stub in `HierarchyClient.liveValue`; post-rebase the stub is replaced at the `live(manager:)` site. No call-site changes at consumer code.
- **D5** (from design doc §R2): Path canonicalization uses `URL(fileURLWithPath:).resolvingSymlinksInPath().standardizedFileURL.path`. Canonical form is stored as `Project.rootPath`; displayed form is the canonical form (no separate `displayPath`).
- **D6** (from master 2026-04-21 APPROVE note 1): ProjectOptionsFeature subsumes rename. The existing `renameProjectSheet` state, actions (`.projectRenameTapped` / `.projectRenameDraftChanged` / `.projectRenameConfirmed` / `.projectRenameCancelled`), the separate sheet body in `HierarchySidebarView`, and the `RenameProjectSheet` struct are **removed**. Existing `HierarchySidebarFeatureTests` rename cases are ported into the new `ProjectOptionsFeatureTests`, not kept against removed actions.
- **D7** (from design doc §Alternatives G): Reorder uses `ForEach(...).onMove(perform:)` inside `.listStyle(.sidebar)`. Custom drag-and-drop is deferred.
- **D8** (from design doc §Cross-cutting / non-git suppression): The single predicate is `project.supportsWorktrees`. No new flag is threaded; three call sites read the existing computed property.
- **D9** (from master REVISE 2026-04-21): The previously-planned archived-Worktree merge test (original P8.3) is **dropped** — with `replaceWorktrees` removed from our scope there is no merge code under test on this branch. The equivalent coverage belongs to T-WORKTREE's `reconcileDiscoveredWorktrees` implementation. This plan's new P8.3 is just the post-rebase verification (stub removed, full suite re-run).

## Outcomes & Retrospective

(To be filled at milestone completion)

## Context and Orientation

Related documents:

- Product spec (authoritative): `docs/product-specs/project-management.md`
- Design doc (this plan's source of truth): `docs/design-docs/pm-project-management.md`
- Related specs referenced for boundary decisions: `docs/product-specs/worktree-management.md` (T-WORKTREE's surface)
- Architecture doc: `docs/architecture.md`
- Golden rules: `docs/golden-rules.md`

Key source files (full repository-relative paths):

- `apps/mac/CodansCore/Project.swift` — `Project` value type. P0.1 adds transient `loadState` and hand-rolled `Codable`. **Conflict file — owned by this branch.**
- `apps/mac/CodansCore/Worktree.swift` — owned by T-WORKTREE (adds `archived`). **Do not touch.**
- `apps/mac/CodansCore/Space.swift` — **Do not touch.**
- `apps/mac/CodansCore/Catalog.swift` — unchanged by this plan.
- `apps/mac/codans/Runtime/HierarchyManager.swift` — P0.2 appends four new methods after existing Project mutations.
- `apps/mac/codans/App/Clients/HierarchyClient.swift` — P0.3 appends four owned closures and one consumed-stub closure (for T-WORKTREE's `reconcileDiscoveredWorktrees`). All additions at file end to minimize merge conflict.
- `apps/mac/codans/Git/GitWorktreeCLI.swift` — existing actor with `discoverGitRoot` + `listWorktrees`. Consumed **only** by `AddProjectFeature` for add-time git/non-git classification. The reconciler does not import this file.
- `apps/mac/codans/App/Clients/FolderPickerClient.swift` — **new file**. NSOpenPanel bridge. P1.1.
- `apps/mac/codans/Runtime/ProjectReconciler.swift` — **new file**. Actor. P1.2.
- `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarView.swift` — current view. P2.2 replaces **only** lines 66-71 (Add-Project stub) with the real sheet. **Lines 78-83 (Add-Worktree stub) untouched — T-WORKTREE territory.** P3.2 rewires the `⋯` menu. P5.1 gates `+` chrome. P5.3 updates Remove-Project dialog copy. P6.1 adds `.onMove`. P7.2 swaps in `FailedProjectRow`.
- `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarFeature.swift` — P3.3 removes rename state/actions. P2.x / P3.x add `.addProjectSheet(...)` delegation and `.projectOptionsTapped`.
- `apps/mac/codans/App/Features/HierarchySidebar/AddProjectFeature.swift` — **new file**. P2.1.
- `apps/mac/codans/App/Features/HierarchySidebar/AddProjectSheet.swift` — **new file**. P2.2.
- `apps/mac/codans/App/Features/ProjectOptions/ProjectOptionsFeature.swift` — **new file**. P3.1.
- `apps/mac/codans/App/Features/ProjectOptions/ProjectOptionsSheet.swift` — **new file**. P3.2.
- `apps/mac/codans/App/Features/HierarchySidebar/FailedProjectRow.swift` — **new file**. P7.1.
- `apps/mac/codans/App/Features/WorktreeHeader/WorktreeHeaderView.swift` — P5.2 gates branch label + GV toggle on `supportsWorktrees`.
- `apps/mac/codans/App/Features/WorktreeDetail/WorktreeDetailView.swift` — P5.2 caller change.
- `apps/mac/codans/App/Features/Root/RootFeature.swift` — P4.1 / P4.2 add reconcile triggers.
- `apps/mac/codans/App/CodansApp.swift` — wires `FolderPickerClient` and the `ProjectReconciler` instance. P1.1 / P1.2 / P4.1.
- `apps/mac/codans/Tests/HierarchyManagerTests.swift` — P0.2 adds coverage.
- `apps/mac/codans/Tests/HierarchySidebarFeatureTests.swift` — P3.3 migrates rename cases out.
- `apps/mac/codans/Tests/ProjectReconcilerTests.swift` — **new file**. P1.2.
- `apps/mac/codans/Tests/AddProjectFeatureTests.swift` — **new file**. P2.1.
- `apps/mac/codans/Tests/ProjectOptionsFeatureTests.swift` — **new file**. P3.1.
- `apps/mac/CodansCoreTests/ProjectCodableTests.swift` — **new file**. P0.1.

Terms of art (defined where first used):

- **Transient field** — a stored property on a `Codable` value type that is *not* serialized. Achieved by hand-writing `init(from:)` / `encode(to:)` and omitting the key. The field always takes its default value on decode.
- **Canonical path** — `URL(fileURLWithPath: raw).resolvingSymlinksInPath().standardizedFileURL.path`. The identity form used for duplicate checks and persistence. Raw user input is canonicalized once at the boundary and never stored.
- **Single-flight** — a `Set<Key>` guard inside an actor so overlapping async tasks for the same key coalesce to one. Used by the reconciler keyed by `ProjectID`.
- **Consumed closure** — a `HierarchyClient` closure whose contract and implementation live on a different branch (here: T-WORKTREE). This branch only calls it. Between our merge and T-WORKTREE's merge, `liveValue` supplies a no-op stub so the build stays green and the rest of the feature is demonstrable.
- **Health row / failed-state row** — replaces the normal Project row in the sidebar when `project.loadState == .failed(_)`. Renders a one-line name + path + a "Show failure" button; context menu offers Retry / Remove. Mirrors supacode's `FailedRepositoryRow`.
- **Non-git UI suppression** — three `if project.supportsWorktrees` gates in the sidebar (`+` chrome), the header (branch label + Git Viewer toggle), and the Add-Worktree menu item. Single predicate; three enforcement points.
- **Options sheet** — a single modal launched from the `⋯` menu that edits every per-Project field: name, defaultEditor, worktreesDirectory. Subsumes what used to be the standalone Rename Project sheet (D6).

## Plan of Work

The work is organized as nine phases (P0–P8), sliced vertically so each phase ends on a green build + passing tests. Each phase is one or a small number of commits landed via `/commit`. Phase order is dependency-driven: data-layer contracts first, reconciler scaffolding second, then vertical features, then triggers, then polish.

### P0 — Data layer and client surface

**P0.1** — Edit `apps/mac/CodansCore/Project.swift`. Add:

```swift
public enum ProjectLoadState: Equatable, Sendable {
  case loading
  case ready
  case failed(reason: String)
}

public struct Project: Equatable, Codable, Sendable, Identifiable {
  // existing fields unchanged
  public var loadState: ProjectLoadState = .loading   // transient

  public init(/* existing params */, loadState: ProjectLoadState = .loading) {
    // existing assignments
    self.loadState = loadState
  }
  public var supportsWorktrees: Bool { gitRoot != nil }
}

extension Project {
  private enum CodingKeys: String, CodingKey {
    case id, name, rootPath, gitRoot, worktreesDirectory, defaultEditor, worktrees, selectedWorktreeID
    // loadState intentionally omitted
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try c.decode(ProjectID.self, forKey: .id)
    self.name = try c.decode(String.self, forKey: .name)
    self.rootPath = try c.decode(String.self, forKey: .rootPath)
    self.gitRoot = try c.decodeIfPresent(String.self, forKey: .gitRoot)
    self.worktreesDirectory = try c.decodeIfPresent(String.self, forKey: .worktreesDirectory)
    self.defaultEditor = try c.decodeIfPresent(String.self, forKey: .defaultEditor)
    self.worktrees = try c.decodeIfPresent([Worktree].self, forKey: .worktrees) ?? []
    self.selectedWorktreeID = try c.decodeIfPresent(WorktreeID.self, forKey: .selectedWorktreeID)
    self.loadState = .loading
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(name, forKey: .name)
    try c.encode(rootPath, forKey: .rootPath)
    try c.encodeIfPresent(gitRoot, forKey: .gitRoot)
    try c.encodeIfPresent(worktreesDirectory, forKey: .worktreesDirectory)
    try c.encodeIfPresent(defaultEditor, forKey: .defaultEditor)
    try c.encode(worktrees, forKey: .worktrees)
    try c.encodeIfPresent(selectedWorktreeID, forKey: .selectedWorktreeID)
  }
}
```

Create `apps/mac/CodansCoreTests/ProjectCodableTests.swift` with one round-trip test: decode a canonical v1 `catalog.json` snippet without `loadState`, encode back, assert JSON dictionaries are equal (via `JSONSerialization`, key-order insensitive). One additional test: decoded Project's `loadState == .loading`.

Acceptance: `xcodebuild test -scheme CodansCore` green.

Commit: `feat(pm): add transient Project.loadState with hand-rolled Codable`

**P0.2** — Edit `apps/mac/codans/Runtime/HierarchyManager.swift`. Append after `setDefaultEditor`:

```swift
func setProjectLoadState(
  _ state: ProjectLoadState,
  projectID: ProjectID,
  spaceID: SpaceID
) {
  guard let (si, pi) = findProjectIndices(projectID: projectID, spaceID: spaceID) else { return }
  guard catalog.spaces[si].projects[pi].loadState != state else { return }
  catalog.spaces[si].projects[pi].loadState = state
  // No scheduleSave — transient.
}

func reorderProjects(
  in spaceID: SpaceID,
  from source: IndexSet,
  to destination: Int
) throws {
  guard let si = catalog.spaces.firstIndex(where: { $0.id == spaceID }) else {
    throw HierarchyError.notFound("Space \(spaceID)")
  }
  catalog.spaces[si].projects.move(fromOffsets: source, toOffset: destination)
  store.scheduleSave(catalog)
}

func setProjectWorktreesDirectory(
  _ path: String?,
  projectID: ProjectID,
  spaceID: SpaceID
) throws {
  guard let (si, pi) = findProjectIndices(projectID: projectID, spaceID: spaceID) else {
    throw HierarchyError.notFound("Project \(projectID)")
  }
  let normalized = path?.trimmingCharacters(in: .whitespacesAndNewlines)
  let value: String? = (normalized?.isEmpty ?? true) ? nil : normalized
  guard catalog.spaces[si].projects[pi].worktreesDirectory != value else { return }
  catalog.spaces[si].projects[pi].worktreesDirectory = value
  store.scheduleSave(catalog)
}

func isPathRegistered(canonical path: String) -> (SpaceID, ProjectID)? {
  for space in catalog.spaces {
    for project in space.projects where Self.canonical(project.rootPath) == path {
      return (space.id, project.id)
    }
  }
  return nil
}

static func canonical(_ raw: String) -> String {
  URL(fileURLWithPath: raw).resolvingSymlinksInPath().standardizedFileURL.path
}
```

**Not added:** `replaceWorktrees`. Worktree-list mutation on reconcile is T-WORKTREE's responsibility.

Unit tests in `apps/mac/codans/Tests/HierarchyManagerTests.swift`:

1. `reorderProjects_movesInPlaceAndPersists`
2. `setProjectLoadState_dedupsAndDoesNotPersist` (verify no `scheduleSave` for identical state)
3. `setProjectWorktreesDirectory_emptyStringClears`
4. `setProjectWorktreesDirectory_dedupsOnEqualValue`
5. `isPathRegistered_canonicalizesBeforeMatch`
6. `isPathRegistered_returnsNilWhenAbsent`

Acceptance: `codans` scheme green with +6 tests.

Commit: `feat(pm): HierarchyManager load-state / reorder / worktreesDir / isPathRegistered`

**P0.3** — Edit `apps/mac/codans/App/Clients/HierarchyClient.swift`. **Append** five new closure properties at the end of the `HierarchyClient` struct body; match with trailing entries in `live(manager:)`, `liveValue`, `testValue` — additive-only placement so this branch and T-WORKTREE can both append without textual conflict.

Signatures:

```swift
// Owned by this branch.
var setProjectLoadState: @MainActor @Sendable (
  _ projectID: ProjectID, _ inSpace: SpaceID, _ state: ProjectLoadState
) -> Void

var reorderProjects: @MainActor @Sendable (
  _ inSpace: SpaceID, _ from: IndexSet, _ to: Int
) throws -> Void

var setProjectWorktreesDirectory: @MainActor @Sendable (
  _ projectID: ProjectID, _ inSpace: SpaceID, _ path: String?
) throws -> Void

var isPathRegistered: @MainActor @Sendable (_ canonical: String) -> (SpaceID, ProjectID)?

// Consumed; T-WORKTREE owns the contract and the live implementation.
// This branch ships a no-op stub in `liveValue` so the Reconciler compiles
// and the rest of the feature is demonstrable end-to-end. On rebase, the
// stub is replaced by T-WORKTREE's real binding (one-line change in
// `live(manager:)`; zero change at every call site).
var reconcileDiscoveredWorktrees: @MainActor @Sendable (
  _ projectID: ProjectID, _ inSpace: SpaceID
) async -> Void
```

`live(manager:)` — for `reconcileDiscoveredWorktrees`, use:

```swift
reconcileDiscoveredWorktrees: { _, _ in
  // Placeholder — T-WORKTREE replaces this with a real implementation
  // calling its worktree-reconciliation routine on `HierarchyManager`.
  // See docs/design-docs/pm-project-management.md §Boundary with T-WORKTREE.
}
```

For `liveValue` (the fatal-error set) and `testValue` (the `unimplemented(...)` set), follow the existing conventions for each.

Acceptance: `codans` scheme builds; no test regressions.

Commit: `feat(pm): HierarchyClient — 4 owned closures + consumed reconcileDiscoveredWorktrees stub`

### P1 — Infrastructure: FolderPicker + Reconciler

**P1.1** — Create `apps/mac/codans/App/Clients/FolderPickerClient.swift`:

```swift
import AppKit
import ComposableArchitecture
import Foundation

nonisolated struct FolderPickerClient: Sendable {
  var pick: @MainActor @Sendable (_ prompt: String) async -> URL?
}

extension FolderPickerClient: DependencyKey {
  static let liveValue = FolderPickerClient(
    pick: { prompt in
      await MainActor.run {
        let pane = NSOpenPanel()
        pane.prompt = prompt
        pane.canChooseFiles = false
        pane.canChooseDirectories = true
        pane.allowsMultipleSelection = false
        pane.canCreateDirectories = false
        guard pane.runModal() == .OK else { return Optional<URL>.none }
        return pane.url
      }
    }
  )
  static let testValue = FolderPickerClient(
    pick: unimplemented("FolderPickerClient.pick", placeholder: nil)
  )
}

extension DependencyValues {
  var folderPickerClient: FolderPickerClient {
    get { self[FolderPickerClient.self] }
    set { self[FolderPickerClient.self] = newValue }
  }
}
```

Acceptance: `codans` scheme builds.

Commit: `feat(pm): FolderPickerClient (NSOpenPanel bridge)`

**P1.2** — Create `apps/mac/codans/Runtime/ProjectReconciler.swift`:

```swift
import Foundation
import CodansCore

actor ProjectReconciler {
  private let client: HierarchyClient
  private let now: @Sendable () -> Date
  private let debounceInterval: TimeInterval
  private var inFlight: Set<ProjectID> = []
  private var lastAllRun: Date?

  init(
    client: HierarchyClient,
    now: @escaping @Sendable () -> Date = Date.init,
    debounceInterval: TimeInterval = 2.0
  ) {
    self.client = client
    self.now = now
    self.debounceInterval = debounceInterval
  }

  func reconcile(projectID: ProjectID, spaceID: SpaceID) async {
    guard !inFlight.contains(projectID) else { return }
    inFlight.insert(projectID)
    defer { inFlight.remove(projectID) }

    let snapshot = await client.snapshot()
    guard let project = snapshot.spaces.first(where: { $0.id == spaceID })?
      .projects.first(where: { $0.id == projectID }) else { return }

    await client.setProjectLoadState(projectID, spaceID, .loading)

    guard FileManager.default.fileExists(atPath: project.rootPath) else {
      await client.setProjectLoadState(
        projectID, spaceID,
        .failed(reason: "Folder no longer exists at \(project.rootPath)")
      )
      return
    }

    // T-WORKTREE's closure owns git enumeration, non-git routing, error recovery,
    // and append-only mutation of project.worktrees. Per contract it does not throw.
    await client.reconcileDiscoveredWorktrees(projectID, spaceID)
    await client.setProjectLoadState(projectID, spaceID, .ready)
  }

  func reconcileAll() async {
    let current = now()
    if let last = lastAllRun, current.timeIntervalSince(last) < debounceInterval {
      return
    }
    lastAllRun = current
    let snapshot = await client.snapshot()
    await withTaskGroup(of: Void.self) { group in
      for space in snapshot.spaces {
        for project in space.projects {
          group.addTask { [self] in
            await reconcile(projectID: project.id, spaceID: space.id)
          }
        }
      }
    }
  }
}
```

Note: `Date()`-based clocking over `any Clock<Duration>` because (a) tests can drive debounce deterministically by injecting a fake `now` closure (one line override in a `withDependencies` block), (b) the reconciler does not need clock-driven sleep/timers, only a monotonic "is 2 seconds past?" check, and (c) `any Clock<Duration>.Instant` existentials are awkward to store as actor state without generics. The real clock is `Date.init`; tests pass a `{ fixedDate }` closure and advance it between calls.

The reconciler does not import `GitWorktreeCLI` or `ProjectScanner`. Its only non-client dependency is `FileManager.default`.

Unit tests in `apps/mac/codans/Tests/ProjectReconcilerTests.swift`. All tests use a **recorder-closure** `HierarchyClient` — no real git fixture, no real `catalog.json`, no `GitWorktreeCLI`:

1. `reconcile_existingFolder_callsClosureAndSetsReady` — record the three calls in order: `setProjectLoadState(.loading)`, `reconcileDiscoveredWorktrees`, `setProjectLoadState(.ready)`.
2. `reconcile_missingFolder_setsFailedAndSkipsClosure` — tmpdir that doesn't exist; assert `reconcileDiscoveredWorktrees` is NOT called; `.failed(reason: …)` matches the message format.
3. `reconcile_unknownProject_isNoOp` — snapshot doesn't contain the Project; assert zero client writes.
4. `reconcile_singleFlight_dedupsOverlappingCalls` — two concurrent `reconcile` calls for the same Project; assert the recorder sees exactly one `reconcileDiscoveredWorktrees` call.
5. `reconcileAll_debounces` — call twice within 0.5s using a `TestClock`; assert second call is a no-op.
6. `reconcileAll_fanoutAcrossProjects` — three Projects across two Spaces; assert one `reconcileDiscoveredWorktrees` per Project.

These tests pass today (against the no-op stub) and continue to pass after T-WORKTREE's rebase without modification — the recorder doesn't care what the closure does.

Wire the `ProjectReconciler` instance in `apps/mac/codans/App/CodansApp.swift` alongside `hierarchyManager` etc. Expose via a new `DependencyKey` on `ProjectReconciler` with `liveValue` constructed from the live `HierarchyClient`.

Acceptance: `codans` scheme green with +6 tests.

Commit: `feat(pm): ProjectReconciler actor — stat + client closure + single-flight`

### P2 — Add Project flow

**P2.1** — Create `apps/mac/codans/App/Features/HierarchySidebar/AddProjectFeature.swift`. Reducer with state / actions per design doc §AddProjectFeature. Dependencies: `@Dependency(HierarchyClient.self)`, `@Dependency(FolderPickerClient.self)`, `@Dependency(GitWorktreeCLI.self)` (register via a new `DependencyKey` on `GitWorktreeCLI` if absent; `liveValue = GitWorktreeCLI()`).

Logic:

- `.openPickerTapped` → `.run { await folderPicker.pick(...) }` → `.folderPicked`.
- `.folderPicked(url?)` → if nil, dismiss. Else canonicalize the URL's path, set `pickedPath`, ask `hierarchyClient.isPathRegistered(canonical:)`; if duplicate, set banner state and **stop** (no classification). Else dispatch `.validationStarted`.
- `.validationStarted` → `.run { try? await gitCLI.discoverGitRoot(candidatePath: pickedPath) }` → `.validationResolved(gitRoot:)`.
- `.validationResolved(gitRoot:)` → set `pickedIsGit = gitRoot != nil`; seed `nameDraft = (pickedPath as NSString).lastPathComponent`.
- `.nameDraftChanged(String)` → trim; compute `canSubmit`.
- `.submitTapped` → guard `canSubmit`; call `try? hierarchyClient.addProject(spaceID, name, rootPath, gitRoot)`; delegate `.delegate(.projectAdded(projectID, spaceID))`. Dismiss.
- `.revealExistingTapped` → delegate `.delegate(.revealExisting(spaceID, projectID))`.
- `.cancelTapped` → clear state.

Tests in `apps/mac/codans/Tests/AddProjectFeatureTests.swift` (TestStore):

1. `happyPath_gitFolder_submits` — real temp-dir `git init` fixture for the classification step; recorder asserts `addProject(...)` once with `gitRoot != nil`; delegate `.projectAdded` emitted.
2. `happyPath_nonGitFolder_submits` — temp dir without `.git`; `gitRoot == nil`.
3. `duplicatePath_blocksSubmit_allowsReveal` — `isPathRegistered` returns pair; submit is a no-op; `revealExistingTapped` emits delegate.
4. `emptyNameDraft_disablesSubmit`.
5. `cancelClearsState`.
6. `pickerCancelled_dismisses`.

Acceptance: `codans` scheme green.

Commit: `feat(pm): AddProjectFeature reducer + tests`

**P2.2** — Create `apps/mac/codans/App/Features/HierarchySidebar/AddProjectSheet.swift` with the UI described in the design doc. Replace `HierarchySidebarView.swift` lines 66-71 (Add Project stub body) with a real `AddProjectSheet(store: …)`. Wire `HierarchySidebarFeature` to scope `AddProjectFeature`.

Delegate routing:

- `AddProjectFeature.Delegate.projectAdded(projectID, spaceID)` → `HierarchySidebarFeature.Delegate.reconcileProjectRequested(projectID, spaceID)` → `RootFeature` dispatches `Task { await reconciler.reconcile(projectID, spaceID) }`.
- `AddProjectFeature.Delegate.revealExisting(spaceID, projectID)` → `HierarchySidebarFeature` calls `hierarchyClient.selectSpace(spaceID)` + `selectProject(projectID, inSpace: spaceID)` directly (no RootFeature hop — pure catalog mutation).

**Lines 78-83 of `HierarchySidebarView.swift` untouched.**

Manual verification: run the app; `+ Add Project`; pick a git folder; Project lands with `.loading`, transitions to `.ready`. Worktree-list population requires T-WORKTREE post-rebase — on this branch with the no-op stub, only the main-checkout row (seeded by `hierarchyClient.addProject` for non-git; absent for git without T-WORKTREE) shows. Record this expected limitation as an P8.1 manual-test note.

Commit: `feat(pm): Add Project sheet — NSOpenPanel + git/non-git classification`

### P3 — Project Options sheet (subsumes Rename)

**P3.1** — Create `apps/mac/codans/App/Features/ProjectOptions/ProjectOptionsFeature.swift`. State / actions per design doc §ProjectOptionsFeature. Dependencies: `@Dependency(HierarchyClient.self)` only. On `.saveTapped`, sequence `renameProject` → `setDefaultEditor` → `setProjectWorktreesDirectory`; on any throw, keep sheet open, set `validationError`.

Tests in `apps/mac/codans/Tests/ProjectOptionsFeatureTests.swift`:

1. `save_fansOutThreeCalls_inOrder`
2. `save_skipsRenameIfNameUnchanged`
3. `save_emptyWorktreesDirectory_clearsOverride`
4. `cancel_keepsDraftsLocal`
5. `save_blankName_rejectsAndKeepsSheetOpen`
6. `save_editorUnchanged_skipsSetDefaultEditor`

Acceptance: `codans` scheme green.

Commit: `feat(pm): ProjectOptionsFeature reducer + tests`

**P3.2** — Create `apps/mac/codans/App/Features/ProjectOptions/ProjectOptionsSheet.swift`. Fields: name, default editor (Picker over `EditorRegistry.descriptors`; first row "Use global default" → `nil`), worktrees directory (TextField; placeholder shows the default `~/.codans/repos/<name>/`). Save / Cancel buttons.

Rewire `⋯` menu in `HierarchySidebarView`'s `ProjectHeaderRow` (lines 506-527). "Rename Project" and any future rename entry point dispatch `.projectOptionsTapped(projectID:, inSpace:)`. Remove the standalone rename sheet presentation block (lines 84-91 and 424-453). Remove the `RenameProjectSheet` struct and its four related actions from `HierarchySidebarFeature`. Add `projectOptionsSheet: ProjectOptionsSheet?` state + `.projectOptionsTapped` action.

Commit: `feat(pm): Project Options sheet — subsumes rename via ⋯ menu`

**P3.3** — Edit `apps/mac/codans/Tests/HierarchySidebarFeatureTests.swift`:

- Delete `projectRenamePath` test (and helpers it used exclusively).
- Grep the test file for `renameProjectSheet` / `.projectRename*` / `RenameProjectSheet` — zero hits.
- Add a new sidebar-level smoke test `projectOptionsTapped_populatesSheet` asserting state field becomes non-nil (no direct HierarchyClient call from the sidebar reducer).

Acceptance: no orphan references; `codans` scheme green.

Commit: `test(pm): migrate rename coverage to ProjectOptionsFeature; drop orphan actions`

### P4 — Reconcile triggers

**P4.1** — Edit `apps/mac/codans/App/Features/Root/RootFeature.swift`. Add `@Dependency(ProjectReconciler.self)`. Extend `.onLaunch` merge with `.run { _ in await reconciler.reconcileAll() }`. Handle `HierarchySidebarFeature.Delegate.reconcileProjectRequested(projectID, spaceID)` → `.run { _ in await reconciler.reconcile(projectID, spaceID) }`.

Commit: `feat(pm): reconcile on app launch + after Add Project`

**P4.2** — Still inside `RootFeature.onLaunch`, add a long-lived `.run` effect that subscribes to `NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification)` and awaits each, calling `await reconciler.reconcileAll()`. Debounce is enforced inside the reconciler (2 s).

Add a single assertion in `RootFeatureTests.swift` that `.onLaunch` emits the reconciler task effect.

Commit: `feat(pm): reconcile on window activation with 2s debounce`

### P5 — Non-git UI suppression + Remove copy

**P5.1** — In `HierarchySidebarView.swift`, wrap the `+` button inside `ProjectHeaderRow` (around line 500) with `if project.supportsWorktrees`. Hover chrome layout must not shift when the button is absent — if needed, keep the button present but `.disabled(!project.supportsWorktrees).opacity(0)` to preserve width; preferred: just hide with `if`, since `.opacity(isHovering ? 1 : 0)` already serves the non-shift goal. Use `if`.

Commit: `feat(pm): hide sidebar + Worktree chrome on non-git Projects`

**P5.2** — Edit `WorktreeHeaderView.swift`: add `let supportsWorktrees: Bool` parameter. Wrap the branch `Label(branchLabel, …)` (line 20) and `HeaderGitViewerToggle(…)` (line 38) in `if supportsWorktrees`. Update the caller `WorktreeDetailView.swift` at the construction site to pass `project.supportsWorktrees`. Lookup: `hierarchyManager.catalog` walks using the existing in-scope `(spaceID, projectID)` identifiers.

Commit: `feat(pm): hide branch label and Git Viewer toggle on non-git Projects`

**P5.3** — In `HierarchySidebarView.swift` line 124 (Project removal confirmation message), replace:

```
Text("Removes the Project and every Worktree under it. This closes all their panes and cannot be undone.")
```

with:

```
Text("Removes the Project and closes all its panes. Files on disk are not affected.")
```

Commit: `feat(pm): Remove Project dialog copy — "Files on disk are not affected"`

### P6 — Reorder Projects

**P6.1** — In `HierarchySidebarView.treeBody`, attach `.onMove` to the `ForEach(activeSpace.projects)`:

```swift
ForEach(activeSpace.projects) { project in
  projectSection(project, in: activeSpace, ...)
}
.onMove { source, destination in
  store.send(.reorderProjects(from: source, to: destination, inSpace: activeSpace.id))
}
```

Add action `.reorderProjects(from: IndexSet, to: Int, inSpace: SpaceID)` that calls `try? hierarchyClient.reorderProjects(spaceID, from, to)`. Test: `reorderProjects_dispatchesClient` asserts the single client call.

If drag handles don't appear under `.listStyle(.sidebar)` without edit mode, add `.environment(\.editMode, .constant(.active))` to the `List` and document in §Surprises.

Commit: `feat(pm): drag-to-reorder Projects inside a Space`

### P7 — Failed-state row UX

**P7.1** — Create `FailedProjectRow.swift` mirroring supacode's `FailedRepositoryRow`. Fields: `name`, `rootPath`, `reason`, `retry: () -> Void`, `remove: () -> Void`. Body: two-line row (name + path in small caption), a warning-triangle button that opens a popover with the reason + Retry / Remove buttons. Context menu with Retry Loading / Remove Project.

Commit: `feat(pm): FailedProjectRow view with Retry / Remove`

**P7.2** — In `HierarchySidebarView.projectSection`, switch on `project.loadState`:

- `.ready` → normal section unchanged.
- `.loading` → normal section with a trailing inline `ProgressView().scaleEffect(0.5)` on the header.
- `.failed(let reason)` → render `FailedProjectRow` instead of the `DisclosureGroup`.

Retry dispatches `.retryProjectTapped(projectID:, inSpace:)` → sidebar delegate `.reconcileProjectRequested` → reconciler. Remove reuses the existing `.projectRemoveTapped` path.

Commit: `feat(pm): render failed Projects with FailedProjectRow; wire Retry`

### P8 — Verify, ship, rebase

**P8.1** — Local verification:

```
make mac-generate
make mac-lint
xcodebuild test -workspace apps/mac/codans.xcworkspace -scheme CodansCore -configuration Debug -quiet
xcodebuild test -workspace apps/mac/codans.xcworkspace -scheme codans   -configuration Debug -quiet
xcodebuild test -workspace apps/mac/codans.xcworkspace -scheme CodansKit        -configuration Debug -quiet
```

Expected tail: `** TEST SUCCEEDED **` for each.

Manual walkthrough (what is demonstrable on this branch **before** T-WORKTREE merges; the stub makes `reconcileDiscoveredWorktrees` a no-op, so worktree-list populating is deferred):

1. `+ Add Project` → pick a git folder → Project appears with `.loading` then `.ready`; **worktree list stays empty until T-WORKTREE rebases** (expected; call out in PR body).
2. Pick a non-git folder → Project appears `.ready`; `+ Worktree` chrome hidden; branch label hidden; Git Viewer toggle hidden; synthetic Worktree row present (added by `HierarchyManager.addProject` when `gitRoot == nil`).
3. Duplicate-path banner → "Reveal existing Project" jumps to the existing row.
4. Delete a registered Project's folder → focus window → row switches to `FailedProjectRow` with "Folder no longer exists at …". (This path does NOT depend on T-WORKTREE.)
5. Restore folder, click Retry → state recovers to `.ready`.
6. `⋯` → Project Options: edit name, editor, worktrees dir; save; confirm catalog change via a second launch.
7. Drag a Project above another; reorder persists across relaunch.
8. Remove Project: dialog says "Files on disk are not affected"; confirming leaves the directory intact on disk (verify with `ls` outside the app).

**P8.2** — Push and PR:

```
git push -u origin feat/project-mgmt
gh pr create \
  --base feature/hierarchy-management \
  --title "Project Management: Add / Health / Options / Reorder" \
  --body-file <path>
```

PR body references `docs/product-specs/project-management.md`, `docs/design-docs/pm-project-management.md`, and this plan. Explicitly calls out the `reconcileDiscoveredWorktrees` stub + expected worktree-list emptiness until T-WORKTREE's PR merges.

Post `PR_READY: <url>` to master.

**P8.3** — Post-T-WORKTREE-rebase:

Once T-WORKTREE's PR lands on `feature/hierarchy-management`, rebase `feat/project-mgmt` onto the updated base. The only textual conflict target is `apps/mac/codans/App/Clients/HierarchyClient.swift` — both branches append to file end; the conflict is mechanical. Resolve by keeping both sets of closures and **removing** our stub for `reconcileDiscoveredWorktrees` in `live(manager:)` — T-WORKTREE's real binding takes over. Leave the `struct`-level property declaration in place (T-WORKTREE will have added theirs; if both exist, collapse to one).

Re-run P8.1's verification. The Add-Project happy path now populates worktrees correctly on first reconcile; the on-focus reconcile picks up worktrees added outside the app. Record results in §Surprises if anything diverges from expectations.

Commit (rebase): `chore(pm): rebase onto T-WORKTREE; drop reconcileDiscoveredWorktrees stub`

Post `PR_READY: <url>` again.

**No archived-Worktree test on this branch.** With `replaceWorktrees` removed from our scope (D9), there is no merge code here for an archived test to exercise. Equivalent coverage belongs in T-WORKTREE's test surface.

## Concrete Steps

Run from `/Users/wanggang/.worktree/repos/codans/feat/project-mgmt`.

Baseline before starting:

```
make mac-generate
make mac-lint
xcodebuild test -workspace apps/mac/codans.xcworkspace -scheme codans -configuration Debug -quiet
```

Expected: lint clean; existing sidebar + manager tests pass.

After each phase:

```
xcodebuild test -workspace apps/mac/codans.xcworkspace -scheme <scheme> -configuration Debug -quiet
```

Expected tail: `** TEST SUCCEEDED **`.

Commit at each numbered step via `/commit`; keep the phase/step ID in the commit message (e.g. `feat(pm): P0.1 …`).

PR body template (P8.2):

```
Project Management — Add / Health / Options / Reorder

Spec:   docs/product-specs/project-management.md
Design: docs/design-docs/pm-project-management.md
Plan:   docs/exec-plans/pm-project-management.md

Highlights:
- Add Project via NSOpenPanel, with git / non-git classification and
  duplicate-path guard (+ Reveal existing action).
- Transient Project.loadState (ready / loading / failed(reason)).
- ProjectReconciler on launch + window focus; Project-level failure only
  for a missing root folder.
- Worktree-list enumeration on reconcile is delegated to
  HierarchyClient.reconcileDiscoveredWorktrees (T-WORKTREE). Ships as a
  no-op stub until T-WORKTREE's PR merges.
- Project Options sheet (name / default editor / worktrees directory);
  subsumes standalone Rename sheet.
- Drag to reorder inside a Space.
- Non-git Projects suppress + Worktree, branch label, Git Viewer toggle.
- Remove Project is data-only — files on disk unaffected; dialog says so.

Coordination:
- Does not touch CodansCore/Worktree.swift (T-WORKTREE).
- Additive-only edits to HierarchyClient.swift (all at file end).
- HierarchySidebarView.swift lines 78-83 untouched.
- Post-T-WORKTREE-merge rebase: drop the no-op reconcileDiscoveredWorktrees stub.

Verification:
- make mac-lint                     → clean
- xcodebuild test … CodansCore   → ** TEST SUCCEEDED **
- xcodebuild test … codans      → ** TEST SUCCEEDED **
- xcodebuild test … CodansKit           → ** TEST SUCCEEDED **

Manual walkthrough: [paste from P8.1].
```

## Validation and Acceptance

Accepted iff all of the following hold:

1. `make mac-lint` exits 0 with no new findings relative to the branch baseline.
2. Each of the three test schemes ends with `** TEST SUCCEEDED **`.
3. Pre-existing `HierarchySidebarFeatureTests` still pass after P3.3's rename-action removal; `grep projectRename apps/mac/codans/Tests/` returns zero hits.
4. New test files present and green: `ProjectCodableTests.swift`, `ProjectReconcilerTests.swift`, `AddProjectFeatureTests.swift`, `ProjectOptionsFeatureTests.swift`; at least six new cases in `HierarchyManagerTests.swift`.
5. Manual walkthrough (P8.1) completes without regression for every bullet — noting the bullets explicitly flagged as "worktree list stays empty until T-WORKTREE rebases".
6. PR opens against `feature/hierarchy-management` (not `main`). Body links spec + design + plan.
7. Post-rebase (P8.3) re-run green. No call-site changes outside `HierarchyClient.swift`.

## Idempotence and Recovery

- All `xcodebuild test` and `make` commands are re-runnable without side effects beyond build caches.
- `make mac-generate` is safe to re-run.
- `ProjectReconciler` is idempotent by design; the consumed closure is idempotent by its contract. Repeated reconciles are a no-op after the first effective one.
- If a commit needs to be reworked, create a new follow-up commit rather than `git commit --amend`.
- `catalog.json` round-trip safety: the Codable test in P0.1 proves adding the transient field does not change persisted JSON for unchanged Projects. If that test ever fails, stop and investigate; do not ship.
- If `.onMove` in P6.1 does not work under `.listStyle(.sidebar)`, fall back to `.environment(\.editMode, .constant(.active))`; if still broken, record in §Surprises and split reorder into a follow-up PR (nice-to-have-ish; not blocking the spec's must-haves).
- If a rebase conflict in P8.3 looks non-mechanical (more than closures at file end), stop and coordinate with master before resolving.

## Artifacts and Notes

No prototyping was required — the design doc resolves the trade-offs and every dependency already exists:

- `NSOpenPanel` — standard AppKit; single `MainActor.run` inside the client.
- `FileManager.default.fileExists(atPath:)` — standard.
- `GitWorktreeCLI.discoverGitRoot` — already shipped; covered by `GitWorktreeCLITests.swift`.
- TCA `@Dependency` + `withTaskGroup` + actor single-flight — patterns used elsewhere.
- SwiftUI `ForEach.onMove` inside `.listStyle(.sidebar)` — documented.

Branch base: `feature/hierarchy-management`. All PRs target that, not `main`.

## Interfaces and Dependencies

In `apps/mac/CodansCore/Project.swift`:

```swift
public enum ProjectLoadState: Equatable, Sendable {
  case loading
  case ready
  case failed(reason: String)
}

public struct Project: Equatable, Codable, Sendable, Identifiable {
  // existing fields
  public var loadState: ProjectLoadState   // transient (not encoded)
}
```

In `apps/mac/codans/Runtime/HierarchyManager.swift`, the four new methods from P0.2 must exist with the shown signatures. No `replaceWorktrees`.

In `apps/mac/codans/App/Clients/HierarchyClient.swift`, the struct gains the four **owned** closures from P0.3 plus the **consumed** `reconcileDiscoveredWorktrees` closure (with a no-op `liveValue` stub on this branch). All additions at file end.

In `apps/mac/codans/App/Clients/FolderPickerClient.swift` (new file): `nonisolated struct FolderPickerClient: Sendable { var pick: @MainActor @Sendable (_ prompt: String) async -> URL? }` exposed via `DependencyValues.folderPickerClient`.

In `apps/mac/codans/Runtime/ProjectReconciler.swift` (new file): `actor ProjectReconciler` with `reconcile(projectID:spaceID:)` and `reconcileAll(debounceSeconds:)`. Exposed via `DependencyValues.projectReconciler`. Constructed with `HierarchyClient` + a clock; **no** `GitWorktreeCLI`, **no** scanner protocol.

In `apps/mac/codans/App/Features/HierarchySidebar/AddProjectFeature.swift` (new file): `@Reducer struct AddProjectFeature` with state / actions per design doc §AddProjectFeature, nested `enum Delegate: Equatable { case projectAdded(ProjectID, SpaceID); case revealExisting(SpaceID, ProjectID) }`. Uses `GitWorktreeCLI.discoverGitRoot` at add-time only.

In `apps/mac/codans/App/Features/ProjectOptions/ProjectOptionsFeature.swift` (new file): `@Reducer struct ProjectOptionsFeature` per design doc §ProjectOptionsFeature.

In `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarFeature.swift`:

- **Remove** state field `renameProjectSheet: RenameProjectSheet?`.
- **Remove** actions `.projectRenameTapped`, `.projectRenameDraftChanged`, `.projectRenameConfirmed`, `.projectRenameCancelled`.
- **Remove** struct `RenameProjectSheet`.
- **Add** state field `projectOptionsSheet: ProjectOptionsSheet?` (payload has `(projectID, spaceID)`).
- **Add** actions `.projectOptionsTapped(projectID:, inSpace:)`, `.retryProjectTapped(projectID:, inSpace:)`, `.reorderProjects(from:, to:, inSpace:)`, `.addProject(AddProjectFeature.Action)`, `.projectOptions(ProjectOptionsFeature.Action)`.
- **Extend** `Delegate` enum with `reconcileProjectRequested(ProjectID, SpaceID)`.

In `apps/mac/codans/App/Features/Root/RootFeature.swift`:

- Add `@Dependency(ProjectReconciler.self)`.
- Extend `.onLaunch` merge with reconciler.reconcileAll + NSApplication.didBecomeActive subscription.
- Handle `case .sidebar(.delegate(.reconcileProjectRequested(let pid, let sid))):` → run reconcile for that Project.

In `apps/mac/codans/App/Features/WorktreeHeader/WorktreeHeaderView.swift`, the struct gains `let supportsWorktrees: Bool`; branch `Label` and `HeaderGitViewerToggle` are gated on it. `WorktreeDetailView` passes the value.

In `apps/mac/codans/App/Features/HierarchySidebar/FailedProjectRow.swift` (new file): the view in P7.1.

**Out of scope for this plan** (from spec):

- Clone from URL.
- `git init` on an empty folder.
- Drag-from-Finder add-project shortcut.
- Per-Project description / tooltip.
- Undo-remove toast.
- Per-Project section collapse memory per Space.
- Any change to `Worktree.swift`, `Space.swift`, or `HierarchySidebarView.swift` lines 78-83 (T-WORKTREE territory).
- Worktree-list enumeration / merge / per-Worktree staleness (T-WORKTREE).
- Archived-Worktree merge test (was previously planned — dropped with `replaceWorktrees` removal; equivalent coverage belongs to T-WORKTREE).
