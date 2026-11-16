# Git Platform

A Git Platform is the service that hosts the `origin` remote of a repository and its Pull Requests: GitHub, through the `gh` CLI, or GitLab, through the `glab` CLI. This domain shows the Pull Request of each Worktree branch (state, draft, diff size, merge state, review, CI checks) and runs the write actions on it (merge, close, mark ready, rerun failed checks). The UI label is "PR" for GitHub and "MR" for GitLab; the domain term is Pull Request (see the [glossary](../glossary.md#git-platforms)).

Availability: Available. The post-merge Worktree action setting has no effect (see [Write actions](#write-actions)).

## Scope and ownership

| Topic | Owner |
|---|---|
| How `gh`, `glab`, `git`, and `ssh` start (login shell, environment) | [Environment](environment.md) |
| Storage of the Git Platform aliases and the merge defaults | [Settings](settings.md) |
| Placement of the toolbar status slot and the sidebar row | [Main Window](main-window.md) |
| Pull Request summary on a Workspace group row | [Workspace](workspace.md) |
| "Archive All Merged" and the Worktree lifecycle | [Worktree](worktree.md) |
| The target ref that the Diff Viewer compares against | [Git Diff Viewer](git-diff-viewer.md) |

## No HTTP, no tokens

codans sends no HTTP request to a Git Platform and stores, reads, or forwards no token. Each read and write is a `gh` or `glab` subprocess through the shared `CommandRunner`, with argv only (no shell string) and an environment allowlist that removes the token variables (`GH_TOKEN`, `GITHUB_TOKEN`, `GITLAB_TOKEN`, and the like). Authentication is `gh auth login` or `glab auth login`, and the token stays in the store of that CLI. To find the hosts that `glab` is logged in to, codans reads only host names, whether a token is present, and the API protocol from the `glab` config file. A change that adds an HTTP client, a Keychain entry, or OAuth breaks this rule ([ADR 0004](../adrs/0004-gitlab-support-through-glab.md) item 3).

## Model

- **Git Platform repository**: kind, API host, and full path (`GitPlatformRepository`). The path keeps every segment, because GitLab groups nest (`group/sub/repo`). The host can include a port.
- **Fetch unit**: one repository whose Pull Requests are read together. A git Project is one unit, keyed by its own `ProjectID`. A Workspace has one unit per source repository of its rows, keyed by an ID derived from the Workspace ID and the canonical repository root, stable across launches. A unit lists `(WorktreeID, branch)` pairs; archived rows and rows without a branch (detached HEAD) are not in it.
- **Batch** (`BatchedPullRequests`): the result for one unit. It holds the resolved repository, the snapshot per branch (a branch without a Pull Request has no entry), the branch set that was asked for, and the fetch time. Write actions and web URLs take their target repository from the batch.
- **Snapshot** (`PullRequestSnapshot`, in `CodansCore/GitPlatform/`): a provider-neutral Pull Request. Fields that carry a rule:
  - `headSHA`: the head commit of the source branch when it was read. Merge requires it.
  - `checkRollup`: the CI checks, read in the same query as the rest. There is no separate checks call.
  - `mergeState`: clean, conflicted, behind, blocked, draft, or unknown, with an optional reason.
  - `mergeOptions` and `canRerunFailedChecks`: capability differences between Git Platforms are data on the snapshot, not optional protocol methods.
  - `baseRefName` and `baseRepositoryURL`: the target of the Pull Request, for the Diff Viewer. When they are missing, do not guess the target from the branch name; a fork Pull Request targets another repository.
- **Pairing**: a Worktree shows the snapshot whose source branch equals `Worktree.branch`. Several Worktrees of one unit can show the same snapshot. Two Workspace members with the same branch name in different repositories never mix, because cache, cancellation, queue, and write targets are per unit.

The reducer keeps the batches per unit and projects them into a per-Worktree map that the views read. The batches are also written to a disk cache (`github-snapshots.json` in the app cache directory, for both Git Platforms) only to paint badges at launch. A cache entry that does not decode is dropped, entries for Projects that left the catalog are dropped, and the next fetch replaces the rest.

## Resolving the Git Platform

Each fetch reads `git remote get-url origin` (a plain git step in `GitService`) and the alias list, then `GitPlatformResolver` gives the repository. The order is in [ADR 0005](../adrs/0005-git-platform-aliases.md) item 3: alias, public host or logged-in host (GitHub first), the `ssh -G` HostName of an SSH remote, a host name that contains `github` or `gitlab`, else none.

- An alias is checked first, so a user can correct any automatic result. An alias without a port also matches an SSH remote with a port, because that port is the SSH port.
- An alias or a name match resolves even when the CLI is missing or not logged in to that host. The fetch then fails with the install or login message at the badge position. This is the intended way to tell the user what to fix.
- A unit with no Git Platform shows no badge and no error, and the poll skips it. An event-driven refresh resolves it again.
- When a unit resolves to a repository different from its cached batch (an alias edit, a login, a new `origin`), the old batch and the row snapshots are dropped **before** the read. A failed read of the new repository thus never leaves badges or write targets of the old one.
- The logged-in hosts of each CLI, the `ssh -G` results, and the found CLI paths are cached. A missing CLI is not cached. All three are dropped by the Settings "Re-check" and when a `gh` or `glab` command ends in a Pane, so an install or `auth login` in a Pane shows the badge without a Re-check.
- Each unit resolves alone, so one Workspace can have GitHub and GitLab members ([ADR 0004](../adrs/0004-gitlab-support-through-glab.md) item 16). The Project has no Git Platform setting.

## Fetching

```
 Worktrees ──group by repository──► fetch units (Project, or Workspace repository)
                                          │ origin + aliases → GitPlatformResolver
                                          ▼
                    GitPlatformClient ─kind─► GitHub: gh api graphql, one alias per branch
                                          └─► GitLab: glab api graphql, sourceBranches list
                                          │ chunks run in parallel; fork filter
                                          ▼
                   batch per unit ──► GitPlatformFeature state ──► sidebar badge,
                                      (+ disk cache)               status slot, popover
```

- The cost follows the number of repositories, not the number of Worktrees: one CLI call reads all branches of a chunk, with Pull Request data and checks in one round trip. Views never start a fetch. A per-row fetch was removed because it exhausted the API rate limit on launch; do not add one back.
- A fetch is all or nothing. If one chunk fails, the batch fails and nothing partial is shown.
- **Fork filter.** A query by head branch name also returns fork Pull Requests whose source branch has the same name (a fork's `main` into the upstream `main`). Per branch: keep the Pull Requests whose source is this repository (GitHub: head owner; GitLab: source project path); if none, keep those whose base branch differs from the head branch; take the most recently updated. A deleted fork counts as a fork. The reducer never sees the filtered entries.
- GitHub reads open and merged Pull Requests only. GitLab also reads closed ones, but an open or merged one wins.
- GitLab specifics that the code handles: all pages are read before a snapshot is made, older self-managed instances get a reduced query without review fields, and a `null` `currentUser` means "not logged in" because GitLab answers anonymous queries.

## Freshness

There is no expiry time on the data. Events invalidate it, and a foreground poll covers changes on the Git Platform side.

| Event | Effect |
|---|---|
| Project selected; HEAD of a Worktree moved (`WorktreeHeadWatcher`, then reconcile) | Fetch its units, unless the batch is under 30 s old and covers the same branch set |
| Project added, or a repository added to a Workspace | First fetch of each new unit, also when it is not selected or the app is in the background |
| `git`, `gh`, or `glab` ends in a Pane | Fetch that Pane's unit after 1.5 s |
| Remote-tracking refs change (`RemoteRefsWatcher`, any process) | Fetch the unit after 2 s; poll it as hot for 3 minutes |
| Merge, close, mark ready, or rerun succeeds | Fetch the unit after 2 s, because the Git Platform is not consistent at once |
| Merge refused because the head moved | Fetch the unit at once |
| Alias list changes; sidebar "Refresh all" | Queue a fetch of every unit |
| App becomes active | Queue a fetch of each unit not fetched in the last 30 s, selected Project first |

The remote-refs watcher exists because an agent that runs `git push` or `gh pr create` stays the foreground job of its Pane, so the Pane signal does not see it.

**Poll.** While the app is frontmost (`NSApp.isActive`, not user activity), every unit of every Project polls. When the app resigns active the timer stops, so a background app starts no Git Platform process. The cadence follows the latest batch and the selection: a unit with an open Pull Request whose checks run or whose merge state is unknown polls fastest, a unit with settled open Pull Requests slower, and a unit with none slowest. Units of the selected Project poll faster than the others. The range is 10 seconds to 5 minutes.

A fetch from any source resets the cadence of its unit. At most two poll-started fetches run at once.

**One fetch per unit.** A request for a unit that has a fetch in flight sets a queued flag; when the fetch ends, one more fetch runs with the current branch pairs. A burst of events thus becomes at most one extra fetch. A result that arrives after its unit left the catalog is discarded, so a removed Project is not written back to state or to disk.

## What the UI shows

- **Sidebar badge** (`WorktreePullRequestBadge`): the number, state, and check ring of the row's snapshot, or the error for the row. A click opens the Pull Request in the browser; a hover opens the popover. The row shows no loading state, because each selection starts a fetch.
- **Toolbar status slot**: for the selected Worktree, a snapshot that is not closed shows its number, diff size, check ring, and a summary. A toast takes the slot first. A click opens the Pull Request; a hover opens the same popover.
- **Popover** (`PullRequestPopover`): metadata, checks, the merge split button with the reason when merge is disabled, and the other actions. Opening it for an open snapshot without `headSHA` refreshes the unit.
- **Workspace group row**: a count of the open and merged Pull Requests of its members. See [Workspace](workspace.md).
- **Commands**: "Open PR on GitHub" / "Open MR on GitLab" and "Open Project on GitHub" / "Open Project on GitLab", in the menu and the command palette. "Open Project" uses the same resolution order.

## Write actions

All writes address the repository and number explicitly (`PullRequestReference`), never the working directory. One Worktree runs one write at a time; a second request while one runs is dropped. The result shows as a toast in the status slot.

- **Merge** uses the strategy from the split button; the default comes from the Project override, then the global setting. On GitLab the project merge method applies, so `rebase` acts as Merge.
- **Head commit guard** ([ADR 0004](../adrs/0004-gitlab-support-through-glab.md) item 17). A merge sends the `headSHA` of the snapshot the user saw (GitHub `--match-head-commit`, GitLab `sha`). There is no merge path without a SHA. When the head moved, the error "The branch has new commits. Review them, then merge again." stays through later reads until the user selects "Review", which shows the new head only after a successful read of it. The error goes when the row shows another Pull Request or another branch. There is no "merge anyway".
- **Close** and **Mark ready** show only for an open Pull Request (Mark ready also only for a draft).
- **Rerun failed** shows when `canRerunFailedChecks` is true. GitHub reruns each failed Actions run of the head commit, found again at the time of the action, so it never reruns the wrong workflow; failures from external status contexts do not count. GitLab retries the head pipeline, which retries only failed and canceled jobs.

> **Discrepancy:** [ADR 0004](../adrs/0004-gitlab-support-through-glab.md) item 10 defines a post-merge Worktree action, and Settings stores it globally and per Project (Do nothing, Archive, Delete, Ask). No code reads it: the `pullRequestMerged` delegate is a no-op, so the Worktree stays as it is after a merge whatever the setting says.

## Errors

- A batch that fails because the CLI is missing, not logged in, or too old puts an actionable error on every row of the unit, at the badge position. The popover shows the message for the kind, with an "Install gh" or "Run gh auth login" button (`glab` for GitLab), or "Retry" for a CLI that is too old. The next successful fetch clears it.
- Other batch errors (network, GraphQL, oversize output, an unreadable `origin`) are kept on the unit only. The rows keep the data they show.
- A click on an error badge refreshes the whole unit.

## Traps

- On a failed non-CLI fetch, badges show the last good data without a mark. A badge can be old while the logs show errors.
- A closed GitLab merge request can show on a sidebar row; a closed GitHub pull request never does. The status slot hides closed ones on both.
- The Settings "Re-check" drops the caches but does not re-resolve units that had no Git Platform; a Pane `gh`/`glab` command, an alias change, or "Refresh all" does.
- The HEAD-move refresh skips a fetch when the batch is under 30 s old and the branch set is the same. A new commit on a branch does not refresh at once; the remote-refs watcher catches the push.
- A merge can fail for a reason the snapshot did not show, because GitLab reports `UNCHECKED` until something asks it to recheck. codans asks for a recheck after a read, so the next poll shows the real state.

## Shape of the implementation

`RootFeature` builds the fetch units from the catalog and sends the events. `GitPlatformFeature` (`App/Features/GitPlatform/`) is the one reducer that owns fetches, the poll, the per-unit batches, the per-Worktree projection, and the write actions; it never branches on the Git Platform kind except for UI labels. `GitPlatformClient` selects `GitHubGitPlatform` or `GitLabGitPlatform` (`GitPlatform/`), which implement the `GitPlatform` protocol; only their decoding layer knows the wire values. The neutral model is in `CodansCore/GitPlatform/`.

## Related decisions

- [ADR 0004](../adrs/0004-gitlab-support-through-glab.md): GitLab through `glab`, one Git Platform interface, mixed Workspaces, the head commit guard.
- [ADR 0005](../adrs/0005-git-platform-aliases.md): Git Platform aliases and the resolution order; no Project Git Platform choice.
