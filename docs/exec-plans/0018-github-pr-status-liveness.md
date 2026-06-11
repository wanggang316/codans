# ExecPlan: GitHub PR Status Liveness — focus-gated adaptive refresh

**Status:** Complete (M4 deferred)
**Author:** Gump (with Claude)
**Date:** 2026-05-29

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

Today, a PR's state in the sidebar badge and the status bar can sit stale indefinitely while the user works. After a PR's checks finish, a reviewer approves, a teammate merges or closes it on the web, or a fresh PR is opened from a terminal, **nothing in the app reflects the change** until the user happens to switch Projects, run a local `git checkout`, or trigger the error-state retry. For a tool whose users live inside its terminal panes for long stretches, that means "GitHub state changed without me touching the local repo" is invisible by default.

After this plan lands, the **active Project's** PR data refreshes on its own while the app is in the foreground:

- A PR whose CI is still running has its check rollup repainted on a tight cadence (~15 s), so red/green flips appear without any user action.
- A PR merged or closed elsewhere flips to its terminal state within one slow-cadence cycle (~60 s) while the user is looking at the app.
- A PR opened from a terminal pane (or anywhere) appears in the sidebar within one slow cycle, without a Project switch.
- Refresh **pauses entirely** when the app is not the active application, so an idle or backgrounded app spends zero GitHub rate-limit budget and no CPU on polling.

What a contributor observes after this plan lands, compared to today:

1. Open a PR's worktree, push a commit that re-triggers CI in a terminal pane. Previously the badge's check overlay stays at its last-seen color until you switch Projects and back. After this plan: the overlay flips to "running" within ~15 s and to its final pass/fail color within ~15 s of CI completing — app in foreground, no interaction.
2. A teammate merges your PR on github.com. Previously the row keeps its open pill until you cause a local invalidation. After this plan: the row flips to merged within ~60 s while the app is foreground.
3. Background the app (cmd-tab away). Previously there was no polling to stop; after this plan, polling is provably paused — no `gh api graphql` subprocess fires until the app is active again.

This plan adds no new visual surface; the badges, popover, and status bar are unchanged. It changes **when** their data is refreshed.

## Progress

- [x] M1 — Foreground poll of the active Project at a fixed cadence, gated on app-active — 2026-05-30
- [x] M2 — Adaptive cadence: fast while any open PR has CI in flight or unsettled merge state; slow otherwise — 2026-05-30
- [x] M3 — Migrate post-mutation + manual retry to project-level `projectRefreshRequested`; retire the residual v1 single-branch fetch surface (closes 0013 DEC-6 / follow-up #1) — 2026-05-30
- [ ] M4 — (Optional) Terminal command-detection immediate refresh — **deferred**, see DEC-3
- [x] M5 — Documentation: amend the v2 design doc's invalidation model + Alternative D; cross-link from 0013 — 2026-05-30

Each unchecked entry gets a completion timestamp `— 2026-MM-DD` when the milestone lands (matching the `0013` convention).

Landing commits: `8c37fc93` (plan), `2691ef31` (M1–M3 reducer + RootFeature wiring + post-mutation/retry migration), `e81f4ca6` (M3 v1-surface deletion), this commit (M5 docs). The RootFeature poll wiring was physically committed inside `43fb505d` — see DEC-4.

## Surprises & Discoveries

### S-1 (2026-05-30): Pre-existing test-target breakage blocked the M3 build

The `codansTests` target did not compile at HEAD before this work started: commit `9e7e198e` had added a `changeTypes: [String: ChangeStatus]` parameter to `DiffFeature.Action.commitDiffSucceededFor` but left three test call sites in `DiffFeatureTests.swift` (≈ lines 523, 845, 1076) on the old signature. Because the whole test target must compile before any filtered subset runs, this masked the GitHub work entirely. Fixed in `a7f08fed` by passing `changeTypes: [:]` at the three sites — independent of 0018, but a prerequisite for verifying it.

### S-2 (2026-05-30): `worktreePaths` is now write-only state

Removing the v1 surface left `state.worktreePaths` written by the kept mutation/popover handlers (`presentPopover`, `mergeRequested`, `closeRequested`, `markReadyRequested`, `rerunFailedJobsRequested`) but **read by nothing** in production — the batched path resolves paths from `projectGitRoots` / `projectWorktreePairs` instead. Deleting it was left out of scope here because its writers are all kept actions, so removing it would mean touching unrelated handlers and re-baselining their TestStore assertions. Flagged as a candidate for a separate cleanup commit.

### S-3 (2026-05-30): Parallel-editing entanglement with an unrelated refactor

The RootFeature poll wiring (M1) was edited in the same `RootFeature.swift` working copy as an unrelated diff-inspector refactor in progress. The two changes could not be cleanly separated by the time the file was committed, so the poll wiring physically landed inside `43fb505d` (`refactor(diff-inspector): …`) rather than the `feat(github)` commit. History was deliberately **not** rewritten to un-mix them. See DEC-4.

## Decision Log

### DEC-1 (2026-05-29): Scoped foreground poll, not background polling

The v2 GitHub design (`docs/design-docs/github-integration-batched.md`) deliberately chose pure event-driven invalidation and rejected periodic polling (Alternative D). The stated objections were: continuous rate-limit burn while the user is away, battery drain, and introducing a "background activity" concept the app otherwise lacks.

Those objections all target *background, all-Project, runs-while-AFK* polling. They do not apply to a poll that is:

- **Scoped to the single active Project** — at most one repository's worth of branches per cycle, never the whole catalog.
- **Gated on the app being the active application** — the loop is cancelled the instant the app resigns active, so an idle or backgrounded app polls zero times. This is the property that answers "AFK rate-limit burn" and "battery": an AFK user's app is not the active application.
- **Adaptive** — fast only while there is something genuinely in flight (open PR with running CI or unsettled merge state); slow otherwise; and even the slow cadence runs only while foreground.

The premise in Alternative D that "event-driven is strictly better — same freshness guarantee when the user is interacting" does not hold for **remote** state: the user typing in a terminal pane is not a GitHub-invalidating event, so there is no freshness guarantee for check/review/merge changes that originate on GitHub's side. This plan adds the missing signal for exactly those remote changes, under gating that preserves the zero-idle-cost property the original design valued.

### DEC-2 (2026-05-29): Reuse `projectRefreshRequested` + the existing re-entrancy model

The poll does not introduce a new fetch path. Each tick dispatches the existing `projectRefreshRequested`, which already honours `inFlightFetchProjects` / `queuedRefreshByProject` and is tagged `CancelID.projectFetch(P)`. A tick that lands while a prior fetch is still running collapses into the queued-refresh slot instead of stacking subprocesses. The poll's own re-arm timer is a separate single-slot cancellable (`CancelID.poll`), so retargeting or pausing cleanly tears down the loop.

### DEC-3 (2026-05-30): M4 (terminal command-detection) deferred to a later plan

M4 would shorten the cold-start lag for a PR the user *just* created or pushed from a terminal pane, by turning a `gh`/`git push` foreground-job exit into an immediate forced refresh. It is deferred for v1 because the M1/M2 poll already bounds worst-case staleness: a remotely-originated PR or branch surfaces within one idle cycle (~60 s) while the app is foreground. The remaining gap is purely the cold-start interval between "command finished in a pane" and "next idle tick" — acceptable for v1, and not worth coupling the GitHub reducer to `TerminalEngine`'s foreground-job poll before the simpler poll has proven itself in use. The hook point (`Runtime/TerminalEngine.swift` foreground-job poll → RootFeature → forced `projectRefreshRequested`) is recorded in the M4 milestone so a later plan can pick it up without re-discovery.

### DEC-4 (2026-05-30): RootFeature poll wiring physically landed in an unrelated commit

The M1 RootFeature wiring (the `didResignActiveNotification` stream, `makePollTargetChange`, and the `selectionChanged` retarget) was edited in a `RootFeature.swift` working copy that already carried an in-progress, unrelated diff-inspector refactor. The two could not be cleanly separated by commit time, so the poll wiring physically landed inside `43fb505d` (`refactor(diff-inspector): …`) rather than the `feat(github)` commit `2691ef31`. History was deliberately **not** rewritten to un-mix them — rewriting shared branch history to satisfy commit hygiene was judged higher-risk than recording the entanglement here. See S-3. Future readers tracing the poll wiring should look in `43fb505d`, not only the `feat(github)` commits.

## Outcomes & Retrospective

### 2026-05-30 — M1–M3 + M5 delivered; M4 deferred

**Delivered.** The active Project's PR data now refreshes on its own while codans is the frontmost app, with zero polling cost when it is not:

- **M1** — a single-slot cancellable poll (`CancelID.poll`) re-issues `projectRefreshRequested` for the active Project on a clock-driven timer, gated on app-active via `pollTargetChanged`. Resigning active dispatches `pollTargetChanged(nil)`, which cancels the loop; becoming active or switching Projects re-points it.
- **M2** — the cadence is chosen per tick from the target's last snapshot: ~15 s while any open PR has unsettled merge state or a non-completed check, ~60 s once settled. The idle cadence still runs (while foreground) so remote merges/closes/new PRs surface within ~60 s.
- **M3** — `postMutationRefresh` and the badge/popover retry now drive the project-level batched path (delayed `projectRefreshRequested`), and the dormant v1 single-branch surface (`worktreeBecameVisible` / `refreshRequested` / `snapshotLoaded` actions, `snapshotFetchEffect`, `GitHubService.pullRequest` + its live impl, `GhCommand.pullRequestView`, `JSONOutputParsers.parsePullRequest`, and their tests) was removed. This closes 0013 DEC-6 / Future-work #1.
- **M5** — the v2 design doc's Caching & Invalidation table and Alternative D now record the adopted poll; 0013 Future-work #1 is struck through and cross-linked here.

**Deferred.** M4 (terminal command-detection immediate refresh) — see DEC-3.

**Verification.** The whole `codansTests` target compiles and the GitHub + Root suites pass (`** TEST SUCCEEDED **`). A pre-existing, unrelated test-target break had to be fixed first to even reach the GitHub tests — see S-1.

**Lessons.**
- The original v2 design's rejection of polling (Alternative D) was sound *for its scope* (background, all-Project, AFK). Re-reading the objections showed every one of them keys on properties this poll deliberately lacks — the right move was to scope and gate, not to relitigate the rejection. (DEC-1.)
- Reusing `projectRefreshRequested` + the existing in-flight/queued model meant the poll added no new fetch path and inherited re-entrancy safety for free. (DEC-2.)
- Two follow-ups left open by this work: `worktreePaths` is now write-only dead state (S-2), and the poll wiring is mixed into an unrelated commit (S-3 / DEC-4). Both are recorded rather than silently carried.

## Context and Orientation

Related documents:
- Design doc: `docs/design-docs/github-integration-batched.md` — the v2 execution model, GraphQL shape, and the **Caching and Invalidation** section + **Alternative D** that this plan revises.
- Prior plan: `docs/exec-plans/0013-github-integration-batched.md` — DEC-6 and "Future work #1" describe the postMutationRefresh→project-level migration that M3 here delivers.

Key source files:
- `apps/mac/codans/App/Features/GitHub/GitHubFeature.swift` — TCA reducer owning PR snapshot state. Already has `projectRefreshRequested`, the per-Project in-flight/queued re-entrancy model, `enqueueProjectFetch`, `projectGitRoots`, and the `CancelID` enum. This plan adds a poll target + tick actions and a cadence helper here.
- `apps/mac/codans/App/Features/Root/RootFeature.swift` — observes `HierarchyManager` selection changes and `NSApplication.didBecomeActiveNotification` in `onLaunch` (lines ~430–528). Already builds `WorktreeBranchPair` lists for `projectActivated` (`makeActiveProjectGitHubRefresh`, ~2055). This plan adds a `didResignActiveNotification` observation and a helper that drives the poll target from (app-active × active-project).
- `apps/mac/codans/App/Features/HierarchySidebar/WorktreeGitHubBadge.swift` + `App/Features/StatusBar/StatusBarView.swift` — consumers that read `store.snapshots[worktreeID]`. Unchanged; they repaint automatically as the poll refreshes that dict.
- `apps/mac/codans/CodansCore/GitHub/PullRequestSnapshot.swift` + `CheckResult.swift` — the model the cadence predicate inspects (`PullRequestState` = open/merged/closed, `isDraft`, `checkRollup: [CheckResult]` with `CheckStatus` = queued/inProgress/waiting/pending/completed, `mergeStateStatus`).

Orientation. The data already flows correctly: a forced `projectRefreshRequested` runs one batched `gh api graphql`, writes `snapshotsByProject[P]`, and projects each branch into the per-Worktree `snapshots` dict the views read. The only thing missing is a clock that re-issues that forced refresh while the user is looking at the app. This plan supplies that clock, gated so it costs nothing when the app is not foreground.

Definitions:
- **Active Project** — `Catalog.selectedProjectID`'s Project.
- **App-active** — the codans application is the frontmost macOS app (`NSApplication.shared.isActive`; transitions via `didBecomeActiveNotification` / `didResignActiveNotification`).
- **In-flight (for cadence)** — a PR with `state == .open` and either `mergeStateStatus == .unknown` (GitHub still computing) or any `checkRollup` entry whose `status != .completed`.
- **Poll target** — the single Project the loop currently refreshes; `nil` means the loop is paused.

## Plan of Work

### Milestone 1: Foreground poll of the active Project (fixed cadence)

A thin, observable vertical slice: while the app is active and a Project is selected, that Project's PR data refreshes on a fixed timer; the loop pauses when the app resigns active.

State (`GitHubFeature.State`):
- `var pollTarget: ProjectID?` — current poll target; `nil` = paused.
- `var projectWorktreePairs: [ProjectID: [Action.WorktreeBranchPair]] = [:]` — last-known branch pairs per Project, so a tick can re-issue a fetch without the caller re-supplying them. Write it everywhere `projectGitRoots[P]` is already written (inside `enqueueProjectFetch`) and on `pollTargetChanged`.

Actions:
- `case pollTargetChanged(ProjectID?, gitRoot: URL?, worktreeBranches: [Action.WorktreeBranchPair])`
- `case pollTick(ProjectID)`

`CancelID`:
- `case poll` — single slot for the re-arm timer; retarget/pause cancels the prior loop.

Constants (M1 uses one fixed value; M2 splits it):
- `static let pollCadence: Duration = .seconds(20)`

Reducer:
- `pollTargetChanged(P?, gitRoot, pairs)`:
  - `state.pollTarget = P`
  - if `P == nil` → `return .cancel(id: CancelID.poll)`
  - else stash `state.projectGitRoots[P] = gitRoot` (if non-nil) and `state.projectWorktreePairs[P] = pairs`, then arm the first tick:
    `return .run { send in try await clock.sleep(for: Self.pollCadence); await send(.pollTick(P)) }.cancellable(id: CancelID.poll, cancelInFlight: true)`
  - Retargeting does **not** fetch immediately — `projectActivated` / focus-gained already issue the immediate refresh; the loop only maintains freshness afterward.
- `pollTick(P)`:
  - guard `state.pollTarget == P` else `return .none` (defensive; cancellation normally prevents stale ticks).
  - resolve `gitRoot = state.projectGitRoots[P]`, `pairs = state.projectWorktreePairs[P]`; if either missing, just re-arm (no fetch).
  - `let fetch = enqueueProjectFetch(projectID: P, gitRoot: gitRoot, pairs: pairs, state: &state)` (forced; honours in-flight/queued).
  - `let rearm = .run { send in try await clock.sleep(for: Self.pollCadence); await send(.pollTick(P)) }.cancellable(id: CancelID.poll, cancelInFlight: true)`
  - `return .merge(fetch, rearm)`

Dependency: add `@Dependency(\.continuousClock) var clock` to `GitHubFeature` (TestStore-controllable via an immediate/advancing test clock).

RootFeature wiring:
- Add a `static func makePollTargetChange(client: HierarchyClient, appActive: Bool) -> GitHubFeature.Action` mirroring `makeActiveProjectGitHubRefresh`: returns `.pollTargetChanged(nil, nil, [])` when `!appActive` or there is no active Project / git root; otherwise `.pollTargetChanged(P, gitRoot, pairs)`.
- In `onLaunch`, alongside the existing `didBecomeActive` focus stream, add a `didResignActiveNotification` stream. Both feed `pollTargetChanged`: become-active → target = active Project; resign-active → target = nil. (Become-active keeps its existing reconcile + `projectActivated` immediate refresh; this only adds the poll retarget.)
- In `selectionChanged`, where the projectID transition already dispatches `projectActivated`, also dispatch `makePollTargetChange(client:, appActive: NSApplication.shared.isActive)` so switching Projects re-points the loop.

Acceptance (M1): with the app foreground and a Project selected, exactly one `gh api graphql` fires per `pollCadence`. cmd-tab away → no further fetches. cmd-tab back → fetches resume. TestStore: `pollTargetChanged(P)` arms a tick; advancing the test clock by the cadence yields one `projectBatchLoaded`; `pollTargetChanged(nil)` cancels (no further ticks after clock advance).

### Milestone 2: Adaptive cadence

Replace the single constant with two, chosen per tick from the current snapshot of the target Project.

Constants:
- `static let pollCadenceActive: Duration = .seconds(15)` — something is in flight.
- `static let pollCadenceIdle: Duration = .seconds(60)` — settled (or no open PR).

Helper:
```
private static func pollCadence(for batched: BatchedPullRequests?) -> Duration {
  guard let batched else { return pollCadenceIdle }
  let inFlight = batched.byBranch.values.contains { snap in
    snap.state == .open
      && (snap.mergeStateStatus == .unknown
          || snap.checkRollup.contains { $0.status != .completed })
  }
  return inFlight ? pollCadenceActive : pollCadenceIdle
}
```
Both the arm in `pollTargetChanged` and the re-arm in `pollTick` compute their sleep via `pollCadence(for: state.snapshotsByProject[P])`. The idle cadence still runs (while foreground) so merges/closes/new PRs that originate remotely are caught within ~60 s without any in-flight CI to key on.

Acceptance (M2): TestStore with a target whose snapshot has a non-completed check → next tick scheduled at 15 s; with all checks completed and merge state settled → 60 s. Flipping a fixture from running→completed lengthens the next interval.

### Milestone 3: Project-level post-mutation + manual refresh; retire v1 single-branch path

Delivers 0013 DEC-6 / "Future work #1". `postMutationRefresh` and the badge/popover error-retry currently use the v1 single-branch `gh pr view` path (`snapshotFetchEffect` → `pullRequest(branch:)`), which leaves `checkRollup` empty and only refreshes one Worktree.

- Add a `WorktreeID → ProjectID` resolution to state (a `projectByWorktree: [WorktreeID: ProjectID]` map maintained where pairs are stored, or thread `projectID` through the `*Completed` actions). Prefer the map — it also lets `postMutationRefresh` find the gitRoot/pairs already stashed.
- Change `postMutationRefresh(worktreeID:state:)` to resolve the owning Project and return a **2-second delayed** `projectRefreshRequested` (tagged `CancelID.delayedProjectRefresh(P)`, which already exists), replacing the per-Worktree `snapshotFetchEffect`.
- Retarget the badge/popover `onRetry` (`HierarchySidebarView.swift:1282`, `WorktreePullRequestPopover.swift:90`) from `.refreshRequested(worktreeID, …)` to a project-level `projectRefreshRequested` — plumb the project context the views already have access to.
- Once nothing dispatches them, delete the dormant v1 surface: `Action.worktreeBecameVisible`, `Action.refreshRequested`, `Action.snapshotLoaded`, `snapshotFetchEffect`, `GitHubService.pullRequest(branch:worktreePath:)` + its `LiveGitHubService` impl + `GhCommand.pullRequestView` + `JSONOutputParsers.parsePullRequest` + the `snapshots`/`snapshotLoadedAt`/`loading` slots if no longer read. Keep `latestWorkflowRun` (still seeds "Rerun failed jobs" until Open Question 4 resolves).

Acceptance (M3): merging from the popover flips the whole Project's affected rows within ~2 s with full `checkRollup` populated (not the empty-checks v1 result). Error-retry re-runs the batched fetch. Build is green with the v1 single-branch symbols removed.

### Milestone 4 (optional): Terminal command-detection immediate refresh

The poll's idle cadence catches a remotely-created PR within ~60 s, but a PR a user just opened via `gh pr create` in a pane — or a branch they just `git push`ed — has a visible lag. `TerminalEngine` already runs a foreground-job poll (`Runtime/TerminalEngine.swift:505`) that resolves the foreground job per pane. When a `gh` or `git push` foreground job in a pane belonging to the active Project exits, emit an event RootFeature turns into an immediate (or short-delayed) forced `projectRefreshRequested` for that Project. This closes the cold-start blind spot without shortening the poll cadence. Scoped as optional because the poll already bounds worst-case staleness.

### Milestone 5: Documentation

- In `docs/design-docs/github-integration-batched.md`: add a row to the **Caching and Invalidation** table for the active-Project liveness poll (source: foreground timer; fires: forced refresh of the active Project on an adaptive cadence while app-active); and append a paragraph to **Alternative D** recording that a scoped, focus-gated, adaptive poll is adopted (per this plan) and why its constraints sidestep D's original objections. Reference Open Question 5 (rate-limit-aware global backoff) as the relevant guard.
- In `docs/exec-plans/0013-github-integration-batched.md`: mark "Future work #1 (postMutationRefresh → project-level)" as delivered by 0018.

## Concrete Steps

Run from `apps/mac`:

```
make mac-generate          # only if new files are added to the target
make mac-build
make mac-check             # swift-format + swiftlint (strict)
```

Targeted tests during development:

```
# from apps/mac — adjust to the project's test invocation
xcodebuild test -scheme codans -only-testing:codansTests/GitHubFeatureTests
xcodebuild test -scheme codans -only-testing:codansTests/RootFeatureTests
```

Expected: the new `GitHubFeatureTests` poll cases pass; existing GitHub + Root suites stay green.

## Validation and Acceptance

Behavioural, app-active:
1. Select a Project with an open PR whose CI is running. Watch the badge's check overlay flip from running to its final color within ~15 s of CI finishing, with no interaction. Expected: one `gh api graphql` roughly every 15 s while CI runs (verify via `log stream --predicate 'subsystem == "com.gumpw.codans.github"'`).
2. With all PRs settled, confirm the cadence relaxes to ~60 s.
3. Merge a PR from github.com in a browser; within ~60 s the sidebar row flips to merged while the app is foreground.
4. cmd-tab to another app; confirm via the log stream that no further batched fetches fire. cmd-tab back; fetches resume.

TestStore (deterministic, via `continuousClock`):
- `pollTargetChangedArmsTick` — setting a target arms a tick; advancing by the cadence emits `projectRefreshRequested`/`projectBatchLoaded`.
- `pollPausesWhenTargetNil` — `pollTargetChanged(nil)` cancels; advancing the clock emits nothing.
- `pollCadenceFastWhenChecksRunning` / `pollCadenceSlowWhenSettled` — the next interval reflects the in-flight predicate.
- `pollTickCollapsesWhileFetchInFlight` — a tick during an in-flight fetch queues rather than stacking.

## Idempotence and Recovery

The poll is a single cancellable effect (`CancelID.poll`); re-arming with `cancelInFlight: true` guarantees at most one live timer per app. Retarget/pause is idempotent — repeated `pollTargetChanged` with the same value just re-arms the same single slot. No on-disk state changes; nothing to clean up. Reverting the plan is a code removal (the actions/state are additive; views are untouched).

## Interfaces and Dependencies

In `apps/mac/codans/App/Features/GitHub/GitHubFeature.swift`:

    // State
    var pollTarget: ProjectID?
    var projectWorktreePairs: [ProjectID: [Action.WorktreeBranchPair]]
    var projectByWorktree: [WorktreeID: ProjectID]   // M3

    // Action
    case pollTargetChanged(ProjectID?, gitRoot: URL?, worktreeBranches: [Action.WorktreeBranchPair])
    case pollTick(ProjectID)

    // CancelID
    case poll

    // Constants
    static let pollCadenceActive: Duration   // .seconds(15)
    static let pollCadenceIdle: Duration     // .seconds(60)

    // Dependency
    @Dependency(\.continuousClock) var clock

In `apps/mac/codans/App/Features/Root/RootFeature.swift`:

    @MainActor
    static func makePollTargetChange(
      client: HierarchyClient, appActive: Bool
    ) -> GitHubFeature.Action

    // CancelID
    case appResignActive   // the didResignActive observation stream

No new third-party dependencies. `continuousClock` is the standard TCA clock dependency; `NSApplication` notifications are already used by the app.
