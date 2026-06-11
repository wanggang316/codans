# ExecPlan: Main-Window T0 — Foundation & Contracts

**Status:** Draft
**Author:** Gump (T0 sub-agent, via Claude)
**Date:** 2026-04-21

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this change, sibling agents can build the new Sidebar (T1), Header bell (T2), and Git Viewer overlay (T3) against a frozen contract: the Catalog can persist Space-scoped last-active-Worktree and per-Worktree Git-Viewer visibility; the notification inbox can be queried by Worktree/Project/Space without every caller re-implementing the `PaneID → WorktreeID` join; and `ContentView` no longer carries the Hierarchy ↔ Inbox sidebar-mode Picker. End-users see no visual difference from T0 alone except for the missing mode-toggle segmented control in the sidebar toolbar.

## Progress

- [x] M1 — Catalog model extensions (Space.lastActiveWorktreeID, Worktree.gitViewerVisible) with explicit Codable + backward-compat tests (2026-04-21)
- [x] M2 — HierarchyManager mutation API (setSpaceLastActiveWorktree, setWorktreeGitViewerVisible) + tests (2026-04-21)
- [x] M3 — Catalog pane/worktree resolution helpers (worktreeID(forPane:), paneIDs(inWorktree:)) + tests (2026-04-21)
- [x] M4 — NotificationInbox pure aggregation helpers (unreadCount / hasUnread ×2 / notifications) + tests (2026-04-21)
- [x] M5 — InboxStore markRead(forWorktree:in:) and dismissAll() + tests (2026-04-21)
- [x] M6 — ContentView drop sidebar mode Picker; RootFeature doc-comment only (state kept) (2026-04-21)
- [ ] M7 — Local verification: lint + all test schemes; push branch; open PR to feature/main-window; post PR_READY (in progress — lint passes after suppression commit; all three test schemes green; push + PR pending)

## Surprises & Discoveries

- **M1 pre-T0 fixture** (2026-04-21): hand-crafted JSON in `decodesPreT0JSONWithDefaults` failed because `SpaceID`/`ProjectID`/`WorktreeID` serialize as `{"raw": "uuid-str"}`, not as a bare string. Rewrote the test to build the catalog in memory, encode it, then strip the two new keys via `JSONSerialization` round-trip. Keeps the test resilient to future ID shape changes.
- **M1 ghostty prebuild** (2026-04-21): first `make mac-generate` in this worktree failed at the Ghostty build step (remote tarball returned 400). Worked around by copying the entire `.build/ghostty/` cache (`fingerprint` file, `GhosttyKit.xcframework`, `share/`, `include/`, `lib/`) from the canonical checkout at `/Users/wanggang/dev/00/codans/apps/mac/.build/ghostty/`. The build-ghostty.sh script fingerprint check then short-circuits. Not a code issue.
- **M2 preexisting filename collision** (2026-04-21): `xcodebuild test -scheme codans` failed to build with *"filename SettingsStoreTests.swift used twice"*. Commit 5d1eb42 renamed the production `SettingsStore.swift` → `NotificationSettingsStore.swift` but missed the test file, leaving duplicate basenames in the `codansTests` target. Renamed `Tests/NotificationsTests/SettingsStoreTests.swift` → `NotificationSettingsStoreTests.swift` and its struct to match. Separate `fix(tests):` commit, not in any T0 milestone.
- **M7 preexisting lint errors** (2026-04-21): `make -C apps/mac lint` failed on two `async_without_await` violations in `apps/mac/CodansKit/Transport/{UnixSocketTransport,RPCClient}.swift` (both blame to 2026-04-20, before T0). Verified by `git stash` — errors reproduce without T0 changes. Escalated via `CLARIFY`; master chose option B (suppress to unblock + document in PR). Added `// swiftlint:disable`/`:disable:next` annotations with a follow-up comment naming the real fix (a separate CodansKit concurrency audit). Landed as `chore(CodansKit): suppress pre-existing async_without_await lint to unblock T0 PR`.

## Decision Log

- **D1**: Keep `Catalog.version = 1` (additive Codable, no bump). Follow-up if a non-additive field lands.
- **D2**: Aggregation helpers take `Catalog` as an explicit parameter (pure functions on CodansCore) rather than holding a captured resolver. Explicit dependency > hidden state, and CodansCore stays MainActor-free.
- **D3**: `SidebarMode` / `sidebarMode` / `.inbox` Scope stay in `RootFeature` with an updated doc-comment reserving them for T2. Delete-then-re-add is churn.
- **D4**: `dismissAll` is the canonical name per the design brief; existing `clearAll` stays as a legacy alias to avoid C6 M5 caller churn — tracked via doc-comment so T2 can collapse them.
- **D5** (per master feedback 2026-04-21, corrected): the *"T2 must either reuse or remove"* tracking note applies **only** to the plumbing that becomes dead when M6 deletes the sidebar-mode Picker — i.e. `SidebarMode` enum, `RootFeature.State.sidebarMode`, `.sidebarModeChanged` action, and the `.inbox` Scope / `state.inbox`. The new setters (`setSpaceLastActiveWorktree`, `setWorktreeGitViewerVisible`) are **live** long-lived APIs — T1/T3 call them in their final form — so they carry ordinary semantic doc-comments (what they mean, which persistence path they take, idempotence behavior), not disposal hints.
- **D6** (per master feedback 2026-04-21): doc-comments on the four aggregation helpers carry a perf note: *"render-hot paths should cache a snapshot-scoped index"*.
- **D7** (per master feedback 2026-04-21): `dismissAll` doc-comment: *"canonical name; `clearAll` is a legacy alias kept to avoid C6 M5 churn, may be removed in T2."*

## Outcomes & Retrospective

**2026-04-21 — M1 through M6 landed; M7 push + PR outstanding.**

Shipped:
- Catalog model fields (`Space.lastActiveWorktreeID`, `Worktree.gitViewerVisible`) with backward-compatible Codable.
- HierarchyManager setters (`setSpaceLastActiveWorktree`, `setWorktreeGitViewerVisible`) on the standard debounced save pipeline.
- Catalog resolution helpers (`worktreeID(forPane:)`, `paneIDs(inWorktree:)`).
- Pure NotificationInbox aggregation (`unreadCount`, two `hasUnread`, `notifications(forWorktree:)`) with the render-hot perf note baked into every doc-comment.
- InboxStore `markRead(forWorktree:in:)` and canonical `dismissAll` (forwards to legacy `clearAll`).
- ContentView Picker removed; sidebar always renders hierarchy; `SidebarMode` / `.sidebarModeChanged` / `.inbox` Scope kept with "T2 must either reuse or remove" notes.

Gaps / deferred:
- No stale-reference pruning for `Space.lastActiveWorktreeID` if the referenced Worktree is removed — design doc §Goals punts this to the Space-switcher feature.
- `clearAll` stays as a legacy alias of `dismissAll` until T2 chooses to collapse them.
- `SidebarMode` / `state.sidebarMode` / `.sidebarModeChanged` / `state.inbox` / `.inbox` Scope are dead plumbing marked for T2 to reuse or remove.
- CodansKit `async_without_await` suppressions are temporary — a follow-up concurrency audit removes the keywords or consolidates the API.

Lessons:
- Auditing the base branch's lint state before starting would have surfaced the `async_without_await` violations earlier. Worth a quick `make mac-lint` at the start of every feature sub-branch.
- The pre-T0 filename collision on `SettingsStoreTests` is a reminder that Tuist's `buildableFolders` recursion can silently allow basename clashes; a later hygiene pass could enforce unique basenames.
- The `[PaneID: WorktreeID]` index is the natural caching boundary for per-frame aggregation — design the T1/T2 bell/sidebar render paths around building it once per catalog snapshot.

## Context and Orientation

Related documents:
- Product spec: `docs/product-specs/ui-main-window-redesign.md`
- Design doc: `docs/design-docs/mw-t0-foundation.md`
- Architecture doc: `docs/architecture.md`

Key source files:

- `apps/mac/CodansCore/Space.swift` — Space value type; gains `lastActiveWorktreeID` and explicit Codable. Currently 20 lines, no custom Codable.
- `apps/mac/CodansCore/Worktree.swift` — Worktree value type; gains `gitViewerVisible` and explicit Codable. Currently 26 lines, no custom Codable.
- `apps/mac/CodansCore/Catalog.swift` — Already uses explicit Codable (version-gated); gets two new helpers (`worktreeID(forPane:)`, `paneIDs(inWorktree:)`).
- `apps/mac/CodansCore/Notifications/NotificationInbox.swift` — Pure inbox projection; gains four aggregation helpers.
- `apps/mac/codans/Runtime/HierarchyManager.swift` — `@MainActor @Observable`; gains two mutation methods that go through the existing `store.scheduleSave(catalog)` pipeline (same shape as `renameSpace`, `selectProject`).
- `apps/mac/codans/Notifications/InboxStore.swift` — `@MainActor` actor-equivalent; gains `markRead(forWorktree:in:)` and `dismissAll`. Uses existing `scheduleSave` + `publishMutation`.
- `apps/mac/codans/App/ContentView.swift` — Drops `modeTogglePicker` and the `switch store.sidebarMode` in `sidebarColumn`; always renders `HierarchySidebarView`.
- `apps/mac/codans/App/Features/Root/RootFeature.swift` — `SidebarMode` enum, `state.sidebarMode`, `.sidebarModeChanged`, and `.inbox` Scope remain; doc-comments updated per D5.

Test targets:

- `apps/mac/CodansCoreTests/CatalogCodableTests.swift` — extend with backward-compat decode + new-field round-trip.
- `apps/mac/CodansCoreTests/NotificationInboxTests.swift` — extend with aggregation tests (new cases).
- `apps/mac/codans/Tests/HierarchyManagerTests.swift` — extend with two mutation tests.
- `apps/mac/codans/Tests/NotificationsTests/InboxStoreTests.swift` — extend with `markRead(forWorktree:in:)` + `dismissAll` tests.

Orientation: work moves from innermost layer (pure Codable in CodansCore) outward (HierarchyManager / InboxStore in the app module) and finishes with the UI-layer deletion. Each milestone is independently verifiable and leaves the project compiling and green. No cross-module edits are batched: Codable extensions land before aggregation helpers that depend on them, and helpers land before the app-layer glue that calls them.

## Plan of Work

### Milestone 1 — Catalog model extensions

Goal: at the end of M1 the `Space` / `Worktree` structs carry the two new fields, round-trip through JSON, and decode old (pre-T0) JSON with defaults.

In `apps/mac/CodansCore/Space.swift`:
- Add `public var lastActiveWorktreeID: WorktreeID?` after `selectedProjectID`.
- Extend the memberwise `init` to accept `lastActiveWorktreeID: WorktreeID? = nil`.
- Add an explicit `Codable` extension with `CodingKeys` `{ id, name, projects, selectedProjectID, lastActiveWorktreeID }` and `init(from:)` using `decodeIfPresent` for the new key (default `nil`).
- `encode(to:)` writes all fields; use `encodeIfPresent` for the optional.

In `apps/mac/CodansCore/Worktree.swift`:
- Add `public var gitViewerVisible: Bool` after `selectedTabID`.
- Extend the memberwise `init` to accept `gitViewerVisible: Bool = false`.
- Add explicit `Codable` extension with `CodingKeys` `{ id, name, path, branch, tabs, selectedTabID, gitViewerVisible }`. `init(from:)` uses `decodeIfPresent` for `gitViewerVisible` with `?? false`.
- `encode(to:)` writes all fields.

Tests — append to `apps/mac/CodansCoreTests/CatalogCodableTests.swift`:
- `decodesPreT0JSONWithDefaults` — feed a hand-crafted catalog JSON whose spaces/worktrees omit the new keys; expect `lastActiveWorktreeID == nil` on every Space and `gitViewerVisible == false` on every Worktree; assert the decode does not throw.
- `roundTripsLastActiveWorktreeAndGitViewerVisible` — build a Catalog with one Space whose `lastActiveWorktreeID` is set and one Worktree whose `gitViewerVisible == true`; encode + decode; assert equality.

Acceptance: `xcodebuild test -scheme CodansCoreTests` passes the full suite; the two new tests are green. `git diff --stat` shows changes only under `apps/mac/CodansCore/` and `apps/mac/CodansCoreTests/`.

**Commit after M1**: `feat(core): add Space.lastActiveWorktreeID and Worktree.gitViewerVisible`

### Milestone 2 — HierarchyManager mutation API

Goal: the two new setters are callable from the app and persist through the existing debounced save.

In `apps/mac/codans/Runtime/HierarchyManager.swift`:
- Add `func setSpaceLastActiveWorktree(spaceID: SpaceID, worktreeID: WorktreeID?)` near the Space mutations section. Resolve the space by id; if not found, `return` silently (match `selectSpace` style — no throw). If unchanged, no save. Otherwise set and `store.scheduleSave(catalog)`.
- Add `func setWorktreeGitViewerVisible(worktreeID: WorktreeID, visible: Bool)` near the Worktree mutations (or create a new `// MARK: - Worktree mutations` section). Walk `catalog.spaces → projects → worktrees` to find the worktree; if not found, return silently. If unchanged, no save. Otherwise set and `store.scheduleSave(catalog)`.
- Both methods get **semantic** doc-comments (per corrected **D5**):
  - `setSpaceLastActiveWorktree` doc-comment states: the field records which Worktree to restore-into when the window re-activates this Space; pass `nil` to clear; missing `spaceID` is a silent no-op; unchanged value is a silent no-op; mutations go through the standard `store.scheduleSave(catalog)` debounced pipeline (same path as `renameSpace` / `selectSpace`); it is safe to call from render-time handlers because the underlying save is debounced.
  - `setWorktreeGitViewerVisible` doc-comment states: the field records whether the right-side Git Viewer overlay is visible for this Worktree (state persists across Space switches and app restarts); missing `worktreeID` is a silent no-op; unchanged value is a silent no-op; mutations go through `store.scheduleSave(catalog)`.
  - These are **not** dead-plumbing APIs; they are the long-lived entry points T1 (Space switcher) and T3 (Git Viewer toggle) will call. No "reuse or remove" disposal note on either.

Tests — append to `apps/mac/codans/Tests/HierarchyManagerTests.swift`:
- `setSpaceLastActiveWorktreePersists` — build a manager with one Space containing a Project with a Worktree; call the setter; assert the catalog field is updated; assert `CatalogStore.scheduleSave` was called (or persistence happens via existing test fixture; mirror prior tests' approach).
- `setSpaceLastActiveWorktreeMissingSpaceIsNoOp` — call with an unknown `SpaceID`; assert no mutation, no save.
- `setWorktreeGitViewerVisiblePersists` — similar shape.
- `setWorktreeGitViewerVisibleUnchangedSkipsSave` — call with the same value twice; assert save happens only once (or at least the second call is a no-op — depends on how tests observe persistence; if awkward, collapse into a single "sets and persists" test).

Acceptance: app scheme test suite passes. Reading `catalog.spaces[...].lastActiveWorktreeID` after the setter returns the new value.

**Commit after M2**: `feat(runtime): add HierarchyManager setters for lastActiveWorktreeID and gitViewerVisible`

### Milestone 3 — Catalog pane/worktree resolution helpers

Goal: a pure, testable API that the aggregation helpers can call.

In `apps/mac/CodansCore/Catalog.swift`:
- Add `extension Catalog { public func worktreeID(forPane paneID: PaneID) -> WorktreeID? }` — walks `spaces → projects → worktrees → tabs → panes`, returns the first match or `nil`. Linear scan; documented as O(n).
- Add `extension Catalog { public func paneIDs(inWorktree worktreeID: WorktreeID) -> Set<PaneID> }` — returns all PaneIDs under the worktree across all tabs.
- Add an internal-or-private helper if it simplifies M4 (e.g. `panelIndex: [PaneID: WorktreeID]`) — *but do not expose publicly*; aggregation helpers build their own index in M4. Decide during M4 whether to share.

Tests — new file `apps/mac/CodansCoreTests/CatalogResolutionTests.swift`:
- `worktreeIDForPanelFindsAcrossTabs` — catalog with 2 tabs, 2 panes in each; resolve each pane; assert correct worktree.
- `worktreeIDForPanelMissingReturnsNil` — resolve a random PaneID; expect `nil`.
- `panelIDsInWorktreeReturnsAllLeaves` — catalog with one Worktree hosting 2 tabs × 2 panes each; expect set of 4 PaneIDs.

Acceptance: CoreTests scheme green.

**Commit after M3**: `feat(core): add Catalog pane/worktree resolution helpers`

### Milestone 4 — NotificationInbox aggregation helpers

Goal: pure, catalog-aware aggregation callable from both reducer-land and views.

In `apps/mac/CodansCore/Notifications/NotificationInbox.swift` (or a sibling file `NotificationInbox+Aggregation.swift` for clarity — decision during edit; prefer one file if it stays under ~120 lines total):
- Implement `unreadCount(forWorktree:in:)`, `hasUnread(forProject:in:)`, `hasUnread(forSpace:in:)`, `notifications(forWorktree:in:)` per design API.
- Helpers build a single `[PaneID: WorktreeID]` map per call from the catalog (not from tabs in reverse — iterate outward for cache locality and so a pane without a matching worktree is just absent).
- Each helper doc-comment carries the render-hot-path perf note per **D6**.

Test file — either append to `apps/mac/CodansCoreTests/NotificationInboxTests.swift` or new `NotificationInboxAggregationTests.swift`:
- Fixture: Space `S1` { Project `P1` [Worktree `W1a`, `W1b`], Project `P2` [Worktree `W2`] }, one Pane per worktree. Inbox has: one unread + one read on `W1a`, one unread on `W1b`, zero on `W2`.
- `unreadCountForW1aIsOne` — asserts 1, not 2 (read one excluded).
- `hasUnreadForP1IsTrue` — aggregates W1a+W1b, true.
- `hasUnreadForP2IsFalse` — no notifications under W2.
- `hasUnreadForS1IsTrue` — cross-project aggregation.
- `notificationsForW1aIsTimeDescending` — returns both notifications (read included), newest first by `createdAt`.
- `aggregationIgnoresPanelsNotInCatalog` — append a notification with a PaneID not in any catalog worktree; none of the helpers should surface it.

Acceptance: CoreTests scheme green. No MainActor annotations on the helpers (verified by the tests living outside `@MainActor` scope).

**Commit after M4**: `feat(core): add NotificationInbox aggregation helpers keyed by worktree/project/space`

### Milestone 5 — InboxStore mutation helpers

Goal: T2 can drive markRead/dismissAll from the Header bell popover.

In `apps/mac/codans/Notifications/InboxStore.swift`:
- Add `func markRead(forWorktree worktreeID: WorktreeID, in catalog: Catalog, now: Date = Date())`. Implementation: build the `paneIDs(inWorktree:)` set from catalog; iterate `inbox.notifications` and set `readAt = now` on each entry whose `paneID` is in the set and whose `readAt == nil`. If anything mutated, call `scheduleSave()` + `publishMutation()`. (Match `markRead(_ ids:)` shape.)
- Add `func dismissAll(now: Date = Date())` — forwards to `clearAll(now:)`. Doc-comment per **D7**.
- Update doc-comment on existing `clearAll` to cross-link: *"Legacy alias of `dismissAll`; see design doc T0."*

Tests — append to `apps/mac/codans/Tests/NotificationsTests/InboxStoreTests.swift`:
- `markReadForWorktreeOnlyMarksScopedNotifications` — catalog with two worktrees; append notifications for panes in each; call setter for one worktree; assert the other worktree's unread count is unchanged.
- `markReadForWorktreeIsIdempotent` — calling twice leaves state unchanged after the first call (second call does not re-schedule save; observe via `pendingSaveTask` or by counting `unreadCount` transitions).
- `dismissAllDelegatesToClearAll` — one appended notification; call `dismissAll`; assert `isUnread` → false and `dismissedAt != nil`.

Acceptance: app-scheme tests green; existing C6 tests unaffected.

**Commit after M5**: `feat(notifications): add InboxStore markRead(forWorktree:in:) and dismissAll`

### Milestone 6 — ContentView Picker removal + doc-comments

Goal: UI no longer exposes the mode toggle; the reducer state is preserved as internal plumbing.

In `apps/mac/codans/App/ContentView.swift`:
- Delete `modeTogglePicker` (private var + the `ToolbarItem` that hosts it).
- Replace the `@ViewBuilder var sidebarColumn` with a direct `HierarchySidebarView(store: ..., currentSelection: ...)` call. Remove the `.toolbar { ToolbarItem { modeTogglePicker } }` application on the sidebar column.
- Keep the rest untouched (Settings / Inspector / editor toast, etc.).
- Update the class-level doc-comment: strike the "leading column swaps between HierarchySidebarView and InboxSidebarView" sentence; reference T0 / T2.

In `apps/mac/codans/App/Features/Root/RootFeature.swift`:
- Apply the per-**D5** *"T2 must either reuse or remove"* disposal note to every piece of plumbing this milestone turns into unreachable code:
  - `SidebarMode` enum — doc-comment header
  - `RootFeature.State.sidebarMode` — doc-comment on the property
  - `.sidebarModeChanged(_:)` action case — doc-comment near the enum case
  - `state.inbox` / `Scope(state: \.inbox, action: \.inbox) { InboxSidebarFeature() }` — doc-comment above the Scope block
- Each note should read approximately: *"Reserved for T2 bell-popover reuse; no current dispatch site after T0. T2 must either reuse or remove."* (vary wording to match the declaration's context.)
- Do not delete `state.sidebarMode`, `.sidebarModeChanged`, the `.inbox` Scope, or `InboxSidebarFeature`.

Tests:
- Confirm `RootFeatureTests` (if any exist covering `sidebarModeChanged`) still compile and pass. The dispatch is no longer reachable from UI but the reducer branch remains valid.
- No new tests required — this milestone is a UI deletion. Manual smoke: launch the app, see sidebar always shows hierarchy, the toolbar has no Picker.

Acceptance: `make -C apps/mac lint` passes. `xcodebuild build -scheme codans` succeeds. `ContentView` no longer references `SidebarMode` or `modeTogglePicker`.

**Commit after M6**: `refactor(shell): remove sidebar mode Picker from ContentView`

### Milestone 7 — Verify, push, open PR

Goal: the branch is ready for master to route through Codex review.

Concrete steps listed below. Do not push until all schemes are green and lint is clean.

## Concrete Steps

Run from `/Users/wanggang/.worktree/repos/codans/feat/mw-foundation` unless otherwise stated.

```bash
# Before starting any milestone, confirm a clean tree on the correct branch.
git status
git branch --show-current   # → feat/mw-foundation
```

Per-milestone commit loop (use /commit for each):

```
<edit files for milestone M_n>
/commit                       # invokes the slash command; writes English commit msg
```

Verification before push:

```bash
# Lint
make -C apps/mac lint

# Generate Xcode workspace (idempotent; needed if not already generated)
make -C apps/mac generate

# Build + tests — schemes generated by Tuist
xcodebuild test -workspace apps/mac/codans.xcworkspace \
  -scheme CodansCoreTests -destination 'platform=macOS'
xcodebuild test -workspace apps/mac/codans.xcworkspace \
  -scheme codans -destination 'platform=macOS'
xcodebuild test -workspace apps/mac/codans.xcworkspace \
  -scheme CodansKit -destination 'platform=macOS'
```

Note: `make mac-test` is a placeholder; the project ships tests via Xcode schemes. Running each scheme explicitly is the current equivalent.

Push + PR:

```bash
git push -u origin feat/mw-foundation

gh pr create --base feature/main-window --title "T0: main-window foundation & contracts" \
  --body-file /tmp/pr-body.md
```

PR body will be written to `/tmp/pr-body.md` immediately before the `gh pr create` call via here-doc; include: (a) design-doc link, (b) ExecPlan link, (c) contracts frozen for T1/T2/T3, (d) test command transcripts.

Expected post-push output: `pr` URL printed to stdout; confirm with `gh pr view`.

Then push to master:

```
prowl send --target 81AAD975-7EF9-4B55-9599-8EFA2752A074 --no-wait \
  '我是 49276D62-83DA-4740-B376-A34027E05A31: PR_READY: <pr_url>'
```

## Validation and Acceptance

- `make -C apps/mac lint` exits 0.
- `xcodebuild test` of `CodansCoreTests`, `codans`, and `CodansKit` all exit 0; new test methods visible in the transcripts.
- `git diff main...feat/mw-foundation --stat` touches only:
  - `apps/mac/CodansCore/{Space,Worktree,Catalog}.swift`
  - `apps/mac/CodansCore/Notifications/NotificationInbox.swift` (or a sibling aggregation file)
  - `apps/mac/CodansCoreTests/{CatalogCodableTests,CatalogResolutionTests,NotificationInboxTests or NotificationInboxAggregationTests}.swift`
  - `apps/mac/codans/Runtime/HierarchyManager.swift`
  - `apps/mac/codans/Tests/HierarchyManagerTests.swift`
  - `apps/mac/codans/Notifications/InboxStore.swift`
  - `apps/mac/codans/Tests/NotificationsTests/InboxStoreTests.swift`
  - `apps/mac/codans/App/ContentView.swift`
  - `apps/mac/codans/App/Features/Root/RootFeature.swift`
  - `docs/design-docs/mw-t0-foundation.md` (already committed before execute phase starts? — if yes, skip)
  - `docs/exec-plans/0008-mw-t0-foundation.md`
- Manual smoke: `make mac-run-app`; sidebar renders hierarchy; no mode-toggle segmented control in toolbar; existing tabs/panes still render; opening/closing a pane still writes notifications to the inbox (C6 unchanged).
- Acceptance in behavior terms: given a Catalog with `Space.lastActiveWorktreeID` set and `Worktree.gitViewerVisible = true`, quitting and re-launching the app preserves both values. T1/T3 can read them on startup.

## Idempotence and Recovery

- Each milestone lands in a single commit; re-running a milestone after partial failure means discarding the working tree (`git restore --staged --worktree <files>`) and re-applying the plan's edits — no external side effects are created until M7's push.
- M7's `git push` is idempotent for a branch that already tracks origin. `gh pr create` fails cleanly if a PR already exists for the branch; in that case, use `gh pr edit` or re-run after closing the stale PR.
- If lint/test fails mid-way, revert the offending commit (`git reset --soft HEAD~1` + re-edit) rather than amending — per repo policy of preferring new commits.
- Branch `feat/mw-foundation` is the only branch touched; no merges / force-pushes in this plan.

## Artifacts and Notes

(Filled during execution — test transcripts, any notable diffs.)

## Interfaces and Dependencies

Public surface added in this plan (CodansCore):

```swift
public extension Space {
  var lastActiveWorktreeID: WorktreeID? { get set }
}

public extension Worktree {
  var gitViewerVisible: Bool { get set }
}

public extension Catalog {
  func worktreeID(forPane paneID: PaneID) -> WorktreeID?
  func paneIDs(inWorktree worktreeID: WorktreeID) -> Set<PaneID>
}

public extension NotificationInbox {
  /// Render-hot paths should cache a snapshot-scoped index — the helper rebuilds
  /// `[PaneID: WorktreeID]` per call.
  func unreadCount(forWorktree worktreeID: WorktreeID, in catalog: Catalog) -> Int

  /// Render-hot paths should cache a snapshot-scoped index.
  func hasUnread(forProject projectID: ProjectID, in catalog: Catalog) -> Bool

  /// Render-hot paths should cache a snapshot-scoped index.
  func hasUnread(forSpace spaceID: SpaceID, in catalog: Catalog) -> Bool

  /// Render-hot paths should cache a snapshot-scoped index.
  /// Time-descending (newest createdAt first); includes read and dismissed entries.
  func notifications(forWorktree worktreeID: WorktreeID, in catalog: Catalog) -> [AgentNotification]
}
```

App-side surface added (apps/mac/codans):

```swift
@MainActor
extension HierarchyManager {
  /// Records which Worktree to restore when the window re-activates this Space.
  /// Pass `nil` to clear. Missing `spaceID` is a silent no-op; unchanged value
  /// is a silent no-op. Persists via the standard debounced `store.scheduleSave`
  /// pipeline (same path as `renameSpace` / `selectSpace`).
  func setSpaceLastActiveWorktree(spaceID: SpaceID, worktreeID: WorktreeID?)

  /// Records whether the right-side Git Viewer overlay is visible for this
  /// Worktree. Persists across Space switches and app restarts. Missing
  /// `worktreeID` is a silent no-op; unchanged value is a silent no-op.
  /// Persists via the standard debounced `store.scheduleSave` pipeline.
  func setWorktreeGitViewerVisible(worktreeID: WorktreeID, visible: Bool)
}

@MainActor
extension InboxStore {
  func markRead(forWorktree worktreeID: WorktreeID, in catalog: Catalog, now: Date = Date())

  /// Canonical name; `clearAll` is a legacy alias kept to avoid C6 M5 churn,
  /// may be removed in T2.
  func dismissAll(now: Date = Date())
}
```

Dependency direction preserved: all new public types live in CodansCore (no app-module imports). App-side extensions on `HierarchyManager` / `InboxStore` stay app-local.
