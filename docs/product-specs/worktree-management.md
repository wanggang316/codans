# Product Spec: Worktree Management

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-04-21

## Summary

A **Worktree** is a `git worktree` of a Project — a concrete branch checkout on disk with its own directory and its own Tab/Pane layout. codans is built around the workflow of running multiple features in parallel, one Worktree per feature, each with its own terminal and agent. This spec covers the full user-facing Worktree lifecycle: creating a Worktree (branch name + base ref + optional fetch), listing pre-existing ones, switching between them, archiving (soft-hide, reversible), removing (physical delete with safety checks), and pruning stale entries. Worktree operations run through the bundled `git-wt` helper (the same one supacode uses), which wraps `git worktree` with better defaults and streaming output.

## Background: why `git-wt`

Rather than shelling out to `git worktree` directly, codans bundles the open-source [`git-wt`](https://github.com/khoi/git-wt) helper as a submodule (same as supacode). It covers the common create/list/remove surface with:

- JSON-formatted listing (cleaner than parsing porcelain output),
- sensible path defaults,
- copy-ignored / copy-untracked flags for seeding a new worktree from the current checkout,
- streaming output so long-running operations (`--copy-ignored` on big repos) can drive a progress UI.

This spec describes the user-facing behavior; the `git-wt` dependency is noted here for completeness but is a design-level detail.

## User Stories

- As a developer starting a new feature, I want to create a Worktree by specifying a branch name and base ref so I can spin up an isolated checkout without typing the full `git worktree add` incantation.
- As a user with uncommitted tooling (`.env`, `node_modules`) in the current checkout, I want an option to copy ignored and/or untracked files into the new Worktree so it's immediately runnable.
- As a user returning to a Project, I want existing worktrees — including those I created on the CLI outside codans — to show up automatically in the sidebar.
- As a user switching between features, I want clicking a Worktree in the sidebar to instantly activate its tabs, panes, and terminal state.
- As a user finishing a feature, I want to **archive** a Worktree to hide it from the main list without deleting files, so I can come back if I need to re-run or re-reference it.
- As a user cleaning up, I want to **remove** a Worktree — physically delete the directory and deregister the branch from git — with a safety check for uncommitted changes and a confirmation dialog.
- As a user whose worktrees got deleted outside codans, I want a **prune** action that clears stale git references and orphaned sidebar rows.
- As a user who made a mistake, I want to **unarchive** a previously archived Worktree and restore it to the main list.
- As a user experimenting, I want to see the current branch, local change count, and last-modified time on each Worktree row so I can decide what to work on next.

## Requirements

### Must Have

#### Create

- [ ] **Create Worktree sheet** triggered from the sidebar Project row's `[+]` button. The sheet prompts for:
  - **Branch name** (required). Must pass `git check-ref-format --branch` (live validation). Must not collide with an existing local branch in this Project; duplicate-branch is a blocking error.
  - **Base ref** (required; pre-populated with an automatic choice — typically the Project's default remote branch, e.g. `origin/main`). Dropdown lists local and remote refs.
  - **Fetch origin before creating** (optional toggle, default off). When on, run `git fetch origin` before creating.
  - **Copy ignored files** (optional toggle, default off). Passes `--copy-ignored` to `git-wt`.
  - **Copy untracked files** (optional toggle, default off). Passes `--copy-untracked` to `git-wt`.
- [ ] **Streaming progress.** When `copyIgnored` or `copyUntracked` is enabled, the sheet shows live output lines from `git-wt` so large copies don't look frozen.
- [ ] **Worktree path derivation.** The on-disk path is computed as `<Project.worktreesDirectory>/<sanitized-branch-name>`, where `Project.worktreesDirectory` defaults to `~/.codans/repos/<project-name>/` (per [Project Management spec](project-management.md)). Branch-name sanitization: replace `/` with `-` and strip characters invalid on macOS filesystems.
- [ ] **Post-create selection.** On success, the new Worktree is added to the sidebar, selected, and a single Tab with a single Pane opens in its directory.
- [ ] **Create failure handling.** On failure, the sheet stays open with a human-readable error (branch exists / ref not found / filesystem error / `git fetch` failed); no partial state is left in `catalog.json`.

#### List / discover

- [ ] **Discover existing worktrees.** On Project add and on reconcile (app launch + window focus), query `git-wt ls --json` and merge results into the sidebar. Worktrees created on the CLI outside codans appear without user action.
- [ ] **Main-checkout present.** The Project's main checkout is always listed as the first Worktree row. It is the only Worktree that cannot be removed or archived from the app.
- [ ] **Per-Worktree metadata.** Each row surfaces:
  - branch name (or detached HEAD indicator),
  - relative path from the Project's git root (for disambiguation when two worktrees share a branch label),
  - an unread-notification dot (consuming existing `InboxClient` data),
  - an active-Worktree marker (the current selection in this Project).
- [ ] **Ordering.** Worktrees are sorted by creation time (newest first), with the main checkout pinned at the top regardless of age.

#### Switch

- [ ] **One-click activation.** Clicking a Worktree row selects it, restores its Tabs/Panes, and updates the header's branch label and git-viewer state.
- [ ] **Switch is instant.** No progress UI; state for the target Worktree is already in memory. (Inherits from T1/T3 behavior — this spec just affirms it applies to newly-created Worktrees too.)

#### Archive (soft hide, reversible)

- [ ] **Archive Worktree** action on the row's context menu. Archiving:
  - hides the Worktree from the Project's main list in the sidebar,
  - closes any open Tabs/Panes of that Worktree,
  - does **not** touch files on disk,
  - does **not** deregister the branch from git,
  - is reversible via Unarchive.
- [ ] **Archived-Worktrees surface.** A secondary surface (sheet or dedicated section at the bottom of the Project) lists the Project's archived Worktrees, with Unarchive and Remove actions per row.
- [ ] **Unarchive** returns the Worktree to the main list at its original creation-time sort position; no tabs/panes are auto-reopened (user selects to re-activate).
- [ ] **Archive confirmation.** First-time archive in a session shows a confirmation explaining the soft-hide semantics ("Files and branch are kept. Find it later under 'Archived Worktrees'."). Subsequent archives skip the confirmation for the rest of the session.

#### Remove (hard delete)

- [ ] **Remove Worktree** action on the row's context menu and on each Archived-Worktrees row. Two modes:
  - **Safe remove** — runs `git worktree remove` (via `git-wt`) without `--force`. Fails if the worktree has uncommitted changes or is locked; the error is surfaced with a one-click "Force Remove" follow-up.
  - **Force remove** — runs `git worktree remove --force`. Always shown via a confirmation dialog that explicitly calls out "uncommitted changes will be discarded" and "this cannot be undone".
- [ ] **Remove effects.** On success:
  - the worktree directory is deleted from disk,
  - the worktree is deregistered from git (`.git/worktrees/<name>` removed by git),
  - the row disappears from the sidebar and from the archived list (if applicable),
  - any open Tabs/Panes of that Worktree are closed.
- [ ] **Remove failure handling.** On failure, leave the Worktree in place with the git error message in a banner; never leave catalog and disk out of sync.
- [ ] **Main checkout cannot be removed** from within codans; the context-menu entry is hidden for that row.

#### Prune

- [ ] **Prune stale** action, available on each Project's `⋯` menu. Runs `git worktree prune` and then re-queries `git-wt ls --json`; rows whose directories no longer exist are removed from the sidebar. A summary toast ("Pruned 2 stale worktrees") confirms the result.

#### Safety and reconciliation

- [ ] **Uncommitted-changes check before remove.** Safe remove surfaces the specific reason ("3 uncommitted files in <path>") instead of a generic error, so users can make an informed choice before force-removing.
- [ ] **External deletion resilience.** If a Worktree's directory is deleted outside codans, the reconcile on window focus marks the row as stale and offers a one-click "Prune" — never a crash, never a silent state mismatch.

### Nice to Have

- [ ] **Rename branch** inside an existing Worktree (wrapper around `git branch -m`), with live name validation.
- [ ] **Line-change badge** — small `+123 -45` indicator per Worktree row (supacode has this).
- [ ] **Git fetch action** per Worktree — context menu "Fetch origin" without going through the Create flow.
- [ ] **Copy path** action on the Worktree row.
- [ ] **Reveal in Finder** on the Worktree row.
- [ ] **Branch-name autocomplete** in the Create sheet (tab-completion against local branches you might want to re-use).
- [ ] **Worktree templates / hooks** — run a user-defined script after a new Worktree is created (e.g. `pnpm install`). Beyond v1.

## Acceptance Criteria

### Create

- **Given** a Project with `worktreesDirectory` at the default `~/.codans/repos/<project-name>/`, **when** the user creates a Worktree named `feature/login` from base `origin/main`, **then** a new directory appears at `~/.codans/repos/<project-name>/feature-login/`, a Worktree row is added to the sidebar, and a terminal opens in that directory.
- **Given** the user types a branch name that already exists locally, **when** they attempt to create, **then** the Create button is disabled and an inline error reads "Branch 'x' already exists".
- **Given** the user types an invalid branch name (e.g. with spaces), **when** the live validator runs, **then** the error "Branch name is invalid" appears and the Create button is disabled.
- **Given** the user enables "Copy ignored" on a repo with a 500 MB `node_modules`, **when** creation runs, **then** the sheet streams progress lines and the Create button re-enables only on completion; the resulting Worktree has `node_modules/` in place.
- **Given** the user enables "Fetch origin" and the network is down, **when** they attempt to create, **then** the fetch error is surfaced clearly and no Worktree is created.

### List / switch

- **Given** a user manually ran `git worktree add` outside codans, **when** they focus the codans window, **then** the new Worktree appears in the sidebar within the reconcile cycle.
- **Given** two Worktrees on the same branch at different paths, **when** they are listed, **then** each row shows the relative path so the user can disambiguate.
- **Given** the user clicks an inactive Worktree row, **when** it becomes active, **then** the header branch label updates and the Worktree's saved Tabs/Panes restore.

### Archive

- **Given** a Worktree is archived, **when** the user looks in the main Project list, **then** it is no longer visible; **and when** they open "Archived Worktrees", **then** it is present.
- **Given** an archived Worktree, **when** the user chooses Unarchive, **then** it returns to the main list in its original relative order.
- **Given** an archived Worktree, **when** the user chooses Remove from the archived list, **then** the same remove flow applies (safe / force) and on success it disappears from both lists and the disk directory is deleted.

### Remove

- **Given** a Worktree with 3 modified files, **when** the user chooses Safe Remove, **then** the operation fails, the error message names the uncommitted files, and a "Force Remove" button appears in the error dialog.
- **Given** the user confirms Force Remove, **when** it completes, **then** the worktree directory is gone, the row disappears, any terminal tabs in it are closed, and `git worktree list` no longer references it.
- **Given** the main checkout row, **when** the user opens the context menu, **then** no Remove or Archive action is present.

### Prune

- **Given** a Worktree whose directory was deleted from disk outside codans, **when** the user triggers Prune on the Project, **then** the stale row disappears and a toast reports "Pruned 1 stale worktree".

## Scope

### In Scope

- Create with branch name + base ref + optional fetch + optional copy-ignored/untracked.
- Auto-discover worktrees created outside codans.
- Switch Worktree with full state restoration.
- Archive / unarchive (soft, reversible).
- Safe remove + force remove with explicit confirmation.
- Prune stale references.
- Per-row metadata: branch, relative path, unread dot, active indicator.

### Out of Scope (v1)

- **Worktree from a detached commit without a branch** — v1 always creates a named branch.
- **Rebase / merge / pull / push / commit UI** — terminal-first; use `git`, `lazygit`, etc.
- **Multi-worktree bulk operations** (e.g. "archive all merged worktrees").
- **Conflict-resolution UI.**
- **Archive script** (supacode runs a user-configured shell script on archive). v1 keeps archive as pure metadata; scripting can come back later as a C3 hook subscription.
- **Moving a Worktree between Projects.**
- **Changing a Worktree's on-disk path** after creation (users can force-remove and recreate).

### Future Consideration

- Archive hook / script, wired through C3.
- Inline rebase/merge helpers.
- Branch rename in-place.
- Auto-archive prompt when a PR merges (depends on GitHub integration).

## Design

Product-level only; technical shape of the Create sheet, reconcile scheduler, and error-surfacing UI goes into follow-up design docs.

References for the follow-up design:

- **supacode** — `GitClient` (`/Users/wanggang/dev/opensource/supacode/supacode/Clients/Git/GitClient.swift`) is the canonical shape for a `git-wt`-backed client, including `createWorktreeStream` for streaming progress and `worktrees(for:)` for listing. The `WorktreeCreationPromptFeature` reducer mirrors the sheet's validation flow almost one-to-one. supacode's archive feature in `RepositoriesFeature` (`archiveWorktreeConfirmed`, `unarchiveWorktree`, `ArchivedWorktreesDetailView`) is the archive UX we're borrowing.
- **`git-wt` tool** — <https://github.com/khoi/git-wt>. Bundle as a submodule under `apps/mac/ThirdParty/git-wt/` (mirroring supacode's `Resources/git-wt`), invoked with `Bundle.main.url(forResource:)`.
- **Existing code** — `HierarchyClient.createWorktree` and `HierarchyClient.removeWorktree` are data-only right now; they will be extended (or replaced) to run the actual git operations via a new `GitWorktreeClient`. `CodansCore/Worktree.swift` will need a new `archived: Bool` field (default false; Codable `decodeIfPresent ?? false` to keep existing catalogs compatible).

## Open Questions

1. **`archived` persistence** — store `archived: Bool` on each `Worktree` (in-place) vs. a separate `archivedWorktrees` array per Project. *Leaning:* in-place flag with `decodeIfPresent` default; simpler, matches existing T0 patterns.
2. **Create-sheet base-ref default** — always the Project's default remote branch, or the currently-selected Worktree's branch? *Leaning:* default remote branch (matches supacode's `automaticWorktreeBaseRef`); predictable regardless of selection.
3. **Remove while terminals are running** — hard-kill attached processes before deleting the directory, or block with an error until terminals are closed? *Leaning:* hard-kill with explicit confirmation copy ("this will terminate N running processes in this Worktree"); otherwise force-remove has a frustrating trap.
4. **Where does `worktreesDirectory` live for edit** — inline in the Create sheet as an "advanced" disclosure, or only in the Project options sheet? *Leaning:* Project options only; per-create override would let users scatter worktrees and undermine the predictable default.
5. **Branch sanitization collision** — if two branches sanitize to the same directory name (e.g. `feature/a` and `feature-a` both become `feature-a`), reject at create time or append a suffix? *Leaning:* reject with a clear error; silent suffixing is confusing.
6. **Archive-script equivalent** — keep deferred to a future C3 hook (our current leaning) vs. v1-minimal "run a user-defined script on archive"? *Leaning:* defer; v1 ships pure-metadata archive.
