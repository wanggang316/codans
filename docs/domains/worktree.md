# Worktree

A Worktree is one `git worktree` of a Project: a checkout of one branch in its own directory, with its own Tabs and Panes. This domain covers how Worktree rows enter and leave the catalog, the order of the rows, the status slot and the branch switcher of the selected Worktree, and the foreground task of each Pane.

Availability: Available, with two Hidden parts. The recent commits that the branch switcher loads have no view. The per-Worktree process list has no view; only the tab hover card shows a process.

## Scope and ownership

This domain owns:

- Creation, discovery (reconcile), archive, unarchive, removal, and prune of Worktrees.
- The order of Worktree rows below a Project row.
- The status slot in the window toolbar: which of three forms it shows.
- The branch switcher of the header.
- The process registry: one live foreground task for each Pane.

Other pages own the neighbor topics:

| Topic | Owner |
|---|---|
| Sidebar, header, and tab bar layout; tab hover card | [Main Window](main-window.md) |
| Pull Request data, the Pull Request form of the status slot, the action after a merge | [Git Platform](git-platform.md) |
| Worktrees of a Remote Project (SSH transport, remote paths) | [Remote Projects](remote-projects.md) |
| Workspace rows, groups, and member checkouts | [Workspace](workspace.md) |
| Storage of global and per-Project settings | [Settings](settings.md) |
| Unread state that moves a Worktree up | [Notifications](notifications.md) |
| Diff window and Git Viewer | [Git Diff Viewer](git-diff-viewer.md) |
| `codans worktree` verbs | [CLI](cli.md) |
| Default chords | [Keyboard Shortcuts](keyboard-shortcuts.md) |

## Behavior and invariants

### Common rules

- `HierarchyManager` holds the catalog and starts no process. Git work runs in `GitWorktreeClient` or `GitService`, off the main actor. The catalog changes only after the git step succeeds.
- `GitWorktreeClient` is the only place that starts git for Worktree operations. It calls the bundled `wt` script (`git-wt`) for `wt ls --json` and `wt sw`, and plain `git` for the other commands.
- A `WorktreeID` is made when `HierarchyManager.createWorktree` writes the row. No ID exists before that.
- All path comparisons use the canonical path (`HierarchyManager.canonicalPath`, symlinks resolved). `createWorktree` canonicalizes the path that it stores.
- In one Project, two rows cannot have the same canonical path or the same name.
- The main checkout is the row whose `path` equals `Project.rootPath`. It cannot be archived, removed, pinned, or dragged. The menus leave the items out, and `HierarchyManager` throws `invariantViolation` for archive and remove.
- A Project without a `gitRoot` has no Worktree actions. The actions are not shown.
- The plain Worktree lifecycle refuses each row of a Workspace Project and each row that a Workspace lists as a member checkout. See [Workspace](workspace.md).

### Create

Entry points: the `+` row of a Project, "New Worktree…" in the main menu and the command palette, the New Agent view, and `codans worktree new`.

- The directory is `<base>/<sanitized branch name>`. The base is, in order: the per-Project `worktreesDirectory`, then `<defaultWorktreesDirectory>/<project name>`, then `~/.codans/repos/<project name>`.
- `GitWorktreeClient.sanitizeBranchName` removes `\0`, `:`, and `\`, and keeps `/` as a directory separator. If the directory exists, creation stops with an error. No suffix is added.
- The sheet does not permit a name whose sanitized form matches a local branch (the comparison ignores case). It shows which branch or which Worktree, visible or archived, has the name.
- The sheet closes on Create. A pending row then shows the progress. A pending row is in reducer memory only (`HierarchySidebarFeature.State.pendingWorktrees`). It is not a catalog row and it has no Tabs. A Project can have a maximum of 8 pending rows.
- The local stream (`createWorktreeStream`) does these steps: optional `git fetch origin` (only if the repository has an `origin` remote), `wt sw` with the optional copy of ignored and untracked files, then the setup phase.
- The setup phase runs the Project `createScript` in the new directory. A script that does not start, exits with a non-zero code, or runs past its deadline does not stop the creation and does not remove the Worktree.
- Deadlines: 20 minutes for `wt sw`, 60 minutes for the setup script. At the deadline the command and its child processes stop.
- The path of the new Worktree is the entry that `wt ls --json` shows after `wt sw` and did not show before. The output text of `wt sw` is not the source.
- The new row goes to the top of the unpinned segment. The catalog write does not select it. `RootFeature` selects it if the auto-switch setting is on, and starts the agent profile that the sheet selected.
- Cancel during `wt sw` stops the child process and writes nothing. Cancel during the setup phase stops the script and writes the catalog row, because the directory exists.
- Failure keeps the pending row with Retry and Discard. If the git step succeeded and the catalog write failed, Retry repeats only the catalog write. Discard never deletes a directory.
- A Remote Project runs `git worktree add` on the Host. It does not copy files and does not run `createScript`.
- `hierarchy.createWorktree` (the IPC method behind `codans worktree new`) uses the same stream for a local git Project when the path does not exist. If the path exists, it only adds the row. For a Remote Project or a Project without a `gitRoot`, it only adds the row.

### Creation lease

Creation puts the directory on disk before it writes the row. A reconcile in that time must not add the row first, because it adds rows at the end of the list.

- `HierarchyManager.beginWorktreeCreation` and `endWorktreeCreation` hold a set of lease tokens for each Project. While a Project holds a lease, reconcile does not add new rows. It continues to sync branches and to archive stale rows.
- Each exit path of a creation must release its lease. Release is idempotent.
- The release must come after the catalog write. Cancel during the setup phase sends the finish action first and then cancels the effect, for this reason.
- A pending row whose catalog write failed keeps a lease until Retry or Discard, so reconcile cannot add a second row for the path.
- When the last lease of a Project is released, the app reconciles that Project one time. This adds Worktrees that were made outside the app in the meantime.
- If a row for the path exists at the catalog write, `createWorktree(reuseExisting: true)` returns that row.

### Discover (reconcile)

`HierarchyClient.reconcileDiscoveredWorktrees` reads `wt ls --json` for the `gitRoot` and gives the entries to `HierarchyManager.reconcileDiscoveredWorktrees`. It runs:

- At launch, each time the app becomes active, and each hour. `ProjectReconciler.reconcileAll` drops calls that come less than 10 seconds after the last one.
- For one Project: after the Project is added, when the HEAD of one of its Worktrees changes (`WorktreeHeadWatcher`), when the last creation lease is released, and after `codans worktree prune`.

Rules:

- A path on disk without a row gets a new row at the end of the list. The name is the branch, or the last path component for a detached HEAD.
- A row whose path is on disk gets its `branch` and `headSHA` updated in place. The name changes only if it was equal to the old branch.
- A row whose path is not in the discovered set is archived, with its Pane sessions stopped. The main checkout, pinned rows, and rows that are archived are not changed.
- If the discovered set is empty, no row is archived. A healthy repository always reports its main checkout, so an empty set means that discovery failed. `wt ls --json` can print an empty list with exit code 0 when git fails. See the [lesson learned](../lessons-learned/2026-08-25-disk-full-auto-archived-worktrees.md).
- Reconcile never deletes a row.
- A Project without a `gitRoot` is probed for one on each reconcile. It becomes a git Project when a repository appears at its root.
- A discovery error is written to the log (`com.gumpw.codans.hierarchy`, category `reconcile`) and changes nothing.

### Archive and unarchive

Archive hides a Worktree. It does not change the directory or the branch.

- `setWorktreeArchived(true)` stops the session of each Pane (`suspendSurface`), keeps the Tabs and Panes in the catalog, sets `archived` and `archivedAt`, and moves the selection to the first visible Worktree of the Project.
- An archived Worktree cannot be selected. `selectWorktree` throws.
- Interactive archive (row menu, main menu, chord, command palette) asks for confirmation each time. See [ADR 0011](../adrs/0011-worktree-archive-and-delete-chords-are-window-wide.md).
- The sidebar flow first stops the run scripts of the Worktree, then runs the Project `archiveScript` in a temporary Tab and waits for it, then sets the flag. The exit code of the script does not stop the archive.
- Unarchive clears `archived` and `archivedAt` and does not change the selection. Entry point: "Archived Worktrees…" in the Project menu.
- "Archive All Merged" in the Project menu and the command palette archives each Worktree whose Pull Request is merged, after one confirmation.

### Remove

Entry points: "Remove Worktree" in the row menu, "Delete Worktree" in the main menu and the command palette, "Remove All Merged", the Archived Worktrees sheet, and `codans worktree rm --delete`.

- One confirmation dialog comes before the removal. It states that the directory and its uncommitted changes are deleted. The removal is always forced.
- The sidebar flow stops the run scripts, runs the Project `deleteScript` in a temporary Tab, then calls `removeWorktreeWithGit`. The Archived Worktrees sheet and the automatic cleanup call `removeWorktreeWithGit` directly and do not run `deleteScript`.
- `removeWorktreeWithGit` does these steps in order: close all surfaces of the Worktree, remove the git worktree, delete the branches, remove the catalog row. The surfaces close first because the removal moves the directory.
- Local removal first moves the directory to a trash folder, then runs `git worktree prune --expire=now`, with `git worktree remove --force` as the fallback. A background task deletes the trash folder. This order avoids the git checks for submodules and uncommitted changes. A removal on a Remote Project is `git worktree remove --force` on the Host.
- The local branch is deleted with `git branch -D`. If git refuses because the branch is checked out in a different Worktree, the removal succeeds and a notice names the kept branch.
- If the setting "Delete remote branch with worktree" is on, the remote branch is deleted before the local branch, because the upstream configuration of the local branch gives the remote. A failure there does not stop the removal.
- `codans worktree rm` without `--delete` removes only the catalog row. The next reconcile adds the row again if the git worktree exists.
- Cleanup (Settings → Worktrees): if `autoDeleteArchived` is on, each reconcile of a local git Project removes the archived Worktrees whose `archivedAt` is older than the period. Pinned rows and Workspace member checkouts are not removed. An archived row without `archivedAt` gets the current time and is not removed in that pass.

### Prune

"Prune Stale Worktrees" (Project menu, command palette) runs `git worktree prune` and shows how many registrations it removed. It deletes nothing on disk. The rows of the removed registrations are archived by the next reconcile. `codans worktree prune` runs the same command, then reconciles the Project immediately. It refuses a Remote Project.

### Row order

The rows below a Project row are in four segments, in this order:

| Segment | Members | Order in the segment | Source |
|---|---|---|---|
| main | The main checkout | One row | Catalog |
| pinned | `isPinned`, not the main checkout | Catalog array order | Catalog |
| pending | Creations in progress | Order of submission | Reducer memory |
| unpinned | All other rows | Catalog array order | Catalog |

Archived rows are in no segment. A Project without a `gitRoot` shows no row for its root: the Project row stands for that Worktree (`Project.rowWorktree`).

- The order in a segment is the relative order of its rows in `Project.worktrees`. There is no sort index and no second order table. [ADR 0001](../adrs/0001-project-order-is-manual-only.md) uses the same rule for Projects.
- A drag moves a row only in its segment (`reorderWorktrees`, segments `pinned` and `unpinned`). Rows of other segments and archived rows keep their catalog positions. If an offset is out of range, the full move is dropped.
- Pin moves the row to the end of the pinned segment. Unpin moves it to the top of the unpinned segment.
- A new Worktree goes to the top of the unpinned segment. A discovered Worktree goes to the end.
- When a Worktree goes from zero to some unread notifications and `moveNotifiedWorktreeToTop` is on, `promoteWorktree` moves it to the top of the unpinned segment. A pinned row never moves. The row does not move back when the unread state clears.
- Row IDs have a prefix (`wt:` or `pending:`), because `WorktreeID` and `PendingWorktreeID` are both UUIDs.

### Status slot

The status slot is an item of the window toolbar. `StatusBarView` shows one form, by priority:

1. Toast: `StatusBarFeature.State.toast` is not nil.
2. Pull Request: the selected Worktree has a snapshot in `GitPlatformFeature` and its state is not closed. This is the same snapshot that the sidebar badge reads.
3. Idle: the local time, a time-of-day icon, and the command palette chord.

- The toast is the only reducer state. The other two forms come from data that other features own.
- `StatusToast` has the cases `inProgress`, `success`, and `warning`. It has no error case: a fatal error uses a sheet or a banner.
- A `success` toast clears after 3 seconds and a `warning` toast after 8 seconds. An `inProgress` toast stays until a different toast replaces it or it is dismissed.
- Each push increments `State.sequence`. A clear timer clears the toast only if its sequence is the current one, so a late timer cannot clear a newer toast.
- Only `RootFeature` pushes toasts. It maps the results of child features (editor open, run script, agent launch, Pull Request actions, hand-off, workflow start) to a toast. A child feature does not send actions to the status slot.
- In a narrow window the slot shows a compact form, and then nothing.
- The slot state is in memory only.

### Header label and branch switcher

- The first line of the header label is the branch. For a detached HEAD it is `Detached HEAD @<7-character SHA>` (`Worktree.detachedHeadTitle`, also used by the sidebar row).
- A click on the first line opens the branch switcher. The line is not a button for the root row of a Project without a `gitRoot` and for a Workspace group row.
- The popover lists local branches, then remote branches, with a filter field. `GitService.listAllBranches` reads both sets with one `git for-each-ref` call, so the list is consistent during a `git fetch`.
- A local branch that a different Worktree of the same repository has checked out is shown as blocked and cannot be selected.
- A click on a remote branch switches to the local branch of the same name if one exists. If not, it runs `git switch --track`.
- A row menu has "Switch", "New Branch From…" (creates the branch and switches to it), and "Rename…" (local branches only).
- The switch runs `git switch` with no check for uncommitted changes before it. If git refuses, the first line of its stderr shows in a banner that the user can dismiss.
- After a switch the reducer sets nothing. git writes HEAD, `WorktreeHeadWatcher` reports the change (200 ms debounce), the Project reconciles, and `RootFeature` sends `headChangedForCurrentWorktree`. That action stops the spinner and clears the caches. Do not add a second refresh path.
- The branch list is cached until the selected Worktree changes or its HEAD changes. A `git fetch` in a Pane does not refresh the list.
- A change of the selected Worktree cancels all effects of the switcher in flight, so a late result cannot show on a different Worktree.
- Hidden: the reducer loads the 10 most recent commits when the popover opens. No view shows them.

### Worktree processes

`WorktreeProcessRegistry` keeps a maximum of one entry for each Pane: the live foreground task of that Pane. It is session state and is not saved. After a restart, entries come only from new samples.

Availability: the tab hover card shows the entry of its Tab (`processEntry(inTab:)`): the entry of the focused Pane, or else the oldest entry of the Tab. Hidden: `processEntries(in:)` gives the list for a Worktree, and no view shows that list.

Entry rules:

- An entry exists only while a foreground sample shows an agent or a command that is not a shell. A launch record alone never makes an entry.
- A command that the user types and a launch from the app use the same sampling path.
- An agent that waits for input stays an entry.
- The PID and the start time of the process identify the entry. If one of them changes, it is a new entry.

Name of an entry, in order:

1. The name of the launch record, while the record is valid.
2. The display name of the agent, if the sample is an agent.
3. The process name.

A launch record comes from a Run script or an agent launch of the app. It becomes invalid when:

- The process of the Pane is replaced.
- The launch was sent to a Pane that was in use, and the sampled process started before the launch request.
- 15 seconds pass with no observed entry.

A sample is invalid, and the entry is removed or hidden, in these cases:

| Case | Effect |
|---|---|
| The Pane is not in the catalog, or its Worktree is archived | The entry is removed. |
| The sample shows only a shell | The entry is removed immediately. |
| A local sample is empty | The sample is ignored. The third empty sample in sequence removes the entry. |
| The probe of a remote Host fails | The entry is hidden immediately. It comes back only if a new sample shows the same process in 30 seconds. |

A remote sample without a start time gives an entry with no start time.

The icon of an entry is the agent mark if the sample is an agent. If not, it is the tool mark that `CommandIconCatalog` has for the executable name, or the terminal symbol. The name of a Run script never selects the icon.

## Interactions and failure modes

- **`wt` not in the bundle.** `wtScriptURL` throws `GitWorktreeError.executableMissing`. The build step `verify-git-wt.sh` fails the build if the submodule is not there, and `embed-git-wt.sh` copies only the `wt` file to `Resources/git-wt/wt`.
- **git fails during discovery.** See the empty-set rule in Discover.
- **Crash during creation.** A pending row is lost. If the directory exists, the next reconcile adds it as a row.
- **Worktree removed outside the app.** The next reconcile archives its row. If the row is pinned, it stays.
- **Lock on a git worktree.** Local removal runs `git worktree unlock` first, because `prune` ignores a locked worktree and `remove --force` fails on it.
- **Archive and Pane sessions.** Archive stops the sessions of all Panes of the Worktree. Unarchive does not start them again.
- **Catalog fields.** `archived`, `archivedAt`, and `isPinned` are optional on decode and are not written when they have their default values. A new `Worktree` field must follow this pattern.

## Implementation map

- `apps/mac/CodansCore/Worktree.swift`: `Worktree`, `detachedHeadTitle`.
- `apps/mac/CodansCore/Catalog+Sidebar.swift`: `Project.childWorktrees`, `Project.rowWorktree`.
- `apps/mac/CodansCore/Settings/WorktreeSettings.swift`: `resolveBaseDirectory`, cleanup settings.
- `apps/mac/CodansCore/Settings/GitProjectSettings.swift`: `createScript`, `archiveScript`, `deleteScript`.
- `apps/mac/CodansCore/StatusBar/StatusToast.swift`: `StatusToast`.
- `apps/mac/CodansCore/Agents/ForegroundJobClassifier.swift`: shell and command classification of a sample.
- `apps/mac/codans/Git/GitWorktreeClient.swift`: `GitWorktreeClient`, `CreateWorktreeSpec`, `GitWorktreeError`, `sanitizeBranchName`, `wtScriptURL`.
- `apps/mac/codans/Git/LiveGitService.swift`: `listAllBranches`, `switchBranch`.
- `apps/mac/codans/Runtime/HierarchyManager.swift`: `createWorktree`, `removeWorktree`, `setWorktreeArchived`, `setWorktreePinned`, `reorderWorktrees`, `promoteWorktree`, `reconcileDiscoveredWorktrees`, `beginWorktreeCreation`, `archivedWorktreesDue`.
- `apps/mac/codans/Runtime/ProjectReconciler.swift`: `reconcile`, `reconcileAll`.
- `apps/mac/codans/Runtime/WorktreeHeadWatcher.swift`: `WorktreeHeadWatcher`.
- `apps/mac/codans/Runtime/WorktreeProcessRegistry.swift`: `WorktreeProcessRegistry`, `updateProcessSample`, `recordProcessLaunch`.
- `apps/mac/codans/Runtime/TerminalEngine.swift`: `processForegroundSample`.
- `apps/mac/codans/App/Clients/HierarchyClient.swift`: `reconcileDiscoveredWorktrees`, `removeWorktreeWithGit`, `runWorktreeLifecycleScript`.
- `apps/mac/codans/App/Features/HierarchySidebar/`: `HierarchySidebarFeature`, `CreateWorktreeFeature`, `ArchivedWorktreesFeature`, `SidebarOutlineModel`, `PendingWorktree`.
- `apps/mac/codans/App/Features/StatusBar/`: `StatusBarFeature`, `StatusBarView`, `WorktreeProcessIconView`.
- `apps/mac/codans/App/Features/BranchSwitcher/`: `BranchSwitcherFeature`, `BranchSwitcherView`.
- `apps/mac/codans/App/Features/WorktreeHeader/WorktreeHeaderInfoLabel.swift`: header label and popover host.
- `apps/mac/codans/App/Features/Root/RootFeature.swift`: toast routing, `worktreeHeadChanged`, blocked branches.
- `apps/mac/codans/App/Features/Socket/handlers/HierarchyHandlers.swift`: `createWorktree`, `removeWorktree`; `HierarchyHandlers+Layout.swift`: `pruneWorktrees`.
- `apps/mac/codans-cli/Commands/WorktreeCommands.swift`: `codans worktree` verbs.
- `apps/mac/scripts/verify-git-wt.sh`, `apps/mac/scripts/embed-git-wt.sh`; submodule `apps/mac/ThirdParty/git-wt/`.

Tests, in `apps/mac/codans/Tests/` unless a path is given:

- `GitWorktreeClientTests`, `CreateWorktreeFeatureTests`, `HierarchySidebarCreationLeaseTests`, `HierarchySidebarFeatureTests`.
- `HierarchyManagerWorktreeMgmtTests`, `ProjectReconcilerTests`.
- `HierarchyManagerReorderTests`, `HierarchySidebarOrderingTests`, `SidebarOutlineModelTests`, `apps/mac/CodansCoreTests/CatalogSidebarTests.swift`, `apps/mac/CodansCoreTests/WorktreeArchivedCodableTests.swift`.
- `BranchSwitcherFeatureTests`, `StatusBarTests/`.
- `HierarchyManagerProcessTests`.

## Related decisions

- [ADR 0001](../adrs/0001-project-order-is-manual-only.md): the catalog array is the order.
- [ADR 0011](../adrs/0011-worktree-archive-and-delete-chords-are-window-wide.md): scope and chords of Archive Worktree and Delete Worktree, and the archive confirmation.
- [Lesson learned: a full disk archived every Worktree](../lessons-learned/2026-08-25-disk-full-auto-archived-worktrees.md): why an empty discovery set archives nothing.
