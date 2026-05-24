# ExecPlan: Worktree Branch Switcher & Diff History

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-05-24

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this change, a user in `touch-code` can switch the current Worktree's branch and browse the branch's commit history without leaving the app. The Worktree detail header becomes the entry point: row 1 shows the current branch name and a chevron, row 2 shows `folder · project`. Clicking row 1 reveals a popover listing every local and remote branch (current marked, click to switch) and the 10 most recent commits, with a "View all" button. The Diff Viewer's right panel gains a Changes / History segmented control — Changes preserves today's behaviour, History lists the current branch's commits, and clicking a commit renders that commit's full diff in the existing left-side renderer. The whole flow stays inside the app and reuses the existing HEAD-change observer so the UI refreshes without bespoke reload plumbing.

## Progress

**State:** Draft
**Active worker:** none
**Last handoff:** —

### Handoff log

(Append-only. One line per completed dispatch. Format: `<ISO ts> <task-id> <role> <outcome> [<commit-sha>]`)

### Task checklist

#### M1 — Git service layer

- [ ] T1: Add `BranchRef`, `BranchInventory`, `BranchSwitchTarget` to `TouchCodeCore/Git/GitModels.swift` (+ tests)
- [ ] T2: Add argv builders to `apps/mac/touch-code/Git/GitCommand.swift` (+ tests)
- [ ] T3: Add `GitOutputParser.parseBranchInventory` to `apps/mac/touch-code/Git/GitOutputParser.swift` (+ tests)
- [ ] T4: Add `currentBranch / listAllBranches / switchBranch` to `GitService` + `LiveGitService` (+ tests)
- [ ] T5: Extend `App/Clients/GitServiceClient.swift` with three new closures + `unimplemented` test values

#### M2 — BranchSwitcherFeature + view

- [ ] T6: Create `App/Features/BranchSwitcher/BranchSwitcherFeature.swift` reducer + TestStore tests
- [ ] T7: Create `App/Features/BranchSwitcher/BranchSwitcherView.swift` + `BranchRowView` + `RecentCommitRowView`
- [ ] T8: Add inline `ErrorBannerView` (sub-view under the header)

#### M3 — Header refit + cross-feature wiring

- [ ] T9: Rewrite `App/Features/WorktreeHeader/WorktreeHeaderInfoLabel.swift` to the two-row layout + branch button + popover host
- [ ] T10: Mount `BranchSwitcherFeature` in `WorktreeDetailView` (scope), wire `RootFeature` to forward `WorktreeHeadWatcher` events to BranchSwitcher + DiffFeature, and handle `BranchSwitcher.delegate.openDiffViewerOnHistoryTab`

#### M4 — DiffFeature Changes / History tabs

- [ ] T11: Extend `App/Features/Diff/DiffFeature.swift` with `selectedTab`, `historyState`, `presentedCommitSha`, `diffsByCommit`, and corresponding actions + effects + cancellation IDs + TestStore tests
- [ ] T12: Update `App/Features/Diff/Views/DiffInspectorView.swift` to host a segmented picker that routes to Changes vs History content
- [ ] T13: Create `App/Features/Diff/Views/DiffHistoryListView.swift` (header + list + empty / error / load-more)
- [ ] T14: Update `App/Features/Diff/Views/DiffDrawerView.swift` to render either a per-file diff or a commit diff, with the `<sha> · <subject>` title path

#### M5 — Verification & test fixtures

- [ ] T15: Author user-test fixtures in `docs/user-tests/_shared/fixtures/` (3 git bundles + restore script + 3 catalog seeds)
- [ ] T16: Declare every `accessibilityIdentifier` named in the user-test seams table; run `make mac-check`; runtime-validate the user-test set per the Exit Gate below

## Surprises & Discoveries

(None yet)

## Decision Log

(None yet — first new decisions land here as M1 begins. Architectural decisions already taken live in the design doc.)

## Outcomes & Retrospective

(To be filled at milestone completion)

## Context and Orientation

Related documents:

- Product spec: `docs/product-specs/worktree-branch-switcher-and-history.md`
- Design doc: `docs/design-docs/worktree-branch-switcher-and-history.md`
- User tests: `docs/user-tests/worktree-branch-switcher-and-history.md`
- Test conventions: `docs/user-test-patterns.md`
- Architecture: `docs/architecture.md`
- Golden rules: `docs/golden-rules.md`

Key source files (read before editing the matching task):

- `apps/mac/TouchCodeCore/Git/GitModels.swift` — domain models for git data crossing the service ↔ app boundary; `Commit`, `LogPage`, `WorkingTreeStatus`, `ChangedFile`, `RemoteInfo`. New `BranchRef` / `BranchInventory` / `BranchSwitchTarget` types land here. Pure `Sendable`, no UI or service references.
- `apps/mac/touch-code/Git/GitService.swift` — `nonisolated public protocol GitService: Sendable` listing every read-only git method the app calls. Three new methods are added at the bottom.
- `apps/mac/touch-code/Git/LiveGitService.swift` — `Process`-backed implementation. Every method goes through the `CommandRunner` seam with the 16 MiB output cap + 10 s timeout already configured. Pattern to mirror for the new methods.
- `apps/mac/touch-code/Git/GitCommand.swift` — pure argv builders. Two new builders (`symbolicRefShortHead`, `forEachRefBranches`) are added alongside a small switch helper for `BranchSwitchTarget`.
- `apps/mac/touch-code/Git/GitOutputParser.swift` — `nonisolated enum GitOutputParser` with parsers for log, status, and diff numstat. One new parser (`parseBranchInventory`) is added.
- `apps/mac/touch-code/App/Clients/GitServiceClient.swift` — TCA dependency wrapper over `GitService`. Adds three `@Sendable` closures + matching `unimplemented` test values.
- `apps/mac/touch-code/Runtime/WorktreeHeadWatcher.swift` — debounced file-system observer on each Worktree's `.git/HEAD`. We do **not** change this file; we subscribe to its existing `events()` stream from `RootFeature` and forward into the two reducers below.
- `apps/mac/touch-code/App/Features/WorktreeHeader/WorktreeHeaderInfoLabel.swift` — toolbar leading-cluster view. Rewritten to a two-row layout with the branch row hosting the new popover.
- `apps/mac/touch-code/App/Features/WorktreeHeader/WorktreeHeaderFeature.swift` — unchanged. Branch state goes into a new sibling reducer (see design doc Alt 1 for the rejected alternative).
- `apps/mac/touch-code/App/Features/Diff/DiffFeature.swift` — TCA reducer for the Diff inspector and drawer. Extended in-place (no child reducer) per design doc Alt 5.
- `apps/mac/touch-code/App/Features/Diff/Views/DiffInspectorView.swift` — right-panel host. Wraps the existing body in a tab router.
- `apps/mac/touch-code/App/Features/Diff/Views/DiffDrawerView.swift` — left-side diff renderer. Adapted to accept either a file path or a commit sha + subject for its title.
- `apps/mac/touch-code/App/Features/WorktreeDetail/WorktreeDetailView.swift` — host that mounts the toolbar and the Diff inspector. The new `BranchSwitcherFeature` store is scoped here at the leading toolbar item.
- `apps/mac/touch-code/App/Features/Root/RootFeature.swift` — root reducer; already runs the `WorktreeHeadWatcher.events()` loop. New: forward each event to BranchSwitcher + Diff scopes and handle the BranchSwitcher delegate that opens the Diff Viewer on the History tab.

Terms used in this plan (defined here so the reader does not need to chase them down):

- **Inventory** — the `BranchInventory` value returned from `git for-each-ref` (current name + sorted local + sorted remote branches).
- **Fast-path** — when the user picks `origin/x` in the popover and a local branch `x` already exists, the reducer issues `git switch x` instead of `git switch --track origin/x`. Avoids creating a duplicate tracking branch.
- **HEAD-change tick** — one event emitted by `WorktreeHeadWatcher` after `.git/HEAD`'s contents change (debounced to ~200 ms by the watcher).
- **Settled** — the post-switch state where `WorktreeHeadWatcher` has fired, catalog has been refreshed, and `Worktree.branch` reflects the new branch.

How the pieces fit together: `GitService` + `LiveGitService` learn three new operations. A new `BranchSwitcherFeature` reducer holds the popover's state, calls those operations, and emits a delegate when the user asks to view all commits. `WorktreeHeaderInfoLabel` renders the two-row layout and hosts the popover. `RootFeature` already operates the `WorktreeHeadWatcher` event loop; it gains routing for the new delegate and forwarding of HEAD events to the new feature plus `DiffFeature`. `DiffFeature` keeps its existing Changes side and grows a History side that shares the worktree context already in its state. The left diff renderer is the same in both modes.

## Plan of Work

The plan is organised into five milestones so each one is independently verifiable. M1 has no UI dependencies and is the foundation. M2 / M3 are sequential (the view in M3 wires the reducer from M2 onto the toolbar). M4 depends only on M1 and can be implemented in parallel with M2 / M3 if helpful. M5 is verification work that closes out the feature.

The work is sliced vertically inside each milestone: a slice (data → effect → reducer → view) ends with something a user can see, even if the final outcome is only reachable after the next milestone lands.

### Milestone 1 — Git service layer

This milestone teaches `GitService` to read the branch inventory, read the current branch, and switch to a target branch. Nothing in the UI changes yet; at the end, a Swift REPL or a test can call the new client methods and get back real values from a checked-out repository.

**T1** adds the three new types to `apps/mac/TouchCodeCore/Git/GitModels.swift`: `BranchRef` (`shortName`, `isRemote`, `upstream`), `BranchInventory` (`current`, `local`, `remote`), and the input enum `BranchSwitchTarget` (`.local(name:)`, `.remoteTracking(shortName:)`). All three are `public nonisolated`, `Equatable`, and `Sendable`. Tests are unit-level — Equatable round-trips and a tiny encode/decode sanity check if `Codable` is required by existing tests (verify by reading `TouchCodeCoreTests` headers before implementing).

**T2** appends two static helpers to `apps/mac/touch-code/Git/GitCommand.swift`:

```swift
static func symbolicRefShortHead() -> [String]                  // ["symbolic-ref", "--short", "HEAD"]
static func forEachRefBranches() -> [String]                    // for-each-ref + custom --format
static func switchBranch(target: BranchSwitchTarget) -> [String]
```

The `forEachRefBranches` format string is `%(refname)%09%(refname:short)%09%(upstream:short)%09%(HEAD)`, record-separated by newline. Verify the `--format` string with a small test that runs against a fixture repo (or, if process-level tests are forbidden by CI, just snapshot the argv output).

**T3** adds `parseBranchInventory(_ bytes: Data, currentMarker: Character = "*") throws -> BranchInventory` to `apps/mac/touch-code/Git/GitOutputParser.swift`. Behaviour: split on `\n`, drop empty lines, per line split on `\t` into 4 fields, classify `refs/heads/*` as local and `refs/remotes/<remote>/*` as remote, drop refs ending in `/HEAD` on the remote side, mark current via `%(HEAD)` == `*`, sort each list ascending by `shortName`, then if `current` is in local pull it to position 0. Unit tests cover: empty input → empty inventory with nil current; single local; mixed local + remote; `origin/HEAD` filtered; current marker placement; sort order; UTF-8 branch names (Chinese / emoji); tab/newline inside the input that should never occur — confirm parser throws `GitError.unparsable` instead of silently corrupting.

**T4** wires the new operations through both layers. In `GitService.swift`, append the three method signatures with documentation comments matching the design doc's API Design block verbatim (kept short). In `LiveGitService.swift`, implement them following the existing pattern: `ensureIsRepo(at:)` first, build argv via `GitCommand`, call the shared private `run(arguments:cwd:)`, parse the bytes, return. For `currentBranch`, treat exit code `1` from `symbolic-ref --short HEAD` as detached and return `nil` (do **not** throw); any other non-zero exit re-throws via the existing `GitError.exec` path. For `switchBranch`, no body parsing — just discard stdout on success and let the existing exit-code → `GitError.exec` mapping carry stderr to the caller. Unit tests use a mock `CommandRunner` that records argv + cwd + env and returns a scripted `CommandOutcome`: assert argv matches the `GitCommand` outputs, assert detached HEAD returns nil, assert non-zero exit throws `GitError.exec(code, stderr)` with stderr preserved verbatim.

**T5** adds the three closures to `apps/mac/touch-code/App/Clients/GitServiceClient.swift`:

```swift
var currentBranch:   @Sendable (URL) async throws -> String?
var listAllBranches: @Sendable (URL) async throws -> BranchInventory
var switchBranch:    @Sendable (BranchSwitchTarget, URL) async throws -> Void
```

Update both `live(service:)` and `testValue`. The `testValue` uses `unimplemented(...)` with `String?` nil placeholder, `BranchInventory(current: nil, local: [], remote: [])` placeholder, and a void placeholder for `switchBranch`. Smoke-test that `GitServiceClient.live(service: LiveGitService())` compiles and that `testValue` traps when the new methods are called without an explicit override.

**Exit Gate (M1):**

- Every task ends with an atomic commit on `feat/git_branch_update`.
- `make mac-check` passes (swiftlint + swift-format).
- All new unit tests pass: `xcodebuild test -scheme touch-code -testPlan Default` (or whatever the repo's invocation is — verify in `Makefile`).
- No runtime user-test coverage yet (no UI surface exists).

### Milestone 2 — BranchSwitcherFeature reducer + view

This milestone builds the reducer and views that drive the popover. Nothing on screen yet — `WorktreeDetailView` does not mount the feature until M3. The exit signal is "the TestStore tests all pass and `BranchSwitcherView` previews render in Xcode".

**T6** creates `apps/mac/touch-code/App/Features/BranchSwitcher/BranchSwitcherFeature.swift`. The reducer follows the design doc's state outline and action list. Implementation notes:

- State fields: `worktreeID`, `worktreePath`, `inventory`, `inventoryLoading`, `recentCommits`, `commitsLoading`, `isPopoverOpen`, `isSwitching`, `searchQuery`, `switchError`. `SwitchError` is a small enum `case message(String)`.
- Actions: `worktreeChanged(WorktreeID?, String?)`, `popoverTapped`, `popoverDismissed`, `searchQueryChanged(String)`, `branchTapped(BranchSwitchTarget)`, `viewAllCommitsTapped`, `errorDismissed`, `inventoryLoaded(Result<BranchInventory, GitError>)`, `commitsLoaded(Result<[Commit], GitError>)`, `switchFailed(message: String)`, `headChangedForCurrentWorktree`, `delegate(Delegate)`. `Delegate.openDiffViewerOnHistoryTab(WorktreeID, ProjectID?)`.
- Effect IDs: `CancelID.inventory`, `.commits`, `.switch`. `popoverTapped` toggles `isPopoverOpen`; opening kicks both loads in `.merge`; `branchTapped` cancels the two read loads, closes the popover, sets `isSwitching = true`, and runs `switchBranch` — on success no further state change (HEAD watcher does the rest), on failure dispatches `switchFailed(message:)`. `headChangedForCurrentWorktree` clears `inventory` + `recentCommits` + `isSwitching` so the next `popoverTapped` re-fetches.
- TestStore coverage: popover open dispatches both loads; in-flight load cancels on `worktreeChanged`; `branchTapped` produces the expected effect chain; `switchFailed` populates the banner and clears the spinner; `headChangedForCurrentWorktree` clears the spinner and resets caches; `viewAllCommitsTapped` emits the delegate and closes the popover.

**T7** creates the popover content under the same directory: `BranchSwitcherView.swift` (root), `BranchRowView.swift`, and `RecentCommitRowView.swift`. `BranchSwitcherView` reads `store.inventory`, draws a section header "Branches" followed by the rows (current first), then a divider before the Recent Commits group; the footer is a `Button("View all") { store.send(.viewAllCommitsTapped) }`. The search box (Should-Have item from spec) is rendered when `inventoryLoading == false || !inventory.local.isEmpty`; filter is a simple substring match on `shortName`. All rows declare the `accessibilityIdentifier` strings from the user-test seams table.

**T8** adds the inline error banner: a small `BranchSwitcherErrorBannerView` shown by `WorktreeDetailView` directly under the toolbar when `store.switchError != nil`. The banner has the dismiss button on its trailing edge and the verbatim git error first line. It is intentionally placed in `BranchSwitcher/` (not `WorktreeHeader/`) because its data source is the BranchSwitcher reducer; T9 reads from the same store.

**Exit Gate (M2):**

- TestStore tests for `BranchSwitcherFeature` cover the seven action paths listed in T6.
- `make mac-check` passes.
- Xcode previews render `BranchSwitcherView` populated with mock inventory + commits.

### Milestone 3 — Header refit and cross-feature wiring

This milestone replaces the static branch subtitle with the new two-row layout, hosts the popover, and wires HEAD events + the "View all" delegate. After this milestone, a user can open the app, click the branch in the toolbar, see the popover, switch branches, and see the header refresh.

**T9** rewrites `apps/mac/touch-code/App/Features/WorktreeHeader/WorktreeHeaderInfoLabel.swift`. The signature gains a `@Bindable var branchSwitcherStore: StoreOf<BranchSwitcherFeature>`. Row 1: `HStack` of `WorktreeRowIcon` (existing) + `Text(branchTitle)` + spinner-or-chevron. Row 2: `Text("\(worktree.name) · \(project.name)")` in caption style. The whole row 1 is wrapped in a `Button { branchSwitcherStore.send(.popoverTapped) }` styled as a plain content button with hover affordance via `.onHover` (matches existing chrome). The button anchors a `.popover(isPresented: $branchSwitcherStore.isPopoverOpen.animation()) { BranchSwitcherView(store: branchSwitcherStore) }`. `branchTitle` reads `worktree.branch` if present; else `"(detached HEAD)"` — extension OQ-D1 deferred.

**T10** completes the wiring:

- In `apps/mac/touch-code/App/Features/WorktreeDetail/WorktreeDetailView.swift`, add a new `let branchSwitcherStore: StoreOf<BranchSwitcherFeature>` to the view, pass it into `WorktreeHeaderInfoLabel`, and render the `BranchSwitcherErrorBannerView` under the toolbar when `branchSwitcherStore.switchError != nil`.
- In `apps/mac/touch-code/App/Features/Root/RootFeature.swift`, register a `BranchSwitcherFeature` scope keyed by the active worktree id (one live store per visible detail view). On every `WorktreeHeadWatcher.events()` tick, send `.headChangedForCurrentWorktree` to the matching BranchSwitcher store AND `.headChangedForCurrentWorktree` (new) to the Diff store. Handle `BranchSwitcher.Action.delegate.openDiffViewerOnHistoryTab(worktreeID, projectID)` by issuing whatever existing root-level action opens the Diff Viewer (verify the action name in `RootFeature` before implementing — likely `.toggleGitViewer` or similar), followed by `.diff(.tabSelected(.history))`.
- Update the `WorktreeDetailView` mount sites in `RootView` (or wherever the detail view is constructed) to pass the new scoped store.

After this milestone the user-visible flow works for the happy path (UT-BSH-HD-001, UT-BSH-HD-002, UT-BSH-BP-001..005, UT-BSH-BP-008..009). UT-BSH-BP-005..009 depend on the rest of M3 being live but predate M4. UT-BSH-DV-* is still gated on M4.

**Exit Gate (M3):**

- Every task ends with an atomic commit.
- `make mac-check` passes.
- TestStore additions for `RootFeature`'s forwarding behaviour are green.
- Runtime validator returns PASS for the static UT-BSH-HD-* + UT-BSH-BP-* + UT-BSH-VS-002 (VoiceOver) cases. UT-BSH-BP-009 explicitly verifies the cross-feature wiring lands on the History tab.

### Milestone 4 — Diff Viewer Changes / History tabs

This milestone adds the second tab and the new commit-diff path to `DiffFeature`. Parallel to M2 / M3; merges cleanly because the only shared call surface is `GitServiceClient.log` and `commitDiff`, both unchanged by M1.

**T11** extends `apps/mac/touch-code/App/Features/Diff/DiffFeature.swift`:

- State additions: `enum DiffTab { case changes, history }`, `var selectedTab: DiffTab = .changes`, `struct HistoryState { var commits: [Commit]; var nextOffset: Int; var pageLimit: Int = 50; var loading: Bool; var hasMore: Bool; var error: GitError? }`, `var historyState: HistoryState = .init()`, `var presentedCommitSha: String?`, `var diffsByCommit: [String: DiffEntryState] = [:]`.
- Actions: `tabSelected(DiffTab)`, `historyAppeared`, `historyLoadNextPageRequested`, `historyPageSucceeded([Commit], hasMore: Bool)`, `historyPageFailed(GitError)`, `historyCommitTapped(sha: String, subject: String)`, `commitDiffSucceededFor(sha: String, document: DiffDocument)`, `commitDiffFailedFor(sha: String, error: GitError)`, `commitDiffTooLargeFor(sha: String, reason: TooLargeReason, copyCommand: String)`, `headChangedForCurrentWorktree`.
- Cancellation IDs: `.historyPage`, `.commitDiff`. Both `cancelInFlight: true`.
- `worktreeSelected` resets `historyState`, `presentedCommitSha`, `diffsByCommit` in addition to today's resets.
- `historyAppeared` is a no-op when `historyState.commits.isEmpty == false || historyState.loading`; otherwise emits the first page load. `historyLoadNextPageRequested` is gated on `hasMore && !loading`.
- `commitDiff` loading reuses the existing size-cap logic (`maxFileBytes` / `maxFileLines`); if the raw diff body exceeds caps, emit `commitDiffTooLargeFor` with a `copyCommand` of `cd <worktree> && git show <sha>`.

**T12** updates `apps/mac/touch-code/App/Features/Diff/Views/DiffInspectorView.swift`:

- Header replaces today's `Text(headerTitle) + refresh button` with a `Picker("Tab", selection: $store.selectedTab) { ... }.pickerStyle(.segmented)`. Refresh button stays but its target is the active tab (refresh = `refreshRequested` on Changes, `historyAppeared` with cache cleared on History).
- Content `switch store.selectedTab` routes to either the existing Changes body or the new `DiffHistoryListView`.

**T13** creates `apps/mac/touch-code/App/Features/Diff/Views/DiffHistoryListView.swift`. Layout: scrollable LazyVStack of commit rows; each row shows short sha + subject + relative time (use `RelativeDateTimeFormatter`). The last visible row triggers `store.send(.historyLoadNextPageRequested)` via `.onAppear`. Empty state (`store.historyState.commits.isEmpty && store.historyState.loading == false && store.historyState.error == nil`) shows `diff_inspector.history_empty_state` with text "No commits on this branch". Error state shows a retry button that re-issues the failed page. Selected row uses `Color.accentColor.opacity(0.18)` background (matches existing file row selection).

**T14** updates `apps/mac/touch-code/App/Features/Diff/Views/DiffDrawerView.swift`. The drawer reads `store.selectedTab` and renders either the file diff (existing path, gated on `presentedFilePath`) or the commit diff (new path, gated on `presentedCommitSha`). The title element gets the `diff_drawer.title_text` identifier and renders `path` in Changes mode or `"\(shortSha) · \(subject)"` in History mode. The "too large" placeholder reuses the existing copy of the file-mode UI but with the commit-specific copy command.

**Exit Gate (M4):**

- TestStore additions for `DiffFeature` cover: tab toggling preserves state; history first-page load on `historyAppeared`; commit selection caches `diffsByCommit`; `worktreeSelected` resets history; `headChangedForCurrentWorktree` resets history.
- `make mac-check` passes.
- Runtime validator returns PASS for UT-BSH-DV-001 through UT-BSH-DV-005.

### Milestone 5 — Verification & fixtures

This milestone produces the fixtures the user-test cases need and runs the final end-to-end pass.

**T15** authors the four fixture artifacts under `docs/user-tests/_shared/fixtures/`:

- `repo-multi-branch.bundle` — a git bundle (≤ 200 KB) containing local branches `main`, `feat/header-redesign`, `bugfix/menu`; a single remote `origin` with `origin/main`, `origin/feat/new-shell`, `origin/HEAD → origin/main`; ≥ 60 commits on `main`; HEAD checked out on `feat/header-redesign`. Generator script committed alongside the bundle (`_shared/fixtures/setup/build-repo-multi-branch.sh`) so the bundle can be regenerated deterministically.
- `repo-empty.bundle` — `git init` only.
- `repo-detached.bundle` — same content as `repo-multi-branch.bundle` but HEAD detached at the third commit of `main`.
- `_shared/fixtures/setup/restore-repo-multi-branch.sh` — script that takes `<tmp>` and unbundles into `<tmp>/repo-multi-branch` (parametrised similarly for the other two).
- `catalog/branch-switcher.json`, `catalog/branch-switcher-empty.json`, `catalog/branch-switcher-detached.json` — catalog seeds with a `__TMP__` placeholder the runner replaces before launching the app.

**T16** is the closing pass:

- Declare every `accessibilityIdentifier` named in the user-test seams table. The relevant call sites are: `WorktreeHeaderInfoLabel` (`worktree_header.*`), `BranchSwitcherView` + rows (`branch_switcher.*`), `BranchSwitcherErrorBannerView` (`branch_switcher.error_*`), `DiffInspectorView` (`diff_inspector.tab_picker`, `diff_inspector.changes_list`), `DiffHistoryListView` (`diff_inspector.history_*`), and `DiffDrawerView` (`diff_drawer.title_text`).
- Run `make mac-check` + the full Xcode test suite.
- Hand the running app + fixtures to `/hs-user-test` to runtime-validate every case in the user-test set. Expected outcome: 21 PASS + 1 MANUAL (VS-003).
- Update the Progress dashboard's Outcomes & Retrospective section with the final case verdicts and any deferred follow-ups.

## User Test Coverage

| Task | User-test cases covered |
|------|--------------------------|
| T1 | — (data model only; covered transitively by every UT-BSH-* case that asserts inventory shape) |
| T2 | — (argv builders; covered transitively by T4 service tests + UT-BSH-BP-006/007/008 at runtime) |
| T3 | — (parser; covered transitively by UT-BSH-BP-001/002/004) |
| T4 | UT-BSH-BP-005, UT-BSH-BP-006, UT-BSH-BP-007, UT-BSH-BP-008 (service-layer success and failure observable via the popover flow) |
| T5 | — (client wrapper; covered transitively by all UT-BSH-BP-* and UT-BSH-DV-* cases) |
| T6 | UT-BSH-BP-001, UT-BSH-BP-005, UT-BSH-BP-008, UT-BSH-BP-009 (reducer behaviour for open, switch, error, delegate) |
| T7 | UT-BSH-BP-001, UT-BSH-BP-002, UT-BSH-BP-003, UT-BSH-BP-004 (popover content) |
| T8 | UT-BSH-BP-008 (inline error banner) |
| T9 | UT-BSH-HD-001, UT-BSH-HD-002, UT-BSH-HD-003, UT-BSH-VS-001, UT-BSH-VS-002 (header layout, hover, detached HEAD, no glass capsule, VoiceOver) |
| T10 | UT-BSH-BP-005, UT-BSH-BP-009, UT-BSH-SW-1..3 (cross-feature wiring + HEAD-watcher forwarding + delegate routing) |
| T11 | UT-BSH-DV-001, UT-BSH-DV-002, UT-BSH-DV-003, UT-BSH-DV-004, UT-BSH-DV-005 (reducer behaviour for tabs, history, commit selection) |
| T12 | UT-BSH-DV-001, UT-BSH-DV-003 (segmented control hosting + tab switching) |
| T13 | UT-BSH-DV-001, UT-BSH-DV-004, UT-BSH-DV-005 (history list, infinite scroll, empty state) |
| T14 | UT-BSH-DV-002 (commit diff rendering + `<sha> · <subject>` title) |
| T15 | — (fixtures; covered by every UT-BSH-* case that consumes them) |
| T16 | UT-BSH-VS-003 (manual smoke) + serves as the final exit gate that all 22 cases ran |

Every user-test case ID appears in at least one task row above. Non-behavioural tasks are flagged with `—` and a one-line reason.

## Concrete Steps

All commands assume the working directory is the repo root unless stated. Run `mise trust . apps/mac` once per worktree if not done already.

Build + lint (every task ends with this):

```
make mac-check
```

Expected: `swift-format` writes any reformat in place, `swiftlint` reports no warnings. Non-zero exit fails the task.

Run a focused test target during development of T4:

```
xcodebuild test -workspace apps/mac/touch-code.xcworkspace -scheme touch-code-tests \
  -only-testing:touch-codeTests/LiveGitServiceBranchTests | xcbeautify
```

Expected (sample): a transcript ending in `** TEST SUCCEEDED **`; a non-zero exit indicates a failure. Verify the scheme + target name with `xcodebuild -list -workspace apps/mac/touch-code.xcworkspace` before running.

Full app build for smoke test:

```
make mac-build && make mac-run-app
```

Expected: the app opens with the sidebar populated from the seed catalog. Click the branch in the worktree header to trigger the popover; pick another branch; observe the header spinner then settle.

Runtime-validate the user-test set after M5:

```
# Hand the running app + fixture tmpdirs + catalog seeds to /hs-user-test.
# The skill runs each case and emits a results table.
```

Expected outcome: 21 PASS + 1 MANUAL (UT-BSH-VS-003, screen recording attached).

## Validation and Acceptance

Two layers must both pass.

**Static.** All commits cleanly land on `feat/git_branch_update`; `make mac-check` passes; the new Xcode test targets pass (`xcodebuild test ...`); the reviewer subagents (`/hs-spec-reviewer`, `/hs-code-reviewer`) approve each task with no Critical findings.

**Runtime.** After T16 finishes, hand the running app + the fixtures from T15 to `/hs-user-test`. Expected result table (abbreviated):

```
UT-BSH-HD-001  PASS
UT-BSH-HD-002  PASS
UT-BSH-HD-003  PASS
UT-BSH-BP-001  PASS
UT-BSH-BP-002  PASS
UT-BSH-BP-003  PASS
UT-BSH-BP-004  PASS
UT-BSH-BP-005  PASS
UT-BSH-BP-006  PASS
UT-BSH-BP-007  PASS
UT-BSH-BP-008  PASS
UT-BSH-BP-009  PASS
UT-BSH-DV-001  PASS
UT-BSH-DV-002  PASS
UT-BSH-DV-003  PASS
UT-BSH-DV-004  PASS
UT-BSH-DV-005  PASS
UT-BSH-VS-001  PASS  (or downgrade to MANUAL per OQ-UT2)
UT-BSH-VS-002  PASS
UT-BSH-VS-003  MANUAL
```

Any FAIL blocks acceptance and is filed into Surprises & Discoveries with a follow-up task.

## Idempotence and Recovery

- All tasks are repo edits + tests; rerunning a task is safe (Edit / Write are idempotent, tests don't mutate state).
- If `make mac-check` rewrites code via `swift-format`, re-stage and re-commit; do not amend if the commit has been pushed.
- Fixture authoring (T15) writes new files only; if regenerating a bundle, delete the old `.bundle` first and rerun the generator script — the script must be deterministic (same SHAs each run).
- Branch switch testing dirties the fixture repo; the runner restores from the bundle on teardown. If a test crashes mid-switch and leaves a dirty tmpdir, `rm -rf <tmp>/repo-*` is safe — the canonical content is the bundle.
- Rollback: revert the M4 commits to disable the History tab; revert M3 to revert the header (the legacy single-row code remains in git history and can be cherry-pick-restored if a hotfix is needed); M1 is additive and can stay even on rollback.

## Artifacts and Notes

No prototyping required — the design doc already validated the approach against the existing code patterns (`LiveGitService` for the new methods, `DiffFeature` for the new tab additions, `WorktreeHeadWatcher` for HEAD-change reactivity). Each task starts from a clear reference implementation in the same file.

Key transcripts to capture during execution and paste here:

- T3: parser unit-test transcript showing `XCTAssertEqual` outputs against the inventory cases.
- T4: mock-`CommandRunner` test transcript showing argv assertions for `switchBranch(.remoteTracking("origin/feat/x"))` → `["switch", "--track", "origin/feat/x"]`.
- T6: TestStore transcript demonstrating the `branchTapped → switchFailed → headChangedForCurrentWorktree` recovery loop.
- T11: TestStore transcript demonstrating that tab switching does not refetch already-loaded commits.
- T16: the runtime validator's results table.

Hold these in the Surprises & Discoveries section if anything unexpected surfaces during execution.

## Interfaces and Dependencies

The end-state interfaces that must exist after this plan:

In `apps/mac/TouchCodeCore/Git/GitModels.swift`:

```swift
public nonisolated struct BranchRef: Equatable, Hashable, Sendable {
  public let shortName: String
  public let isRemote: Bool
  public let upstream: String?
  public init(shortName: String, isRemote: Bool, upstream: String?)
}

public nonisolated struct BranchInventory: Equatable, Sendable {
  public let current: String?
  public let local: [BranchRef]
  public let remote: [BranchRef]
  public init(current: String?, local: [BranchRef], remote: [BranchRef])
}

public nonisolated enum BranchSwitchTarget: Equatable, Sendable {
  case local(name: String)
  case remoteTracking(shortName: String)
}
```

In `apps/mac/touch-code/Git/GitService.swift`, appended to the protocol:

```swift
func currentBranch(at path: URL) async throws -> String?
func listAllBranches(at path: URL) async throws -> BranchInventory
func switchBranch(to target: BranchSwitchTarget, at path: URL) async throws
```

In `apps/mac/touch-code/Git/GitCommand.swift`, appended:

```swift
static func symbolicRefShortHead() -> [String]
static func forEachRefBranches() -> [String]
static func switchBranch(target: BranchSwitchTarget) -> [String]
```

In `apps/mac/touch-code/Git/GitOutputParser.swift`, appended:

```swift
static func parseBranchInventory(_ bytes: Data, currentMarker: Character = "*") throws -> BranchInventory
```

In `apps/mac/touch-code/App/Clients/GitServiceClient.swift`, three new stored closures (with both `live(service:)` and `testValue` populated):

```swift
var currentBranch:   @Sendable (URL) async throws -> String?
var listAllBranches: @Sendable (URL) async throws -> BranchInventory
var switchBranch:    @Sendable (BranchSwitchTarget, URL) async throws -> Void
```

In `apps/mac/touch-code/App/Features/BranchSwitcher/`:

- `BranchSwitcherFeature` reducer with the state / action / delegate surface listed in T6.
- `BranchSwitcherView`, `BranchRowView`, `RecentCommitRowView` SwiftUI views.
- `BranchSwitcherErrorBannerView` SwiftUI view.

In `apps/mac/touch-code/App/Features/Diff/DiffFeature.swift`:

- `enum DiffTab { case changes, history }`
- `struct HistoryState { var commits: [Commit]; var nextOffset: Int; var pageLimit: Int = 50; var loading: Bool; var hasMore: Bool; var error: GitError? }`
- Extended `State` with `selectedTab`, `historyState`, `presentedCommitSha`, `diffsByCommit`.
- Extended `Action` with the eleven new cases listed in T11.
- Extended `CancelID` with `.historyPage`, `.commitDiff`.

Dependencies (TCA, libghostty, GitHub integration, etc.) are unchanged. The only new external behaviour is the additional argv flowing through the existing `CommandRunner` seam; rate limits and timeouts remain the values set in `LiveGitService` (16 MiB output cap, 10 s timeout). No new third-party packages or schema changes required.
