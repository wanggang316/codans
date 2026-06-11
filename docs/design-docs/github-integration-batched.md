# Design Doc: GitHub Integration v2 — Repository-batched PR fetch

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-04-23
**Supersedes:** [github-integration.md](github-integration.md)

## Context and Scope

v1 shipped in PR #39 with a per-Worktree fetch model: each sidebar row, on appearance, triggered one `gh pr view <branch>` subprocess, then — after snapshot load — a second `gh pr checks <number>` subprocess. With a single open Project carrying 20+ Worktrees, a cold refresh fires ~40 subprocesses back-to-back, each paying ~80–150 ms of `gh` cold-start plus ~300–500 ms of network round-trip. The sidebar feels unresponsive during that window; badges paint in staggered fashion; CI-rollup overlays flicker in one by one.

A more recent bug surfaced during Stage 1 of the sidebar redesign revealed a second-order problem with the v1 scheduling model: the `.task(id:)` that kicked the first fetch was attached to a SwiftUI `Group` whose initial branch resolved to `EmptyView()`, which does not mount into the view tree — so for rows without cached data the dispatch never happened. We patched the symptom (Stage 1.5, commit `9cef30a`), but the underlying fragility — one fetch per row, driven by the row's own `.task` — makes the fetch path brittle to any SwiftUI lifecycle detail.

This document replaces the v1 fetch model with a **repository-batched GraphQL fetch**. The user-visible surface (sidebar capsule, popover, command-palette entries, Settings) is unchanged. The execution model beneath it is replaced.

Repository state at design time:

- v1 code is live in `codans/GitHub/` and `codans/App/Features/GitHub/`. All tests pass; feature is in production use.
- `GhExecutableResolver`, `CommandRunner` wrapping, env allowlist, and `GhCommand` argv builder are reusable verbatim. The substitution is limited to the **query body** (replaces `pr view` / `pr checks` with `gh api graphql`) and the **dispatch surface** (replaces per-row `.task` with reducer-owned effects keyed by project).
- `RepositorySettings` (GitHub integration toggle, merge strategy, post-merge action) is unchanged.
- The persistence story is unchanged — still memory-only, still reset on app launch.

This document is the source of truth for the v2 execution model and the migration off v1.

## Goals and Non-Goals

**Goals**

- Cut subprocess cost per refresh cycle from **O(W)** (Worktrees in the active Project) to **O(R)** (Repositories the user has open; ≤ 1 in practice), for a typical 10–40× reduction in subprocess launches.
- Fetch PR metadata + aggregated check results in **one network round-trip per repository**, so CI health paints with the PR snapshot instead of arriving second.
- Replace per-row `.task(id:)` dispatch with reducer-owned project-level effects driven by explicit invalidation events (Worktree appearance, branch change, post-write mutation, manual refresh).
- Keep all v1 user-facing surfaces pixel-for-pixel identical — badge, popover, context menu, palette entries, Settings — so the refactor is invisible unless the user is measuring latency.
- Preserve every v1 non-functional guarantee: zero in-app HTTP, zero Keychain use, zero token material in codans, zero hidden network work from SwiftUI view bodies.

**Non-Goals**

- **No direct GitHub REST/GraphQL HTTP.** We continue to delegate to `gh` — specifically `gh api graphql`, which runs the query against `gh`'s authenticated HTTP stack. The only thing that changes is the query body.
- **No OAuth in codans.** `gh auth login` remains the sole authentication path; tokens live in `gh`'s config store; we never read them.
- **No webhooks, server push, or background polling.** Invalidation is event-driven (defined below), not time-driven.
- **No review threads, comments, issues, discussions, or actions dashboards.** Scope remains PR metadata + aggregated check rollup.
- **No disk persistence of PR state.** Snapshots are memory-only. One exception tracked in Open Questions: caching last-known snapshot to show instantly on restart, explicitly deferred.
- **No query-budget optimization for public repos we don't own.** The design assumes the user interacts with their own repositories; cross-repo aggregations are out of scope.
- **No partial-result rendering.** If a GraphQL query fails, we fail the chunk; we do not render partially-populated sidebar state to avoid "half-merged" visual confusion.

## Design

### Overview

The execution model is:

1. **Reducer owns fetch lifecycle.** The `GitHubFeature` reducer listens for invalidation events (Worktree added / removed / branch-changed / post-mutation, Project activated, Manual refresh). On any such event for a Project, it fires **one** effect that asks the client to fetch PR data for **all Worktrees in that Project at once**.

2. **Client issues a batched GraphQL query.** `GitHubClient.batchPullRequests(host, owner, repo, branches)` invokes `gh api graphql` once, passing a query string that carries one GraphQL alias per branch (up to 25 per chunk, multiple chunks run concurrently with cap 3). The response carries every branch's PR data in one payload; the client decodes it into `[branch: PullRequestSnapshot]` and returns.

3. **Reducer distributes per-Worktree.** On success, the reducer maps `branch → WorktreeID` via the local catalog and writes the result into `state.snapshots[worktreeID]`. Views read from there unchanged.

4. **Invalidation is event-driven, not TTL-based.** v1 used a 30-second freshness window; v2 drops it. The cache is "live until something known-invalidating happens". Known-invalidating events are enumerated below — they're few, and every one is cheaper than a blind 30-second re-probe of every Worktree.

5. **Check rollup travels with the snapshot.** The v1 separation of `pullRequest(branch:)` + `checks(number:)` is collapsed: the GraphQL query pulls `statusCheckRollup.contexts` alongside the rest. Consumers read `snapshot.checkRollup` directly. The separate `state.checks[prNumber]` map disappears.

6. **The gh subprocess path is unchanged.** Resolver, env allowlist (`PATH`, `HOME`, `GH_CONFIG_DIR`, `XDG_CONFIG_HOME`, forced `LC_ALL`), timeout (20 s), output cap (bumped to 8 MB for batched queries, see Risks), argv safety model all reused.

Three load-bearing decisions, covered in [Alternatives Considered](#alternatives-considered):

1. **Batch by repository, not by Worktree.** A single gh invocation covers every branch in the active Project. Cost scales with Project count, not Worktree count.

2. **GraphQL alias pattern instead of N REST calls.** GitHub's GraphQL API supports per-field aliases, letting us query `branch0: pullRequests(...) branch1: pullRequests(...) ...` against a single `repository(owner, name)` root. One round-trip, one rate-limit charge.

3. **Event-driven invalidation; no TTL.** The 30-second freshness window in v1 existed because we didn't have a better signal. We do now: branch changes are observable (filesystem watches on `.git/HEAD`), Worktree add/remove is already in `HierarchyManager`, Project activation is observable. A cache that lives until something relevant happens is both cheaper and more correct than a periodic refresh.

### System Context Diagram

```
      ┌──────────────────────────────────────────────────────────────────┐
      │  codans app window                                           │
      │                                                                  │
      │  ┌──────────────────┐   ┌───────────────────────────────────┐    │
      │  │  Sidebar         │   │  GitHubFeature (TCA reducer)      │    │
      │  │  Worktree rows   │──▶│   state:                          │    │
      │  │   + PR badge     │   │   · snapshotsByProject            │    │
      │  │   + overlay      │   │   · inFlightFetchProjects         │    │
      │  └──────────────────┘   │   · queuedRefreshByProject        │    │
      │         ▲    │          │   effects:                        │    │
      │         │    │hover     │   · refreshProject(projectID)     │    │
      │         │    ▼          │   · delayedFullRefresh(postWrite) │    │
      │         │  popover      └────────────────┬──────────────────┘    │
      │         │               ┌─ GitHubClient (DI) ─                   │
      │         │               ▼                                        │
      │  ┌──────────────────┐   ┌────────────────────────────────┐       │
      │  │  Branch watcher  │──▶│  codans/GitHub/            │       │
      │  │  (HEAD filesys)  │   │    · GitHubService (proto)     │       │
      │  └──────────────────┘   │    · LiveGitHubService         │ ──────┼──┐
      │                         │      ├ buildBatchedQuery()     │       │  │
      │                         │      ├ chunk(branches, n=25)   │       │  │
      │                         │      └ TaskGroup (cap=3)       │       │  │
      │  HierarchyManager.catalog                                 │       │  │
      │  (Worktree add/remove,  │    · DynamicKeyedDecoder        │       │  │
      │   selection changes)    │    · PullRequestSnapshot (ext)  │       │  │
      │                         │    · GitHubError (ext)          │       │  │
      │                         └────────────────────────────────┘       │  │
      └──────────────────────────────────────────────────────────────────┘  │
                                                                            │
                                                                            ▼
                                                          ┌───────────────────────────┐
                                                          │ /opt/homebrew/bin/gh       │
                                                          │   gh api graphql \         │
                                                          │     --hostname <host> \    │
                                                          │     -f query='<aliased>' \ │
                                                          │     -f owner=<owner> \     │
                                                          │     -f repo=<repo>         │
                                                          │                            │
                                                          │  One child per chunk,      │
                                                          │  up to 3 concurrent.       │
                                                          │  cwd = project.gitRoot     │
                                                          │  timeout 20s, cap 8 MB     │
                                                          └──────────┬─────────────────┘
                                                                     │ HTTPS
                                                                     ▼
                                                           api.github.com/graphql
```

External boundaries touched:

- **`gh` CLI** — unchanged role. The subcommand shifts from `gh pr view / gh pr checks` to `gh api graphql`. Still one child per request. Still cwd-scoped so `gh` resolves the remote from the project's gitRoot.
- **`HierarchyManager`** — now also observed for `worktreeAdded` / `worktreeRemoved` / `projectActivated`, not just selected-Worktree. These drive cache invalidation.
- **Filesystem** — new: a lightweight `WorktreeBranchWatcher` observes `.git/HEAD` per Worktree. Dispatches `worktreeBranchChanged(worktreeID, newBranch)` when a terminal-initiated `git checkout` lands. Optional for v2.0; may defer to v2.1 if complexity is not justified.
- **`SettingsStore`** — unchanged.

### Execution Flow

A complete refresh cycle for one Project, triggered by (for example) the user activating that Project:

```
 1. User selects Project P in sidebar.
    HierarchyManager.selectedProjectID flips. RootFeature observes.

 2. RootFeature dispatches GitHubFeature.Action.projectActivated(P).

 3. Reducer checks state.snapshotsByProject[P]:
    - Cached + branches match current catalog → no-op.
    - Missing OR branches changed → schedule a refresh.

 4. Reducer collects current branches:
      let branches = project.worktrees
        .filter { !$0.archived && $0.branch != nil }
        .compactMap(\.branch)

 5. Reducer resolves host/owner/repo:
      let remote = try await gitClient.remoteInfo(project.gitRoot)
    (Not part of GitHubClient — this is a pure git-local operation.)

 6. Reducer calls client:
      let result = try await gitHubClient.batchPullRequests(
        remote.host, remote.owner, remote.repo, branches
      )

 7. LiveGitHubService.batchPullRequests:
     a. Chunks `branches` into slices of ≤ 25.
     b. Spawns a TaskGroup, capped at 3 concurrent children.
     c. For each chunk:
          - Builds a GraphQL query with one alias per branch.
          - Runs `gh api graphql --hostname <h> -f query=<q> -f owner=<o> -f repo=<r>`.
          - Decodes response via DynamicKeyedDecoder.
          - Filters fork PRs (see Fork PR Filtering).
          - Returns [branch: PullRequestSnapshot].
     d. Merges chunk results into a single dictionary.

 8. Reducer receives [branch: Snapshot], maps into [WorktreeID: Snapshot] via the
    catalog's branch→worktree index, and writes into state.snapshotsByProject[P].

 9. Views re-render via @ObservableState. Every row in Project P paints its badge
    with the new data. Check rollup overlays paint in the same pass — the data
    was in the snapshot from the start.

10. A single additional write (mergePullRequest / close / markReady) fires a
    delayed full refresh (step 2) after 2 seconds to pick up GitHub's updated
    state without racing the eventual-consistency window.
```

Throughout: the effect is `.cancellable(id: CancelID.projectFetch(P), cancelInFlight: true)`. Back-to-back triggers collapse to the last one. A Project switch cancels any in-flight fetch for the previous Project.

### GraphQL Query Shape

The query is **programmatically assembled** as a raw string. We do not use a typed query builder — GitHub's GraphQL schema is stable enough, the query is small, and maintaining a typed DSL costs more than it saves.

One chunk of up to 25 branches produces one query:

```graphql
query($owner: String!, $repo: String!) {
  repository(owner: $owner, name: $repo) {
    branch0: pullRequests(
      first: 5,
      states: [OPEN, MERGED],
      headRefName: "<branch-name-0>",
      orderBy: {field: UPDATED_AT, direction: DESC}
    ) {
      nodes { ...PRFields }
    }
    branch1: pullRequests(first: 5, states: [OPEN, MERGED],
      headRefName: "<branch-name-1>", orderBy: {...}) { nodes { ...PRFields } }
    ...
    branch24: pullRequests(...) { nodes { ...PRFields } }
  }
}
```

With `PRFields` defined as one inline fragment — **we do not use GraphQL fragments** because `gh api graphql` passes the whole query as a single `-f query=` argument and inlining keeps the wire payload under the argv size limit. Fields:

```graphql
number
title
state
isDraft
additions
deletions
mergeable
mergeStateStatus
reviewDecision
url
updatedAt
headRefName
baseRefName
commits { totalCount }
author { login }
headRepository { name owner { login } }
statusCheckRollup {
  contexts(first: 100) {
    nodes {
      ... on CheckRun {
        name
        status
        conclusion
        startedAt
        completedAt
        detailsUrl
      }
      ... on StatusContext {
        context
        state
        targetUrl
        createdAt
      }
    }
  }
}
```

**Why `first: 5` per branch.** A branch can have multiple PRs across its history (reopened PRs, pushed twice, merged and re-opened). We fetch the latest 5 and pick the most-recently-updated one that passes fork-PR filtering. Five is a safe ceiling — rarely exceeded in practice; if exceeded, we accept showing the most recent 5 and log the truncation at `.debug`.

**Why `states: [OPEN, MERGED]`.** Closed (non-merged) PRs are rare and usually intentional dead-ends — showing them in the sidebar adds noise for near-zero value. If the user wants to see closed PRs, they click "Open on GitHub". A v2.x setting could expand the filter if a user case arrives.

**Why `orderBy: UPDATED_AT DESC`.** Within the 5-PR slice, we want the most recently active one on top. `UPDATED_AT` (rather than `CREATED_AT`) handles the re-open-after-close case correctly.

**Branch-name escaping.** Branch names like `feat/"weird"name` or branches containing backslashes would break the query. We escape to GraphQL string rules: backslash-escape `\`, `"`, and control characters; reject any branch containing newlines. Rejection raises a `.malformedBranchName(branch)` error which the reducer logs and excludes from the fetch.

**Why alias name format `branch{index}`.** Plain integer indices avoid any name collision with user branch names, which would otherwise need their own escaping (GraphQL aliases must match `/[_a-zA-Z][_a-zA-Z0-9]*/`). The response decoder maintains a separate `[alias: branchName]` mapping to pair results back up.

### Response Decoding

The response shape, for one chunk:

```json
{
  "data": {
    "repository": {
      "branch0": { "nodes": [ { ... PR fields ... } ] },
      "branch1": { "nodes": [] },
      "branch2": { "nodes": [ {...}, {...} ] },
      ...
    }
  }
}
```

Two non-obvious decoding patterns:

#### 1. Dynamic keys for aliases

The `repository` object has N arbitrary string keys (`branch0`, `branch1`, …) whose set isn't fixed. Standard `CodingKeys` enumerations don't support this. Custom decoder:

```swift
struct DynamicKey: CodingKey {
  let stringValue: String
  init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
  let intValue: Int?
  init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
}

struct RepositoryResponse: Decodable {
  let pullRequestsByAlias: [String: PullRequestConnection]

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: DynamicKey.self)
    var out: [String: PullRequestConnection] = [:]
    for key in c.allKeys {
      out[key.stringValue] = try c.decode(PullRequestConnection.self, forKey: key)
    }
    self.pullRequestsByAlias = out
  }
}
```

Upstream of this, the caller keeps the `[alias: originalBranch]` map from query-construction time and zips the decoded dictionary back to branch names before returning.

#### 2. Union-type normalization

`statusCheckRollup.contexts.nodes` is a GraphQL union `CheckRun | StatusContext`. The two types overlap in purpose (CI status) but differ in field names:

- `CheckRun` has `name`, `detailsUrl`, `status`, `conclusion`.
- `StatusContext` has `context`, `targetUrl`, `state`.

We normalize at decode time into a single `CheckNode` that carries whichever fields the row actually has:

```swift
struct CheckNode: Decodable, Equatable, Hashable {
  let name: String?          // CheckRun.name OR StatusContext.context
  let detailsUrl: String?    // CheckRun.detailsUrl OR StatusContext.targetUrl
  let status: String?        // CheckRun only
  let conclusion: String?    // CheckRun only
  let state: String?         // StatusContext only

  enum CodingKeys: String, CodingKey {
    case name, context, detailsUrl, targetUrl, status, conclusion, state
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let n = try c.decodeIfPresent(String.self, forKey: .name)
    let ctx = try c.decodeIfPresent(String.self, forKey: .context)
    self.name = n ?? ctx
    let dUrl = try c.decodeIfPresent(String.self, forKey: .detailsUrl)
    let tUrl = try c.decodeIfPresent(String.self, forKey: .targetUrl)
    self.detailsUrl = dUrl ?? tUrl
    self.status = try c.decodeIfPresent(String.self, forKey: .status)
    self.conclusion = try c.decodeIfPresent(String.self, forKey: .conclusion)
    self.state = try c.decodeIfPresent(String.self, forKey: .state)
  }
}
```

Downstream, `CheckRollup.from(nodes:)` collapses `status` + `conclusion` + `state` into a single semantic enum (passing / failing / pending / skipped) using the same logic as v1's `CheckRollup.from(checks:)`.

### Fork PR Filtering

**The trap.** GitHub's `pullRequests(headRefName: "main")` matches any PR whose head-ref literally equals `main` — which includes **fork PRs** whose source branch happens to share a name with an upstream branch. A common case: a contributor on a fork named their feature branch `main`, opens a PR into upstream `main`, and now a query against upstream's local `main` returns that PR despite upstream-`main` being the **target**, not the source.

**The rule.** For each branch's result array:

1. Start by keeping every entry where `headRepository.owner.login == <owner of the project's remote>`. These are upstream-to-upstream PRs, which are the common case and always correct.

2. If step 1 produced zero entries, keep entries where `baseRefName != headRefName`. This lets us surface fork PRs whose head is our branch (valid) while rejecting ones targeting our branch (invalid).

3. From the survivors, pick the first (most-recently-updated, per the `orderBy` clause).

4. If zero survivors, this branch has no PR.

The filter is applied in `LiveGitHubService.batchPullRequests` before the `[branch: PullRequestSnapshot]` dictionary is returned. The reducer sees a clean mapping; it does not know about forks.

**Fixture coverage.** The golden-file fixture suite gains one fork-PR example to exercise the filter:

```
Tests/GitHubTests/Fixtures/batched-pr-fork-noise.json
  branches: ["main", "feature-x"]
  responses:
    main — 2 PRs, one upstream-targeting-main (to skip), one upstream-sourced-from-main (to keep)
    feature-x — 1 PR, fork-sourced, upstream-targeting (ambiguous; kept by rule 2)
```

### Data Model

Three changes from v1:

**1. `PullRequestSnapshot` gains `checkRollup`.** The separate `checks(number:)` call disappears; its output is now a field on the snapshot.

```swift
public struct PullRequestSnapshot: Equatable, Sendable, Codable {
  public let number: Int
  public let title: String
  public let state: PullRequestState
  public let isDraft: Bool
  public let additions: Int
  public let deletions: Int
  public let commitCount: Int
  public let mergeable: MergeableState
  public let mergeStateStatus: MergeStateStatus          // NEW
  public let reviewDecision: ReviewDecision?             // NEW
  public let url: URL
  public let updatedAt: Date
  public let headRefName: String
  public let baseRefName: String
  public let author: String
  public let checkRollup: [CheckResult]                  // NEW (replaces separate fetch)
  public let headRepositoryOwner: String                 // NEW (for fork filtering at write time)
}
```

`MergeStateStatus` and `ReviewDecision` are new enums. `MergeStateStatus` distinguishes `.clean` from `.dirty` / `.blocked` / `.behind` / `.draft` / `.hasHooks` / `.unknown` — richer than v1's `MergeableState` (which only knew `.mergeable` / `.conflicting` / `.unknown`) and lets the popover's merge button explain precisely *why* it's disabled.

**2. New `BatchedPullRequests` value type.** Returned by `batchPullRequests`:

```swift
public struct BatchedPullRequests: Equatable, Sendable {
  public let host: String
  public let owner: String
  public let repo: String
  public let byBranch: [String: PullRequestSnapshot]    // nil if branch has no PR
  public let fetchedAt: Date
}
```

The reducer stores one of these per Project and derives `state.snapshots[worktreeID]` by lookup.

**3. `state.checks[prNumber]` is removed.** Check data now lives on the snapshot. Any consumer of `state.checks[snapshot.number]` changes to `snapshot.checkRollup` — a mechanical rewrite.

### Caching and Invalidation

The v1 freshness window (30 s per snapshot, per Worktree) is deleted. Replaced with event-driven invalidation.

**Cache key: `ProjectID`.** Each Project's fetched snapshots live together because they share a GraphQL query and therefore share a lifecycle. Per-Worktree invalidation is expressed as "refresh this Project, but only use the result for Worktree X" — which collapses to "refresh this Project", so we don't bother distinguishing.

**Invalidation events:**

| Event | Source | Fires |
|---|---|---|
| Project activated (switched to from another Project) | `HierarchyManager.selectedProjectID` delta | refresh if cached snapshots' branch set ≠ current Worktree branches |
| Worktree added | `HierarchyManager` catalog delta | refresh Project |
| Worktree removed | `HierarchyManager` catalog delta | drop from cache; no fetch |
| Worktree branch changed | `WorktreeBranchWatcher` (filesystem watch on `.git/HEAD`) | refresh Project |
| Merge / close / markReady completed | `GitHubFeature.*Completed(.success)` | 2-second delayed refresh of Project |
| Manual refresh | user action (palette, popover refresh button) | refresh Project immediately |
| `gh` availability recovered from `.unavailable` | `GhAvailabilityCache` | refresh every Project that has a queued refresh request |
| App became active (optional, behind setting) | `NSApp.didBecomeActiveNotification` | refresh all open Projects, rate-limited to 60s per Project |
| Active-Project liveness poll | foreground timer, gated on `NSApp.isActive` × the active Project | forced refresh of the active Project on an adaptive cadence (~15 s while a PR has CI in flight or an unsettled merge state, ~60 s once settled); cancelled the instant the app resigns active, so an idle/backgrounded app polls zero times |

**Re-entrancy model.** Each Project carries three state slots:

- `snapshotsByProject[P]` — current cached result (or nil if never fetched).
- `inFlightFetchProjects` — set of Project IDs with an active subprocess chain.
- `queuedRefreshByProject` — Projects that asked for a refresh while one was in flight; the enqueued refresh runs after the in-flight one completes.

An invalidation event checks if a fetch is in flight; if yes, mark the Project as "queued" and no-op; otherwise start a fetch and add to `inFlightFetchProjects`. On completion, clear the in-flight mark and, if queued, fire a follow-up fetch.

This pattern handles the merge-close-mark-ready-merge rapid-fire case cleanly: the first fetch runs to completion, subsequent requests collapse into one queued fetch that runs last.

**Cancellation.** A queued refresh is dropped if the Project is closed or the user navigates away. An in-flight fetch is cancelled on Project deactivation via `.cancellable(id: CancelID.projectFetch(P), cancelInFlight: true)`.

### Availability Probe and Recovery Loop

The v1 probe (`gh auth status --json hosts`, 30 s TTL) is reused with two additions:

**1. In-flight dedup.** Multiple reducer cases can ask for availability concurrently (first-run, Settings pane, post-install refresh). An actor-serialized cache ensures one subprocess runs:

```swift
actor GhAvailabilityCache {
  private var cachedValue: GitHubAvailability?
  private var cachedAt: Date?
  private var inFlight: Task<GitHubAvailability, Never>?
  private let ttl: TimeInterval = 30

  func value() async -> GitHubAvailability {
    if let task = inFlight { return await task.value }
    if let v = cachedValue, let at = cachedAt,
      Date().timeIntervalSince(at) < ttl { return v }
    let task = Task<GitHubAvailability, Never> { await probe() }
    inFlight = task
    let result = await task.value
    inFlight = nil
    cachedValue = result
    cachedAt = Date()
    return result
  }

  func invalidate() { cachedAt = nil }
}
```

**2. Recovery loop.** When availability flips to `.unavailable` (typically `.notInstalled` after the user uninstalls `gh`, or `.notAuthenticated` after a token revoke), the reducer starts a heartbeat:

```swift
.run { send in
  while !Task.isCancelled {
    try? await ContinuousClock().sleep(for: .seconds(15))
    await send(.availabilityReprobe)
  }
}.cancellable(id: CancelID.availabilityRecovery, cancelInFlight: true)
```

On each reprobe, if availability flips back to `.available`, the loop cancels itself (`.availabilityProbed(.available, …)` cancels `CancelID.availabilityRecovery`) and any queued Project refreshes are dispatched. Cadence: 15 seconds — chosen to match a reasonable "user just ran `gh auth login`" turnaround, without being so fast it hammers `gh` during long offline periods.

### Fetch Scheduling in the Reducer

Action additions:

```swift
enum Action: Equatable {
  // NEW (project-level)
  case projectActivated(ProjectID)
  case projectDeactivated(ProjectID)
  case projectRefreshRequested(ProjectID)
  case projectBatchLoaded(ProjectID, TaskResult<BatchedPullRequests>)

  // NEW (branch change)
  case worktreeBranchChanged(WorktreeID, newBranch: String)

  // EXISTING (kept, semantics lightly adjusted)
  case worktreeBecameVisible(WorktreeID, ...)   // deprecated; no-op after v2 migration
  case refreshRequested(WorktreeID, ...)         // now routes to projectRefreshRequested
  case snapshotLoaded(...)                       // deprecated path; retained for write-side delayed refresh of a single worktree

  // Write actions UNCHANGED in shape; effect handlers updated to use delayedFullRefresh
  case mergeRequested(...), mergeCompleted(...)
  case closeRequested(...), closeCompleted(...)
  case markReadyRequested(...), markReadyCompleted(...)
  case rerunFailedJobsRequested(...), rerunFailedJobsCompleted(...)

  // EXISTING (popover / availability / delegate) — unchanged
  ...
}
```

**Project fetch effect:**

```swift
case .projectRefreshRequested(let projectID):
  guard state.inFlightFetchProjects.contains(projectID) == false else {
    state.queuedRefreshByProject.insert(projectID)
    return .none
  }
  state.inFlightFetchProjects.insert(projectID)
  return .run { [client = gitHubClient, gitClient] send in
    do {
      let project = ... // from a read-only observer of HierarchyManager or pass-through parameter
      let remote = try await gitClient.remoteInfo(project.gitRoot)
      let branches = project.worktrees
        .filter { !$0.archived }
        .compactMap(\.branch)
      guard !branches.isEmpty else {
        await send(.projectBatchLoaded(projectID, .success(.empty)))
        return
      }
      let byBranch = try await client.batchPullRequests(
        remote.host, remote.owner, remote.repo, branches
      )
      await send(.projectBatchLoaded(projectID, .success(
        BatchedPullRequests(host: remote.host, owner: remote.owner, repo: remote.repo,
                            byBranch: byBranch, fetchedAt: .now)
      )))
    } catch {
      await send(.projectBatchLoaded(projectID, .failure(error as? GitHubError ?? .other(...))))
    }
  }
  .cancellable(id: CancelID.projectFetch(projectID), cancelInFlight: true)

case .projectBatchLoaded(let projectID, .success(let batched)):
  state.inFlightFetchProjects.remove(projectID)
  state.snapshotsByProject[projectID] = batched
  if state.queuedRefreshByProject.remove(projectID) != nil {
    return .send(.projectRefreshRequested(projectID))
  }
  return .none

case .projectBatchLoaded(let projectID, .failure(let error)):
  state.inFlightFetchProjects.remove(projectID)
  state.lastErrorByProject[projectID] = error
  return .none
```

**Write-action completion:**

```swift
case .mergeCompleted(let worktreeID, _, .success):
  state.mutating.remove(worktreeID)
  guard let projectID = state.projectFor(worktreeID) else { return .none }
  let snapshot = state.projectionSnapshot(worktreeID: worktreeID)
  let delayed = Effect.run { send in
    try? await ContinuousClock().sleep(for: .seconds(2))
    await send(.projectRefreshRequested(projectID))
  }
  .cancellable(id: CancelID.delayedRefresh(projectID), cancelInFlight: true)
  if let snapshot {
    return .merge(
      .send(.delegate(.pullRequestMerged(worktreeID, snapshot: snapshot))),
      delayed
    )
  }
  return delayed
```

The 2-second delay is explicit: GitHub's API is not strongly consistent with its own UI after a merge, and issuing a fetch immediately after `gh pr merge` can return the pre-merge state. Two seconds is the empirical minimum we've measured; three seconds felt sluggish; the trade-off is acceptable at two.

### Client API Surface

New type on `GitHubClient`:

```swift
nonisolated struct GitHubClient: Sendable {
  // v2 primary
  var batchPullRequests: @Sendable (
    _ host: String,
    _ owner: String,
    _ repo: String,
    _ branches: [String]
  ) async throws -> [String: PullRequestSnapshot]

  // Availability — unchanged
  var availability: @Sendable () async -> GitHubAvailability

  // Write actions — unchanged shape, still cwd-scoped
  var merge: @Sendable (_ number: Int, _ strategy: MergeStrategy, _ worktreePath: URL) async throws -> Void
  var close: @Sendable (_ number: Int, _ worktreePath: URL) async throws -> Void
  var markReady: @Sendable (_ number: Int, _ worktreePath: URL) async throws -> Void
  var rerunFailedJobs: @Sendable (_ runID: Int64, _ worktreePath: URL) async throws -> Void

  // Optional single-branch refresh — retained for the delayed-refresh-after-write
  // path when the reducer specifically wants to re-check one PR without firing
  // a full-project fetch. Implementation uses the same GraphQL query with a single
  // alias — essentially batchPullRequests with branches.count == 1.
  var pullRequest: @Sendable (
    _ host: String, _ owner: String, _ repo: String, _ branch: String
  ) async throws -> PullRequestSnapshot?

  // Check / workflow-run fetches — REMOVED in v2. Data comes from the batched query.
}
```

Test doubles for `GitHubClient.testValue` become slightly richer (single extra stub), and a new `.recorded(...)` helper lets tests assert call counts for batched queries.

### `GitService.remoteInfo` — new helper

Host/owner/repo are parsed from `git remote get-url origin`. This is a pure-git operation; belongs on `GitService`, not `GitHubClient`.

```swift
extension GitService {
  public func remoteInfo(at path: URL) async throws -> RemoteInfo {
    let stdout = try await run(
      arguments: ["remote", "get-url", "origin"],
      cwd: path
    )
    return try RemoteInfo.parse(stdout)
  }
}

public struct RemoteInfo: Equatable, Sendable {
  public let host: String   // "github.com" or GHES domain
  public let owner: String
  public let repo: String

  public static func parse(_ urlString: String) throws -> RemoteInfo {
    // Accepts both SSH and HTTPS remotes:
    //   git@github.com:owner/repo.git
    //   https://github.com/owner/repo.git
    //   ssh://git@github.com/owner/repo.git
    // Rejects non-GitHub-style hosts unless they match a registered Enterprise
    // host (read from `gh auth status --json hosts`).
  }
}
```

Parsing failure throws `.remoteInfoUnavailable`. The reducer catches this and records a per-Project error instead of a per-Worktree error — the whole Project is stuck until the user fixes the remote.

### UI Layer

Zero visual change.

Reducer changes that the view layer needs to adapt to:

- `PullRequestBadge.loadedBody(snapshot:)` already reads `snapshot.additions / deletions` — unchanged.
- `WorktreeRowIcon` reads `rollup` (a `CheckRollup` enum value) — source changes from `store.checks[snapshot.number]` to `PullRequestBadge.CheckRollup.from(checks: snapshot.checkRollup)`. Mechanical substitution.
- `WorktreeGitHubBadge` reads `store.snapshots[worktreeID]` — unchanged externally; the reducer derives this dictionary from `state.snapshotsByProject[P]`.
- `PullRequestPopover` reads `snapshot.checkRollup` and the new `snapshot.mergeStateStatus` / `snapshot.reviewDecision` to explain merge-disabled reasons more precisely. Existing `mergeDisabledReason` helper extended.

The sidebar row's existing `.task(id: BadgeTaskIdentity)` that currently triggers `worktreeBecameVisible` is **removed** after migration (step 6 below). The reducer is now responsible for kicking off fetches via Project-level events.

### Write-side Flow Unchanged

Merge / close / markReady / rerunFailedJobs continue to:

1. Invoke `gh pr merge <number> --squash` (etc.) subprocesses via `GitHubClient`.
2. Cancel-in-flight on re-invocation via `CancelID.mutation(worktreeID)`.
3. On success, dispatch `.delegate(.pullRequestMerged(...))` and a delayed full-project refresh.

The only change: the post-mutation refresh goes to the whole Project, not just the one Worktree.

### Settings Surface

Unchanged from v1. The availability pane, merge strategy picker, and post-merge-action picker all continue to work. A new optional setting (may land in v2.1):

- **"Refresh on app focus"** — toggle, default off. If on, `NSApp.didBecomeActiveNotification` fires `projectRefreshRequested` for every open Project, rate-limited to 60 s per Project.

No migration; additive `decodeIfPresent` on `GeneralSettings`.

## Migration Plan

Six phases, each a separate PR or commit group. Each produces a green build + green tests + a usable app.

### Phase 1 — Add `RemoteInfo` + `GitService.remoteInfo(at:)`

- New DTO in `CodansCore/Git/RemoteInfo.swift`.
- Parser + `GitService.remoteInfo(at:)` method + `LiveGitService` wiring.
- Tests: 8 URL variants (ssh, https, ssh://, with/without .git, github.com + enterprise host).
- No behavior change — this is a new method; nothing calls it yet.

### Phase 2 — Extend `PullRequestSnapshot` + DTO types

- Add `checkRollup`, `mergeStateStatus`, `reviewDecision`, `headRepositoryOwner` fields. Codable compatibility: new fields default to nil / empty on decode from pre-v2 fixtures.
- `GhCommand.pullRequestView` remains for back-compat; updated to include the new fields (they're already available from the same `gh pr view --json`).
- Tests: golden-file fixtures updated to include new fields. New fixture for a PR with a populated `statusCheckRollup`.

### Phase 3 — Add `GitHubClient.batchPullRequests` + `LiveGitHubService` implementation

- `GhCommand.apiGraphQL(query:, hostname:, variables:) -> (argv, expectedExitCodes)`.
- `LiveGitHubService.batchPullRequests`:
  - Chunk branches (max 25 per chunk).
  - `withThrowingTaskGroup` with max-concurrent = 3.
  - GraphQL query builder (pure string function, tested in isolation).
  - Response decoder (dynamic keys + union-type normalization).
  - Fork-PR filter.
- Tests (≥ 10):
  - Single-chunk happy path (2 branches, both have PRs).
  - Multi-chunk path (60 branches → 3 chunks).
  - Fork-PR filter (branch with upstream + fork PR, keeps upstream).
  - Fork-PR filter (branch with only fork PR, keeps if `base != head`).
  - Empty branches array (no subprocess).
  - One chunk throws, others succeed (propagate error).
  - Malformed branch name (escaped / rejected).
  - `gh` unavailable at chunk time.
  - Response with `"data": null` + `"errors": [...]` (GraphQL error).
  - Oversize response (> 8 MB).

### Phase 4 — Reducer migration: project-level fetch path

- Add new actions (`projectActivated` / `projectRefreshRequested` / `projectBatchLoaded` / etc.).
- Wire `HierarchyManager` observation: dispatch `projectActivated` on Project switches.
- Refactor reducer to keep both paths temporarily: per-Worktree fetch still works for compatibility, but `projectBatchLoaded` now populates the same `state.snapshots` dictionary.
- Add in-flight + queued tracking.
- Tests: 8+ `TestStore` cases covering each new action and the re-entrancy model.

### Phase 5 — View migration: read checks from snapshot

- `WorktreeRowIcon`: source `rollup` from `snapshot.checkRollup` instead of `store.checks[snapshot.number]`.
- `WorktreeGitHubBadge`: unchanged.
- `PullRequestPopover`: accept check list from `snapshot.checkRollup`.
- `CheckRow` unchanged.
- `RootFeature`: remove the `.task` on each sidebar row that drove `worktreeBecameVisible`.
- Tests: existing view snapshot tests pass.

### Phase 6 — Delete v1 path

- Remove `GitHubClient.pullRequest(branch:worktreePath:)` (single-branch by-branch) — or keep it as a thin wrapper over `batchPullRequests` with one branch, for the surgical-refresh case after writes.
- Remove `GitHubClient.checks`.
- Remove `GitHubClient.latestWorkflowRun` (optional; kept if the "Rerun failed jobs" UI still needs the run ID — see Open Questions).
- Remove `state.checks[prNumber]` dictionary.
- Remove `snapshotFetchEffect` and `checksFetchEffect` single-branch helpers.
- Remove the `worktreeBecameVisible` action and its handler (now a no-op after migration).
- Tests: delete tests for removed methods; confirm all remaining tests pass.

### Phase 7 (optional, v2.1) — `WorktreeBranchWatcher`

- Filesystem watch on each active Worktree's `.git/HEAD`.
- Debounced (500 ms) — rapid `git checkout` iterations coalesce.
- Dispatches `worktreeBranchChanged` on change; reducer invalidates the Project and refetches.
- Not blocking for v2.0 ship; the existing `HierarchyManager` reconcile path on focus-gained will pick up branch changes eventually.

## Alternatives Considered

### A. Keep v1 per-Worktree model; add 3-way in-flight cap + `statusCheckRollup` consolidation

Minimal change: keep the per-Worktree `gh pr view` dispatch but (1) consolidate `gh pr view --json statusCheckRollup` so checks come free, cutting subprocess count from 2N to N; (2) add an in-flight cap at 3 to avoid burst.

- **Upside:** Zero architectural changes. Could ship in half a day.
- **Downside:** Still O(N) subprocess count. 20 Worktrees still takes 20 × 150 ms cold-start = 3 s just to fork everything. Doesn't address the `.task`-on-`EmptyView` fragility either — still relies on per-row view-lifecycle dispatch.
- **Why rejected:** The cost is in the fork count, not the total work. Consolidating pr view + pr checks is a fine incremental improvement but does not solve the scaling problem. Ship it only if v2 is blocked.

### B. Batch via `gh pr list --json ... --state all --limit 1000`

Instead of a custom GraphQL query, use the built-in `gh pr list`, which returns all PRs in a repo with a single subprocess. Filter client-side by branch name.

- **Upside:** No custom GraphQL; uses well-documented gh subcommand. Simpler response schema.
- **Downside:** `gh pr list --json` does not include `statusCheckRollup`. Adding it requires `--json statusCheckRollup` which IS supported, but gh's implementation does a separate GraphQL call per PR internally — effectively N round-trips, just hidden. Total wall-clock time is the same as N-branch worst case.
- **Why rejected:** The perceived simplicity ("just use gh pr list") is a leak. gh's internal implementation still makes N requests; we'd end up no faster than v1.

### C. Direct GraphQL via `URLSession`, OAuth in Keychain

Implement an in-app HTTP client + OAuth device-flow + Keychain storage. Same batched query, but without subprocess overhead.

- **Upside:** ~300 ms faster per fetch (no fork). Full control over retries, rate limits, proxy config.
- **Downside:** ~1500 lines of code we don't currently have: OAuth device flow, token storage, token refresh, rate-limit backoff, custom error taxonomy, Enterprise host switcher UI, token-revoke handling, "re-auth" surface. Security-sensitive; subject to audit. Duplicates functionality `gh` already does correctly.
- **Why rejected:** The `gh api graphql` call adds ~100–150 ms of subprocess cost per chunk. With 3 concurrent chunks, that overhead is ~200 ms total per Project-refresh. Paying a 1500-line engineering bill to shave ~200 ms is the wrong trade. Revisit if codans ever needs real-time PR updates, review threads, or cross-repo aggregation.

### D. Periodic background polling instead of event-driven invalidation

Poll every Project every N seconds on a background timer.

- **Upside:** Simple mental model. UI always fresh-ish.
- **Downside:** Consumes rate limit continuously even when the user is AFK. Battery drain. Adds a "background activity" concept that codans otherwise does not have.
- **Why rejected:** Event-driven is strictly better: same freshness guarantee when the user is interacting, zero cost when idle. The few rare "GitHub state changed without me doing anything" cases are handled by manual refresh (popover reload button) and merge-side delayed refresh.

**Update — a scoped, focus-gated, adaptive poll is adopted.** The "same freshness guarantee when the user is interacting" premise holds only for *local* state: a user typing in a terminal pane is not a GitHub-invalidating event, so check completions, reviews, and merges/closes that originate on GitHub's side have no freshness guarantee under pure event-driven invalidation. The added signal is a single poll that refreshes **only the active Project**, **only while the app is the frontmost application** (cancelled on resign-active), at an **adaptive cadence** (fast only while something is genuinely in flight). Each of D's three objections targets *background, all-Project, runs-while-AFK* polling and is sidestepped by this scoping: an AFK user's app is not frontmost, so it polls zero times — no continuous rate-limit burn, no battery drain, no always-on background-activity concept. The relevant guard against pathological burn is Open Question 5 (rate-limit-aware global backoff). See the "Active-Project liveness poll" row in Caching and Invalidation.

### E. Persist last snapshot to disk for instant-on-restart

Write `state.snapshotsByProject` to `~/.config/codans/github-cache.json` on change; read on launch to paint badges before the first fetch completes.

- **Upside:** Sidebar badges visible instantly after launch, even before `gh api graphql` runs.
- **Downside:** Stale data for up to one fetch cycle. Adds a "but the app showed X and now it shows Y" class of bug reports. Doubles the file-IO surface (another file to manage, migrate, recover).
- **Why rejected for v2.0:** The current approach — empty sidebar for ~500 ms on launch, then populated — is acceptable. Revisit if users report the blank initial state as confusing. Explicitly tracked in Open Questions.

## Cross-Cutting Concerns

### Security

All v1 guarantees preserved:

- No token material in codans; `gh` owns auth.
- Subprocess argv is `(executable, [args])` — no shell interpretation.
- GraphQL query is passed as a single `-f query=<body>` argument (gh handles the HTTP POST body). The query body itself contains user-derived branch names; these are GraphQL-string-escaped before interpolation. Branch names failing the escape are dropped with a log-line.
- No outbound network from the app — all HTTP through `gh`.

New attack-surface considerations:

- **GraphQL query size**: the query string can grow large (~20 KB for 25 branches). It's passed as a CLI argument, well under macOS's `ARG_MAX` (1 MB).
- **Response size cap**: bumped from 2 MB to 8 MB. GitHub's GraphQL responses for 25 branches × 5 PRs × full check rollup can hit ~4–6 MB in pathological cases (large repos with many CI jobs). 8 MB leaves headroom; oversize triggers `.other("gh stdout exceeded 8 MB")`.

### Observability

- `os.Logger` subsystem `com.gumpw.codans.github`, category `batch` (new).
- Every batched call logs: Project ID + chunk count + branch count + duration + exit code at `.debug`.
- GraphQL errors (response contains `"errors": [...]`) logged at `.error` with the first error's message.
- Fork-PR filter decisions logged at `.debug` with `privacy: .private(mask: .hash)` on branch names.
- Per-Project in-flight / queued state changes logged at `.debug`.

### Error handling

`GitHubError` gains:

- `.ghCLIOutdated(minVersion: String)` — `gh api` recognized but `--hostname` rejected or GraphQL flag shapes differ. Minimum supported `gh`: 2.20+.
- `.graphQLError(String)` — response came back with `errors` array. Message is the first error's `message`.
- `.remoteInfoUnavailable` — `git remote get-url origin` failed or returned an unparseable URL.
- `.oversizeResponse(bytes: Int)` — gh stdout exceeded the 8 MB cap.

The popover's error state renders each of these with a specific remediation. `.ghCLIOutdated` is the most user-action-required: the banner copy shows `brew upgrade gh`.

### Testing Strategy

Layered:

1. **Unit: GraphQL query builder.** Deterministic string output for given (branches, chunk size). Golden-file assertions.
2. **Unit: Response decoder.** Known JSON fixtures → decoded DTO. Covers dynamic keys, union type normalization, fork PR filtering.
3. **Unit: `LiveGitHubService.batchPullRequests`.** `RecordingCommandRunner` harness. Cases listed in Phase 3.
4. **TCA `TestStore`: `GitHubFeature`.** All new actions exercised. Re-entrancy model covered.
5. **Integration (behind env flag).** A real `gh api graphql` call against a test repo, gated on `TC_RUN_GITHUB_INTEGRATION_TESTS=1`. Not part of CI.

Total new test count estimate: ~40–50, on top of v1's 106.

### Migration / Rollback

Rollback is a feature flag + code path:

- A hidden `SettingsStore.general.githubFetchModel: "legacy" | "batched"` gate. Default: `"batched"`. Setting to `"legacy"` routes the reducer down the v1 path.
- Both paths coexist during Phase 4. After Phase 6 (v1 code deleted), rollback becomes a git revert, not a runtime toggle.
- During Phase 4–5, bug reports can be reproduced by flipping the gate without a rebuild.

## Risks

- **R1: GraphQL query complexity budget.** GitHub imposes per-query complexity scoring. 25 branches × 5 PRs × ~100 check-rollup nodes is empirically ~5000 points — well under the 10 000 per-query cap. But a repo with very dense CI (100+ jobs per PR) could exceed it. *Mitigation:* on detecting a `complexity` error in response, halve the chunk size and retry. Log the event.

- **R2: `gh api graphql` minimum version.** Requires `gh` 2.20+ for stable GraphQL + `--hostname` behavior. *Mitigation:* availability probe includes `gh --version` parse; show actionable banner for outdated installs. Pin a minimum version in the Settings "Requirements" copy.

- **R3: `WorktreeBranchWatcher` FS watch exhaustion.** macOS has a per-process FS watch limit (~2048). Projects with hundreds of Worktrees could exhaust it. *Mitigation:* watch only Worktrees currently in the visible sidebar viewport (bounded to ~50). Fall back to post-focus reconcile for the rest.

- **R4: In-flight + queued state leaks.** If a Project is removed from the catalog while a fetch is in flight, the `inFlightFetchProjects` set could retain the stale ID. *Mitigation:* on Project removal, cancel the fetch via `CancelID.projectFetch(P)` and remove from both sets. Reducer test: "Project removed mid-fetch".

- **R5: Oversize GraphQL response on edge-case repos.** Eight MB cap may still clip. *Mitigation:* on `.oversizeResponse`, halve chunk size and retry. Log as a signal to trim response fields in a future version.

- **R6: `headRepositoryOwner` missing from some PR shapes.** GraphQL sometimes returns null for deleted forks. *Mitigation:* fork filter treats null `headRepositoryOwner` as "fork, keep only if base ≠ head". Fixture includes null-owner case.

- **R7: Event-driven invalidation misses an event.** If a Worktree's branch changes but `WorktreeBranchWatcher` isn't watching (Phase 7 deferred) and the user doesn't trigger focus-gained, the snapshot is stale indefinitely. *Mitigation:* `HierarchyManager.reconcileDiscoveredWorktrees` (which runs on focus-gained via the existing reconciler) updates each Worktree's `branch` field. The reducer observes these updates and invalidates the Project. This covers the branch-change case without filesystem watches — at the cost of latency between change and first refresh.

## Open Questions

1. **Should v2 ship with or without `WorktreeBranchWatcher`?** Without, branch changes get picked up on focus-gained (via `HierarchyManager` reconcile) — a few-second delay. With, changes are instant but add FS-watch complexity. *Leaning:* ship v2.0 without; add in v2.1 based on whether the delay is user-visible.

2. **Should we persist last-good snapshots to disk?** v2.0 does not; sidebar is empty for ~500 ms on launch. Tradeoff noted in Alternative E. *Leaning:* defer until user feedback demands it.

3. **Chunk size 25 vs. 50.** The 25 limit comes from empirical testing of small repos. Larger repos may tolerate 50. *Leaning:* keep 25 for v2.0, measure in production, tune.

4. **Does `rerunFailedJobs` still need `latestWorkflowRun`?** The batched query returns `statusCheckRollup.contexts` with `detailsUrl`, which for CheckRun items is the Actions run URL. We may be able to derive the run ID from that URL and drop `latestWorkflowRun` entirely. *Leaning:* verify empirically in Phase 3; drop if the URL parsing is reliable.

5. **Rate-limit-aware dispatch.** If we see a sequence of failures with rate-limit markers, should we back off across all Projects or just the one that tripped? *Leaning:* global backoff — if user's token is rate-limited, pausing all Projects for 60 s is more honest than letting other Projects continue to 429.

6. **Does `statusCheckRollup` include required-status-checks?** GitHub considers certain required checks critical for merge. The `.blocked` merge state status covers it, but the popover might want to highlight the specific required check. *Leaning:* v2.0 shows `.blocked` as an opaque state; v2.1 parses required-checks from a supplementary GraphQL field if user feedback warrants it.

## References

- [github-integration.md (v1, superseded)](github-integration.md) — the v1 per-Worktree design that ships today in PR #39.
- [mw-t1-sidebar.md](mw-t1-sidebar.md) — sidebar row composition referenced by the UI layer section.
- [docs/architecture.md](../architecture.md) — module boundaries and dependency rules.
- [GitHub GraphQL API reference](https://docs.github.com/en/graphql) — specifically the `PullRequest`, `StatusCheckRollup`, `CheckRun`, `StatusContext` types.
- [`gh api graphql`](https://cli.github.com/manual/gh_api) — gh manual section for GraphQL delegation.
- [GraphQL Alias syntax](https://graphql.org/learn/queries/#aliases) — the primary batching technique used here.
