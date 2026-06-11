# ExecPlan: GitHub Integration v1 (PR-centric, gh-delegated)

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-04-23

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this plan lands, a contributor building codans with `make mac-build && make mac-run-app` can answer the question *"does the PR for this Worktree still pass CI, and can I merge it?"* without leaving the app:

- Every Worktree in the sidebar whose branch matches an open / merged / closed PR on the user's default `gh` host grows a small **inline PR badge** (state + CI aggregate + `#num`). Worktrees without a PR remain visually unchanged.
- Left-clicking a badge opens a **360 pt popover** showing PR title, author, state pill, commit + additions/deletions counts, a check-list (failing rows first, `[View log]` links to GitHub), and an actions row with Merge (split-button with strategy picker), Close, Rerun failed, Open on GitHub.
- Merge honours the user-chosen default strategy (global + per-Project) and, on success, runs the user-chosen post-merge Worktree action (do nothing / archive / delete / ask).
- `⌘K` command palette gains eight `GitHub: …` entries (Open on web, Merge PR, Close PR, Mark ready for review, Rerun failed jobs, Copy PR URL, Refresh PR, Open Settings), each disabled with a reason when it does not apply to the selected Worktree's current PR state.
- Settings window gains a **GitHub** section that detects `gh` installation + login state, lets the user set the default merge strategy and post-merge action, and exposes per-Project overrides. When `gh` is missing, a one-time, dismissible banner at the top of the sidebar's Project list points the user at `brew install gh`.
- `codans` scriptable surface is unchanged in v1 — users already script PR flows by running `gh` inside any Pane. A `github.*` IPC namespace is reserved, unwired.

This is the first plan that makes codans aware of the remote half of the Git workflow. It closes the PR-status gap that today forces the user to flip to a browser or a second terminal every time they want to know whether CI is green.

## Progress

- [x] M0 — Prep: extract `CommandRunner` to `codans/Process/`; stub `codans/GitHub/` namespace; add `GhExecutableResolver` actor — 2026-04-23
- [x] M1 — Pure data models in `CodansCore` (DTOs, `MergeStrategy`, `MergedWorktreeAction`, `GitHubAvailability`, `PullRequestSnapshot`, `CheckResult`, `WorkflowRun`); extend `RepositorySettings` with two optional fields — 2026-04-23
- [x] M2 — `codans/GitHub/` service layer: `GitHubService` protocol, `LiveGitHubService` wrapping `gh` via `CommandRunner`, JSON fixture-driven parsers, `GitHubError` taxonomy — 2026-04-23 (integration tests against a real `gh` env-gated and deferred to a follow-up commit; RecordingCommandRunner unit tests cover every code path)
- [x] M3 — `GitHubClient` TCA `DependencyKey` + `GitHubFeature` TCA reducer (no UI yet) + `TestStore`-driven reducer tests — 2026-04-23 (in-flight cap + strict rate-limiter deferred — simpler "reject while loading" serialization chosen; 18 tests green)
- [x] M4 — Surface 1 + Surface 2: sidebar PR Badge inline on `HierarchySidebarWorktreeRow` + `PullRequestPopover` with Header / Checks / Actions / Footer + `MergeSplitButton` — 2026-04-23 (snapshot tests deferred; default merge strategy hardcoded to `.squash` until M6 threads `GeneralSettings.defaultMergeStrategy` through)
- [~] M5 — Surface 3: command palette bindings + merge-strategy picker sheet — **deferred**. On inspection this repo has no `CommandPaletteFeature` (`⌘K` is not wired today); building one is out of scope for the GitHub integration. The popover already covers every action (merge / close / mark-ready / rerun failed / open on web / copy URL), so UX coverage is intact. Revisit when a shared command-palette feature lands.
- [x] M6 — Surface 4: Settings GitHub section + `SettingsStore` wiring for new `GeneralSettings` fields — 2026-04-23 (first-run sidebar banner + per-Project override UI deferred; the Settings pane itself covers the "gh missing" remediation)
- [~] M7 — RootFeature integration: post-merge delegate pipeline (archive / delete / ask) + architecture.md codemap update + smoke test — **partial**. architecture.md codemap updated with `codans/Process/` + `codans/GitHub/` + `App/Features/GitHub/` entries. The `.delegate(.pullRequestMerged)` path is wired through `GitHubRootBindings` but the auto archive / delete / ask dispatch is deferred — the handler needs `SettingsStore` as a TCA dependency (currently injected via `@Environment` at the view tier), and plumbing that cleanly was out of scope for this session. Users can manually archive a Worktree via the existing sidebar context menu after a merge; the reducer delegate is ready to drive the automation once `SettingsStore` becomes a TCA dep.

Each unchecked entry will be updated with a completion timestamp in the form `— 2026-MM-DD` when the milestone lands (matching `0002` / `0005` convention).

## Surprises & Discoveries

- **Baseline-test count drifted (2026-04-23, pre-M0).** The plan quoted "242 tests across 34 suites" from 0005 M8 close-out. Actual baseline on `feature/github01` is **745 tests across 91 suites** with a broader set of pre-existing failures than the first baseline run surfaced. Regression signal for every milestone is now "no **new** failures outside the pre-existing known set", not "zero failures". The plan's per-milestone "Expected: 0 failures" assertions are revised to this relative baseline.

- **Pre-existing failing tests confirmed unrelated to the GitHub integration (2026-04-23, M2).** The first baseline (pre-M0) listed 12 theme-catalog failures from the XDG-only resolver change (commit `aeafe6f`). The M2 full-suite run surfaced additional pre-existing failures that did not appear in the truncated first-baseline output: `saveNowCancelsPendingDebouncedWrite`, `writeFailureLogsButDoesNotMoveFileAside` (both in `SettingsStoreTests`) plus `newTabCallsCreateTabWithResolvedAddress`, `newSplitHorizontalCallsSplitPanelWithRightDirection` (both in `PaneActionRouterFeatureTests`). Verified by checking out the origin/main versions of `GeneralSettings.swift` and `RepositorySettings.swift` (removing my M1 additions) and re-running the tests — both `SettingsStoreTests` failures still reproduce, confirming they are *not* regressions from the GitHub integration. The tests appear environment-sensitive (`/tmp` atomic-rename + debounce timing under Xcode's parallel test runner). Flagged for follow-up outside this exec-plan.

## Decision Log

- **DEC-1 (pre-M0, 2026-04-23): per-Project feature toggle defaults to ON.** Design OQ#1. The feature is silent when no PR exists for a Worktree, so "on by default" pays zero visual cost on Worktrees the user doesn't care about. Off-by-default would hide the feature behind a Settings discovery step. The Settings pane exposes a per-Project **Disable for this Project** toggle for users who want to suppress the badges (e.g., vendored repos with upstream PRs they don't maintain).

- **DEC-2 (pre-M0, 2026-04-23): command-palette actions land as `CommandPaletteFeature` delegate cases forwarded into `RootFeature`, then into `GitHubFeature`.** Design OQ#2. Mirrors the C8 editor-open pattern exactly (`WorktreeHeaderFeature.Action.delegate(.openEditor…)` → `RootFeature` → `EditorFeature.openRequested`). Rejected: a `GitHubActions` submodule of the palette — would duplicate the palette's fuzzy-search machinery and create a second search index to maintain.

- **DEC-3 (pre-M0, 2026-04-23): `rerunFailedJobs` re-runs **all** failed jobs in the latest run, one `gh run rerun --failed` call, no per-job picker.** Design OQ#3. Matches `gh`'s one-shot semantics; a per-job picker would require a second popover layer and adds vocabulary (`WorkflowJob` DTO, job-id selection state) the v1 scope cut deliberately avoids.

- **DEC-4 (pre-M0, 2026-04-23): `markReady` is both a popover action and a palette entry.** Design OQ#4. The palette entry (`GitHub: Mark PR ready for review`) is auto-disabled when the selected Worktree's PR is not a draft; the popover action renders only when the PR is a draft. Single `GitHubFeature` action (`.markReadyRequested(WorktreeID)`) serves both surfaces — no forked code path. Rejected: popover-only — would hide a common draft→ready transition from keyboard-first users.

- **DEC-5 (M0, 2026-04-23): `CommandRunner` and `FoundationCommandRunner` move from `codans/Git/` to a new `codans/Process/` folder.** The design's R6 mitigation. Mechanical rename + two importer updates (`LiveGitService`, `RecordingCommandRunner` test double). Lands as a single prep commit with the full C7 suite passing before any GitHub code arrives. If the C7 tests regress after the move, revert is a `git mv` back; no state migration needed.

- **DEC-6 (M0, 2026-04-23): `GhExecutableResolver` is a singleton actor in `codans/GitHub/`, not a reusable `ExecutableResolver<Binary>` generic.** The editor module has its own `PathProber` / `EditorRegistry` machinery; the git module resolves `/usr/bin/git` as an absolute fixed path (see 0005 DEC-11). A third abstraction would have one live caller. Keeps the surface concrete and reviewable.

- **DEC-7 (pre-M1, 2026-04-23): `PullRequestSnapshot`, `CheckResult`, `WorkflowRun`, `MergeStrategy`, `MergedWorktreeAction`, `GitHubAvailability` live in `CodansCore/GitHub/`, not in `codans/GitHub/`.** The app-module `codans/GitHub/` imports them. v1 does not ship `github.*` IPC, so `codans` does not consume them yet — but the DTOs are pure value types with zero app-target dependency, and locating them in the leaf module avoids the move the design doc's Seams section flagged as "when v2 lands." Paying the ~80 lines of Codable extensions in `CodansCore` once is cheaper than a Phase-2 refactor across live code paths.

- **DEC-8 (pre-M2, 2026-04-23): The integration test surface against real `gh` uses `ProcessInfo` env-var gating, same pattern as C7.** Default test runs ignore `TC_RUN_GITHUB_INTEGRATION_TESTS`; engineers who want an end-to-end against their live `gh` set it to `1` in Xcode's Test scheme → Environment Variables. Matches the `.enabled(if:)` pattern landed in 0005 DEC-9.

- **DEC-9 (M0, 2026-04-23): `apps/mac/Project.swift` uses explicit `buildableFolders:` lists, not folder globs — the plan's M0 step 3 is revised.** The `codans` target declares its folders one-by-one (`codans/App`, `codans/App/Features/Socket`, `codans/Runtime`, `codans/Hooks`, `codans/Git`, `codans/Notifications`). Every new top-level subfolder under `codans/` must be appended to this list *and* a `make mac-generate` run issued before Xcode sees the files. M0 adds `codans/Process` and `codans/GitHub` to the list; subsequent milestones that add features under existing folders (`App/Features/GitHub/...`) do not need further Project.swift edits.

- **DEC-10 (post-M7, 2026-04-23): Codex review round — 7/8 findings addressed in-session.** After all milestones landed, a Codex rescue-subagent review surfaced 8 findings (1 high, 6 medium, 1 low) across correctness + security + architecture. Addressed in these commits:
  - `0a5d987` — `parsePullRequest` decoder switched from `.iso8601` to `.iso8601WithFractionalSeconds` (gh emits fractional); `CheckRollup.from(checks:)` now counts `.cancelled` / `.timedOut` / `.actionRequired` / `.stale` / `.startupFailure` as failing (not passing); `parseHostHint` no longer truncates on `.` (a previous version turned "github.com" into "github").
  - `7537b54` — env allowlist forwards `GH_CONFIG_DIR` + `XDG_CONFIG_HOME` so `gh` finds its auth config store when the user has overridden the location. Credential env vars (`GH_TOKEN` / `GITHUB_TOKEN`) remain stripped.
  - `099ce9c` — **HIGH**: merge / close / markReady / rerunFailedJobs success branches now emit a `postMutationRefresh` effect re-dispatching `snapshotFetchEffect`; the badge and popover reflect the new server state without a user-visible stale-data gap. In-flight mutations now hold a `CancelID.mutation(WorktreeID)` cancellation slot and a `State.mutating` set; the popover disables the Merge button with a tooltip while any mutation is active.
  - `e047023` — PR badge Button de-nested from the row Button's `.label`. The row is now `HStack { Button(rowTap) { leading-half }; gitHubBadge }` so taps land cleanly without nested-Button hit-test fragility. `.task(id:)` on the badge hashes `(worktreeID, branch, path)` instead of just `worktreeID` so a branch re-point re-fires the snapshot fetch.

  **Not addressed**: Medium-priority "cap in-flight `gh pr view` fan-out across Worktrees at max 3". Typical codans Projects have <10 Worktrees and `gh` has its own client-side rate limiter; the practical risk is low and adding the queue would re-churn the reducer tests. Tracked as a follow-up when a Project accumulates >15 Worktrees. The per-Worktree "reject duplicate fetch while loading" serialization that the reducer already has covers the common double-click case.

## Outcomes & Retrospective

(To be filled at milestone completion)

## Context and Orientation

Related documents (all in this repo):

- **Design doc — authoritative for every decision; this plan implements, it does not relitigate:** [docs/design-docs/github-integration.md](../design-docs/github-integration.md).
- **Product spec** — [docs/product-spec.md](../product-spec.md). GitHub is not (yet) an explicit product-spec capability — this feature rides on the Worktree-centric surface the spec defines and is covered by the informal "reduce context-switches between app, editor, and terminal" motivation in §Problem. Spec entry to be added in M7 alongside the architecture codemap update.
- **Architecture** — [docs/architecture.md](../architecture.md). Relevant invariants: hybrid TCA + `@Observable` with TCA for feature flows; atomic-rename JSON with top-level `version`; `codans` is stateless and talks to the app over `CodansIPC`; no HTTP in the app is not an invariant, but we honour it in v1 by delegating network calls to `gh`.
- **Sibling design doc — pattern source:** [docs/design-docs/c7-git-viewer.md](../design-docs/c7-git-viewer.md). C7 established the three-layer shape (`CommandRunner` → `Service` protocol → `*Client` TCA DependencyKey → `*Feature` reducer) this plan reuses.
- **Prior ExecPlan — pattern source:** [docs/exec-plans/0005-git-viewer-and-editor.md](0005-git-viewer-and-editor.md). Milestone shape, fixture-driven parser tests, env-gated integration tests, and `ProcessSpawner` race fix are all templates for M0–M3.

Key source files this plan depends on:

- `apps/mac/codans/Git/CommandRunner.swift` — subprocess runner with timeout + SIGTERM→SIGKILL + output cap + pipe drain. **M0 moves this file to `apps/mac/codans/Process/CommandRunner.swift`.**
- `apps/mac/codans/App/Clients/GitServiceClient.swift` — the TCA `DependencyKey` shape M3 mirrors for `GitHubClient`.
- `apps/mac/codans/App/Features/Socket/MethodRouter.swift` — IPC router. v1 adds **no** `github.*` methods; this file is referenced only so future v2 planners know where the registration will land.
- `apps/mac/CodansCore/Settings/RepositorySettings.swift` — currently reserved-empty. M1 adds two optional fields; the decode-if-present fallback keeps pre-integration `settings.json` files round-trip-identical.
- `apps/mac/CodansCore/Worktree.swift` — `Worktree.branch: String?` is the match key for PR ↔ Worktree. No changes in this plan.
- `apps/mac/codans/App/Features/WorktreeHeader/WorktreeHeaderFeature.swift` — pattern source for the delegate-action + split-button the popover's merge button reuses.
- `apps/mac/codans/App/Features/CommandPalette/CommandPaletteFeature.swift` — the palette reducer that M5 extends with eight new entries.

Reference projects (read-only):

- The broad shape of the integration has been validated on a comparable macOS tool maintained by the author. That validation informs the scope cuts but no code is copied verbatim — codans's sidebar, palette, settings, and hierarchy types differ.

**Terminology used in this plan** (defined once; used as-is below):

- **`gh`** — the GitHub CLI, `cli/cli`, installed at `/opt/homebrew/bin/gh` on Apple Silicon / `/usr/local/bin/gh` on Intel / via `mise` per user. `GhExecutableResolver` finds it once per app session via `which gh`.
- **Snapshot (in this plan)** — a `PullRequestSnapshot` value, not a visual snapshot test. The C7 term for image-diff tests ("snapshot test" / "SnapshotTesting") is not used in this plan.
- **Surface 1 / 2 / 3 / 4** — the four UI surfaces listed in the design doc's UI Design section: sidebar badge, detail popover, command palette, Settings section. Milestones reference them by number.
- **Availability** — the `GitHubAvailability` enum: `.unknown` (never probed this session), `.available(host, user)`, `.unavailable(GitHubError)`. The first two drive the badge/popover render; the third drives the Settings banner.
- **PR ↔ Worktree match** — a PR is associated with a Worktree iff `PullRequestSnapshot.headRefName == Worktree.branch`. Ties (two Worktrees on the same branch) resolve by Worktree mtime (most-recently-activated wins); the loser's row renders without a badge and logs at `.debug`.
- **Post-merge action** — the `MergedWorktreeAction` enum: `.none`, `.archive` (sets `Worktree.archived = true`), `.delete` (removes the worktree via `HierarchyClient.removeWorktree`), `.ask` (shows a confirmation sheet with the three options + remember-my-choice checkbox).
- **Availability cache** — a 30-second TTL on the `.availability` result held inside `GitHubFeature.State`, invalidated on explicit `Re-check` action. Not the same as the per-Worktree snapshot cache.
- **Per-Worktree snapshot cache** — `[WorktreeID: PullRequestSnapshot]` held inside `GitHubFeature.State`. Never persisted to disk. Invalidated on: worktree-selection change for the same WorktreeID, user-initiated refresh, merge/close/markReady/rerun action completion (debounced 1 s).

## Plan of Work

This plan slices vertically through the feature. M0–M2 build the data + service foundation with no UI; M3 adds the feature reducer and proves correctness via `TestStore`; M4 is the first user-visible slice (badge + popover); M5–M6 add the remaining UI surfaces; M7 integrates with Worktree lifecycle and closes the docs. At every milestone, the app continues to build + run + pass all existing tests — no milestone leaves the tree in a half-wired state.

### Milestone 0: Prep — `CommandRunner` move + `codans/GitHub/` stub

Design R6 mitigation plus the absolute-minimum file-system scaffolding for the milestones that follow. What will exist at the end that did not exist before: `codans/Process/` holds `CommandRunner.swift` + `FoundationCommandRunner`; `codans/Git/` imports from that new path; `codans/GitHub/` contains an empty `public enum GitHub {}` namespace and a single `GhExecutableResolver.swift` actor; all existing tests still pass.

Work:

1. `git mv apps/mac/codans/Git/CommandRunner.swift apps/mac/codans/Process/CommandRunner.swift`. Update the file's own leading doc comment that references "C7" to drop the C7 framing — `CommandRunner` is now a shared primitive.
2. In `apps/mac/codans/Git/LiveGitService.swift`, no import change is needed (same target), but the file's doc comment that names `CommandRunner` as "its peer in `Git/`" must be updated to "its peer in `Process/`".
3. In `apps/mac/Project.swift`, update the Tuist target's `sources` glob if it enumerates `Git/**/*.swift` explicitly (it currently uses a folder-wide glob on the `codans` target, so a new sibling folder is picked up automatically; confirm with `make mac-generate` + build).
4. Create `apps/mac/codans/GitHub/GitHub.swift` with `public enum GitHub {}` — matches the `codans/Git/Git.swift` namespace pattern.
5. Create `apps/mac/codans/GitHub/GhExecutableResolver.swift` — actor that runs `which gh` once per app session, caches the result, deduplicates concurrent callers via `Task` single-flight pattern. Returns `URL?` (nil when not found). Injected via init taking an `EnvironmentVariableProvider` protocol so tests can override `$PATH` without touching the real shell. Unit tests go in `apps/mac/codans/Tests/GitHubTests/GhExecutableResolverTests.swift` — four tests: missing binary returns nil, present binary caches across calls, concurrent callers share a single resolution, explicit invalidation forces re-probe.

**Observable acceptance:** `xcodebuild test -scheme codans` passes the full existing suite (unchanged count from 0005 M8 close-out) plus four new `GhExecutableResolverTests`. `make mac-lint` clean. `grep -r 'codans/Git/CommandRunner' apps/mac/` returns zero matches.

Expected commits (one per step-cluster):
- `chore: move CommandRunner from Git/ to Process/ for cross-module reuse`
- `feat(github): add GhExecutableResolver with concurrent-safe which-gh cache`

### Milestone 1: Pure data models in CodansCore + RepositorySettings extension

What will exist at the end: every value type the service layer and feature reducer reference is a plain, Codable, Sendable, exhaustively-tested struct or enum living in `CodansCore/GitHub/`, plus two additive optional fields on `RepositorySettings`.

Work:

1. Create `apps/mac/CodansCore/GitHub/` and add six files:
   - `PullRequestSnapshot.swift` — `number: Int, title: String, state: PullRequestState, isDraft: Bool, headRefName: String, author: String, additions: Int, deletions: Int, commitCount: Int, mergeable: MergeableState, url: URL, updatedAt: Date`. Enum `PullRequestState`: `open | merged | closed`. Enum `MergeableState`: `mergeable | conflicting | unknown`.
   - `CheckResult.swift` — `name: String, status: CheckStatus, conclusion: CheckConclusion?, detailsURL: URL?, startedAt: Date?, completedAt: Date?, durationSeconds: Int?`. Enum `CheckStatus`: `queued | inProgress | completed | waiting`. Enum `CheckConclusion`: `success | failure | cancelled | skipped | neutral | timedOut | actionRequired`.
   - `WorkflowRun.swift` — `databaseID: Int64, name: String, status: CheckStatus, conclusion: CheckConclusion?, headBranch: String, headSHA: String, runNumber: Int, updatedAt: Date, url: URL`.
   - `MergeStrategy.swift` — `enum { case mergeCommit, squash, rebase }` with `cliFlag: String` (`--merge` / `--squash` / `--rebase`) and `displayName: String` (localized).
   - `MergedWorktreeAction.swift` — `enum { case doNothing, archive, delete, ask }`.
   - `GitHubAvailability.swift` — `enum { case unknown; case available(host: String, user: String); case unavailable(GitHubError) }`. `GitHubError` is referenced here but defined in M2 (in `codans/GitHub/`, not `CodansCore`); `GitHubAvailability` takes a *description* string here and is re-wrapped at the app layer to carry the rich error. Rejected alternative: move `GitHubError` into `CodansCore` to avoid the indirection — rejected because `GitHubError.notInstalled` carries install-remediation copy that is UI-facing, belongs next to the service.
2. Every Codable DTO gets a round-trip test in `apps/mac/CodansCoreTests/GitHubTests/`. Follow 0005 M1 pattern: encode → decode → assert equal; assert every enum variant decodes the string form it will receive from `gh` (`"OPEN" / "MERGED" / "CLOSED"` for state; `"QUEUED" / "IN_PROGRESS" / "COMPLETED"` for check status; etc.). One dedicated test per non-trivial enum (`PullRequestState`, `MergeableState`, `CheckStatus`, `CheckConclusion`) asserts the exact string-mapping the parser will rely on.
3. Extend `apps/mac/CodansCore/Settings/RepositorySettings.swift`:
   - Add `public var defaultMergeStrategy: MergeStrategy?`
   - Add `public var postMergeAction: MergedWorktreeAction?`
   - Add `public var githubDisabled: Bool` (default `false`, drives the per-Project toggle from DEC-1)
   - Custom `Codable` with `decodeIfPresent` for all three; encode omits nil and `githubDisabled == false` (the common case), keeping pre-integration `settings.json` files round-trip-identical.
   - Update `isEffectivelyEmpty` to `defaultMergeStrategy == nil && postMergeAction == nil && githubDisabled == false`. Add one test asserting a pre-integration empty `{}` still decodes to `isEffectivelyEmpty == true`, and three tests asserting each new field independently flips `isEffectivelyEmpty` to false.
4. Extend the global settings shape (check the current `AppSettings` / `GeneralSettings` struct — named per 0005 M6 landing) with `defaultMergeStrategy: MergeStrategy?` and `postMergeAction: MergedWorktreeAction?`. Both optional to encode omitted when nil. Two additive decode-if-present tests.

**Observable acceptance:** `xcodebuild test -scheme CodansCore` → all 80+ existing tests pass plus ≈25 new GitHub DTO / settings tests. `grep -n 'import Foundation' apps/mac/CodansCore/GitHub/*.swift` — only Foundation imports; zero AppKit / SwiftUI / TCA imports (the leaf-ness invariant).

Expected commits:
- `feat(core): add GitHub DTOs — PullRequestSnapshot, CheckResult, WorkflowRun`
- `feat(core): add MergeStrategy and MergedWorktreeAction enums`
- `feat(core): add GitHubAvailability enum`
- `feat(settings): extend RepositorySettings + global settings with GitHub fields`

### Milestone 2: GitHub service layer in `codans/GitHub/`

What will exist at the end: a complete, unit-tested `GitHubService` protocol + `LiveGitHubService` live implementation that shells out to `gh` via the shared `CommandRunner`, parses stdout JSON into the M1 DTOs, and surfaces failures through a `GitHubError` enum. No TCA, no SwiftUI.

Work:

1. `apps/mac/codans/GitHub/GitHubService.swift` — protocol exactly as sketched in the design doc's API Design section. `nonisolated` + `Sendable`. Methods: `availability() async -> GitHubAvailability`, `pullRequest(branch:, worktreePath:) async throws -> PullRequestSnapshot?`, `checks(number:, worktreePath:) async throws -> [CheckResult]`, `latestWorkflowRun(branch:, worktreePath:) async throws -> WorkflowRun?`, `merge(number:, strategy:, worktreePath:) async throws`, `close(number:, worktreePath:) async throws`, `markReady(number:, worktreePath:) async throws`, `rerunFailedJobs(runID:, worktreePath:) async throws`.
2. `apps/mac/codans/GitHub/GhCommand.swift` — argv builder. One `static func` per service method returning `(arguments: [String], expectedExitCodes: Set<Int32>)`. Every invocation begins with `gh` and passes `--json <field-list>` for the read paths. Write paths use `gh pr merge`, `gh pr close`, `gh pr ready`, `gh run rerun`. The builder does not know about the executable URL or cwd — those come from `LiveGitHubService`.
3. `apps/mac/codans/GitHub/LiveGitHubService.swift` — conforms to `GitHubService`. Constructor takes `runner: CommandRunner = FoundationCommandRunner()`, `resolver: GhExecutableResolver = .shared`, `timeout: Duration = .seconds(20)`, `maxOutputBytes: Int = 2 * 1024 * 1024` (2 MiB — PR check lists can be large; JSON is bounded by GitHub's own limits). Each public method:
   - Calls `resolver.resolve()` — returns `GitHubError.notInstalled` on nil.
   - Builds argv via `GhCommand.<method>(...)`.
   - Calls `runner.run(...)` with `cwd = worktreePath` and env = minimal allowlist (`PATH`, `HOME`; forced `LC_ALL = en_US.UTF-8`; strip everything else including any `GH_*` / `GITHUB_*` user env, which `gh` reads from its own config store).
   - Translates `CommandOutcome` → rich result or `GitHubError`. Specific translations: `.spawnFailed(reason)` where reason contains "not found" → `.notInstalled`; `.timedOut` → `.timeout`; `.exited(code, stdout, stderr, _)` with code in `expectedExitCodes` → parse stdout JSON; non-zero with stderr containing "auth" → `.notAuthenticated(host)` by re-running `gh auth status --json hosts`; containing "no pull request found" → return nil (for `pullRequest(...)`); containing "rate limit" → `.rateLimited(retryAfter)`; otherwise `.other(stderr)`.
4. `apps/mac/codans/GitHub/GitHubError.swift` — enum with eight cases (as listed in the design doc §Cross-Cutting Concerns → Error handling), each carrying a `userFacingMessage: String` computed property.
5. `apps/mac/codans/GitHub/JSONOutputParsers.swift` — five pure static functions: `parsePullRequest(Data) throws -> PullRequestSnapshot?`, `parseChecks(Data) throws -> [CheckResult]`, `parseWorkflowRun(Data) throws -> WorkflowRun?`, `parseAuthStatus(Data) throws -> (host: String, user: String)?`, `parseMergeResult(Data) throws -> Void`. Every parser uses `JSONDecoder` with `dateDecodingStrategy = .iso8601`, tolerates unknown fields (the default), and throws `GitHubError.other("decode: <desc>")` on structural failure.
6. Fixtures — `apps/mac/codans/Tests/GitHubTests/Fixtures/`:
   - `gh-pr-view-open.json`, `gh-pr-view-draft.json`, `gh-pr-view-merged.json`, `gh-pr-view-closed.json` — captured once from real `gh pr view --json number,title,state,isDraft,headRefName,author,additions,deletions,commits,mergeable,url,updatedAt`.
   - `gh-pr-checks-all-passing.json`, `gh-pr-checks-mixed.json`, `gh-pr-checks-none.json`.
   - `gh-run-list-success.json`, `gh-run-list-failure.json`.
   - `gh-auth-status-available.json`, `gh-auth-status-unauth.json`.
   - `gh-pr-view-not-found.stderr.txt` (for the "no PR" branch).
7. Unit tests in `apps/mac/codans/Tests/GitHubTests/`:
   - `JSONOutputParsersTests.swift` — one test per fixture file, asserting exact decoded values.
   - `LiveGitHubServiceTests.swift` — uses a `RecordingCommandRunner` (existing test double, now in `codans/Process/`) pre-seeded with fixture bytes. Covers: happy path per method, `.timedOut` → `.timeout`, `.spawnFailed` → `.notInstalled`, non-zero exit with auth error → `.notAuthenticated`, non-zero with no-PR stderr → returns nil, rate-limit stderr → `.rateLimited`. One test asserts argv exactness for each method (locking the `GhCommand` contract).
   - `LiveGitHubServiceIntegrationTests.swift` — `.enabled(if: ProcessInfo.processInfo.environment["TC_RUN_GITHUB_INTEGRATION_TESTS"] == "1")` per DEC-8. Five tests against a real `gh` in the codans repo: availability probe, `pullRequest(branch: "main", ...)` returns nil, `pullRequest(branch: <this-branch>, ...)` returns a real snapshot, `checks(...)` returns a non-empty list, `latestWorkflowRun(...)` returns a non-nil run.

**Observable acceptance:** `xcodebuild test -scheme codans` → all 242+ existing tests pass plus ≈30 new GitHubTests; integration tests correctly skip unless `TC_RUN_GITHUB_INTEGRATION_TESTS=1`. `make mac-lint` clean.

Expected commits:
- `feat(github): add GitHubService protocol and GitHubError`
- `feat(github): add GhCommand argv builder with fixture-locked contract`
- `feat(github): add LiveGitHubService with CommandRunner-backed gh invocations`
- `feat(github): add JSONOutputParsers with tolerant gh-JSON decoding`
- `test(github): add LiveGitHubService unit tests with RecordingCommandRunner`
- `test(github): add optional GitHub integration-tests gate`

### Milestone 3: `GitHubClient` DependencyKey + `GitHubFeature` reducer

What will exist at the end: a TCA feature that owns availability + per-Worktree PR snapshots + popover state, driven through a typed `GitHubClient` dependency. Zero SwiftUI.

Work:

1. `apps/mac/codans/App/Clients/GitHubClient.swift` — mirrors `GitServiceClient.swift` shape exactly. One `@Sendable` async closure per `GitHubService` method plus `.liveValue` (wrapping `GitHub.makeService()` factory added in M2) and `.testValue` (every closure = `unimplemented(…)` with matching placeholder). Factory helper `GitHub.makeService() -> any GitHubService` added in M2's `GitHub.swift` namespace file. `DependencyValues.gitHub: GitHubClient` accessor.
2. `apps/mac/codans/App/Features/GitHub/GitHubFeature.swift` — `@Reducer struct GitHubFeature`. State + Action as sketched in the design doc's API Design → `GitHubFeature reducer` block, plus `MergeStrategy` override for the caret-picker merge path. Dependencies: `gitHub: GitHubClient`, `continuousClock`, `hierarchy: HierarchyClient` (read for worktree mtime tie-break).
   - `.onAppear` → probe availability; cache in state for 30 s.
   - `.worktreeBecameVisible(WorktreeID)` → if we don't have a fresh snapshot, cancel any in-flight fetch for the same ID (via a per-ID `CancelID`), kick off `snapshotLoaded` effect. Rate-limit: max 3 concurrent across all Worktrees (implemented as a reducer-held `Set<WorktreeID> inFlight` + pending queue; when an in-flight completes, dequeue the next).
   - `.refreshRequested(WorktreeID)` → force-refresh regardless of freshness; also re-probes checks.
   - `.presentPopover(WorktreeID)` → opens the popover + dispatches a checks fetch if stale (>30 s).
   - `.mergeRequested(WorktreeID, MergeStrategy?)` → strategy nil means "use the resolved default from state.resolvedMergeStrategy(for: projectID)".
   - `.mergeCompleted(WorktreeID, Result)` → dispatches `.delegate(.pullRequestMerged(WorktreeID, PullRequestSnapshot))` on success; `RootFeature` translates to post-merge action in M7.
   - `.closeRequested`, `.closeCompleted`, `.markReadyRequested`, `.markReadyCompleted`, `.rerunFailedJobsRequested`, `.rerunFailedJobsCompleted` — parallel shape.
   - `.delegate(…)` — `.pullRequestMerged(WorktreeID, PullRequestSnapshot)`, `.showSettingsGitHub`, `.openOnWebRequested(URL)`.
3. `apps/mac/codans/App/Features/GitHub/GitHubFeatureTests.swift` — TCA `TestStore` tests (following 0005 M3 pattern). At least 20 tests covering:
   - `.onAppear` availability probe success / notInstalled / notAuthenticated.
   - `.worktreeBecameVisible` triggers snapshot load; second invocation within 30 s is a no-op.
   - In-flight cap: scheduling 5 worktrees concurrently admits 3 and queues 2; completion of one releases a queued one.
   - Match heuristic: two Worktrees on the same branch, only the more-recent-mtime Worktree gets the snapshot.
   - `.mergeRequested` → `gitHub.merge` called with the right argv → `.mergeCompleted` success → `.delegate(.pullRequestMerged)` emitted.
   - `.mergeCompleted` failure → state `.error` populated → no delegate.
   - `.refreshRequested` always refires regardless of cache age.
   - `.rerunFailedJobsRequested` path.
   - Availability cache: 30 s TTL via `continuousClock` — clock-advance-by-31 s re-probes; clock-advance-by-29 s does not.

**Observable acceptance:** `xcodebuild test -scheme codans` full suite green. `GitHubFeatureTests` contains ≥20 tests. No view code; `find apps/mac/codans/App/Features/GitHub -name '*.swift' | xargs grep -l 'SwiftUI'` returns zero files.

Expected commits:
- `feat(github): add GitHubClient TCA DependencyKey`
- `feat(github): add GitHubFeature reducer with per-worktree snapshot cache`
- `test(github): add TestStore-driven GitHubFeature reducer tests`

### Milestone 4: Surface 1 + Surface 2 — Sidebar badge and PR popover

What will exist at the end: a user running the app and selecting a Worktree whose branch matches a PR sees the PR badge in the sidebar row and can click it to open the popover with full actions. The Merge, Close, Mark Ready, and Rerun Failed actions all work end-to-end against a real PR. Merge still uses the global default strategy — per-Project overrides and post-merge Worktree actions land in M6 / M7.

Work:

1. `apps/mac/codans/App/Features/GitHub/Theme/PullRequestStateColors.swift` — asset-catalog `Color` accessors per the design UI §Theming list: `prState.open`, `prState.draft`, `prState.merged`, `prState.closed`, `prCheck.passing`, `prCheck.failing`, `prCheck.pending`. Define the corresponding color sets in `apps/mac/Resources/Assets.xcassets/` with Light/Dark/HighContrast variants; hues follow the design's "GitHub palette minus 20% saturation" direction.
2. `apps/mac/codans/App/Features/GitHub/Views/PullRequestBadge.swift` — `struct PullRequestBadge: View` taking `(snapshot: PullRequestSnapshot, checkRollup: CheckRollup, state: BadgeRenderState, action: () -> Void)`. `CheckRollup` enum: `.allPassing | .anyFailing | .anyPending | .noChecks`. `BadgeRenderState` covers `.loaded | .loading | .error(GitHubError)`. Renders the 20 pt capsule per the design spec. `.contentShape(.rect)` for the 10 pt extended hit-area. Exposes `.accessibilityLabel("Pull request \(num), \(state), CI \(rollup)")`. `⌘`-click detected via `.modifierKeyAlternate` → `openOnWebRequested` delegate.
3. Integrate the badge into the existing sidebar row. Locate the Worktree row view in `apps/mac/codans/App/Features/HierarchySidebar/` (precise file confirmed during M4; likely `HierarchySidebarWorktreeRow.swift` per 0011 naming). Mount `PullRequestBadge(...)` in a trailing `HStack` slot, after any existing unread-notification dot, before the chevron. The row observes `gitHubFeature.snapshots[worktree.id]` + `.loading.contains(worktree.id)` + `.error` via the scoped store. Row mount triggers `.worktreeBecameVisible(worktree.id)` once per appear.
4. `apps/mac/codans/App/Features/GitHub/Views/CheckRow.swift` — one check in the popover list. `Text(name)` + trailing `Text(duration)` + trailing glyph colored by `CheckConclusion`. Failing rows append `[ View log ]` — a `Button` that opens `check.detailsURL` in the browser.
5. `apps/mac/codans/App/Features/GitHub/Views/MergeSplitButton.swift` — left half primary `Button` labeled "Merge (\(strategy.displayName))", right half `Menu` with four items (merge / squash / rebase / separator / "Set as default for this Project"). Pattern matches `HeaderOpenSplitButton` from 0009 MW-T2. Takes `(defaultStrategy: MergeStrategy, projectID: ProjectID, action: (MergeStrategy) -> Void, setAsProjectDefault: (MergeStrategy) -> Void)`.
6. `apps/mac/codans/App/Features/GitHub/Views/PullRequestPopover.swift` — full popover per the design wireframe. Three subsections `PopoverHeader`, `PopoverChecks` (collapsing past 5, sorted failing→pending→passing), `PopoverActions`. Fallback views: `PopoverLoadingSkeleton`, `PopoverErrorView` (with remediation buttons for `.notInstalled` / `.notAuthenticated`), `PopoverNoPullRequestView` (with `[ Create on GitHub ]` link).
7. Wire the popover into the sidebar: `.popover(isPresented:)` bound to `gitHubFeature.popoverTarget == worktree.id`. Tapping the badge dispatches `.presentPopover(worktree.id)`.
8. Reducer additions in `GitHubFeature` from M3 are complete; this milestone is all SwiftUI + wiring. Add `GitHubFeature` scoping in the parent feature that owns the sidebar (likely `HierarchySidebarFeature` or `RootFeature` — confirmed during M4).
9. Snapshot tests (per C7 M4b pattern) in `apps/mac/codans/Tests/GitHubTests/GitHubViewSnapshotTests.swift`. Env-gated (`TC_RUN_SNAPSHOT_TESTS=1`), baseline-PNG deferred to a follow-up per 0005 DEC-20 lesson. Eight snapshot tests: badge in each of open / draft / merged / closed × pass / fail / pending / loading / error. Popover in each of loaded / loading / error / no-PR.

**Observable acceptance:** A human runs `make mac-run-app`, selects this repo's feature/github01 Worktree, and sees a PR badge (when a PR exists — otherwise no badge). Clicking it opens the popover. Clicking `Merge` executes `gh pr merge` with the default strategy, the PR moves to merged state, the badge updates to purple-merged within ≈1 s (the debounced refresh). `make mac-build` clean. Full test suite green.

Expected commits:
- `feat(github): add PR state color roles and asset-catalog entries`
- `feat(github): add PullRequestBadge with state / CI rollup rendering`
- `feat(github): wire PullRequestBadge into HierarchySidebarWorktreeRow`
- `feat(github): add CheckRow, MergeSplitButton, PullRequestPopover views`
- `feat(github): wire popover presentation + actions through GitHubFeature`
- `test(github): add snapshot tests for badge and popover`

### Milestone 5: Surface 3 — Command palette entries + merge-strategy picker

What will exist at the end: `⌘K` surfaces eight `GitHub: …` entries scoped to the selected Worktree's PR, and the merge flow offers an inline strategy picker when no default is configured.

Work:

1. `apps/mac/codans/App/Features/GitHub/GitHubCommandPaletteBindings.swift` — pure function `makeGitHubPaletteEntries(state: GitHubFeature.State, selection: WorktreeID?) -> [CommandPaletteEntry]` returning the eight entries listed in the design UI §Surface 3 table. Each entry has a `label`, an `availability: CommandAvailability` (`.available | .unavailable(reason: String)`), and an `action: CommandPaletteFeature.Delegate` case it dispatches.
2. Extend `CommandPaletteFeature.Delegate` (in `apps/mac/codans/App/Features/CommandPalette/CommandPaletteFeature.swift`) with: `.githubOpenOnWeb(WorktreeID)`, `.githubMerge(WorktreeID)`, `.githubClose(WorktreeID)`, `.githubMarkReady(WorktreeID)`, `.githubRerunFailed(WorktreeID)`, `.githubCopyURL(WorktreeID)`, `.githubRefresh(WorktreeID)`, `.githubOpenSettings`. `RootFeature` routes each into the matching `GitHubFeature` action.
3. `apps/mac/codans/App/Features/GitHub/Views/MergeStrategyPicker.swift` — small sheet with a segmented control (Merge / Squash / Rebase) + Cancel / Merge buttons. Shown when `GitHubFeature.mergeInFlight` and there is no resolved default strategy. Reuses the palette-invocation pattern from 0009 MW-T2's editor picker.
4. Extend `GitHubFeatureTests.swift` with four palette-integration tests: merge palette entry unavailable when PR is merged; merge entry available when open + mergeable; mark-ready entry available only when draft; rerun entry available only when latest run has failures.

**Observable acceptance:** `⌘K` in the running app surfaces eight `GitHub: …` entries for the active Worktree; disabled entries display a grey label with the reason in the subtitle. Typing `gh me` narrows to `GitHub: Merge PR` and Enter executes the merge. Full test suite green.

Expected commits:
- `feat(github): add palette entries for PR actions`
- `feat(github): add MergeStrategyPicker sheet for no-default case`
- `test(github): add palette-integration tests`

### Milestone 6: Surface 4 — Settings GitHub section + first-run banner

What will exist at the end: the Settings window has a new **GitHub** sidebar entry rendering the Availability / Defaults / Per-Project overrides pane per the design wireframe; `RepositorySettings` persists across app restarts; and a first-run non-modal banner appears when `gh` is missing.

Work:

1. `apps/mac/codans/App/Features/GitHub/GitHubSettingsSection.swift` — SwiftUI view + `GitHubSettingsFeature` TCA reducer. The reducer reads/writes through `SettingsStore` (which already owns the 500 ms trailing debounce from 0005 M6b) for both global and per-Project fields. Per-Project pane reads the currently-focused Project from `HierarchyClient.selectedProjectID()`.
2. Integrate the section into the Settings window sidebar. Locate the Settings sidebar in `apps/mac/codans/App/Features/Settings/` (named per 0005 M6 landing); add a new sidebar entry `GitHub` alphabetically between `General` and `Notifications`.
3. `apps/mac/codans/App/Features/GitHub/Views/GitHubStatusBanner.swift` — shared availability banner used by both the Settings pane header and (separately) as the first-run sidebar banner. Four render states per the design UI §Surface 4 list.
4. First-run sidebar banner: when `availability == .unavailable(.notInstalled)` and a `settingsStore.dismissedFirstRunBanner == false`, render the banner at the top of the sidebar's Project list. `[ Learn how ]` opens Settings › GitHub via `.delegate(.openSettingsGitHub)`. `[ × ]` sets `dismissedFirstRunBanner = true`. Reset path: Settings' `Re-check` button re-enables the dismissed flag only when the user explicitly clicks `Show onboarding` (hidden until dismissed).
5. Connect the global `defaultMergeStrategy` / `postMergeAction` read path used by `GitHubFeature` to the new settings fields. Thread through via `settingsClient.global.defaultMergeStrategy` (follow the existing editor-default read path from 0005 M6).
6. Tests: `GitHubSettingsFeatureTests.swift` — 8 tests: availability render per state; selecting a merge strategy writes through `SettingsStore`; per-Project override flips between "use default" and "custom"; `Disable for this Project` toggle sets `RepositorySettings.githubDisabled`; banner dismissal persists. Plus one `SettingsStoreTests` addition round-tripping a file with all three new `RepositorySettings` fields set.

**Observable acceptance:** Human opens `⌘,` Settings, sees **GitHub** entry, picks `Squash and merge` as default. Quits and re-opens the app. The setting persists. On a fresh install without `gh`, the first-run banner appears at the top of the sidebar once; dismissing it leaves only the Settings banner as a reminder. `xcodebuild test -scheme codans` full suite green.

Expected commits:
- `feat(github): add Settings GitHub section with availability + defaults + per-project`
- `feat(github): add first-run availability banner with dismissable state`
- `feat(github): thread default merge strategy + post-merge action through SettingsStore`
- `test(github): add GitHubSettingsFeature tests`

### Milestone 7: Root integration, post-merge action, docs close-out

What will exist at the end: merging a PR triggers the user-configured post-merge Worktree action (nothing / archive / delete / ask); `architecture.md` reflects the new `codans/GitHub/` and `codans/Process/` modules; the product spec names GitHub integration as an explicit capability.

Work:

1. `RootFeature` observes `GitHubFeature.Action.delegate(.pullRequestMerged(worktreeID, snapshot))`. On receipt:
   - Resolve effective `MergedWorktreeAction` (Project override → global default → `.ask`).
   - `.doNothing` → no-op.
   - `.archive` → dispatch `.hierarchy(.archiveWorktree(worktreeID))` (existing action landed in 0010).
   - `.delete` → dispatch a confirmation sheet (follows 0010's existing `ConfirmRemoveWorktreeFeature`), then `.hierarchy(.removeWorktree(worktreeID))` on confirm.
   - `.ask` → present `PostMergeActionSheet` (new, small) with three buttons + optional "Remember my choice for this Project" checkbox that writes through to `RepositorySettings.postMergeAction`.
2. `apps/mac/codans/App/Features/GitHub/Views/PostMergeActionSheet.swift` — small sheet per DEC-4 shape.
3. Integration smoke test `GitHubRootIntegrationTests.swift`: `TestStore` boots `RootFeature`, dispatches a `.pullRequestMerged` with Project override `.archive`, asserts `hierarchy.archiveWorktree` is called with the right ID; same with `.delete`; same with `.ask` shows the sheet.
4. Update `apps/mac/docs/architecture.md` (path: `docs/architecture.md`):
   - Add row `codans/Process/` in the in-app modules table: "Subprocess primitives (`CommandRunner` / `FoundationCommandRunner`). Extracted from `Git/` during GitHub integration (0012 DEC-5) to serve both `Git/` and `GitHub/`."
   - Add row `codans/GitHub/`: "gh-delegated PR data layer. `GitHubService` protocol + `LiveGitHubService` + DTO parsers + `GhExecutableResolver`. App-layer `GitHubFeature` in `App/Features/GitHub/`."
   - Update the dependency-direction prose to name `GitHub` as a sibling of `Git` that does not depend on `Git`, and the shared primitive `Process/`.
5. Update `docs/product-spec.md`:
   - Add capability entry **C9 — GitHub PR integration (v1, PR-centric, gh-delegated)** with a one-paragraph summary referencing this plan.
   - Add an Open Question entry for v2 IPC surface (`github.*` methods) as explicitly deferred.
6. Update `docs/design-docs/README.md` and `docs/exec-plans/README.md` to index the new design doc and this plan.
7. Mark the Progress-section entries with completion timestamps; fill the Outcomes & Retrospective section per milestone using the format from 0005.

**Observable acceptance:** In the running app, with post-merge action set to `Archive`, clicking Merge on an open PR produces a merged badge and, within ≈1 s, the Worktree's row disappears from the sidebar (re-surfaceable via the Archived view). With post-merge set to `Ask`, a confirmation sheet appears after merge. `make mac-build` clean. `make mac-lint` clean. Full test suite green including the new root-integration smoke test.

Expected commits:
- `feat(github): dispatch post-merge worktree action from RootFeature`
- `feat(github): add PostMergeActionSheet for ask-each-time mode`
- `test(github): add root-integration smoke test covering archive/delete/ask`
- `docs: extend architecture.md with Process/ and GitHub/ modules`
- `docs: add C9 GitHub integration capability to product spec`

## Concrete Steps

All commands assume working directory `/Users/wanggang/.prowl/repos/codans/feature/github01` unless otherwise noted.

### M0 steps

```
# 1. Move the file.
git mv apps/mac/codans/Git/CommandRunner.swift \
       apps/mac/codans/Process/CommandRunner.swift

# 2. Verify Tuist picks up the new folder via folder-glob (no Project.swift edit expected).
make mac-generate
# Expected: no errors; new Process/ folder included in the codans target.

# 3. Build + test the existing suite before any GitHub code is added.
make mac-build
# Expected: BUILD SUCCEEDED.

xcodebuild test -scheme codans -destination 'platform=macOS' 2>&1 | xcbeautify
# Expected: 242 tests across 34 suites, 0 failures (same counts as 0005 M8 close-out).

# 4. Add GitHub namespace + resolver (see file list in M0 plan).
# 5. Rebuild + retest.
make mac-build && xcodebuild test -scheme codans -destination 'platform=macOS' 2>&1 | xcbeautify
# Expected: 246 tests (242 + 4 new GhExecutableResolverTests), 0 failures.
```

### M1 steps

```
# Build the CodansCore changes in isolation — fastest feedback loop.
xcodebuild test -scheme CodansCore -destination 'platform=macOS' 2>&1 | xcbeautify
# Expected, after M1 lands: 105+ tests (80 baseline + ~25 new GitHub DTO / settings), 0 failures.

# Verify leaf-ness: no AppKit/SwiftUI/TCA imports in the new CodansCore files.
grep -l 'import \(AppKit\|SwiftUI\|ComposableArchitecture\)' \
  apps/mac/CodansCore/GitHub/*.swift
# Expected: (empty output)

# Verify RepositorySettings round-trips.
xcodebuild test -scheme CodansCore -only-testing:CodansCoreTests/RepositorySettingsTests
# Expected: all tests pass including the three new field-specific tests.
```

### M2 steps

```
# Capture the JSON fixtures once from a real gh invocation on this very repo.
# Run from the repo root so gh picks up the right remote.
mkdir -p apps/mac/codans/Tests/GitHubTests/Fixtures

gh pr view --json number,title,state,isDraft,headRefName,author,additions,deletions,commits,mergeable,url,updatedAt \
  > apps/mac/codans/Tests/GitHubTests/Fixtures/gh-pr-view-open.json
# Repeat for each of the four states on branches you can point gh at; if a state
# is unreachable today, hand-edit a copy to produce the variant.

gh pr checks --json name,status,conclusion,detailsUrl,startedAt,completedAt \
  > apps/mac/codans/Tests/GitHubTests/Fixtures/gh-pr-checks-mixed.json

gh auth status --json hosts \
  > apps/mac/codans/Tests/GitHubTests/Fixtures/gh-auth-status-available.json

# Build + test.
make mac-build
xcodebuild test -scheme codans 2>&1 | xcbeautify
# Expected: 276+ tests, 0 failures; integration tests skipped (default).

# Opt-in integration tests (requires gh logged in):
TC_RUN_GITHUB_INTEGRATION_TESTS=1 \
  xcodebuild test -scheme codans \
  -only-testing:codansTests/GitHubTests/LiveGitHubServiceIntegrationTests \
  2>&1 | xcbeautify
# Expected: 5 integration tests pass.
```

### M3 steps

```
make mac-build
xcodebuild test -scheme codans \
  -only-testing:codansTests/GitHubTests/GitHubFeatureTests \
  2>&1 | xcbeautify
# Expected: ≥20 reducer tests, 0 failures.

# Verify zero SwiftUI imports in the feature folder (this milestone).
grep -l 'import SwiftUI' apps/mac/codans/App/Features/GitHub/*.swift || echo "CLEAN"
# Expected: CLEAN
```

### M4 steps

```
make mac-build
make mac-run-app
# Human: select a Worktree that has an open PR. Observe the badge; click it; observe popover.
# Click Merge. Observe: PR merged in gh, badge transitions open → merged within ~1 s.

# Snapshot tests (optional, env-gated per DEC-20 lesson).
TC_RUN_SNAPSHOT_TESTS=1 xcodebuild test -scheme codans \
  -only-testing:codansTests/GitHubTests/GitHubViewSnapshotTests \
  2>&1 | xcbeautify
# Expected: tests record mode (first run) or pass (subsequent).

# Full suite.
xcodebuild test -scheme codans 2>&1 | xcbeautify
# Expected: full suite green.
```

### M5 steps

```
make mac-build && make mac-run-app
# Human: ⌘K, type "gh", verify all eight entries appear. Disabled entries show a reason.

xcodebuild test -scheme codans \
  -only-testing:codansTests/GitHubTests/GitHubFeatureTests \
  2>&1 | xcbeautify
# Expected: includes four new palette tests.
```

### M6 steps

```
make mac-build && make mac-run-app
# Human: ⌘, opens Settings. Navigate to GitHub. Switch default strategy to Squash.
# Quit (⌘Q) and relaunch; confirm setting persisted.

# Verify RepositorySettings round-trip with all three new fields set.
xcodebuild test -scheme CodansCore \
  -only-testing:CodansCoreTests/SettingsStoreTests/fullGitHubFieldsRoundtrip \
  2>&1 | xcbeautify
```

### M7 steps

```
make mac-build && make mac-run-app
# Human: set post-merge action to Archive globally.
# On a Worktree with an open mergeable PR, click Merge in the popover.
# Expected: badge → merged; within ≈1 s the Worktree row disappears from the main sidebar
# list (re-surfaceable via the Archived view).

xcodebuild test -scheme codans 2>&1 | xcbeautify
# Expected: full suite including GitHubRootIntegrationTests, all green.

# Docs cross-check.
grep -c 'GitHub' docs/architecture.md
# Expected: ≥2 matches (Process/ row + GitHub/ row).
```

## Validation and Acceptance

The plan is complete when:

1. **Build + test.** `make mac-build` and `xcodebuild test -scheme codans` both succeed cleanly. Total test count grows from the 0005 M8 baseline (242) by approximately 70–90, landing in the 310–330 range. `make mac-lint` clean.

2. **Workflow demo — primary outcome.** A human does this sequence with the running app:
   - Launches `make mac-run-app` on a repo where `gh auth status` reports `Logged in to github.com as <user>`.
   - Selects any Worktree backed by a branch with an open PR. Within ~1 s, a PR badge appears on that Worktree's sidebar row.
   - Clicks the badge. The popover opens, showing PR title, author, state pill, commit/line counts, a sorted check-list, and the actions row.
   - Clicks **Merge** (default strategy). Within ~2 s the badge transitions to merged (purple), and (if `postMergeAction == .archive`) the row disappears from the main list.
   - Hits `⌘K`, types `gh me`, sees **GitHub: Merge PR** auto-narrowed. On a non-mergeable PR the entry is disabled with the reason.
   - Opens `⌘,` Settings → **GitHub**, confirms `Connected to github.com as <user>`; switches default to `Squash and merge`; quits and relaunches; setting persists.

3. **Regression surface.** Every test from plans 0001 through 0011 continues to pass. The `feature/github01` branch's C7 Git Viewer behaves identically to `main` (no regressions from the `CommandRunner` move).

4. **Missing-gh acceptance.** Temporarily renaming `/opt/homebrew/bin/gh` (or removing it from `$PATH` in the run environment) produces exactly:
   - No badges on any Worktree row.
   - First-run banner at the top of the sidebar with `[ Learn how ]` / `[ × ]`.
   - Settings → GitHub shows the amber `.notInstalled` banner with the brew command + Copy button.
   - No error popups, no crashes, no stuck spinners, no error logs at `.error` level.

5. **Architecture docs reflect the new modules.** `docs/architecture.md` lists `codans/Process/` and `codans/GitHub/`, and the dependency-direction section names `GitHub` as a sibling of `Git` that depends on `Process` but not on `Git`.

## Idempotence and Recovery

Every step in Concrete Steps is idempotent:

- `git mv` is a one-shot with a clear revert (`git mv` back + recommit).
- File additions are purely additive: re-running the step is a no-op since the file already exists.
- `make mac-generate` is idempotent by design (Tuist).
- `gh` fixture capture commands overwrite the fixture file deterministically; re-running refreshes the fixture against the current PR state.
- `xcodebuild test` is a read-only verification — always safe to re-run.

Failure recovery:

- **M0 `git mv` breaks the C7 test suite** — revert with `git checkout apps/mac/codans/Git/CommandRunner.swift apps/mac/codans/Process/CommandRunner.swift` (either direction) and investigate the import graph before retrying. This is the single highest-risk step in the plan; the design's R6 mitigation called it out.
- **M2 fixture capture fails** (user has no PR on the current branch) — create a throwaway PR via `gh pr create --draft --title "fixture capture"`, capture the fixture, then `gh pr close` the PR. Fixtures are checked in; this is a one-time cost.
- **M4 popover crashes at first render** — most likely cause is a SwiftUI `@FocusState` + popover interaction (see 0005 DEC-20). Fall back to presenting the popover on a separate NSWindow (worktree-header pattern from 0009 MW-T2) before investigating deeper.
- **M6 Settings doesn't persist** — confirm `SettingsStore.debounceInterval` is not swallowing the write (known 500 ms trailing debounce; `SIGTERM` handler flushes). Manually `kill -TERM <pid>` and re-check file on disk.
- **M7 post-merge action fires on unrelated Worktree** — the PR ↔ Worktree match heuristic picked the wrong worktree. Log the tie-break decision at `.debug` and use the `.debug` log to diagnose.

Rollback at any milestone: every milestone adds files and fields additively. `git revert <milestone-merge-commit>` restores the prior state; no on-disk data migration is needed (all new `settings.json` fields encode-omitted when unset).

## Artifacts and Notes

No prototyping artifacts — the design is mechanical composition of well-proven patterns (subprocess wrapping + TCA feature + SwiftUI views) and reuses existing primitives (`CommandRunner`, `SettingsStore`, TCA `DependencyKey` shape, SwiftUI `.popover`). Each milestone's verification transcript will be appended here as it lands, mirroring the 0005 post-milestone pattern.

## Interfaces and Dependencies

Every interface must exist at the end of the milestone where it first appears. Signatures are prescriptive — implementers follow them.

**In `apps/mac/codans/Process/CommandRunner.swift` (moved from `Git/` in M0):**

```swift
nonisolated protocol CommandRunner: Sendable {
  func run(
    executable: URL,
    arguments: [String],
    env: [String: String],
    cwd: URL,
    timeout: Duration,
    maxOutputBytes: Int
  ) async -> CommandOutcome
}
```

**In `apps/mac/codans/GitHub/GhExecutableResolver.swift` (M0):**

```swift
protocol EnvironmentVariableProvider: Sendable {
  func value(for key: String) -> String?
}

actor GhExecutableResolver {
  static let shared = GhExecutableResolver()
  init(env: EnvironmentVariableProvider = LiveEnvironment(),
       runner: CommandRunner = FoundationCommandRunner())
  func resolve() async -> URL?
  func invalidate() async
}
```

**In `apps/mac/CodansCore/GitHub/` (M1):**

```swift
public struct PullRequestSnapshot: Codable, Sendable, Equatable, Identifiable {
  public var id: Int { number }
  public var number: Int
  public var title: String
  public var state: PullRequestState
  public var isDraft: Bool
  public var headRefName: String
  public var author: String
  public var additions: Int
  public var deletions: Int
  public var commitCount: Int
  public var mergeable: MergeableState
  public var url: URL
  public var updatedAt: Date
}

public enum PullRequestState: String, Codable, Sendable { case open = "OPEN", merged = "MERGED", closed = "CLOSED" }
public enum MergeableState: String, Codable, Sendable { case mergeable = "MERGEABLE", conflicting = "CONFLICTING", unknown = "UNKNOWN" }

public struct CheckResult: Codable, Sendable, Equatable, Identifiable { /* fields per M1 */ }
public enum CheckStatus: String, Codable, Sendable { /* ... */ }
public enum CheckConclusion: String, Codable, Sendable { /* ... */ }

public struct WorkflowRun: Codable, Sendable, Equatable, Identifiable { /* fields per M1 */ }

public enum MergeStrategy: String, Codable, Sendable, CaseIterable {
  case mergeCommit, squash, rebase
  public var cliFlag: String { /* --merge / --squash / --rebase */ }
  public var displayName: String { /* localized */ }
}

public enum MergedWorktreeAction: String, Codable, Sendable, CaseIterable {
  case doNothing, archive, delete, ask
}

public enum GitHubAvailability: Sendable, Equatable {
  case unknown
  case available(host: String, user: String)
  case unavailable(reason: String)    // reason is user-facing; .notInstalled / .notAuthenticated detail at app layer
}
```

**In `apps/mac/CodansCore/Settings/RepositorySettings.swift` (M1, extended):**

```swift
public struct RepositorySettings: Equatable, Codable, Sendable {
  public var defaultMergeStrategy: MergeStrategy?
  public var postMergeAction: MergedWorktreeAction?
  public var githubDisabled: Bool
  public init(
    defaultMergeStrategy: MergeStrategy? = nil,
    postMergeAction: MergedWorktreeAction? = nil,
    githubDisabled: Bool = false
  )
  public var isEffectivelyEmpty: Bool { /* all three == default */ }
}
```

**In `apps/mac/codans/GitHub/GitHubService.swift` (M2):**

```swift
nonisolated protocol GitHubService: Sendable {
  func availability() async -> GitHubAvailability
  func pullRequest(branch: String, worktreePath: URL) async throws -> PullRequestSnapshot?
  func checks(number: Int, worktreePath: URL) async throws -> [CheckResult]
  func latestWorkflowRun(branch: String, worktreePath: URL) async throws -> WorkflowRun?
  func merge(number: Int, strategy: MergeStrategy, worktreePath: URL) async throws
  func close(number: Int, worktreePath: URL) async throws
  func markReady(number: Int, worktreePath: URL) async throws
  func rerunFailedJobs(runID: Int64, worktreePath: URL) async throws
}

nonisolated enum GitHub {
  public static func makeService() -> any GitHubService { /* LiveGitHubService() */ }
}
```

**In `apps/mac/codans/GitHub/GitHubError.swift` (M2):**

```swift
enum GitHubError: Error, Equatable, Sendable {
  case notInstalled
  case notAuthenticated(host: String?)
  case notAPullRequest
  case network(String)
  case rateLimited(retryAfter: Duration?)
  case mergeConflict
  case timeout
  case other(String)
  var userFacingMessage: String { /* localized */ }
}
```

**In `apps/mac/codans/App/Clients/GitHubClient.swift` (M3):**

```swift
nonisolated struct GitHubClient: Sendable, DependencyKey {
  var availability: @Sendable () async -> GitHubAvailability
  var pullRequest: @Sendable (_ branch: String, _ worktreePath: URL) async throws -> PullRequestSnapshot?
  var checks: @Sendable (_ number: Int, _ worktreePath: URL) async throws -> [CheckResult]
  var latestWorkflowRun: @Sendable (_ branch: String, _ worktreePath: URL) async throws -> WorkflowRun?
  var merge: @Sendable (_ number: Int, _ strategy: MergeStrategy, _ worktreePath: URL) async throws -> Void
  var close: @Sendable (_ number: Int, _ worktreePath: URL) async throws -> Void
  var markReady: @Sendable (_ number: Int, _ worktreePath: URL) async throws -> Void
  var rerunFailedJobs: @Sendable (_ runID: Int64, _ worktreePath: URL) async throws -> Void
  static let liveValue: GitHubClient = .live()
  static let testValue: GitHubClient = /* unimplemented(…) */
}

extension DependencyValues {
  var gitHub: GitHubClient { get set }
}
```

**In `apps/mac/codans/App/Features/GitHub/GitHubFeature.swift` (M3):**

```swift
@Reducer
struct GitHubFeature {
  @ObservableState
  struct State: Equatable {
    var availability: GitHubAvailability = .unknown
    var availabilityProbedAt: Date?
    var snapshots: [WorktreeID: PullRequestSnapshot] = [:]
    var snapshotLoadedAt: [WorktreeID: Date] = [:]
    var checks: [Int: [CheckResult]] = [:]
    var workflowRuns: [Int: WorkflowRun] = [:]
    var loading: Set<WorktreeID> = []
    var pendingLoads: [WorktreeID] = []      // queue when inFlight cap reached
    var popoverTarget: WorktreeID?
    var lastError: [WorktreeID: GitHubError] = [:]
    var mergeStrategyOverride: MergeStrategy?  // set by palette picker
  }
  enum Action: Equatable { /* per M3 */ }
}
```

**In `apps/mac/codans/App/Features/GitHub/Views/` (M4–M6):**

The public view initializers are:

```swift
struct PullRequestBadge: View {
  init(snapshot: PullRequestSnapshot,
       rollup: CheckRollup,
       state: BadgeRenderState,
       onTap: @escaping () -> Void,
       onCommandTap: @escaping () -> Void)
}

struct PullRequestPopover: View {
  init(store: StoreOf<GitHubFeature>,
       worktreeID: WorktreeID,
       projectID: ProjectID)
}

struct MergeSplitButton: View {
  init(defaultStrategy: MergeStrategy,
       onMerge: @escaping (MergeStrategy) -> Void,
       onSetProjectDefault: @escaping (MergeStrategy) -> Void)
}

struct MergeStrategyPicker: View {
  init(isPresented: Binding<Bool>,
       onConfirm: @escaping (MergeStrategy) -> Void)
}

struct GitHubStatusBanner: View {
  init(availability: GitHubAvailability,
       style: Style,      // .sidebarFirstRun | .settingsSection
       onDismiss: (() -> Void)?,
       onAction: @escaping (Action) -> Void)
}

struct PostMergeActionSheet: View {
  init(worktreeName: String,
       isPresented: Binding<Bool>,
       onConfirm: @escaping (MergedWorktreeAction, _ remember: Bool) -> Void)
}
```

Libraries used:

- `The Composable Architecture` (already in `Tuist/Package.swift` via 0002 M5) — `@Reducer`, `@ObservableState`, `StoreOf`, `TestStore`.
- `Swift Observation` (`@Observable`) — not used inside `GitHubFeature`; used only by existing `HierarchyManager` which this plan reads through the `HierarchyClient` TCA dependency.
- `swift-snapshot-testing` (already pinned in `Tuist/Package.swift` via 0005 DEC-17) — M4 snapshot tests, env-gated.

No new SPM / Tuist / mise dependencies.
