# Worktree

A Worktree is one `git worktree` of a Project: a checkout of one branch in its own directory, with its own Tabs and Panes. It is the unit of parallel work: each agent or task gets its own branch on disk, so several branches are live at once. This page covers the Worktree row: what it holds, how it enters and leaves the catalog, the order of the rows below a Project, and the branch switcher of the header.

Availability: Available. Hidden: the recent commits that the branch switcher loads.

## Scope and ownership

This domain owns the lifecycle of Worktree rows (create, reconcile, archive, unarchive, remove, prune), their order, and the branch switcher. Other pages own the neighbor topics:

| Topic | Owner |
|---|---|
| Sidebar, header, toolbar status slot, tab hover card | [Main Window](main-window.md) |
| Foreground process sampling | [Terminal Runtime](terminal-runtime.md) |
| Pull Request data and the action after a merge | [Git Platform](git-platform.md) |
| Worktrees of a Remote Project | [Remote Projects](remote-projects.md) |
| Workspace rows and member checkouts | [Workspace](workspace.md) |
| Unread state that moves a Worktree up | [Notifications](notifications.md) |
| `codans worktree` verbs | [CLI](cli.md) |

## The Worktree row

A row in the catalog holds the path, the name, the `branch` and `headSHA`, its Tabs, and two flags: `archived` (with its time `archivedAt`) and `isPinned`. Rules:

- A `WorktreeID` exists only after the row is written. A creation in progress has no ID.
- Paths are compared in canonical form (symlinks resolved). In one Project, two rows cannot have the same canonical path or the same name.
- The **main checkout** is the row whose path equals `Project.rootPath`. It cannot be archived, removed, pinned, or dragged. The menus leave these items out, and the catalog owner throws `invariantViolation` for archive and remove.
- A Project without a `gitRoot` has no Worktree actions. The Project row stands for its single Worktree.
- The plain lifecycle refuses the rows of a Workspace Project and the member checkouts of a Workspace. See [Workspace](workspace.md).
- For a detached HEAD, the row and the header show `Detached HEAD @<7-character SHA>`.
- `archived`, `archivedAt`, and `isPinned` are optional on decode and are not written at their default values. A new `Worktree` field must follow this pattern, so that older catalogs still decode.

## Lifecycle

```
   create ──► pending ──git ok──► row ◄── reconcile: new path on disk
              (memory)             │ ▲
                 │                 │ │ unarchive
          fail: Retry / Discard    ▼ │
                              archived ◄── archive, or reconcile: path gone
                                   │
    row or archived ──remove (forced)──► gone: directory, branch, row
```

### Git outside the catalog owner

`HierarchyManager` holds the catalog and starts no process. Git work runs in `GitWorktreeClient` or `GitService`, off the main actor. The catalog changes only after the git step succeeds. If the git step succeeds and the catalog write fails, Retry repeats only the write. No path deletes a directory on failure.

`GitWorktreeClient` is the only place that starts git for Worktree operations. It uses the bundled `wt` script (`git-wt` submodule) for listing (`wt ls --json`) and creation (`wt sw`), and plain `git` for the rest. The build fails if the submodule is missing.

### Create

The directory is `<base>/<sanitized branch name>`. The base comes from the per-Project setting, then the global default, then `~/.codans/repos/<project name>`. An existing directory stops the creation; no suffix is added. The sheet refuses a name that matches a local branch (case-insensitive) and names the branch or the Worktree, visible or archived, that holds it.

After Create, a **pending row** shows progress. It lives in reducer memory only: it is not a catalog row and has no Tabs. Creation fetches `origin` if it exists, runs `wt sw`, then runs the Project `createScript` in the new directory. A failed or slow setup script does not stop the creation, because the directory already exists. The path of the new Worktree is the entry that `wt ls --json` shows after `wt sw` and not before, not the output text of `wt sw`.

The new row goes to the top of the unpinned rows. Cancel during `wt sw` writes nothing. Cancel during the setup script still writes the row.

### Creation lease

Creation puts the directory on disk before it writes the row. A reconcile in that window would add the row first, at the end of the list. To prevent this, each creation holds a lease on its Project. While a Project holds a lease, reconcile adds no rows; it still syncs branches and archives stale rows.

- Each exit path releases its lease, after the catalog write. Release is idempotent.
- A pending row whose catalog write failed keeps its lease until Retry or Discard.
- When the last lease of a Project is released, the Project reconciles once, to pick up Worktrees made outside the app in the meantime.

### Reconcile

Reconcile compares `wt ls --json` with the rows of a Project. It runs at launch, when the app becomes active, each hour, and for one Project after an add, a HEAD change, the release of the last lease, and `codans worktree prune`.

- A path on disk without a row gets a new row at the end of the list.
- A row whose path is on disk gets its branch and SHA updated. Its name follows only if it was equal to the old branch.
- A row whose path is gone is archived and its Pane sessions stop. The main checkout, pinned rows, and archived rows do not change.
- **An empty discovery set archives nothing.** A healthy repository always reports its main checkout, and `wt ls --json` can print an empty list with exit code 0 when git fails. See the [lesson learned](../lessons-learned/2026-08-25-disk-full-auto-archived-worktrees.md).
- Reconcile never deletes a row. A discovery error is logged and changes nothing.
- A Project without a `gitRoot` is probed on each reconcile and becomes a git Project when a repository appears.

### Archive and unarchive

Archive hides a Worktree. It stops the session of each Pane, keeps the Tabs and Panes in the catalog, and moves the selection to another visible Worktree. It does not touch the directory or the branch. An archived Worktree cannot be selected. Interactive archive asks for confirmation each time ([ADR 0011](../adrs/0011-worktree-archive-and-delete-chords-are-window-wide.md)); the sidebar flow first stops the run scripts and runs the Project `archiveScript`, whose exit code does not stop the archive. "Archive All Merged" archives each Worktree whose Pull Request is merged.

Unarchive ("Archived Worktrees…" in the Project menu) clears the flag. It does not restart the Pane sessions and does not change the selection.

### Remove

Removal is destructive and is always forced, after one confirmation that names the loss of uncommitted changes. The order is:

1. Close all surfaces of the Worktree, because the next step moves the directory.
2. Move the directory to a trash folder, then `git worktree prune` (fallback `git worktree remove --force`). This skips the git checks for submodules and uncommitted changes. A background task deletes the trash.
3. Delete the branch with `git branch -D`, and the remote branch first if the setting asks for it. A branch that another Worktree has checked out stays, with a notice. A failure here does not stop the removal.
4. Remove the catalog row.

The sidebar flow runs the Project `deleteScript` before step 1. The Archived Worktrees sheet and the automatic cleanup skip it. The automatic cleanup (Settings → Worktrees) removes archived, unpinned rows older than the set period, on each reconcile of a local git Project.

### Prune

"Prune Stale Worktrees" runs `git worktree prune` and reports the count. It deletes nothing on disk. The next reconcile archives the rows of the pruned registrations.

## Row order

The rows below a Project are in four segments:

| Segment | Members | Order |
|---|---|---|
| main | The main checkout | One row |
| pinned | Pinned rows | Catalog array order |
| pending | Creations in progress | Order of submission |
| unpinned | All other visible rows | Catalog array order |

- The order in a segment is the relative order of its rows in `Project.worktrees`. There is no sort index and no second order table, the same rule as for Projects ([ADR 0001](../adrs/0001-project-order-is-manual-only.md)).
- A drag moves a row only inside its segment. Rows of other segments and archived rows keep their positions.
- Pin moves a row to the end of the pinned segment; unpin to the top of the unpinned segment. A new row goes to the top of the unpinned segment, a discovered row to the end.
- When `moveNotifiedWorktreeToTop` is on, a Worktree that gets its first unread notification moves to the top of the unpinned segment. A pinned row never moves.

## Branch switcher

A click on the branch line of the header opens the switcher. It lists local branches, then remote branches, read in one `git for-each-ref` call so that the list stays consistent during a fetch. A local branch checked out in another Worktree is blocked. A remote branch switches to the local branch of the same name, or creates a tracking branch. Row menus add "New Branch From…" and "Rename…".

- The switch runs `git switch` with **no pre-check** for uncommitted changes. If git refuses, its first stderr line shows in a dismissable banner.
- **One refresh path.** After a switch the reducer sets nothing. git writes HEAD, `WorktreeHeadWatcher` reports the change, the Project reconciles, and `RootFeature` sends `headChangedForCurrentWorktree`, which stops the spinner and clears the caches. Do not add a second path.
- The branch list is cached until the selected Worktree or its HEAD changes. A change of the selected Worktree cancels the switcher effects in flight.
- Hidden: the reducer loads the 10 most recent commits; no view shows them.

## Foreground tasks

A Worktree has live foreground tasks, at most one per Pane, kept in memory only. The name of a task prefers the launch record of a Run script or agent launch of the app. The tab hover card is the only view; the per-Worktree list is Hidden. See [Terminal Runtime](terminal-runtime.md) for the sampling rules.

## Traps

- A crash during creation loses the pending row. If the directory exists, the next reconcile adds it as a row, at the end of the list.
- `codans worktree rm` without `--delete` removes only the row. The next reconcile adds it again if the git worktree still exists.
- A Worktree removed outside the app is archived, not removed, by the next reconcile. A pinned row stays visible.
- Unarchive does not restart the Pane sessions that archive stopped.
- A `git fetch` in a Pane does not refresh the cached branch list of the switcher.

## Shape of the implementation

```
 HierarchySidebar ───────► HierarchyClient ──► GitWorktreeClient, GitService (git, off main actor)
   (pending rows,                 │
    confirmations,                └── on success ──► HierarchyManager (catalog: rows, order,
    lifecycle scripts)                                flags, leases, reconcile merge)
 ProjectReconciler, WorktreeHeadWatcher ── decide when reconcile runs
```

The sidebar reducer starts the interactive flows. `HierarchyClient` joins git and the catalog for the multi-step flows (create stream, forced removal). `HierarchyManager` is the single owner of the rows and applies each change only after git succeeds.

## Related decisions

- [ADR 0001](../adrs/0001-project-order-is-manual-only.md): the catalog array is the order.
- [ADR 0011](../adrs/0011-worktree-archive-and-delete-chords-are-window-wide.md): scope and chords of Archive Worktree and Delete Worktree, and the archive confirmation.
- [Lesson learned: a full disk archived every Worktree](../lessons-learned/2026-08-25-disk-full-auto-archived-worktrees.md): why an empty discovery set archives nothing.
