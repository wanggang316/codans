# ExecPlan: GitHub Integration v2 — Repository-batched PR fetch

**Status:** Completed (M1–M6; M7 deferred)
**Author:** Gump (with Claude)
**Date:** 2026-04-23

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this plan lands, activating a Project with twenty-plus Worktrees in codans paints every PR badge in a single visible frame — the sidebar goes from empty to fully populated (state pill + check-rollup overlay + `+N −M` diff) in roughly one round-trip to GitHub, rather than the staggered two-to-three-second wave the v1 per-Worktree model produces today. Specifically:

- Every PR-carrying Worktree in the active Project shows its badge within approximately five hundred milliseconds of Project activation, regardless of Worktree count.
- CI-rollup overlays paint with the badge (same render pass), instead of arriving later when a secondary `gh pr checks` subprocess completes.
- Switching between Projects cancels any in-flight fetch for the Project you just left — no zombie subprocess keeps writing into state after a navigation.
- Merging / closing / marking-ready a PR refreshes the **whole Project**'s PR data after a two-second settle delay, so the merged PR flips to its merged state without the user opening the popover again.
- When `gh` is temporarily unavailable (user uninstalled / un-authed mid-session), the feature backs off to a fifteen-second recovery heartbeat and reconverges automatically when `gh` comes back — no app relaunch required.

What a contributor observes after this plan lands, compared to today:

1. On a cold launch with the codans Project active (20+ Worktrees, 13 of which correspond to merged PRs), previously every row paints its purple `git-merge` icon + `#NNN` pill one-by-one over ~3 seconds. After v2: all 13 rows flip in one frame, ~600 ms after launch completes.
2. Previously, after you merge a PR from the popover, the row's pill stays "open" for ~2 seconds then flips to "merged". After v2: same behavior for that row, plus any dependent Worktrees on the same base branch also get their `mergeStateStatus` refreshed in the same batch.
3. Previously, a `git checkout other-branch` in a terminal pane inside a Worktree does not update the sidebar's PR badge until focus-gained triggers a reconcile. After v2 (if the `WorktreeBranchWatcher` Phase 7 ships): the badge updates within a second of the checkout.

This plan does not add UI; every visual surface is unchanged. It is an execution-model refactor that the user perceives only as speed.

## Progress

- [x] M1 — `RemoteInfo` + `GitService.remoteInfo(at:)` — 2026-04-23 (14 parser tests + 3 service tests; `RemoteInfo.ParseError` kept local to CodansCore to avoid a cross-module dep — see DEC-2)
- [x] M2 — Extend `PullRequestSnapshot` (new fields + Codable compat) — 2026-04-23 (4 fields added: `checkRollup`, `mergeStateStatus`, `reviewDecision`, `headRepositoryOwner`; custom `init(from:)`/`encode(to:)` uses `decodeIfPresent` with defaults so pre-v2 snapshots round-trip identically; 4 new Codable tests; v1 `gh pr view` parser intentionally not updated — see DEC-3)
- [x] M3 — `GitHubClient.batchPullRequests` + `LiveGitHubService` implementation (GraphQL builder, chunking, decoder, fork filter) — 2026-04-23 (GhCommand.apiGraphQL + BatchedPullRequestQuery + JSONOutputParsers.parseBatchedPullRequests + LiveGitHubService.batchPullRequests + 16 unit tests incl. 2 golden-file fixtures)
- [x] M4 — Reducer migration: dual-path during transition (per-Worktree + per-Project coexist) — 2026-04-23 (state: `snapshotsByProject`/`inFlightFetchProjects`/`queuedRefreshByProject`/`lastErrorByProject`/`projectGitRoots`; actions: `projectActivated`/`projectRefreshRequested`/`projectBatchLoaded`/`worktreeBranchChanged`; projection into per-Worktree `snapshots` for v1-view compat; RootFeature `selectionChanged` dispatches on projectID transitions; 6 new TestStore tests; DEC-4 drops the `githubFetchModel` flag — see below; DEC-5 defers `mergeCompletedSchedulesDelayedProjectRefresh` test)
- [x] M5 — View migration: read `checkRollup` from snapshot; retire per-row `.task(id:)` fetch dispatch — 2026-04-23 (HierarchySidebarView + PullRequestPopover + WorktreeRowIcon all read `snapshot.checkRollup`; WorktreeGitHubBadge's `.task(id:)` removed + `BadgeTaskIdentity` deleted; reducer's snapshotLoaded no longer prefetches checks; 3 TestStore tests simplified; 25 GitHubFeatureTests + 16 RootFeatureTests still green)
- [x] M6 — Delete v1 fetch path (partial — see DEC-6) — 2026-04-23 (deleted `checks()` method + closure + argv + parser + fixture + state.checks + Action.checksLoaded + checksFetchEffect + CancelID.checks; kept `pullRequest(branch:)` and `latestWorkflowRun` + related state/actions because `postMutationRefresh` still uses per-Worktree single-branch refresh; full retirement deferred to a follow-up that migrates postMutationRefresh to project-level refresh)
- [ ] M7 — Optional: `WorktreeBranchWatcher` (FS watch on `.git/HEAD` per Worktree) — **deferred** to v2.1; `HierarchyManager` focus-gained reconcile catches branch changes with ~seconds latency, acceptable for v2.0 ship

Each unchecked entry will be updated with a completion timestamp in the form `— 2026-MM-DD` when the milestone lands (matching the `0012` convention).

## Surprises & Discoveries

(None yet)

## Decision Log

### DEC-6 (2026-04-23, M6): Partial v1 retirement — keep `pullRequest(branch:)` + `latestWorkflowRun`

Plan's M6 intent was "pure subtraction of v1 code". In practice the v1 per-Worktree single-PR fetch (`pullRequest(branch:worktreePath:)`) is still reached by `postMutationRefresh` — the helper that fires after merge/close/markReady/rerun to refresh one Worktree's data without a full-project fetch. Fully deleting it would require the write handlers to dispatch `projectRefreshRequested` instead, which needs a WorktreeID → ProjectID lookup. That lookup is doable but large enough that folding it into M6 would turn a pure-delete commit into a refactor.

Compromise: this M6 deletes everything with a clear v2 replacement —

- `GitHubService.checks(number:worktreePath:)` (replaced by `snapshot.checkRollup`)
- `GhCommand.pullRequestChecks(number:)` (never called again)
- `JSONOutputParsers.parseChecks(_:)` (replaced by `parseBatchedPullRequests`)
- `state.checks: [Int: [CheckResult]]` (views read `snapshot.checkRollup`)
- `Action.checksLoaded` + `CancelID.checks` (no longer emitted)
- `checksFetchEffect` helper
- `gh-pr-checks-mixed.json` + `gh-pr-checks-none.json` fixtures

Kept — marked as "retire in a follow-up":

- `GitHubService.pullRequest(branch:worktreePath:)` + `LiveGitHubService.pullRequest` + `GhCommand.pullRequestView` + `JSONOutputParsers.parsePullRequest` — still reachable through `postMutationRefresh`.
- `GitHubService.latestWorkflowRun(...)` — still fetched on `presentPopover` to seed "Rerun failed jobs" (Open Question 4 in the design doc).
- `Action.worktreeBecameVisible` / `Action.refreshRequested` / `Action.snapshotLoaded` / `Action.workflowRunLoaded` — `snapshotLoaded` + `workflowRunLoaded` still drive the surviving single-branch paths; `worktreeBecameVisible` + `refreshRequested` are dormant (no view dispatches them anymore) but harmless to keep until the postMutationRefresh migration.

Follow-up item (to be filed as a new plan): migrate `postMutationRefresh` to fire `.projectRefreshRequested` with a 2 s delay, and drop the residual v1 surface.

### DEC-5 (2026-04-23, M4): Defer `mergeCompletedSchedulesDelayedProjectRefresh` test

Plan's M4 listed 8 TestStore tests; this milestone ships 6. The two deferred:

1. `mergeCompletedSchedulesDelayedProjectRefresh` — requires teaching the existing `mergeCompleted(.success)` handler to ALSO schedule a delayed project-level refresh on top of the current per-Worktree `postMutationRefresh`. That change crosses v1 and v2 paths (need to know the ProjectID for a WorktreeID) and is load-bearing for the "merge flips the badge within 2 s" UX. Scheduling in M5/M6 where the v1 path is being retired anyway is cleaner — adding both paths now would touch code that's about to be deleted.

2. `queuedRefreshFiresAfterInFlightCompletes` — the re-entrancy queue path is implemented but testing it requires a cooperative TaskGroup fixture that yields a snapshot before resolving. Deferred to M5's test update pass when the rest of the queue-drain path gains exercise in integration-style flows. The path IS covered by `projectActivatedWhileInFlightQueuesRefresh` setting the flag — M5 will add the second half that exercises the drain.

### DEC-4 (2026-04-23, M4): Skip the `githubFetchModel` feature flag

Plan called for a hidden `SettingsStore.general.githubFetchModel: "legacy" | "batched"` flag in M4, to let users runtime-toggle between v1 and v2 fetch paths during the transition (rolling back a bad v2 without a rebuild).

Dropped because:

- The dual-write model already gives a graceful degradation: M4 projects v2 results into `state.snapshots`, so views continue to work if v2 fires. If v2 is broken, v1's `worktreeBecameVisible` path (still live) writes the same dictionary — last-writer-wins collapses to "v1 result eventually". The user sees maybe-slower data, not broken data.
- Adding a flag means two runtime code paths + a Settings surface + code-path selection logic + associated tests — ~200 lines of scaffolding for a rollback mode we can reach with `git revert` of a single commit.
- Each M4–M6 commit is independently revertable via git. M4 is additive; M5 is the first commit that changes view consumers; M6 hard-deletes v1. If a regression surfaces during rollout, reverting M5 or M6 is one-line.

Trade-off: lose runtime-toggle observability. Accept it; this repo does not have other runtime-feature-flag scaffolding and introducing the pattern just for this rollback is disproportionate.

### DEC-3 (2026-04-23, M2): Minimal M2 — skip v1 `gh pr view` parser update

Plan's Work Items called for extending `GhCommand.pullRequestView` with the new GraphQL fields (`statusCheckRollup`, `mergeStateStatus`, `reviewDecision`) and teaching `JSONOutputParsers.parsePullRequest` to populate them. Evaluated and deferred to M3/M5:

- The v1 reducer and UI do not read the new fields yet — M5 is the milestone that flips the views. Populating in M2 produces no user-observable effect.
- Changing the v1 query shape forces updating all four `gh-pr-view-*.json` fixtures plus the associated parser tests (~2 hours of cleanup with zero production effect).
- M3 introduces the batched parser that populates the new fields cleanly from GraphQL. The v1 parser is fully retired in M6.

Net effect: v1 `parsePullRequest` continues to emit the 12 original fields; decode defaults fill the 4 new ones to `[]` / `.unknown` / `nil` / `""`. UI code is not yet looking at them, so the defaults are invisible. M5 swaps consumers to read from `snapshot.checkRollup` at the same time M4 routes all fetches through the batched path — at which point the new fields are populated from GraphQL end-to-end.

### DEC-2 (2026-04-23, M1): Local `RemoteInfo.ParseError` instead of reusing `GitError`

Plan's Work Items said "Invalid inputs throw a new `GitError.malformedRemoteURL(String)` case added in `apps/mac/codans/Git/GitError.swift`" while also placing `RemoteInfo.swift` in `apps/mac/CodansCore/Git/`. Contradiction: `CodansCore` is a standalone Swift module and cannot import from the app module, so the parser cannot throw `GitError` directly.

Resolved by giving `RemoteInfo` a nested `ParseError.malformed(String)` enum in `CodansCore`. `LiveGitService.remoteInfo(at:)` (app module) catches `RemoteInfo.ParseError.malformed` and rethrows as `GitError.malformedRemoteURL(_)`. Net effect for callers above the service layer: unchanged — they still see `GitError.malformedRemoteURL`. Net effect for the CLI / other future CodansCore consumers: they can reuse `RemoteInfo.parse` without taking an app-layer dep.

Two existing `GitError` exhaustive switches in `CommitLogView.swift` and `FileChangeListView.swift` needed a new case handler. Added `"Could not parse the remote URL: \(url)"` — matches the existing error-description sentence style.

### DEC-1 (2026-04-23): Execute serially, skip Agent Teams parallelization

Plan identifies M1+M2 as potentially parallel (no overlapping file sets: M1 touches `Git/*`, M2 touches `CodansCore/GitHub/*`). Considered dispatching two worktree-isolated agents. Rejected for this execution because each agent would pay a cold-start cost of reading roughly 8–10 files to match existing project conventions (`nonisolated` modifier placement, Swift-Testing framework vs XCTest, golden-file fixture layout, Codable decodeIfPresent patterns, lint rules). At ~30–60 min per milestone, the coordination + review overhead of two parallel agents exceeds the wall-clock savings, and small-step commit cadence from a single executor gives better debugging granularity. Reconsider Agent Teams for M3 if its sub-tasks prove parallelizable in practice (current read: sequential deps make it not a good candidate).

Initial architectural decisions are already captured in the design doc's "Alternatives Considered" and "Open Questions" sections; this log records only choices made *during execution* that deviate from or extend the plan.

## Outcomes & Retrospective

### Final state (2026-04-23)

Shipped M1 → M6 in six commits across roughly five hours of focused work. Each commit is independently verifiable, each passes build + lint + the GitHub test suites it touches. M7 (filesystem-watched branch changes) deferred to v2.1 per its "optional" marker in the plan.

Delta vs. the plan's Purpose statement:

- "Every PR-carrying Worktree paints its badge within approximately 500 ms of Project activation" — architecturally in place. The reducer now fires one `batchPullRequests` call per Project via `gh api graphql`, chunked at 25 branches with 3 concurrent. Verification is pending real-run measurement (the plan called for stopwatch validation; deferred to manual testing post-review).
- "CI-rollup overlays paint with the badge" — done: `snapshot.checkRollup` travels on the snapshot from the GraphQL response, so `WorktreeRowIcon` renders the overlay in the same pass as the badge's `#N`.
- "Switching between Projects cancels any in-flight fetch" — done: `CancelID.projectFetch(projectID)` with `cancelInFlight: true` on every dispatch.
- "Merging / closing / marking-ready refreshes the whole Project after 2 s" — deferred. Write handlers still call `postMutationRefresh` (per-Worktree v1 refresh). Follow-up plan (see DEC-6) will migrate this to `delayedProjectRefresh(projectID)`.
- "Graceful recovery when `gh` is unavailable" — partial. `GhAvailabilityCache` with 30 s TTL is in place from v1. The 15 s recovery heartbeat from the design doc is scaffolded in `CancelID.availabilityRecovery` but not wired — another follow-up.

### Test count delta

- M1: +17 tests (14 parser + 3 service)
- M2: +4 tests (Codable round-trip + decoder fallbacks)
- M3: +16 tests (query builder, chunker, parser, fork filter, service orchestration)
- M4: +6 TestStore tests (project-level actions + re-entrancy)
- M5: 0 new (3 existing tests simplified after dropping prefetch)
- M6: −3 tests (orphaned checks + pullRequestChecksArgv + checksHappyPath)

Net: +40 new tests. Design-doc estimated +50; the difference is M6 subtractions + deferred items (2 tests flagged in DEC-5 + M4's postMutationRefresh test deferred).

### Follow-ups (filed to be scheduled)

1. ~~**Migrate `postMutationRefresh` to project-level**~~ — **delivered by 0018 (2026-05-30).** `postMutationRefresh` and the badge/popover retry now resolve the owning Project via a `projectByWorktree` map and dispatch a 2 s delayed `projectRefreshRequested`; the single-branch `pullRequest(branch:)` / `snapshotFetchEffect` surface (and the `worktreeBecameVisible` / `refreshRequested` / `snapshotLoaded` actions, `GhCommand.pullRequestView`, `JSONOutputParsers.parsePullRequest`) is fully removed. Closes DEC-6.
2. **Wire availability recovery heartbeat** — on availability flip to `.unavailable`, start a 15 s `Task { while … sleep … reprobe }` loop; on recovery, drain `queuedRefreshByProject`.
3. **M7 — `WorktreeBranchWatcher`** — filesystem watch on `.git/HEAD` per visible Worktree to catch terminal-initiated branch changes within ~1 s instead of waiting for focus-regain reconcile.
4. **Open Question 4 resolution** — measure whether `checkRollup[].detailsURL` reliably carries a parseable run ID; if yes, drop `latestWorkflowRun` and its state map.

### Lessons learned

- **Sanity-checking layering claims matters**: the plan put `RemoteInfo` in `CodansCore` while also throwing an app-module `GitError` — a contradiction caught during M1 that required restructuring (DEC-2). Layer-crossing assumptions are cheapest to surface at plan-review time, next cheapest in the first milestone, more expensive later.
- **Dual-path migration beats feature flags for this repo**: DEC-4's decision to drop the `githubFetchModel` runtime flag in favor of per-commit revertability held up — M4's dual-write kept v1 working as a fallback without needing to carry a flag through five milestones.
- **"Skip cosmetic updates that M5 will invalidate"**: DEC-3 (skip updating v1 `gh pr view` parser in M2) and DEC-6 (keep `pullRequest(branch:)` in M6) both avoided ~2 hours of fixture regeneration + test churn that M5/follow-up would have obsoleted anyway. Worth doing again when the next M lands.
- **TestStore `.withDependencies` needs all deps stubbed, not just the ones the action directly touches**: M4 wire-up in `RootFeature.selectionChanged` broke 2 `exhaustivity = .off` tests because my new dispatch kicked an effect that used unstubbed `.date` + `gitService.remoteInfo` + `GitHubClient.batchPullRequests`. Adding those stubs fixed it, but the pattern is worth noting: downstream effects still need deps even when the test ignores downstream actions.

(To be filled further with review outcomes.)

## Context and Orientation

**Related documents (read first):**

- Design doc (v2, authoritative): [docs/design-docs/github-integration-batched.md](../design-docs/github-integration-batched.md) — the execution model, GraphQL shape, decoder patterns, fork-filter rules, invalidation events, and risks are all specified there. This plan translates that design into ordered, verifiable engineering tasks; it does not restate the design's rationale.
- Design doc (v1, superseded): [docs/design-docs/github-integration.md](../design-docs/github-integration.md) — retained for historical context only. The v1 fetch path it describes is what this plan replaces.
- Prior ExecPlan (v1 implementation): [docs/exec-plans/0012-github-integration.md](0012-github-integration.md) — the milestones it enumerates are what this plan's M1–M6 unwind. Read sections M0–M7 there to understand which pieces persist and which get replaced.
- Architecture map: [docs/architecture.md](../architecture.md), specifically the `codans/Process/`, `codans/GitHub/`, and `codans/App/Features/GitHub/` rows in the codemap table.

**Key source files:**

| Path | Role | What this plan does to it |
|---|---|---|
| `apps/mac/codans/GitHub/GitHubService.swift` | Protocol defining the data layer surface. | Adds `batchPullRequests(host:owner:repo:branches:)`. Single-branch `pullRequest` retained as a convenience. `checks(number:…)` and `latestWorkflowRun(…)` removed in M6. |
| `apps/mac/codans/GitHub/LiveGitHubService.swift` | Concrete implementation wrapping `gh` via `CommandRunner`. | Gains `batchPullRequests`; internal helpers `buildBatchedQuery`, `chunk`, `TaskGroup`-driven concurrent execution, GraphQL response decoding. |
| `apps/mac/codans/GitHub/GhCommand.swift` | Typed argv builder for `gh` subcommands. | New `apiGraphQL(query:hostname:variables:)` entry returning `(argv, expectedExitCodes)`. |
| `apps/mac/codans/GitHub/JSONOutputParsers.swift` | Stdin → DTO pure functions with golden-file tests. | Gains `parseBatchedPullRequests(_:aliasMap:)`. Adds `DynamicKey` helper + union-type `CheckNode` decoder. Existing parsers (`parsePullRequest`, `parseChecks`, `parseLatestWorkflowRun`, `parseAuthStatus`) stay; the first three are orphaned in M6. |
| `apps/mac/codans/GitHub/GitHubError.swift` | Error taxonomy. | Adds `.graphQLError(String)`, `.ghCLIOutdated(minVersion: String)`, `.remoteInfoUnavailable`, `.oversizeResponse(bytes: Int)`. |
| `apps/mac/codans/App/Clients/GitHubClient.swift` | TCA DependencyKey mirroring the service protocol. | `batchPullRequests` closure added; `checks` and `latestWorkflowRun` closures removed in M6. |
| `apps/mac/codans/App/Features/GitHub/GitHubFeature.swift` | TCA reducer owning per-Worktree PR snapshot state. | Adds `projectActivated` / `projectRefreshRequested` / `projectBatchLoaded` actions + new state slots `snapshotsByProject`, `inFlightFetchProjects`, `queuedRefreshByProject`, `lastErrorByProject`. Existing per-Worktree state kept during M4; derived from project state. |
| `apps/mac/codans/App/Features/GitHub/Views/PullRequestPopover.swift` | Popover content. | Reads `snapshot.checkRollup` directly (M5). Existing `checks` parameter path removed. |
| `apps/mac/codans/App/Features/HierarchySidebar/WorktreeGitHubBadge.swift` | Sidebar-row badge view. | Removes `.task(id:)` that currently drives per-Worktree `worktreeBecameVisible`; the reducer now kicks off fetches at the Project level (M5). |
| `apps/mac/codans/Git/GitService.swift` + `apps/mac/codans/Git/LiveGitService.swift` | Read-only git data-layer protocol + impl. | Gains `remoteInfo(at:)` (M1). |
| `apps/mac/codans/App/Clients/GitServiceClient.swift` | TCA DependencyKey for Git operations. | Gains `remoteInfo` closure (M1). |
| `apps/mac/CodansCore/GitHub/PullRequestSnapshot.swift` | PR snapshot DTO. | Gains `checkRollup: [CheckResult]`, `mergeStateStatus`, `reviewDecision`, `headRepositoryOwner`. Codable is additive — old `settings.json` files round-trip identically. |
| `apps/mac/CodansCore/GitHub/MergeStateStatus.swift` (new) + `ReviewDecision.swift` (new) | Pure value-type enums. | New files. |
| `apps/mac/CodansCore/Git/RemoteInfo.swift` (new) | Host/owner/repo value type. | New file. |
| `apps/mac/codans/Tests/GitHubTests/Fixtures/` | Golden-file GraphQL / gh JSON outputs. | New fixtures for batched GraphQL response, including a fork-PR noise case and an empty-branches case. |

**Term definitions (non-obvious):**

- **GraphQL alias.** A `foo: pullRequests(...)` style field rename inside a GraphQL query. Lets one field selection appear multiple times with different arguments in the same request. We use one alias per branch (`branch0`, `branch1`, …) to fan out up to twenty-five branch lookups into a single query.
- **Work-stealing TaskGroup.** `withThrowingTaskGroup` pattern where we prime N child tasks, then on each `group.next()` completion we enqueue the next waiting task until all are scheduled. Keeps concurrent count stable at N (here N=3) without spawning everything at once.
- **Fork PR.** A PR whose `headRefName` happens to match one of our own branch names because the PR's source comes from a fork that shares the name. Must be filtered out or tie-broken to avoid misattributing someone else's PR to our local branch. Rules described in the design doc's "Fork PR Filtering" section.
- **Event-driven invalidation.** Cache stays live until a known-invalidating event (Worktree added / removed / branch-changed, Project activated, post-write mutation, manual refresh). No TTL-based staleness.

**How the parts fit together.** The user-facing flow (user switches to a Project, badges paint) sits at three layers: the view reads per-Worktree snapshots from `state.snapshots[worktreeID]`; the reducer derives that dictionary from `state.snapshotsByProject[projectID].byBranch[worktree.branch]`; the client's `batchPullRequests` is the only code that touches the GraphQL wire and returns the branch-keyed map. The view does not know about Projects; the reducer does not know about GraphQL; the client does not know about Worktrees. This plan respects that layering at every milestone.

## Plan of Work

Seven milestones, roughly in increasing risk and visibility. M1–M3 are strictly additive — they introduce new code paths without changing reducer or view behaviour. M4–M6 perform the cutover inside the reducer. M7 is an optional post-ship refinement.

### Milestone 1: `RemoteInfo` + `GitService.remoteInfo(at:)`

**Goal.** Give the rest of the stack a reliable way to derive `(host, owner, repo)` from a Project's gitRoot, because every batched GraphQL query needs those three fields. No reducer or view touches this yet; it is pre-work for M3.

**What will exist at the end.** A new `RemoteInfo` value type in `CodansCore/Git/`, a new `GitService.remoteInfo(at:)` protocol method with a `LiveGitService` implementation, a new `GitServiceClient.remoteInfo` closure, eight parser-level unit tests covering URL variants (SSH, HTTPS, with/without `.git`, GHES hostname).

**Work items.**

In `apps/mac/CodansCore/Git/RemoteInfo.swift` (new file), define `public nonisolated struct RemoteInfo: Equatable, Sendable, Hashable` with `host: String`, `owner: String`, `repo: String` and a `public static func parse(_ urlString: String) throws -> RemoteInfo` method. The parser accepts three URL shapes: SSH-style `git@<host>:<owner>/<repo>.git`, HTTPS `https://<host>/<owner>/<repo>.git`, and explicit `ssh://git@<host>/<owner>/<repo>.git`. The `.git` suffix is optional. Invalid inputs throw a new `GitError.malformedRemoteURL(String)` case added in `apps/mac/codans/Git/GitError.swift`.

In `apps/mac/codans/Git/GitService.swift`, add to the protocol:

```swift
func remoteInfo(at path: URL) async throws -> RemoteInfo
```

In `apps/mac/codans/Git/GitCommand.swift`, add `static func remoteGetUrl(remote: String = "origin") -> [String]` returning `["remote", "get-url", remote]`.

In `apps/mac/codans/Git/LiveGitService.swift`, implement `remoteInfo(at:)` by running `GitCommand.remoteGetUrl()` with cwd = path, parsing stdout via `RemoteInfo.parse`. Map `GitError.malformedRemoteURL` to `GitHubError.remoteInfoUnavailable` at the *caller* level (the GitHub feature reducer), not here.

In `apps/mac/codans/App/Clients/GitServiceClient.swift`, add the `remoteInfo: @Sendable (URL) async throws -> RemoteInfo` closure to the struct definition, the `live(service:)` wiring, and the `testValue` stub.

Add unit tests in `apps/mac/codans/Tests/Git/` (or wherever the existing GitService tests live — check `Tests/` layout) covering the eight URL variants plus one malformed-URL case.

**Verification.**

```
$ cd apps/mac
$ xcodebuild test -workspace codans.xcworkspace -scheme codans \
    -destination 'platform=macOS' -only-testing:codansTests/RemoteInfoTests
```

Expected: all tests pass, including the new eight. No other test should be affected.

### Milestone 2: Extend `PullRequestSnapshot` with new fields

**Goal.** Widen the snapshot DTO to carry check rollup data and richer merge-state fields that the batched query returns. This is a pure model extension; nobody reads the new fields yet, so decoders must tolerate their absence (for the v1 `gh pr view` path that stays live until M6).

**What will exist at the end.** `PullRequestSnapshot` has four new fields: `checkRollup: [CheckResult]`, `mergeStateStatus: MergeStateStatus`, `reviewDecision: ReviewDecision?`, `headRepositoryOwner: String`. Two new Swift enums. Existing `gh pr view` parser populates the new fields with defaults (empty array, `.unknown`, nil, repository owner from the remote).

**Work items.**

In `apps/mac/CodansCore/GitHub/MergeStateStatus.swift` (new), define `public nonisolated enum MergeStateStatus: String, Codable, Sendable, Equatable` with cases matching GitHub's GraphQL enum: `clean`, `dirty`, `blocked`, `behind`, `hasHooks`, `unstable`, `unknown`, `draft`. Include a fallback decoder so unknown raw values decode to `.unknown` (GitHub adds enum cases; we must not fail).

In `apps/mac/CodansCore/GitHub/ReviewDecision.swift` (new), define `public nonisolated enum ReviewDecision: String, Codable, Sendable, Equatable` with cases: `approved`, `changesRequested`, `reviewRequired`. Fallback decoder: unknown → nil at the consumer level.

In `apps/mac/CodansCore/GitHub/PullRequestSnapshot.swift`, add the four fields. Codable `init(from:)` uses `decodeIfPresent` with these defaults: `checkRollup ?? []`, `mergeStateStatus ?? .unknown`, `reviewDecision ?? nil`, `headRepositoryOwner ?? ""`. `encode(to:)` emits them always (we're on the write side; no round-trip compatibility concern). Update the default initialiser parameter list with the same defaults.

In `apps/mac/codans/GitHub/JSONOutputParsers.swift`, update `parsePullRequest(_:)` to populate the new fields from the existing `gh pr view --json` response — `statusCheckRollup` is already available there if the call includes the field. In `apps/mac/codans/GitHub/GhCommand.swift`, extend `pullRequestView(branch:)` 's field list with `statusCheckRollup,mergeStateStatus,reviewDecision`.

Update existing golden-file fixtures under `apps/mac/codans/Tests/GitHubTests/Fixtures/` to include the new fields (regenerate from a real `gh pr view feature/github01 --json <updated field list>` run and check in).

Update `JSONOutputParsersTests.swift` and `GitHubFeatureTests.swift` expectations to assert the new fields. `RecordingCommandRunner`-based tests in `LiveGitHubServiceTests.swift` also need updated canned outputs.

**Verification.**

```
$ cd apps/mac
$ xcodebuild test -workspace codans.xcworkspace -scheme codans \
    -destination 'platform=macOS' -only-testing:codansTests/GitHubTests 2>&1 \
    | grep -E "(passed|failed)"
```

Expected: all GitHubTests pass. No regression in the broader suite — `gh pr view` still returns a valid snapshot; the UI doesn't yet consume the new fields so its rendering is unchanged.

### Milestone 3: `GitHubClient.batchPullRequests` + `LiveGitHubService` implementation

**Goal.** Ship the core new code path: one gh subprocess per chunk, chunks capped at 25 branches with max 3 concurrent, response decoded through dynamic keys and union-type normalization, fork-PR filter applied. The reducer and views do not call it yet; this milestone is validated purely by tests.

**What will exist at the end.** A new protocol method `GitHubService.batchPullRequests`, its `LiveGitHubService` implementation, the GraphQL query builder, the batched response decoder (with `DynamicKey` + `CheckNode`), the fork-PR filter, fourteen-plus unit tests covering every documented branch of the new code.

**Work items.**

In `apps/mac/codans/GitHub/GitHubService.swift`, add:

```swift
func batchPullRequests(
  host: String,
  owner: String,
  repo: String,
  branches: [String]
) async throws -> [String: PullRequestSnapshot]
```

In `apps/mac/codans/GitHub/GhCommand.swift`, add:

```swift
static func apiGraphQL(
  query: String,
  hostname: String,
  variables: [String: String]
) -> (arguments: [String], expectedExitCodes: Set<Int32>) {
  var args = ["api", "graphql", "--hostname", hostname, "-f", "query=\(query)"]
  for (key, value) in variables.sorted(by: { $0.key < $1.key }) {
    args.append("-f")
    args.append("\(key)=\(value)")
  }
  return (args, [0])
}
```

The variables dictionary is sorted to keep argv deterministic for test diffing.

In a new file `apps/mac/codans/GitHub/BatchedPullRequestQuery.swift`, write a pure function:

```swift
enum BatchedPullRequestQuery {
  static let chunkSize = 25
  static let maxConcurrentChunks = 3

  static func buildQuery(
    branches: [String]
  ) throws -> (query: String, aliasMap: [String: String])
}
```

`buildQuery` validates each branch name (reject any containing newline or null, escape backslash and double-quote for GraphQL string literals), assigns `branch0`…`branch{N-1}` aliases, returns the query string and the `[alias: originalBranch]` map. Throws `GitHubError.malformedBranchName(String)` if any branch fails validation (new error case).

Also in that file:

```swift
static func chunk(_ branches: [String]) -> [[String]]
```

that slices into up to `chunkSize`-length arrays.

In `apps/mac/codans/GitHub/JSONOutputParsers.swift`, add:

```swift
static func parseBatchedPullRequests(
  _ data: Data,
  aliasMap: [String: String],
  remoteOwner: String
) throws -> [String: PullRequestSnapshot]
```

The parser uses a private `DynamicKey: CodingKey` struct + iterating the `repository` object's keys, then for each alias's `nodes` array:

1. Decode each node into a raw `BatchedPullRequestNode` (has fork-filter fields + all snapshot fields).
2. Apply fork-filter rules: keep nodes where `headRepository.owner.login == remoteOwner`; if none, keep nodes where `baseRefName != headRefName`; if none, skip.
3. Pick the first survivor (already sorted by `UPDATED_AT DESC` server-side).
4. Convert to `PullRequestSnapshot`. Map `aliasMap[alias]` → branch name → dictionary key.

Branches that have an entry in `aliasMap` but no surviving PR after filtering are omitted from the returned dictionary (absence = no PR, matching the rest of the system's convention).

Introduce `CheckNode` union-type decoder (handling `CheckRun | StatusContext` per design doc §Response Decoding), and a conversion `CheckNode → CheckResult` that reuses the existing `CheckResult` enum.

In `apps/mac/codans/GitHub/GitHubError.swift`, add four cases: `graphQLError(String)`, `ghCLIOutdated(minVersion: String)`, `remoteInfoUnavailable`, `oversizeResponse(bytes: Int)`, `malformedBranchName(String)`. Update `GitHubError.userFacingMessage` accordingly.

In `apps/mac/codans/GitHub/LiveGitHubService.swift`, implement `batchPullRequests` as:

1. If `branches.isEmpty` return `[:]` without spawning.
2. Bump `maxOutputBytes` for this call to 8 MiB (was 2 MiB for per-Worktree calls; design doc §Security).
3. Build chunks via `BatchedPullRequestQuery.chunk(branches)`.
4. Run `withThrowingTaskGroup` with max-concurrent = 3, work-stealing pattern.
5. Each child task: builds query for its chunk, runs `gh api graphql`, decodes response, filters forks, returns `[branch: snapshot]`.
6. Merge child results. On any child failure, cancel siblings and rethrow.

In `apps/mac/codans/App/Clients/GitHubClient.swift`, add the `batchPullRequests` closure mirroring the service method signature.

**New test file** `apps/mac/codans/Tests/GitHubTests/BatchedPullRequestsTests.swift` covering, at minimum:

1. Single-chunk happy path (2 branches, both with PRs).
2. Multi-chunk path (60 branches → 3 chunks).
3. Fork-PR filter: upstream + fork, keeps upstream.
4. Fork-PR filter: only fork, keeps if `baseRefName != headRefName`.
5. Fork-PR filter: only fork with `base == head`, drops.
6. Empty branches array → no subprocess, returns `[:]` (assert via RecordingCommandRunner call count == 0).
7. Chunk mid-fetch throws → other chunks cancelled, error propagates.
8. Malformed branch name → throws before any subprocess.
9. Response with `"data": null` + `"errors": [...]` → throws `.graphQLError`.
10. Oversize response → throws `.oversizeResponse(bytes:)`.
11. `ghCLIOutdated` detection from stderr pattern.
12. `remoteInfoUnavailable` — actually, this is thrown higher up (by the reducer after `GitService.remoteInfo` fails), not in batchPullRequests; skip here.
13. Branch with zero PRs (empty `nodes` array) → branch is absent from returned dictionary.
14. Branch with five PRs → returns most-recent (first after server-side sort).

Two new golden-file JSON fixtures in `apps/mac/codans/Tests/GitHubTests/Fixtures/`:

- `batched-pr-happy.json` — a two-branch response with fully populated PR data.
- `batched-pr-fork-noise.json` — a response where one branch has upstream + fork noise to exercise filtering rules.

**Verification.**

```
$ cd apps/mac
$ xcodebuild test -workspace codans.xcworkspace -scheme codans \
    -destination 'platform=macOS' \
    -only-testing:codansTests/BatchedPullRequestsTests 2>&1 \
    | grep -E "Test .* (passed|failed)" | tail -20
```

Expected: fourteen new tests pass. No existing test regresses. `GitHubFeatureTests` remains at 19 passing — the reducer hasn't switched paths yet.

Also, exercise it against real `gh` once, outside CI:

```
$ cd apps/mac
$ TC_RUN_GITHUB_INTEGRATION_TESTS=1 xcodebuild test \
    -workspace codans.xcworkspace -scheme codans \
    -destination 'platform=macOS' \
    -only-testing:codansTests/BatchedPullRequestsIntegrationTests
```

(Test file to be added alongside the unit tests, skipped unless the env var is set.)

### Milestone 4: Reducer migration — dual-path during transition

**Goal.** Introduce the Project-level fetch path in `GitHubFeature`, have it populate the **same** `state.snapshots` dictionary the views already read, and keep the v1 per-Worktree path working so rollback is trivial. This is the largest reducer change; it is load-bearing because every subsequent milestone builds on it.

**What will exist at the end.** Four new reducer actions (`projectActivated` / `projectRefreshRequested` / `projectBatchLoaded` / `worktreeBranchChanged`), four new state slots (`snapshotsByProject`, `inFlightFetchProjects`, `queuedRefreshByProject`, `lastErrorByProject`), a new observed stream from `HierarchyManager` that dispatches `projectActivated` on selection changes, eight new `TestStore` tests. The v1 `worktreeBecameVisible` action is retained and still functional.

**Work items.**

In `apps/mac/codans/App/Features/GitHub/GitHubFeature.swift`, extend `State`:

```swift
var snapshotsByProject: [ProjectID: BatchedPullRequests] = [:]
var inFlightFetchProjects: Set<ProjectID> = []
var queuedRefreshByProject: Set<ProjectID> = []
var lastErrorByProject: [ProjectID: GitHubError] = [:]
```

Extend `Action`:

```swift
case projectActivated(ProjectID, gitRoot: URL, branches: [(worktreeID: WorktreeID, branch: String)])
case projectRefreshRequested(ProjectID, gitRoot: URL, branches: [(worktreeID: WorktreeID, branch: String)])
case projectBatchLoaded(ProjectID, TaskResult<BatchedPullRequests>)
case worktreeBranchChanged(WorktreeID, newBranch: String, projectID: ProjectID, gitRoot: URL)
```

Extend `CancelID`:

```swift
case projectFetch(ProjectID)
case delayedProjectRefresh(ProjectID)
case availabilityRecovery   // already reserved in design; add now
```

Implement handlers per the design doc's "Fetch Scheduling in the Reducer" section. The re-entrancy model (in-flight + queued) is covered there; the implementation is a straightforward translation.

Add a helper `state.projectionSnapshot(worktreeID:)` that, given a WorktreeID, returns the projected `PullRequestSnapshot?` from `snapshotsByProject`. Use this for write-action delegate payloads (mergeCompleted etc.).

Wire the observation: in `apps/mac/codans/App/Features/Root/RootFeature.swift`, subscribe to `HierarchyManager.selectedProjectIDChanges` (add this if not already present) and dispatch `GitHubFeature.Action.projectActivated` with the Project's gitRoot and visible branches.

**During M4 only, the per-Worktree path still works.** The existing `worktreeBecameVisible` handler continues to write into `state.snapshots[worktreeID]`. The new `projectBatchLoaded` handler writes into `state.snapshotsByProject` AND (for M4 compat) projects into `state.snapshots[worktreeID]` for each branch found. Views read from `state.snapshots` unchanged. Both paths coexist; the more recent write wins.

Add a hidden feature flag `SettingsStore.general.githubFetchModel: "legacy" | "batched"` (default `"batched"`) and gate the per-Worktree path behind `"legacy"`. This gives a single-line rollback during M4 – M5.

**New TestStore tests** in `apps/mac/codans/Tests/GitHubTests/GitHubFeatureTests.swift`:

1. `projectActivatedWithEmptyBranchesIsNoop`
2. `projectActivatedFiresSingleBatchFetch`
3. `projectActivatedWhileInFlightQueuesRefresh`
4. `queuedRefreshFiresAfterInFlightCompletes`
5. `projectBatchLoadedPopulatesPerWorktreeSnapshots`
6. `projectBatchLoadedFailureStoresLastError`
7. `mergeCompletedSchedulesDelayedProjectRefresh`
8. `worktreeBranchChangedInvalidatesProjectAndRefreshes`

**Verification.**

```
$ xcodebuild test -workspace apps/mac/codans.xcworkspace -scheme codans \
    -destination 'platform=macOS' \
    -only-testing:codansTests/GitHubFeatureTests
```

Expected: 19 existing + 8 new = 27 tests passing.

Manual smoke: `make -C apps/mac run-app`, activate the `codans` Project, observe that all PR badges paint in one visible frame (not staggered). Compare to the same operation on main prior to this commit.

### Milestone 5: View migration — check rollup from snapshot, retire per-row `.task`

**Goal.** Remove the per-row `.task(id: BadgeTaskIdentity)` that currently drives `worktreeBecameVisible`. The reducer is now responsible for kicking off fetches via Project-level events; the view layer becomes strictly passive.

**What will exist at the end.** `WorktreeGitHubBadge` has no `.task(id:)` for `worktreeBecameVisible`. The popover reads `snapshot.checkRollup`. The sidebar-row check-rollup overlay reads `snapshot.checkRollup`. `state.checks[prNumber]` dictionary is not yet removed (M6), but nothing writes to it anymore after this milestone.

**Work items.**

In `apps/mac/codans/App/Features/HierarchySidebar/WorktreeGitHubBadge.swift`:

1. Delete the `.task(id: BadgeTaskIdentity(...))` modifier.
2. Delete the `BadgeTaskIdentity` private struct (unused after #1).
3. The `.popover` and `.onHover` modifiers stay — they don't need the `Color.clear.frame(0,0)` workaround anymore, but keeping it is harmless. Leave unchanged for minimal diff.

In `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarView.swift`, inside `worktreeRow(...)`, replace:

```swift
let rollup: PullRequestBadge.CheckRollup = {
  guard let snapshot, let checks = gitHubStore?.checks[snapshot.number] else {
    return .noChecks
  }
  return PullRequestBadge.CheckRollup.from(checks: checks)
}()
```

with:

```swift
let rollup: PullRequestBadge.CheckRollup = {
  guard let snapshot else { return .noChecks }
  return PullRequestBadge.CheckRollup.from(checks: snapshot.checkRollup)
}()
```

In `apps/mac/codans/App/Features/GitHub/Views/PullRequestPopover.swift`, change its `Content.loaded(snapshot, checks:, workflowRun:)` case to `.loaded(snapshot, workflowRun:)` — the `checks` parameter is redundant because `snapshot.checkRollup` carries the same data. Update `HierarchySidebarView.gitHubPopoverContent` call site accordingly.

In `GitHubFeature.swift`, remove the `checksFetchEffect(...)` call from `snapshotLoaded(.success)` — the reducer no longer needs to prefetch checks because the batched path already includes them and the per-Worktree path is gated behind the legacy flag. If legacy mode is on (flag = `"legacy"`), re-add the effect; expressed via an `if` at that call site.

Update the three TestStore tests from commit `9bf5c91` that now need to NOT expect `checksLoaded`:

1. `worktreeBecameVisibleLoadsSnapshot` — remove the `await store.receive(.checksLoaded(...))` step (test now targets the new non-prefetch default).
2. `refreshRequestedForcesReload` — same.
3. `mergeSucceededEmitsDelegate` — same.

**Verification.**

```
$ xcodebuild test -workspace apps/mac/codans.xcworkspace -scheme codans \
    -destination 'platform=macOS' \
    -only-testing:codansTests/GitHubTests
```

Expected: all GitHub tests pass (count unchanged from M4's 27).

Manual: `make -C apps/mac run-app`, cold-launch with codans Project active. Observe check-rollup overlays paint in the same frame as the PR badge, not after. Compare against M4's run.

### Milestone 6: Delete v1 fetch path

**Goal.** Pure subtraction commit. Everything in v1 that has been migrated to v2 is removed. This is the smallest milestone by LOC added (expect negative diff), the largest by LOC deleted.

**What will exist at the end.** Per-Worktree `pullRequest` / `checks` / `latestWorkflowRun` methods are deleted from `GitHubService` and `GitHubClient`. `state.checks[prNumber]` dictionary is deleted from `GitHubFeature.State`. `worktreeBecameVisible` action is deleted. `snapshotFetchEffect` / `checksFetchEffect` / `workflowRunFetchEffect` helpers are deleted. The `"legacy"` branch of the `githubFetchModel` flag is deleted (and the flag itself is deleted if no legacy case remains).

**Work items.**

In `apps/mac/codans/GitHub/GitHubService.swift`, remove:

- `func pullRequest(branch: String, worktreePath: URL)` — replaced by `batchPullRequests(branches: [branch])`.
- `func checks(number: Int, worktreePath: URL)` — data is now inside snapshots.
- `func latestWorkflowRun(branch: String, worktreePath: URL)` — see Open Question 4 in the design doc; if the URL-parse path landed in M3, delete this. Otherwise leave as a single-call method.

Mirror the deletions in `apps/mac/codans/GitHub/LiveGitHubService.swift`, `apps/mac/codans/GitHub/GhCommand.swift` (`pullRequestView`, `pullRequestChecks`, `runListLatest`), and `apps/mac/codans/App/Clients/GitHubClient.swift`.

In `apps/mac/codans/GitHub/JSONOutputParsers.swift`, remove `parsePullRequest`, `parseChecks`, `parseLatestWorkflowRun` — all replaced by `parseBatchedPullRequests`. `parseAuthStatus` stays.

In `apps/mac/codans/App/Features/GitHub/GitHubFeature.swift`:

- Remove `State.checks: [Int: [CheckResult]]`.
- Remove `State.latestWorkflowRuns: [Int: WorkflowRun]` if Open Question 4's URL-parse path landed; otherwise keep.
- Remove `Action.worktreeBecameVisible`, `Action.refreshRequested` (replaced by `Action.projectRefreshRequested`), `Action.snapshotLoaded`, `Action.checksLoaded`, `Action.workflowRunLoaded`.
- Remove helpers `snapshotFetchEffect`, `checksFetchEffect`, `workflowRunFetchEffect`, `postMutationRefresh` (replaced by direct `projectRefreshRequested` dispatch).
- Remove the `githubFetchModel` feature flag.

Update call sites:

- `apps/mac/codans/App/Features/HierarchySidebar/WorktreeGitHubBadge.swift` — already removed `worktreeBecameVisible` in M5; confirm no references remain.
- The error-case badge that calls `.refreshRequested` needs to dispatch `.projectRefreshRequested` instead. Plumb the project context through.

Delete the TestStore tests for removed actions (approximately nine tests). Confirm the remaining tests still describe the system correctly.

Update `docs/architecture.md` codemap's `codans/GitHub/` entry to drop mentions of `pr view / pr checks / run list` and add `gh api graphql`.

**Verification.**

```
$ xcodebuild test -workspace apps/mac/codans.xcworkspace -scheme codans \
    -destination 'platform=macOS' \
    -only-testing:codansTests/GitHubTests
```

Expected: GitHubTests count drops to 27 – 9 + (any M5/M6-specific tests) ≈ 22 tests passing.

Manual smoke: same as M5 — app starts, badges paint, merge/close/markReady work.

### Milestone 7 (optional): `WorktreeBranchWatcher`

**Goal.** Observe each active Worktree's `.git/HEAD` via a filesystem watcher so terminal-initiated `git checkout` lands in the sidebar within ~1 s instead of waiting for `HierarchyManager` reconcile at focus-gained.

**What will exist at the end.** A new `@Observable WorktreeBranchWatcher` service (pattern copied from `WorktreeStatusMonitor`), installed in ContentView environment, wired into `HierarchySidebarView`'s per-row `.task(id: worktree.id)`. On any HEAD change for a visible Worktree, it dispatches `GitHubFeature.Action.worktreeBranchChanged`.

**Work items.** (Deferred until M1–M6 are stable. Scope details in design doc §Risks R3.)

**Ship criterion.** Ship M7 when a user reports the branch-lag as disruptive; otherwise defer.

## Concrete Steps

All commands assume working directory `/Users/wanggang/dev/00/codans` unless noted. The user runs these by hand between milestones; agent only invokes them when explicitly asked.

**Baseline check before starting M1:**

```
$ make -C apps/mac build 2>&1 | tail -3
  ** BUILD SUCCEEDED **

$ make -C apps/mac lint 2>&1 | tail -3
  # Baseline lint passes (pre-existing violations only, no new ones introduced)

$ xcodebuild test -workspace apps/mac/codans.xcworkspace -scheme codans \
    -destination 'platform=macOS' -only-testing:codansTests/GitHubTests 2>&1 \
    | grep "Test run" | tail -1
  Test run with 19 tests in 1 suite passed after [N.NN] seconds.
```

**Per-milestone build+test:**

```
$ make -C apps/mac build                    # expect: ** BUILD SUCCEEDED **
$ make -C apps/mac lint 2>&1 | grep -E "<changed-files-in-milestone>"    # expect: empty
$ xcodebuild test -workspace apps/mac/codans.xcworkspace -scheme codans \
    -destination 'platform=macOS' \
    -only-testing:codansTests/<milestone-specific-tests>
```

**Per-milestone commit (following project convention `/commit` cadence):**

```
$ git add <files>
$ git commit -m "<type>(<scope>): <description>"
```

Commit messages follow the `feat / fix / refactor / test / docs / chore` types and the `(scope)` conventions of recent sidebar-redesign commits (see commit `8b9f10f` for style reference).

## Validation and Acceptance

**Functional acceptance** (runs at M5 complete; M6 is a pure-subtraction follow-up):

1. `make -C apps/mac run-app`. Wait for main window.
2. Expect: a Project with 20+ Worktrees (use the `codans` Project in the author's catalog, which has `feature/github01`, `feature/command-p`, `feature/theme`, etc.) shows every matching PR badge within ~600 ms of the window becoming interactive. Measure with stopwatch; acceptance is "noticeably faster than v1 — one frame vs. 2–3 second wave".
3. For a Worktree on branch `feature/github01`: badge is purple `git-merge` icon, `#39` capsule, `+5759 −73` diff stats. Popover opens on hover. Merge button is disabled (already merged) with tooltip "Pull request is already merged".
4. Click Merge (on a live open PR, if any exist at test time). Within 2 seconds the badge flips to merged state without a manual refresh.
5. In a terminal, inside the `feature/github01` Worktree: `git checkout feature/theme` (or any other branch that maps to a different PR). The badge updates within focus-regain (v2.0) or ~1 s (v2.1 with watcher).
6. `killall gh` in a terminal. Wait 30 s. Badges still render the last-known state. Settings → GitHub shows `gh not available` banner within ~45 s. Reinstall and wait; within 15 s the feature recovers and Settings banner clears.

**Test-suite acceptance**:

- M1: `RemoteInfoTests` — 9 new (8 URL variants + 1 malformed).
- M3: `BatchedPullRequestsTests` — 14 new (plus 2 integration tests gated on `TC_RUN_GITHUB_INTEGRATION_TESTS`).
- M4: `GitHubFeatureTests` — 19 existing + 8 new.
- M5: `GitHubFeatureTests` — 27 total (3 of the existing tests modified to remove `checksLoaded` expectation).
- M6: `GitHubFeatureTests` drops to ~22 (deletions for removed actions).

Total new tests delivered by this plan: approximately 31. No pre-existing failure in the broader suite should regress.

## Idempotence and Recovery

Each milestone's file additions are new-file operations and can be re-run (the file already exists; Write tool reports "already exists" and is a no-op). Each milestone's file edits are localized enough that a partial apply produces a syntactically valid intermediate state — `xcodebuild build` will fail with a named compile error pointing at the missing function or method. The recovery path is always:

```
$ git diff   # inspect what got through
$ git restore --staged <file>
$ git restore <file>
```

and resume from the failing step.

**Rollback plan** per design doc:

- M1–M3 are additive. `git revert <M3-commit>..<M1-commit>` removes them cleanly with no orphans.
- M4 is reversible via the `githubFetchModel` flag: set it to `"legacy"` at runtime and the v1 fetch path resumes. The flag is deleted in M6; between M4 and M6, rollback is a one-line setting change.
- M5 hard-deletes the per-row `.task`. Rollback is `git revert` of the M5 commit, which restores the `.task(id:)` block.
- M6 is the point of no return — v1 code is gone. Rollback is `git revert` of M6's single commit.

**Catalog safety.** `settings.json` is never written to by this plan (all new state is memory-only). Existing `settings.json` files on disk remain valid across all milestones.

## Artifacts and Notes

**Sample GraphQL query (2 branches).** This is what M3 emits. A developer debugging Phase 3 may paste the query into GitHub's GraphiQL explorer to verify hand-written cases.

```graphql
query($owner: String!, $repo: String!) {
  repository(owner: $owner, name: $repo) {
    branch0: pullRequests(
      first: 5,
      states: [OPEN, MERGED],
      headRefName: "feature/github01",
      orderBy: {field: UPDATED_AT, direction: DESC}
    ) {
      nodes {
        number title state isDraft
        additions deletions
        mergeable mergeStateStatus reviewDecision
        url updatedAt headRefName baseRefName
        commits { totalCount }
        author { login }
        headRepository { name owner { login } }
        statusCheckRollup {
          contexts(first: 100) {
            nodes {
              ... on CheckRun { name status conclusion startedAt completedAt detailsUrl }
              ... on StatusContext { context state targetUrl createdAt }
            }
          }
        }
      }
    }
    branch1: pullRequests(first: 5, states: [OPEN, MERGED],
      headRefName: "feature/theme",
      orderBy: {field: UPDATED_AT, direction: DESC}) {
      nodes { ... same fields ... }
    }
  }
}
```

**Expected response shape** (excerpt):

```json
{
  "data": {
    "repository": {
      "branch0": {
        "nodes": [
          {
            "number": 39,
            "state": "MERGED",
            "mergeStateStatus": "CLEAN",
            "additions": 5759, "deletions": 73,
            "headRefName": "feature/github01",
            "baseRefName": "main",
            "headRepository": { "owner": { "login": "wanggang316" } },
            "statusCheckRollup": {
              "contexts": {
                "nodes": [
                  { "name": "build", "status": "COMPLETED", "conclusion": "SUCCESS", ... },
                  ...
                ]
              }
            },
            ...
          }
        ]
      },
      "branch1": { "nodes": [ ... ] }
    }
  }
}
```

**Decoding the response — `DynamicKey` pattern** (reference from design doc §Response Decoding, included here for M3 implementers):

```swift
struct DynamicKey: CodingKey {
  let stringValue: String
  let intValue: Int? = nil
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { self.stringValue = "\(intValue)" }
}
```

**Validation script** for deterministic GraphQL query output (used in M3 unit tests):

```swift
func test_buildQuery_twoBranches_producesStableOutput() {
  let (query, aliasMap) = try BatchedPullRequestQuery.buildQuery(
    branches: ["feature/github01", "feature/theme"]
  )
  #expect(query == readFixture("batched-query-two-branches.graphql"))
  #expect(aliasMap == ["branch0": "feature/github01", "branch1": "feature/theme"])
}
```

## Interfaces and Dependencies

Libraries and services used:

- **`gh` CLI version 2.20+**, resolved via existing `GhExecutableResolver`. The `api graphql` subcommand, `--hostname` flag, and `-f query=<body>` argument form are the only new CLI surface. Version 2.20 is the floor because `--hostname` support on `api graphql` stabilized there; an earlier version's behavior is undefined.
- **Composable Architecture (TCA) reducers and `@Dependency`** — unchanged from v1.
- **Foundation `URL`, `JSONDecoder`, `Date`** — unchanged from v1.
- **`withThrowingTaskGroup`** for concurrent chunk execution — new usage for this module.

Types that must exist at milestone-specific points:

In `apps/mac/CodansCore/Git/RemoteInfo.swift` (M1):

```swift
public nonisolated struct RemoteInfo: Equatable, Sendable, Hashable {
  public let host: String
  public let owner: String
  public let repo: String
  public init(host: String, owner: String, repo: String)
  public static func parse(_ urlString: String) throws -> RemoteInfo
}
```

In `apps/mac/codans/Git/GitService.swift` (M1):

```swift
public nonisolated protocol GitService: Sendable {
  // existing methods...
  func remoteInfo(at path: URL) async throws -> RemoteInfo
}
```

In `apps/mac/CodansCore/GitHub/MergeStateStatus.swift` (M2):

```swift
public nonisolated enum MergeStateStatus: String, Codable, Sendable, Equatable {
  case clean, dirty, blocked, behind, hasHooks, unstable, unknown, draft
}
```

In `apps/mac/CodansCore/GitHub/ReviewDecision.swift` (M2):

```swift
public nonisolated enum ReviewDecision: String, Codable, Sendable, Equatable {
  case approved, changesRequested, reviewRequired
}
```

In `apps/mac/codans/GitHub/GitHubService.swift` (M3):

```swift
public nonisolated protocol GitHubService: Sendable {
  // existing methods...
  func batchPullRequests(
    host: String,
    owner: String,
    repo: String,
    branches: [String]
  ) async throws -> [String: PullRequestSnapshot]
}
```

In `apps/mac/codans/GitHub/BatchedPullRequestQuery.swift` (M3):

```swift
enum BatchedPullRequestQuery {
  static let chunkSize: Int = 25
  static let maxConcurrentChunks: Int = 3

  static func buildQuery(
    branches: [String]
  ) throws -> (query: String, aliasMap: [String: String])

  static func chunk(_ branches: [String]) -> [[String]]
}
```

In `apps/mac/codans/App/Clients/GitHubClient.swift` (M3, M6):

```swift
nonisolated struct GitHubClient: Sendable {
  var availability: @Sendable () async -> GitHubAvailability
  var batchPullRequests: @Sendable (
    _ host: String, _ owner: String, _ repo: String, _ branches: [String]
  ) async throws -> [String: PullRequestSnapshot]
  var merge: @Sendable (_ number: Int, _ strategy: MergeStrategy, _ worktreePath: URL) async throws -> Void
  var close: @Sendable (_ number: Int, _ worktreePath: URL) async throws -> Void
  var markReady: @Sendable (_ number: Int, _ worktreePath: URL) async throws -> Void
  var rerunFailedJobs: @Sendable (_ runID: Int64, _ worktreePath: URL) async throws -> Void
  // post-M6: pullRequest / checks / latestWorkflowRun are gone.
}
```

In `apps/mac/codans/App/Features/GitHub/GitHubFeature.swift` state (M4):

```swift
@ObservableState
struct State: Equatable {
  // existing availability + popover + mutating fields...
  var snapshots: [WorktreeID: PullRequestSnapshot] = [:]        // derived projection
  var snapshotsByProject: [ProjectID: BatchedPullRequests] = [:]
  var inFlightFetchProjects: Set<ProjectID> = []
  var queuedRefreshByProject: Set<ProjectID> = []
  var lastErrorByProject: [ProjectID: GitHubError] = [:]
  var worktreePaths: [WorktreeID: URL] = [:]   // still needed for write-action routing
}
```

Reducer actions (M4):

```swift
enum Action: Equatable {
  case projectActivated(ProjectID, gitRoot: URL,
                        branches: [(worktreeID: WorktreeID, branch: String)])
  case projectRefreshRequested(ProjectID, gitRoot: URL,
                               branches: [(worktreeID: WorktreeID, branch: String)])
  case projectBatchLoaded(ProjectID, TaskResult<BatchedPullRequests>)
  case worktreeBranchChanged(WorktreeID, newBranch: String,
                             projectID: ProjectID, gitRoot: URL)
  // existing popover / merge / close / markReady / rerun / availability / delegate cases...
}
```

Cancel IDs (M4):

```swift
nonisolated enum CancelID: Hashable, Sendable {
  case availabilityRefresh
  case availabilityRecovery
  case projectFetch(ProjectID)
  case delayedProjectRefresh(ProjectID)
  case mutation(WorktreeID)
  // retired: snapshot(WorktreeID), checks(Int), workflowRun(Int)
}
```
