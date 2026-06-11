# ExecPlan: Worktree Reorder Primitives in Catalog Layer

**Status:** Completed
**Author:** Gump (sub-agent feat/worktree-reorder-catalog)
**Date:** 2026-04-26

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

Land the catalog-layer primitives required by the four-segment Worktree sidebar ordering rule: a segment-aware `reorderWorktrees` API, a `createWorktree` insertion point that places new rows at the top of the unpinned segment, and a `setWorktreePinned` whose flag flip carries explicit positioning (Pin → end of pinned segment, Unpin → top of unpinned segment). After this lands, task02 (sidebar feature wiring) can forward `ForEach.onMove` and the right-click Pin/Unpin actions through `HierarchyClient` without re-deriving section math at the call site.

This work does not ship any user-visible behavior on its own; it ships a closure that task02 will hook into the sidebar `ForEach.onMove` modifier and an enum that names the two reorderable segments. The validation surface is unit tests on `HierarchyManager` and `HierarchyClient`.

The design rationale, segment semantics, alternatives considered, and the rejected `Worktree.sortIndex` approach are captured in `docs/design-docs/worktree-sidebar-ordering.md` (commit 1f714b3, on `main`); this plan inherits all of those decisions and does not re-litigate them. Per master's instruction, no separate design doc is written for this slice.

## Progress

- [x] Add `WorktreeSegment` enum (in `HierarchyManager.swift`, alongside `HierarchyError`) — 2026-04-26
- [x] Add `unpinnedBoundary(in:rootPath:)` private static helper — 2026-04-26
- [x] Change `HierarchyManager.createWorktree` insertion point to the unpinned-segment boundary — 2026-04-26
- [x] Change `HierarchyManager.setWorktreePinned` to carry pin/unpin positioning — 2026-04-26
- [x] Implement `HierarchyManager.reorderWorktrees(in:inSpace:segment:from:to:)` with all-or-nothing validation — 2026-04-26
- [x] Append `reorderWorktrees` closure to `HierarchyClient` (live, liveValue, testValue) — 2026-04-26
- [x] Tests: reorder happy path within each segment — 2026-04-26
- [x] Tests: reorder out-of-range from/to leaves catalog untouched — 2026-04-26
- [x] Tests: createWorktree lands at unpinned segment top — 2026-04-26
- [x] Tests: Pin moves to pinned segment end; Unpin moves to unpinned segment top — 2026-04-26
- [x] Run `make mac-build` clean (lint pre-existing failures on main, see below) — 2026-04-26

## Surprises & Discoveries

- **Test build artifact reuse**: `xcodebuild test-without-building` against an artefact from a different branch can produce phantom failures (signal SEGV during pre-test bootstrap, or stale test bundle). Always run `xcodebuild ... test` (with build) when switching between branches that share `DerivedData`.
- **Pre-existing flaky tests on `main`**: 8 tests fail on `main` independently of this slice — `HierarchyManagerTests/drainLegacyOverrides*` (3) and 5 in `HierarchySidebarFeatureTests` (the latter trip an `Unimplemented: GitHubClient.batchPullRequests` because the reducer subscribes to a GitHub PR effect that the tests don't stub). Verified by running each suite from `/Users/wanggang/dev/00/codans` (commit `1f714b3`, `main`) — same failures. Not in scope for this PR.
- **Pre-existing lint violation**: `HierarchyClient.swift` has an `async_without_await` violation on `runScript` that exists on `main` too. Not introduced by this slice.
- **Build prerequisite**: This worktree's `apps/mac/.build/ghostty` must symlink to a prebuilt copy (e.g., from `/Users/wanggang/dev/00/codans/apps/mac/.build/ghostty`) to avoid the ~20 minute Zig + xcframework build. The symlink is per-worktree local state and not committed.

## Decision Log

- **Closure shape: `(IndexSet, Int)` rather than `[WorktreeID]`.** The bootstrap pre-decides this signature so it mirrors `reorderProjects` (which already takes `IndexSet, Int`) and so SwiftUI's `ForEach.onMove` can forward without translation in task02. Validation against missing IDs degenerates to "any `from` offset out of range, or `to` out of range" given the segment is recomputed from the current catalog snapshot.
- **`WorktreeSegment` placement: in `HierarchyManager.swift`.** It is a runtime-layer concept (a partition of `Project.worktrees` for ordering purposes), not a model field; placing it next to the manager keeps it out of `CodansCore.Worktree` per the bootstrap's "no model-field changes" hard constraint. Re-export not required — the `HierarchyClient` file already imports `CodansCore` and the manager's module.
- **`setWorktreePinned` keeps its existing `(WorktreeID, Bool)` signature.** The task allows changing it but does not require it. The HierarchySidebar feature is hands-off (hard constraint), so changing the signature would break the call at `HierarchySidebarFeature.swift:611` without being able to fix that file. The behavioral upgrade (positioning) happens internally.
- **Boundary algorithm: scan from index 0 for the first row matching the unpinned-segment predicate.** Archived rows are skipped so they do not shift the boundary. See `boundaryIndex(in:project:excluding:)` in Interfaces below.

## Outcomes & Retrospective

Completed 2026-04-26. Six commits land the catalog primitives: `WorktreeSegment` enum, `unpinnedBoundary` helper, `createWorktree` insertion at the unpinned-segment top, `setWorktreePinned` repositioning to the segment boundary, `reorderWorktrees(...)` with all-or-nothing validation, the `HierarchyClient.reorderWorktrees` closure, and 14 + 1 tests. `make mac-build` and the new test suite are green; pre-existing main-branch failures (drainLegacy + sidebar/GitHubClient) are out of scope.

Task02 (sidebar feature wiring) can now consume the closure surface defined in `HierarchyClient`; no further hierarchy-layer work is required for the four-segment ordering rule.

## Context and Orientation

Related documents:

- **Design doc (parent, authoritative for high-level design and contract):** `docs/design-docs/worktree-sidebar-ordering.md`. Read §段语义详述, §Component Boundaries, §Data Storage, §Pending 段成立所需的实现影响 item 6, §Alternatives Considered §1 before reading this plan.
- **Architecture doc:** `docs/architecture.md` (HierarchyManager runtime layer, TCA Clients DI bridge).
- **Worktree management exec plan (precedent for similar work):** `docs/exec-plans/0010-worktree-management.md`.

Key source files:

- `apps/mac/codans/Runtime/HierarchyManager.swift` — `@Observable` runtime that owns the `Catalog`. All catalog mutations flow through it; persistence is a debounced atomic-rename JSON via `store.scheduleSave(catalog)`.
- `apps/mac/codans/App/Clients/HierarchyClient.swift` — TCA dependency-injection bridge. Every public manager command has a `@MainActor @Sendable` closure here, plus `liveValue` / `testValue` entries.
- `apps/mac/codans/Tests/HierarchyManagerWorktreeMgmtTests.swift` — pattern reference for manager-level tests; uses `FakeHierarchyRuntime` + a temp-file `CatalogStore` per test.
- `apps/mac/codans/Tests/HierarchyClientTests.swift` — pattern reference for client-level tests.

Terms used in this plan:

- **Segment:** one of the four sidebar partitions defined by the parent design — `main`, `pinned`, `pending`, `unpinned`. Of these, only `pinned` and `unpinned` are reorderable; `main` is at most one row, `pending` is sidebar-feature in-memory state and not in the catalog.
- **Boundary index:** the position in `Project.worktrees` where the unpinned segment begins. Computed as the first index whose row is non-archived, not the main checkout, and `isPinned == false`. Used as the insertion point for both new worktrees and unpin moves, and as the destination for pin moves (which become "the new last pinned row").
- **Catalog array:** `Project.worktrees: [Worktree]`. Per the parent design's central trade-off, segment-internal order is identical to the catalog array's relative order within that segment; there is no separate `sortIndex` field.

How the parts fit together: `HierarchyManager` owns the catalog and exposes pure mutations; `HierarchyClient` wraps each mutation in a `@MainActor @Sendable` closure so TCA reducers can depend on the closure-bag rather than the live manager. Sidebar features (HierarchySidebarFeature, in task02's scope) consume the client closure. This task ends where task02 begins — at the closure surface.

## Plan of Work

The work is a single thin vertical slice across three files plus tests. It lands in one PR. Order of edits below matches the order to write so the Swift compiler stays happy at each save.

**Step 1 — Define `WorktreeSegment`.** In `apps/mac/codans/Runtime/HierarchyManager.swift`, immediately above the existing `enum HierarchyError` (top of file, around line 5), add:

```swift
enum WorktreeSegment: Sendable, Equatable {
  case pinned
  case unpinned
}
```

The enum is `Sendable` because it crosses the `@MainActor @Sendable` closure boundary in `HierarchyClient`. No methods on it; it is a tag.

**Step 2 — Add a private helper for the unpinned-segment boundary.** Inside `HierarchyManager`, in the `// MARK: - Helpers` block at the bottom of the file (alongside `findProjectIndices`), add:

```swift
/// Index in `worktrees` where the unpinned segment begins. Defined as the
/// first index whose row would render in the unpinned segment of the
/// sidebar (non-archived, not the main checkout, not pinned). Archived
/// and pinned rows in the middle of the array do not shift the boundary.
/// Returns `worktrees.count` when no unpinned row exists.
private static func unpinnedBoundary(
  in worktrees: [Worktree],
  rootPath: String
) -> Int {
  for (i, w) in worktrees.enumerated() {
    if !w.archived && !w.isPinned && w.path != rootPath { return i }
  }
  return worktrees.count
}
```

Pure, static, no actor hop — convenient for unit testing later if we ever want to.

**Step 3 — Change `createWorktree` insertion point.** In the same file, replace the `worktrees.append(worktree)` line (around line 271) with an insert at the boundary:

```swift
let boundary = Self.unpinnedBoundary(
  in: catalog.spaces[spaceIndex].projects[projectIndex].worktrees,
  rootPath: catalog.spaces[spaceIndex].projects[projectIndex].rootPath
)
catalog.spaces[spaceIndex].projects[projectIndex].worktrees.insert(worktree, at: boundary)
```

The selected-id and `scheduleSave` lines below stay unchanged. Note: this also affects the synthetic main worktree path (the `addProject(gitRoot: nil)` branch creates the main row directly, not via `createWorktree`), so that path is untouched.

Audit: `reconcileDiscoveredWorktrees` also calls `worktrees.append(worktree)` (around line 431). The bootstrap scopes the change to `createWorktree`; reconcile-appended rows continue to land at the catalog tail. This is the existing behavior and the parent design doc does not call it out as a target. Recording in Decision Log; not changing.

**Step 4 — Upgrade `setWorktreePinned` with positioning.** Replace the body (currently around lines 366–379) with logic that flips the flag AND moves the row in the catalog array. After flipping, compute `unpinnedBoundary` over the post-flip array, then `move` the row.

For Pin (`isPinned: true`): destination offset is `boundary` (move past all current pinned rows; the row lands as last pinned because boundary is the first non-pinned-section index, so `move` inserts right after the last pinned row).

For Unpin (`isPinned: false`): destination offset is `boundary` over the array AFTER flipping. After flipping the row's `isPinned` to false, that row itself becomes a candidate for the boundary. `unpinnedBoundary` will return the index of the moving row (or earlier, if there is an earlier unpinned row). Apply `move(fromOffsets: [currentIndex], toOffset: boundary)`. SwiftUI/Array semantics: `move(fromOffsets: [i], toOffset: i)` is a no-op, which is correct when the moving row is already at boundary; `move(fromOffsets: [i], toOffset: j)` with `j > i` lands the element at `j - 1` after removal, which is the desired "right at the boundary" position. Worked through cases in the parent design's mental model and confirmed against four scenarios in the test list below.

Idempotency: keep the existing `guard project.worktrees[worktreeIndex].isPinned != isPinned else { return }` guard so toggling to the current value remains a silent no-op (no churn, no save). This means a Pin operation on an already-pinned row will NOT re-position it — matches today's contract for the `setWorktreePinned` flag flip and avoids surprising "Pin re-runs reorder" UX.

**Step 5 — Implement `reorderWorktrees`.** After `setWorktreePinned`, add:

```swift
/// Reorder rows within a single sidebar segment. SwiftUI `.onMove` gives
/// segment-relative `IndexSet` and target offset; this method translates
/// those into a catalog-array mutation that preserves the positions of
/// rows in other segments. All-or-nothing: if any `from` offset or `to`
/// is out of segment range, the whole reorder is dropped (silent no-op,
/// no save). Missing project is `.notFound`.
func reorderWorktrees(
  in projectID: ProjectID,
  inSpace spaceID: SpaceID,
  segment: WorktreeSegment,
  from source: IndexSet,
  to destination: Int
) throws {
  guard let (spaceIndex, projectIndex) = findProjectIndices(projectID: projectID, spaceID: spaceID) else {
    throw HierarchyError.notFound("Project \(projectID)")
  }
  let project = catalog.spaces[spaceIndex].projects[projectIndex]
  let predicate: (Worktree) -> Bool = { w in
    guard !w.archived, w.path != project.rootPath else { return false }
    switch segment {
    case .pinned:   return w.isPinned
    case .unpinned: return !w.isPinned
    }
  }
  let segmentCatalogIndices = project.worktrees.indices.filter { predicate(project.worktrees[$0]) }
  let segmentCount = segmentCatalogIndices.count
  guard source.allSatisfy({ $0 >= 0 && $0 < segmentCount }) else { return }
  guard destination >= 0 && destination <= segmentCount else { return }
  guard !source.isEmpty else { return }
  var segmentRows = segmentCatalogIndices.map { project.worktrees[$0] }
  segmentRows.move(fromOffsets: source, toOffset: destination)
  for (k, catalogIdx) in segmentCatalogIndices.enumerated() {
    catalog.spaces[spaceIndex].projects[projectIndex].worktrees[catalogIdx] = segmentRows[k]
  }
  store.scheduleSave(catalog)
}
```

The "missing ID" check from the parent design's risk table maps onto the offset-range check here: a stale `IndexSet` produced from a snapshot taken before a row was removed has out-of-range offsets, so the guards drop the whole operation and no partial application happens.

**Step 6 — Add `HierarchyClient.reorderWorktrees` closure.** In `apps/mac/codans/App/Clients/HierarchyClient.swift`:

1. Append a struct field at the end of the struct definition (after `removeWorktreeWithLifecycle` around line 361). Place under a new `// MARK: - Worktree sidebar ordering (task01)` to keep grep-able:

```swift
var reorderWorktrees:
  @MainActor @Sendable (
    _ projectID: ProjectID, _ inSpace: SpaceID,
    _ segment: WorktreeSegment, _ from: IndexSet, _ to: Int
  ) throws -> Void
```

2. Add a corresponding entry in `live(manager:settings:gitWorktreeClient:)` (last position, just before the closing `)` of `HierarchyClient(...)` around line 641):

```swift
reorderWorktrees: { projectID, spaceID, segment, from, to in
  try manager.reorderWorktrees(
    in: projectID, inSpace: spaceID,
    segment: segment, from: from, to: to
  )
}
```

3. Add a corresponding entry in `liveValue` (around line 901) and `testValue` (around line 982). Match the style already used:

```swift
// liveValue
reorderWorktrees: { _, _, _, _, _ in
  fatalError("HierarchyClient.liveValue not configured")
}

// testValue
reorderWorktrees: unimplemented("HierarchyClient.reorderWorktrees")
```

Order: append at the end of each initializer's argument list. The Swift compiler is positional with named labels here — placing it last keeps diffs minimal and matches the pattern used by previous additions like `removeWorktreeWithLifecycle`.

**Step 7 — Tests.** Add a new `apps/mac/codans/Tests/HierarchyManagerReorderTests.swift` (manager-level coverage) and extend `apps/mac/codans/Tests/HierarchyClientTests.swift` (client-level smoke). Test cases below in Validation.

**Verification gate after each step:** the build must compile after step 5 (manager surface is now complete) and after step 6 (client surface complete). Tests come at step 7. `make mac-build` and `make mac-lint` must be green before push.

## Concrete Steps

Working directory for all commands: `/Users/wanggang/.worktree/repos/codans/feat/worktree-reorder-catalog`.

```bash
# Build (incremental). Expected: BUILD SUCCEEDED, no warnings introduced.
make mac-build

# Lint. Expected: empty output (--quiet mode).
make mac-lint

# Run the new tests.
# Expected (from Tests output):
#   ✔ HierarchyManagerReorderTests passed
#   (counts vary; all green)
xcrun xcodebuild -workspace apps/mac/codans.xcworkspace \
  -scheme codans-tests -destination 'platform=macOS' test 2>&1 | xcsift
```

If `xcsift` is unavailable, fall back to `| xcbeautify`. Both are pinned in mise per `apps/mac/.mise.toml`.

After tests pass:

```bash
git status                       # confirm only the four expected files are modified/new
git add apps/mac/codans/Runtime/HierarchyManager.swift \
        apps/mac/codans/App/Clients/HierarchyClient.swift \
        apps/mac/codans/Tests/HierarchyManagerReorderTests.swift \
        apps/mac/codans/Tests/HierarchyClientTests.swift \
        docs/exec-plans/worktree-reorder-catalog.md
# Commit cadence per project memory: small commits via /commit after each step.
```

## Validation and Acceptance

A passing run of `xcodebuild test` on the `codans-tests` scheme that exercises the cases below is the acceptance signal.

In `HierarchyManagerReorderTests.swift`:

1. **`reorderWorktreesPinnedHappyPath`** — Setup: project with main + 3 pinned (`p1, p2, p3`) + 1 unpinned. Call `reorderWorktrees(.pinned, from: [0], to: 3)` to move `p1` to the end of the pinned segment. Assert pinned-segment view order is `p2, p3, p1` and the catalog non-pinned rows have not shifted. Also assert `unpinned1` is still in the catalog at the same relative position.
2. **`reorderWorktreesUnpinnedHappyPath`** — Setup: main + 1 pinned + 3 unpinned (`u1, u2, u3`). Call `reorderWorktrees(.unpinned, from: [2], to: 0)` to move `u3` to the top of the unpinned segment. Assert unpinned view order is `u3, u1, u2`.
3. **`reorderWorktreesOutOfRangeFromIsNoOp`** — Setup: main + 2 pinned. Snapshot the catalog. Call `reorderWorktrees(.pinned, from: [5], to: 0)`. Assert catalog is bytewise unchanged (same row IDs in same order).
4. **`reorderWorktreesOutOfRangeToIsNoOp`** — Same setup; call `reorderWorktrees(.pinned, from: [0], to: 99)`. Assert no change.
5. **`reorderWorktreesEmptyFromIsNoOp`** — Same setup; call with empty IndexSet. Assert no change.
6. **`reorderWorktreesUnknownProjectThrows`** — Construct a `ProjectID()` not in the catalog; assert `HierarchyError.notFound` is thrown.
7. **`createWorktreeLandsAtUnpinnedTopBoundary`** — Setup: main + 2 pinned + 3 unpinned. Create a new worktree (no explicit pin). Assert the new row's catalog index is exactly `1 + 2 = 3`. Assert the row right before it is the last pinned, and the row right after is the previous first unpinned.
8. **`createWorktreeFirstUnpinnedRow`** — Setup: main only (no pinned, no unpinned). Create a new worktree. Assert it lands at index 1.
9. **`createWorktreeWithOnlyArchivedRowsLandsAtTail`** — Setup: main + 1 archived unpinned (manually toggled). Create a new worktree. Assert it lands at index 2 (i.e. after the archived row, since the archived row's `path != rootPath && !isPinned` makes it match the boundary predicate ONLY if `!archived` — the helper skips archived, so the boundary is `worktrees.count == 2`). This pins down the archived-row corner case.
10. **`pinMovesToPinnedEnd`** — Setup: main + 2 pinned (`p1, p2`) + 1 unpinned (`u1`). Call `setWorktreePinned(u1, true)`. Assert catalog order is `main, p1, p2, u1` (the formerly-unpinned row is now last pinned).
11. **`pinIdempotentDoesNotMove`** — Setup: main + 2 pinned (`p1, p2`) + 0 unpinned. Call `setWorktreePinned(p1, true)`. Assert catalog order is unchanged (idempotency guard).
12. **`unpinMovesToUnpinnedTop`** — Setup: main + 2 pinned (`p1, p2`) + 2 unpinned (`u1, u2`). Call `setWorktreePinned(p1, false)`. Assert catalog order is `main, p2, p1, u1, u2` — `p1` flipped and landed at unpinned-segment top.
13. **`unpinAlreadyUnpinnedDoesNotMove`** — Setup: main + 1 pinned + 2 unpinned. Call `setWorktreePinned(u1, false)`. Assert catalog unchanged (idempotency).

In `HierarchyClientTests.swift`, add one client-level smoke test that calls `client.reorderWorktrees` against a live manager and asserts the catalog reflects the move — exercising the closure wiring, not the algorithm (already covered above).

Local manual verification: not applicable. This is a pure catalog API; no UI touches in this slice.

## Idempotence and Recovery

Steps 1–6 are pure file edits. Re-running the build after a partial save is safe — Swift will surface compile errors and the next save fixes them. `make mac-build` is incremental; re-running is cheap.

If a test fails on the first green run, prefer adding the missing case to `HierarchyManagerReorderTests` over loosening assertions; the tests are the contract for task02.

If the working tree gets confused between steps:

```bash
git diff apps/mac/codans/Runtime/HierarchyManager.swift
git diff apps/mac/codans/App/Clients/HierarchyClient.swift
```

`git restore <path>` to revert single files without losing other progress.

No persistent state is created or removed by this work. The schema version in `catalog.json` is unchanged. Existing on-disk catalogs continue to load.

## Artifacts and Notes

Key snippet — boundary algorithm walked through one tricky scenario (verifying the unpin no-op case in test 13):

```
Setup: catalog = [main, p1, u1, u2]
Call: setWorktreePinned(u1, false)  // u1 is already unpinned

Existing guard: project.worktrees[2].isPinned (false) != false (false) → equal → return.
Idempotency holds; no flag flip, no boundary recomputation, no move.
catalog stays [main, p1, u1, u2]. ✓
```

And the move-to-itself case (verifying test 11 prerequisites):

```
Setup: catalog = [main, p1, p2]
Call: setWorktreePinned(p1, true)  // p1 already pinned
Idempotency guard returns early. catalog unchanged. ✓
```

## Interfaces and Dependencies

After this work, the following must exist:

In `apps/mac/codans/Runtime/HierarchyManager.swift`:

```swift
enum WorktreeSegment: Sendable, Equatable {
  case pinned
  case unpinned
}

extension HierarchyManager {
  func reorderWorktrees(
    in projectID: ProjectID,
    inSpace spaceID: SpaceID,
    segment: WorktreeSegment,
    from source: IndexSet,
    to destination: Int
  ) throws
}
```

`HierarchyManager.createWorktree` keeps its existing signature; the body inserts at `unpinnedBoundary` instead of appending. `HierarchyManager.setWorktreePinned` keeps its existing signature `(WorktreeID, Bool) -> Void` and behaviorally also performs a position move on flag transitions (no move on idempotent calls).

In `apps/mac/codans/App/Clients/HierarchyClient.swift`:

```swift
nonisolated struct HierarchyClient: Sendable {
  // ...existing fields...

  var reorderWorktrees:
    @MainActor @Sendable (
      _ projectID: ProjectID, _ inSpace: SpaceID,
      _ segment: WorktreeSegment, _ from: IndexSet, _ to: Int
    ) throws -> Void
}
```

`liveValue` traps with the standard "not configured" `fatalError`; `testValue` uses `unimplemented("HierarchyClient.reorderWorktrees")`.

No new third-party dependencies. No changes to the persisted JSON schema (no new `Worktree` fields). No changes to `CodansCore`.

The contract surface task02 will consume:

1. `WorktreeSegment` enum — passed by sidebar reducer when forwarding `ForEach.onMove`.
2. `HierarchyClient.reorderWorktrees` — the only reorder entry point; `try manager.reorderWorktrees(...)` may throw `HierarchyError.notFound` for stale `ProjectID` lookups.
3. `HierarchyClient.setWorktreePinned` — same signature, upgraded behavior. Task02's right-click Pin/Unpin handlers call it without change.
4. `HierarchyClient.createWorktree` / `createWorktreeWithGit` / `createWorktreeWithLifecycle` — same signatures, new rows now appear at the unpinned-segment top.
