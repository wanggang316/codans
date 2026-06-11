# Design Doc: GitHub Integration (PR-centric, gh-delegated) — v1, SUPERSEDED

**Status:** Superseded by [github-integration-batched.md](github-integration-batched.md) (v2)
**Author:** Gump (with Claude)
**Date:** 2026-04-23

> **Supersede notice.** This document describes the per-Worktree fetch model that
> shipped in PR #39 and is currently in production. It is retained for historical
> context — the execution model, client shape, and test scaffolding it describes
> are still live until the v2 migration (see Phases 1–6 in the successor doc)
> completes. The v1 surface (sidebar badge, popover, command-palette entries,
> Settings) is preserved verbatim under v2; only the fetch path changes.
>
> For the current design, read **[github-integration-batched.md](github-integration-batched.md)**.

## Context and Scope

codans already publishes a stable Worktree-selection stream and a per-Worktree read-only git viewer (C7). What it still cannot answer, without leaving the app, is the question the user asks *after* "what changed here?" — namely "does the PR for this worktree still pass CI, and can I merge it?"

This design adds a narrow, PR-centric GitHub surface that attaches to the existing Worktree model. It does **not** replace the terminal — every action stays one keystroke away from the underlying `gh` invocation — and it does **not** grow into a GitHub client. The intent is a glanceable badge + a focused popover + a few command-palette actions, nothing more.

Repository state at design time:

- No GitHub code exists yet. Branch `feature/github01` is greenfield.
- `codans/Git/` holds the C7 read-only `git` data layer plus `FoundationCommandRunner` — the subprocess runner with timeout / SIGTERM→SIGKILL ladder / pipe backpressure that this design will re-use verbatim for `gh`.
- `Worktree` has a nullable `branch: String?` (see `CodansCore/Worktree.swift`); Project has a `gitRoot`. There is no `owner/repo` field on any domain type — `gh`'s cwd-based resolution makes that unnecessary.
- `RepositorySettings` is declared but explicitly reserved-empty (see `CodansCore/Settings/RepositorySettings.swift`); the file comment invites additive fields without a schema version bump. Natural home for per-Project GitHub preferences.
- The broad shape of the integration — subprocess-wrapped `gh`, per-Worktree PR snapshots, inline badge + popover + palette actions, optional archive-on-merge — is a shape that has been validated on a comparable macOS tool the author maintains; that prior validation informs the scope cuts taken below but no code is copied verbatim, because codans's sidebar, command palette, and settings conventions differ.

This document is the source of truth for *how* v1 GitHub integration is structured and *why* it delegates to `gh` rather than talking to the API directly. It does not specify the v2 IPC surface, agent-facing `github.*` methods, or any diff rendering.

## Goals and Non-Goals

**Goals**

- Show, for every Worktree whose branch matches an open/merged/closed PR on the default `gh` host, a compact **status badge** (state + aggregate check result) inline in the sidebar row.
- Expose a **PR details popover** from that badge: number, title, author, draft/ready/merged, commit count, additions/deletions, per-check status list with "open failing check" / "rerun failed jobs" actions, "open on GitHub" link.
- Expose **command-palette actions** for the active Worktree's PR: merge (with strategy), close, mark-ready, rerun failed jobs, open on GitHub.
- Offer a **Settings pane** that: (a) detects `gh` installation + auth status and surfaces clear remediation copy when missing, (b) lets the user pick default merge strategy and post-merge Worktree action (none / archive / delete), (c) toggles the whole feature off per-Project.
- Reuse `FoundationCommandRunner`. No new subprocess infrastructure, no new timeout/signal code.
- Reuse the hybrid TCA + `@Observable` + `*Client` shape that C7 established. Anything a feature reducer calls goes through a typed TCA `DependencyKey` client.
- Stay inside `codans/GitHub/` (in-app module) with pure-function parsers and Decodable DTOs that *could* later move to `CodansCore` if a CLI/iOS consumer needs them. Do not pre-move them.

**Non-Goals**

- **No direct GitHub REST/GraphQL HTTP.** No `URLSession` calls to `api.github.com`. No Octokit-style SDK. No Keychain. No OAuth device flow. If `gh` can't do it, v1 doesn't do it.
- **No issues, reviews, discussions, notifications inbox, codespaces, actions dashboard, releases, projects, gists.** PR-only.
- **No in-app diff rendering for PRs.** "View diff" is `gh pr view --web`. C7's diff viewer is working-tree/log/staged — unrelated.
- **No webhooks, no server push, no background polling thread.** All refresh is user-initiated (open popover, invoke command) or event-triggered (worktree selection change, merge/close action completion + short debounce).
- **No IPC surface (`github.*` methods)** in v1. `codans` already has shell access to `gh` inside any Pane, which is the strictly-better scripted interface. Reserve the namespace (see [Seams](#seams-for-future-work)).
- **No GitHub Enterprise multi-host UI.** Read the default host from `gh auth status`; if the user has multiple hosts configured, we use the default and document the limitation.
- **No merge-conflict resolution, no branch rebase, no force-push, no PR creation.** Creation is explicitly deferred to a sibling design (the existing terminal + `gh pr create` is sufficient for v1).
- **No persistence of PR state to disk.** Memory-only, reset on app launch. Tokens live in `gh`'s config. We store zero secret material.
- **No custom rate-limit handling.** `gh` handles its own; we surface its errors.

## Design

### Overview

The integration is a single in-app folder, `codans/GitHub/`, that mirrors C7's three-layer shape:

1. **Data layer** (`codans/GitHub/`) — pure Swift: `GitHubService` protocol + `LiveGitHubService` implementation. Live impl runs `gh` via the existing `CommandRunner`, parses stdout JSON into Decodable DTOs, translates mechanical `CommandOutcome` values into a domain `GitHubError` enum. No state, no caching, no mutation.

2. **Client boundary** (`codans/App/Clients/GitHubClient.swift`) — TCA `DependencyKey` wrapper mirroring `GitServiceClient` shape. Each protocol method becomes a `@Sendable` async closure; tests inject `.testValue` with `unimplemented(…)` placeholders.

3. **Feature layer** (`codans/App/Features/GitHub/`) — a TCA feature, `GitHubFeature`, that owns: per-Project PR snapshot map (`[WorktreeID: PullRequestSnapshot]`), availability cache (30 s TTL on `gh auth status`), debounced refresh after user actions, and delegate actions consumed by sidebar / command palette / settings.

Three load-bearing decisions, covered in [Alternatives Considered](#alternatives-considered):

1. **Wrap `gh` CLI; don't call the API directly.** Zero auth/Keychain code, zero OAuth flow, zero HTTP stack, zero new SPM dependency, and the user's existing `gh` login is reused. Cost: a hard dependency on a CLI tool the user must install. In this user's environment (`gh` is already present, per the project's GitHub-PR workflow), that cost is effectively zero.

2. **On-demand per-Worktree fetch; GraphQL batch only as a named Phase 2.** v1 lazily fetches a PR snapshot when a Worktree becomes visible in the sidebar viewport or gains selection. This avoids the complexity of a batched GraphQL query (aliased-per-branch, dynamic-keyed decoding, chunked concurrency) until there is measured latency to justify it. See [Risks](#risks) for the sidebar-population burst concern.

3. **Memory-only state, no disk, no IPC in v1.** PR snapshots are rebuilt on app launch. `codans`'s scripted surface for GitHub is plain `gh` inside any Pane (already better than anything we would expose), which lets us keep the IPC wire surface frozen and defer the `github.*` method design until real workflows appear.

Why this is enough. The PR-status question is read-mostly, low-volume (the user checks a handful of Worktrees per session), user-initiated (no background polling), and the authoritative data lives on GitHub's servers. A reducer + a subprocess + a 30-second availability cache covers the hot path. We are not building a PR database.

### System Context Diagram

```
      ┌────────────────────────────────────────────────────────────────┐
      │  codans app window                                         │
      │                                                                │
      │  ┌──────────────────┐    ┌─────────────────────────────────┐   │
      │  │  Sidebar         │    │  GitHubFeature (TCA reducer)    │   │
      │  │  Worktree rows   │───▶│   state: per-Worktree snapshots │   │
      │  │   + PR badge     │    │   effects: debounced refresh    │   │
      │  └──────────────────┘    └──────────────┬──────────────────┘   │
      │         ▲   │                           │ GitHubClient (DI)    │
      │    badge│   │tap → popover              ▼                      │
      │    actions  │                ┌───────────────────────────┐     │
      │             ▼                │  codans/GitHub/       │     │
      │  ┌──────────────────┐        │   ├ GitHubService (proto) │     │
      │  │ PRPopoverView    │        │   ├ LiveGitHubService     │ ────┼──┐
      │  │ CommandPalette   │───────▶│   ├ JSONOutputParsers     │     │  │
      │  │ SettingsView     │        │   └ GitHubError           │     │  │
      │  └──────────────────┘        └───────────────────────────┘     │  │
      │                                                                │  │
      │              HierarchyManager.selectedWorktree                 │  │
      │              (read-only subscription)                          │  │
      └────────────────────────────────────────────────────────────────┘  │
                                                                          │
                                                                          ▼
                                                           ┌──────────────────────────┐
                                                           │ /usr/local/bin/gh        │
                                                           │  (one child per request, │
                                                           │   cwd = worktree.path,   │
                                                           │   timeout 20 s, output   │
                                                           │   cap 2 MB via           │
                                                           │   FoundationCommandRunner)│
                                                           └──────────┬───────────────┘
                                                                      │
                                                                      ▼
                                                             api.github.com (HTTPS)
```

External boundaries touched:

- **`gh` CLI** — only external dependency. Resolved once per app session via `which gh` and cached in a `GhExecutableResolver` actor that deduplicates concurrent lookups. All invocations are fixed argument lists; user-supplied values (branch names, SHAs, merge strategy) are passed as arguments, never interpolated into a shell. No shell interpretation anywhere.
- **File system** — read-only, via `gh`. The Worktree's `path` is passed as `cwd` so `gh` resolves the repo + remote naturally.
- **`HierarchyManager`** — read-only: reactions to `selectedWorktree` changes trigger "refresh this one Worktree's PR snapshot" effects. No writes.
- **`SettingsStore`** — read/write for the Settings pane (merge strategy, post-merge action, per-Project feature toggle).
- **`WorktreeService`** (hierarchy mutator) — invoked on `postMergeAction == .archive` or `.delete` after a successful merge. Existing method; no new plumbing.

### API Design

Three surfaces, each the smallest that supports the Goals.

#### `GitHubService` protocol (data layer)

Sketch — mirrors `GitService` shape, all methods `async throws`:

```swift
protocol GitHubService: Sendable {
  /// Returns .available with the logged-in host on success, .unavailable with a
  /// user-facing reason otherwise. Should be the first method a reducer calls.
  func availability() async -> GitHubAvailability

  /// Fetches the PR associated with `branch` in the repo rooted at `worktreePath`.
  /// Returns nil when `gh pr view` reports "no pull request found". Throws only
  /// on mechanical failure (gh missing, timeout, decode error).
  func pullRequest(branch: String, worktreePath: URL) async throws -> PullRequestSnapshot?

  /// Latest check + status-context results for a PR. Separate from pullRequest()
  /// because checks refresh faster than metadata and live behind a different gh
  /// subcommand (`gh pr checks --json`).
  func checks(number: Int, worktreePath: URL) async throws -> [CheckResult]

  /// Latest workflow run for the PR's head branch. Used to seed "rerun failed jobs".
  func latestWorkflowRun(branch: String, worktreePath: URL) async throws -> WorkflowRun?

  /// User actions. All return after gh exits; callers debounce a refresh on success.
  func merge(number: Int, strategy: MergeStrategy, worktreePath: URL) async throws
  func close(number: Int, worktreePath: URL) async throws
  func markReady(number: Int, worktreePath: URL) async throws
  func rerunFailedJobs(runID: Int64, worktreePath: URL) async throws
}
```

Rationale for separating `pullRequest` from `checks`: the popover refreshes checks every time it opens, but metadata (title/author/diff counts) rarely changes after a PR is created. Two calls let us skip the expensive GraphQL roundtrip when only checks are stale.

#### `GitHubClient` (TCA dependency)

One closure per `GitHubService` method, same Sendable/async-throws shape as `GitServiceClient`. `DependencyKey` exposes `.liveValue` (wrapping `Git.makeGitHubService()`) and `.testValue` (all `unimplemented(…)`).

#### `GitHubFeature` reducer (sketch)

```swift
struct State: Equatable {
  var availability: GitHubAvailability = .unknown
  var snapshots: [WorktreeID: PullRequestSnapshot] = [:]   // PR view
  var checks: [Int: [CheckResult]] = [:]                   // keyed by PR number
  var loading: Set<WorktreeID> = []
  var popoverTarget: WorktreeID? = nil
  var error: GitHubError? = nil
}

enum Action {
  case onAppear                                   // probes availability
  case worktreeBecameVisible(WorktreeID)          // lazy fetch
  case refreshRequested(WorktreeID)               // user-initiated refresh
  case snapshotLoaded(WorktreeID, Result<PullRequestSnapshot?, GitHubError>)
  case checksLoaded(Int, Result<[CheckResult], GitHubError>)

  case presentPopover(WorktreeID)
  case dismissPopover

  case mergeRequested(WorktreeID, MergeStrategy)
  case mergeCompleted(WorktreeID, Result<Void, GitHubError>)
  case rerunFailedJobsRequested(WorktreeID)
  // close, markReady parallel to merge

  case availabilityProbed(GitHubAvailability)
  case delegate(Delegate)                         // for RootFeature (archive-on-merge)
}
```

Delegate actions let `RootFeature` react to "merge completed" with the user-configured post-merge Worktree action (archive / delete / none) without `GitHubFeature` itself reaching into hierarchy state — same pattern C8 uses for editor opens.

### UI Design

Four surfaces, in decreasing order of glanceability: sidebar badge → detail popover → command-palette actions → Settings section. Nothing else. The design deliberately has no dedicated pane, no full-screen view, no toolbar item — the feature should feel like a read-out the app already had, not a new mode.

**Visual principles.**

1. **Silent when absent.** If a Worktree has no PR, nothing renders. The feature must never add visual weight to Worktrees it does not apply to.
2. **State legibility before prettiness.** A glance should resolve three questions: does this Worktree have a PR (yes/no), is it open (open/draft/merged/closed), is CI green (pass/fail/pending/none). All three are conveyed by **glyph + color + number**, never color alone — dark-mode contrast and color-blindness make color-only encodings fragile.
3. **Match existing chrome.** SF Symbols, system font, system accent, macOS popover. No custom animations beyond the default popover transition. Badge typography matches the sidebar row labels (same weight, one step smaller).
4. **Keyboard-first.** Every badge action is reachable from the command palette with its Worktree as context; the badge itself is focusable and responds to Space/Enter. Mouse is redundant with keyboard, never required.

#### Surface 1: Sidebar Worktree-row PR Badge

Placement: inline on the right edge of each `HierarchySidebarWorktreeRow`, after any existing trailing indicator (unread-notification dot, archive indicator), before the row's chevron/disclosure. One new trailing slot; nothing reflows.

Visual: capsule pill, 20 pt tall, min-width 48 pt, auto-grows to fit number. Three parts left-to-right:

```
  ┌───────────────────────────────┐
  │  <state-glyph>  #<num>  <ci>  │
  └───────────────────────────────┘
      ^^^^^^^^^^^   ^^^^^^  ^^^^
      PR state      number  check aggregate
```

**State matrix** (the trade-off here is keeping the palette small enough to learn in one glance):

| PR state    | Glyph (SF Symbol)                  | Fill color token                  | Text color            |
|-------------|-------------------------------------|-----------------------------------|-----------------------|
| open        | `arrow.triangle.pull`               | `prState.open` (green, muted)     | on-fill primary       |
| draft       | `arrow.triangle.pull`  (outlined)   | `prState.draft` (gray, neutral)   | on-fill primary       |
| merged      | `checkmark.circle.fill`             | `prState.merged` (purple, muted)  | on-fill primary       |
| closed      | `xmark.circle.fill`                 | `prState.closed` (gray, dim)      | on-fill secondary     |

**CI aggregate glyph** (right-edge, composited onto the capsule):

| CI rollup     | Glyph                               | Tint                    |
|---------------|-------------------------------------|-------------------------|
| all passing   | `checkmark.circle.fill`             | `.green`                |
| any failing   | `exclamationmark.triangle.fill`     | `.red`                  |
| any pending   | `circle.dotted` (animated bob)      | `.yellow`               |
| no checks     | (omitted)                           | —                       |

**Ephemeral states:**

- **Loading** (first fetch in progress): capsule renders in a skeleton style — outline stroke, no fill, glyph replaced by a small `ProgressView().controlSize(.mini)`. 200 ms delay before it appears so fast responses never flicker in.
- **Error** (fetch failed, not "no PR"): `exclamationmark.circle` in `.tertiaryLabel` with tooltip carrying the `GitHubError.message`. Click opens popover with remediation. Never a red alarm state — the app is not broken; GitHub is temporarily unreachable.

**Interactions:**

- **Left click** → presents popover anchored to the badge.
- **⌘ click** → opens PR on GitHub in the default browser (`gh pr view --web`). Saves a popover round-trip for the common "just show me" case.
- **Right click** → context menu with the command-palette actions inlined (Merge / Close / Rerun failed / Mark ready / Copy URL / Open on GitHub).
- **Hover** → tooltip with PR title (truncated to 80 chars) + `#<num>` + state + author. 400 ms delay.
- **Keyboard focus** → same as left click on Space/Enter.

**Why a capsule and not just a glyph.** A glyph-only indicator is fastest to scan but hides the PR number, which the user needs to disambiguate ("wait, which PR does this worktree have open?") when multiple Worktrees sit on similar branches. The capsule is ~30% wider than the pure-glyph alternative, which is the cost.

**Why inline and not a leading column.** A dedicated PR column on every row would pay visual cost even on rows without PRs (the silent-when-absent principle). Trailing-slot inline pays cost only when a PR exists.

#### Surface 2: PR Popover

Anchored to the badge via `.popover(isPresented:)`. Width 360 pt, auto-height, min-height 160 pt (so the empty "no PR" layout doesn't collapse). Macchrome popover arrow points at the badge.

```
┌───────────────────────────────────────────────────────────┐
│  #1234  Fix flaky terminal resize test                    │  ← title, 1–2 lines, truncates
│  <state-pill> opened by gump · +128 −14 · 3 commits       │  ← meta row, secondary text
├───────────────────────────────────────────────────────────┤
│  Checks                                 12 passed · 1 failed │  ← section header w/ summary
│  ● build (macOS)             1m 42s  ✓                    │  ← row: name · duration · glyph
│  ● unit-tests (macOS)        3m 11s  ✓                    │     row click → open on GitHub
│  ● ui-snapshots (macOS)      2m 04s  ✗  [ View log ]      │     failing rows get a button
│  … 10 more  [ Show all ]                                  │     collapse past 5 by default
├───────────────────────────────────────────────────────────┤
│  [▸ Merge  (squash)] [ Close ] [ Rerun failed ] [ ↗ ]     │  ← actions row
└───────────────────────────────────────────────────────────┘
```

**Section-level states.** Each section has a clear state contract:

- **Header** — always present once snapshot loads; shows PR title + meta.
- **Checks** — omitted entirely when no checks exist (a PR with no CI is common for docs branches; don't show an empty section).
- **Actions** — always present; buttons disable with a tooltip when not applicable (e.g., `Merge` disabled when PR is draft / mergeable != true / not approved — with the specific reason in the tooltip).
- **Footer link** — `↗` icon button, always present: opens the PR on GitHub (`gh pr view --web`).

**Loading / error / empty states:**

- **Loading** (first open, snapshot not cached): skeleton header + skeleton checks list. Three gray rounded rectangles. No spinner — content animates in once loaded.
- **Error**: full-bleed `ContentUnavailableView` with `exclamationmark.triangle`, `GitHubError.message` as subtitle, and one `[ Retry ]` button. Specific shape for `.notInstalled` / `.notAuthenticated` — remediation button label becomes `Install gh` / `Run gh auth login` and opens the relevant copy-command sheet.
- **No PR** (badge never rendered, but popover can be force-opened via command palette when the match heuristic is off): header reads "No pull request for branch `<name>`" with a `[ Create on GitHub ]` link (→ `gh pr create --web`).

**Merge action — the one picker in this design.** The merge button is a **split button**, matching the pattern already established by `HeaderOpenSplitButton`:

- **Primary half**: label `Merge (squash)` or the user's configured default strategy; click-merges immediately. No confirmation dialog — the consequence is reversible for 7 days via `gh pr checkout` + revert, and adding a confirmation for every merge trained the user to dismiss it.
- **Caret half**: picker for `Create merge commit | Squash and merge | Rebase and merge | — | Set as default for this Project`. Selecting a non-default strategy does a one-shot merge without changing the default; the last item persists to `RepositorySettings.defaultMergeStrategy`.

**Rerun failed — scoping.** The `Rerun failed` button is enabled iff the latest workflow run has at least one failed job. It runs `gh run rerun <run-id> --failed`, which re-executes all failed jobs in one call. Per-job selection is explicitly deferred (see Open Questions).

**Checks-list compactness trade-off.** Showing all 20+ checks by default makes the popover tall and fast-scrolling past items the user rarely cares about. Collapsing past 5 hides the passing middle when all that matters is the one red row. The compromise: **sort by status** — failing → pending → passing — then collapse past 5 with a `[ Show all ]` disclosure. The failing one is always above the fold.

#### Surface 3: Command Palette entries

New entries register into the existing `CommandPaletteFeature`. Each entry's availability depends on the currently selected Worktree's cached PR snapshot:

| Label                            | Available when                    | Effect                                               |
|----------------------------------|-----------------------------------|------------------------------------------------------|
| GitHub: Open PR on web            | PR exists                         | `gh pr view --web`                                   |
| GitHub: Merge PR                  | PR open && mergeable              | split-button merge flow (opens inline strategy picker if no default set) |
| GitHub: Close PR                  | PR open                           | confirmation sheet → `gh pr close`                   |
| GitHub: Mark PR ready for review  | PR is draft                       | `gh pr ready`                                        |
| GitHub: Rerun failed jobs         | latest run has failures           | `gh run rerun <id> --failed`                         |
| GitHub: Copy PR URL               | PR exists                         | to clipboard                                         |
| GitHub: Refresh PR                | PR exists                         | force-refresh snapshot + checks                      |
| GitHub: Open Settings             | always                            | opens Settings window at the GitHub section          |

Unavailable entries render disabled with the specific reason in the palette subtitle ("No open PR for this Worktree", "PR already merged") — same pattern the editor palette uses for uninstalled editors.

Default shortcuts are **not assigned in v1**; the palette is the discovery surface. A future iteration can promote frequently-used actions to shortcuts.

#### Surface 4: Settings — GitHub section

Registers as a new sidebar entry in the existing Settings window, alphabetically between `General` and `Notifications`.

```
┌────────────────────────────────────────────────────────────┐
│  GitHub                                                    │
├────────────────────────────────────────────────────────────┤
│                                                            │
│  Availability                                              │
│  ● Connected to github.com as @gump                        │  ← or: unavailable banner
│  [ Re-check ]  [ Open gh docs ]                            │
│                                                            │
│  Defaults                                                  │
│  Default merge strategy     [ Squash and merge ▾ ]         │
│  After merging a PR          ( ) Do nothing                │
│                              (●) Archive the worktree      │
│                              ( ) Delete the worktree       │
│                              ( ) Ask each time             │
│                                                            │
│  Per-Project overrides                                     │
│  Select a Project above to override these defaults.        │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  codans                                           │  │
│  │  Merge strategy: ○ Use default (Squash)               │  │
│  │                  ● Custom  [ Rebase and merge ▾ ]     │  │
│  │  After merge:    ● Use default (Archive)              │  │
│  │                  ○ Custom  [ Delete ▾ ]               │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                            │
│  Disable for this Project  [ ● ]                           │
└────────────────────────────────────────────────────────────┘
```

**Availability banner** — the most important piece of this pane, because it is what the user sees when the feature silently fails:

- `.available(host, user)` → green dot + `Connected to <host> as @<user>`.
- `.notInstalled` → amber banner: *"GitHub CLI is not installed. Run `brew install gh` to enable pull-request features."* with a `[ Copy command ]` button and a dismissible help link.
- `.notAuthenticated(host)` → amber banner: *"Run `gh auth login` in a terminal to sign in."* with `[ Copy command ]`.
- `.unavailable(other reason)` → red banner with `GitHubError.message` verbatim.

Clicking `[ Re-check ]` re-runs the probe immediately (bypassing the 30-second cache).

#### First-run / onboarding surface

No dedicated onboarding modal. On first app launch post-integration:

- If `gh` is available → badges appear silently as Worktrees are selected. No banner, no toast.
- If `gh` is missing → a one-time in-app banner renders at the top of the sidebar's Project list: *"Install GitHub CLI to see pull-request status"* with a `[ Learn how ]` button (opens Settings › GitHub) and a `[ × ]` dismiss. Dismissal is persistent (`settings.json`). Never re-shown unless the user explicitly hits `Re-check` in Settings.

This avoids the well-known anti-pattern of interrupting first-launch flow with a modal the user must dismiss before doing what they came to do.

#### Keyboard model

- **Badge** is focusable in the sidebar tab order, after the Worktree row title. Space/Enter opens the popover.
- **Popover**: Tab cycles `Actions → Check-list rows → Actions`. ↑/↓ moves within the check-list. Esc closes. The Merge button accepts `↩` when focused; the caret is `⌥↩`.
- **Command palette**: all PR actions appear under the normal palette fuzzy-search (`⌘K` global). No new global shortcuts in v1.
- **Merge strategy picker**: ↑/↓ moves through strategies, ↩ commits, Esc cancels without merging.

#### Accessibility

- **VoiceOver labels** are state-specific: `"Pull request 1234, open, CI passing, 12 passed, 1 failed. Activate to see details."` The number, state, and aggregate CI result are all spoken — no information is glyph-only.
- **Color is never the sole indicator.** Every state has a distinct SF Symbol; a fully monochrome rendering remains legible.
- **Dynamic Type** up to `.xxxLarge` supported. The badge grows in height; the check-row truncates the workflow name before the duration/status glyph, never the other way.
- **Tap targets** meet 44 pt guidance for popover buttons. The badge itself is 20 pt tall but carries a 10 pt extra hit area (standard SwiftUI `.contentShape(.rect)` expansion).
- **Reduce Motion**: the `circle.dotted` pending animation is disabled; a static glyph is used.
- **High contrast**: state fill colors have high-contrast variants defined in the asset catalog under the same role tokens (`prState.open.highContrast` etc.).

#### Theming

- Light/Dark/Increased-contrast all supported through asset-catalog `ColorRole`s — new tokens: `prState.open`, `prState.draft`, `prState.merged`, `prState.closed`, `prCheck.passing`, `prCheck.failing`, `prCheck.pending`.
- State-color hues follow GitHub's conventional palette (green / gray / purple / red) but saturation is dropped ~20% vs. GitHub.com to cohabit with the existing muted-chrome of codans's sidebar.
- Accent-color override (user's macOS global accent) only affects focus rings and the Merge primary button — state colors are semantic and do not follow the accent.

### Data Storage

Two disk-touching decisions, both additive:

1. **`RepositorySettings` gains two optional fields:**
   - `defaultMergeStrategy: MergeStrategy?` — `.merge | .squash | .rebase`, nil falls through to global default. When set, merge actions use it without a picker prompt.
   - `postMergeAction: MergedWorktreeAction?` — `.none | .archive | .delete`, nil means "ask each time".

   `RepositorySettings.isEffectivelyEmpty` must be updated to return false when either is set; otherwise the settings GC pass will drop the entry on save. This remains additive on the `settings.json` v2 schema (decoder uses `decodeIfPresent`), no version bump.

2. **Global settings** (`SettingsStore.general` or equivalent) gain `defaultMergeStrategy` used as the initial picker value and the fallback when `RepositorySettings.defaultMergeStrategy` is nil.

Nothing else is persisted. No PR snapshots, no tokens, no caches, no ETag tables.

### Component Boundaries

```
codans/GitHub/                        (in-app module, new)
  ├ GitHubService.swift                   protocol
  ├ LiveGitHubService.swift               wraps CommandRunner + JSON decoders
  ├ GhExecutableResolver.swift            actor-serialized `which gh` with in-flight dedup
  ├ PullRequestSnapshot.swift             Decodable DTO for `gh pr view --json`
  ├ CheckResult.swift                     Decodable DTO for `gh pr checks --json`
  ├ WorkflowRun.swift                     Decodable DTO for `gh run list --json`
  ├ GitHubAvailability.swift              enum: .unknown | .available(host) | .unavailable(reason)
  └ GitHubError.swift                     throwable, includes user-facing message

codans/App/Clients/
  └ GitHubClient.swift                    TCA DependencyKey (mirrors GitServiceClient)

codans/App/Features/GitHub/
  ├ GitHubFeature.swift                   TCA reducer
  ├ Views/
  │   ├ PullRequestBadge.swift            sidebar-row capsule (Surface 1)
  │   ├ PullRequestPopover.swift          popover shell + Header / Checks / Actions (Surface 2)
  │   ├ CheckRow.swift                    one row in the checks list
  │   ├ MergeSplitButton.swift            primary merge + strategy caret
  │   └ GitHubStatusBanner.swift          shared availability banner
  ├ GitHubCommandPaletteBindings.swift    wires Surface 3 into existing CommandPaletteFeature
  ├ GitHubSettingsSection.swift           Surface 4 under the existing Settings window
  └ Theme/
      └ PullRequestStateColors.swift      ColorRole tokens (prState.*, prCheck.*)

CodansCore/
  ├ Settings/RepositorySettings.swift     add defaultMergeStrategy, postMergeAction
  └ Settings/MergeStrategy.swift          enum (moved here, not app-local, because
                                          codans could script merges in v2)
  └ Settings/MergedWorktreeAction.swift   enum
```

**Dependency rules:**

- `codans/GitHub/` may import only `CodansCore` + Foundation. No TCA, no SwiftUI.
- `App/Clients/GitHubClient.swift` imports TCA + `codans/GitHub/` types + `CodansCore`. No UI.
- `App/Features/GitHub/` imports TCA + SwiftUI + the client. Never `codans/GitHub/` directly.
- `codans/Git/` and `codans/GitHub/` must stay siblings — GitHub must not depend on Git; they happen to share `CommandRunner` which lives in `Git/` today. **Before implementation starts, move `CommandRunner.swift` out of `Git/` into a new `codans/Process/` (or similar)** so neither module leaks into the other. Alternative: leave `CommandRunner` where it is and import `Git` from `GitHub` — rejected because it implies a conceptual dependency that does not exist.

**Why no separate Tuist target:** same rationale as every other in-app module (Runtime, Hooks, Git, App/Features/*). Folder-level boundary enforced by review; promote only if a test bundle or second consumer arrives.

### Seams for Future Work

Reserved without wiring:

- **`github.*` IPC namespace.** `IPC.Method` gets no new cases in v1. When v2 lands — e.g., agent-invoked `github.pr.describe` for scripted PR checks — handlers plug into `MethodRouter.routeGitHub(...)` alongside the existing editor / hierarchy / terminal routers.
- **Batched GraphQL.** `LiveGitHubService.pullRequest(...)` currently shells out once per Worktree. A `batchPullRequests([branch], worktreePath)` method can be added via `gh api graphql` with an aliased-per-branch query (25 branches per request, capped concurrency) if sidebar population becomes slow — see Risks below for the trigger.
- **Move of DTOs into `CodansCore`.** If/when `codans` exposes `github.*`, `PullRequestSnapshot` and friends move from `codans/GitHub/` to `CodansCore` so `codans` can decode without depending on the app target. No circular dep risk; they are already pure value types.

## Alternatives Considered

### 1. Direct REST/GraphQL via URLSession + Octokit-style SDK

Add an HTTP client, model the API surface in Swift, handle OAuth device flow, store tokens in Keychain via `Security.framework`, implement rate-limit backoff, cache ETags.

- **Upside:** No `gh` dependency. In-process — no subprocess latency. Finer control: we could stream PR updates, or poll efficiently with conditional requests, or support offline snapshots.
- **Downside:** 5–10× more code, all of it security-sensitive. Token storage pulls in Keychain UI, first-launch prompts, "reset auth" paths. OAuth device flow needs a browser open + polling loop. Rate-limit and retry logic has to be homegrown. Adds an SPM dependency or our own HTTP models. Duplicates what `gh` already does — correctly and with GitHub's own hardening.
- **Why rejected:** Violates Golden Rule #11 (agent legibility — an HTTP client + OAuth + Keychain surface is hard to reason about in-repo). The user already has `gh` in their workflow. The only upside we would actually capitalize on — offline snapshots — is explicitly a Non-Goal. This is the wrong fight to pick for v1.

### 2. `gh` wrapper but with GraphQL-batched pre-fetch at startup

On app launch, read all Worktrees' branches, issue one GraphQL query via `gh api graphql` with aliases for up to 25 branches at a time, populate the whole sidebar's PR badges before the user interacts.

- **Upside:** Badges are instantly populated. Feels polished on projects with many Worktrees. The aliased-query technique is well-understood and known to work against the GitHub GraphQL API.
- **Downside:** Extra complexity (alias generation, dynamic-key decoding, `withThrowingTaskGroup` chunking, request-cancellation on Project switch) for a user that may only look at one Worktree this session. Also creates a startup latency / rate-limit spike for large Project lists.
- **Why rejected for v1:** On-demand fetch per visible Worktree solves the same UX problem for realistic sidebar sizes (<~10 worktrees). We keep the seam open to add the batch path once we measure the problem. Explicitly tracked under [Seams](#seams-for-future-work).

### 3. Integrate into C7 `GitViewerFeature` as a fifth scope (`.pullRequest`)

Make "PR diff + checks" a new tab of the existing git viewer rather than a separate feature.

- **Upside:** One feature, one mental model, one place for "everything git". Fewer TCA features to wire.
- **Downside:** Conflates two very different data paths (local git subprocesses vs. remote `gh` with network/auth/rate-limits vs. different error modes / timeouts / states). C7's current scope is *read-only local*; GitHub brings mutations (merge/close). Error-handling vocabulary diverges. Couples cadences: a C7 refactor would now risk GitHub functionality.
- **Why rejected:** Explicitly contradicts the C7 design doc Non-Goal "No IPC surface, no remote data." Keeping the features separate preserves C7's guarantees and lets `GitHubFeature` own its own lifecycle (availability probe, debounced refresh, popover focus).

### 4. Defer everything except the Settings pane — just detect `gh` availability in v1

Zero UI beyond a Settings checkbox + doctor page.

- **Upside:** Ships tomorrow. Risk-minimizing.
- **Downside:** Does not actually solve the user's problem. The PR-status-at-a-glance question is the whole point.
- **Why rejected:** The user has already created a `feature/github01` branch; shipping a Settings page alone would be busywork. v1 scope as specified is the minimum that answers the motivating question.

## Cross-Cutting Concerns

### Security

- **No secret material in codans.** Tokens live in `gh`'s config store. We never read `~/.config/gh/hosts.yml`.
- **Subprocess argument safety.** All `gh` invocations are `(executable, [argv])` — no shell, no string interpolation. User-supplied tokens are branch names and commit SHAs; those are passed as argv elements and validated before use (branch matches `git check-ref-format`; SHA is `[0-9a-f]{7,40}`). Mirrors C7's handling.
- **Log hygiene.** `os.Logger` category `com.gumpw.codans.github`. Never log PR titles / branch names / emails at `.info` (may contain confidential project info); use `.debug` with `privacy: .private` on those fields.
- **No outbound network from the app.** All HTTP goes through `gh`; app stays off the network. Simplifies the firewall / sandbox story.

### Observability

- `os.Logger` subsystem `com.gumpw.codans.github`, per-method category (`resolver`, `service`, `feature`).
- Every `gh` invocation logs argv + cwd + duration + exit code at `.debug`. No stdout/stderr logging at info — too big, may be sensitive.
- Availability probe failures log the reason at `.info` (install missing, auth missing, wrong host) — these are user-actionable and worth surfacing in Console.app.

### Error handling

`GitHubError` carries a user-facing `message: String` and a discriminant:

- `.notInstalled` — `gh` not on `$PATH`. Remediation: install link.
- `.notAuthenticated(host)` — `gh auth status` reports no token. Remediation: `gh auth login`.
- `.notAPullRequest` — branch has no PR. Not shown as error; Worktree row simply has no badge.
- `.network(underlying)` — gh exited non-zero and stderr mentions connectivity.
- `.rateLimited(retryAfter)` — parsed from gh stderr when present.
- `.merge(conflict)` — gh exit code 1 with specific message.
- `.timeout` — `CommandOutcome.timedOut`. Rare; logs at `.error`.
- `.other(String)` — catchall with stderr preserved.

Errors render inline in the popover with a single remediation button. The Settings pane shows a persistent banner when `availability != .available`.

### Testing strategy

Same shape as C7:

- `RecordingCommandRunner` (existing actor) feeds canned `CommandOutcome`s. Every `LiveGitHubService` method gets tests for: success, non-zero exit, timeout, decode error, empty output, `gh` missing.
- Golden-file JSON fixtures for `gh pr view --json`, `gh pr checks --json`, `gh run list --json` — captured once from real `gh`, checked in, versioned. Tests decode them into DTOs and assert field-by-field.
- `GitHubFeature` reducer tests use TCA's `TestStore` with `.testValue` dependencies; every action path is covered including error-propagation to `.delegate`.
- No integration tests against real GitHub in CI.

### Migration path

Additive. `RepositorySettings` gets two optional fields with decode-if-present fallback; pre-integration `settings.json` files round-trip identically. No `catalog.json` changes. No `hooks.json` changes.

### Rollback plan

The feature is entirely additive with a per-Project toggle. Disabling the toggle makes badges + popovers + palette actions disappear; deleting the `codans/GitHub/` folder + three references in `RootFeature`/`SettingsFeature`/`CommandPalette` removes it entirely. No data migration needed for rollback.

## Risks

- **R1: `gh` output schema changes between versions.** Mitigation: DTOs use `decodeIfPresent` for every non-critical field + a versioned fixture suite + a one-line note in `README`/docs pinning the tested `gh` major version. We accept that a `gh` breaking change will require a codans release; this is a trade we make explicitly in exchange for not running our own API client.

- **R2: Sidebar-population subprocess burst.** On a Project with 15 Worktrees, selecting it fires 15 `gh` processes. Mitigation: `GitHubFeature` caps in-flight fetches at 3 (per-Project `TaskGroup`) and enqueues the rest. If this proves visibly slow in practice, switch to the batched GraphQL path (already seam-reserved). Decision gate: measurable P50 > 500 ms for full badge population on a realistic Project.

- **R3: User has `gh` but configured a non-default host.** Mitigation: `availability` returns `.available(host)` with the host name; Settings pane shows the active host. Multi-host switching is an explicit Non-Goal for v1; document the limitation in the Settings pane help copy.

- **R4: PR↔Worktree match ambiguity** (two Worktrees on same branch, stale refs, branch renamed). Mitigation: tie-break by Worktree mtime (most-recently-activated wins). Show the badge only on the winning row; log `.debug` for the skipped ones. Stale/renamed branches simply fall to the `.notAPullRequest` path.

- **R5: `gh` invocation deadlocks or hangs.** Mitigation: every call inherits `FoundationCommandRunner`'s 20-second default timeout + SIGTERM→SIGKILL ladder. No call can hang the UI.

- **R6: `CommandRunner` move (from `codans/Git/` to `codans/Process/`) breaks C7.** Mitigation: the move is mechanical (rename + update 2 importers); land it as a prep commit with full C7 test suite passing before touching GitHub code. If the move proves disruptive, fall back to leaving `CommandRunner` in `Git/` and adding a `@_exported import` shim — strictly worse but reversible.

- **R7: User runs codans without `gh` installed and finds no feature.** Mitigation: first-run onboarding detects missing `gh` and offers the `brew install gh` copy-to-clipboard plus a "Configure later" dismiss; after that, only the Settings pane banner surfaces the state. The rest of the app is unaffected.

## Open Questions

These are blocking for exec-plan authoring; flagged here rather than guessed:

1. **Per-Project toggle default: on or off?** On means every Project with `gh` available gets badges without user opt-in. Off means badges are invisible until the user discovers the setting. *Leaning:* on, because the feature is silent when no PR exists — no visual cost when absent.

2. **Where do command-palette actions live?** A new `CommandPaletteFeature` delegate case set (mirrors editor pattern), or a `GitHubActions` submodule of the palette? *Leaning:* delegate cases consumed by `RootFeature` + forwarded to `GitHubFeature`, matching the C8 editor-open flow exactly.

3. **Does `rerunFailedJobs` re-run all failed jobs in the latest run, or does the popover let the user pick?** *Leaning:* re-run all in v1 (single call to `gh run rerun --failed`), with a "retry individual job" non-goal — keeps the action list short and matches `gh`'s own one-shot semantics.

4. **Should `markReady` (draft→ready) be a separate command-palette entry, or inline in the popover only?** *Leaning:* popover-only in v1, promote to palette if used.

## References

- [architecture.md § Architectural Invariants](../architecture.md) — Pane/IPC/persistence invariants honored by this design
- [docs/design-docs/c7-git-viewer.md](c7-git-viewer.md) — layering and `CommandRunner` reuse pattern this design mirrors
- [docs/design-docs/c8a-editor-integration-nsworkspace.md](c8a-editor-integration-nsworkspace.md) — delegate-action + `*Client` pattern this design copies
- [GitHub CLI](https://cli.github.com/) — v2.x reference; we test against whatever `mise` / `brew` resolves in CI for the user
- [`gh pr` subcommands](https://cli.github.com/manual/gh_pr) — `view --json`, `checks --json`, `merge`, `close`, `ready`
- [`gh run rerun`](https://cli.github.com/manual/gh_run_rerun) — `--failed` semantics used by [`rerunFailedJobs`](#githubservice-protocol-data-layer)
- [`gh auth status --json`](https://cli.github.com/manual/gh_auth_status) — availability probe source of truth
