# Workspace

A Workspace is a Project that spans several source projects. One task often touches more than one repository, for example an app, its API, and a shared library. A Workspace puts the checkouts of these repositories under one Project, so one sidebar entry holds their terminals, agents, notifications, and Pull Requests. The Workspace root is a plain folder, not a repository.

Availability: Available. A Workspace and its source projects are local; a Remote Project cannot be either.

## Scope and ownership

This page owns the Workspace model, its manifest, the Workspace reconcile, and the Workspace operations. Neighbor topics:

| Topic | Owner |
|---|---|
| The plain Worktree lifecycle (create, archive, remove, reconcile) | [Worktree](worktree.md) |
| Pull Request fetching and the per-repository fetch units | [Git Platform](git-platform.md) |
| Sidebar rows, indentation, and the header | [Main Window](main-window.md) |
| Assembly of the Pane environment | [Environment](environment.md) |
| `codans workspace` verbs and flags | [CLI](cli.md) |

## Model

A Workspace has a list of **source projects** (local repositories, each named by its repository root) and a set of **workspace groups**. Each group holds one **member checkout** per source project.

```
 Workspace (a Project, root folder <root>/)
   ├─ default workspace group ── references ──► main checkout of each source project
   │                                             (owned by the source, not the Workspace)
   └─ named workspace group "feat/abc"
        ├─ member checkout app  ── linked worktree of ──► source project app
        └─ member checkout lib  ── linked worktree of ──► source project lib
```

- The **default workspace group** is named `default`. There is exactly one, and it cannot be deleted. Its members are the existing main checkouts of the source projects, on whatever branch each one is. Adding a Workspace or a source project creates no branch, switches no branch, and creates no git worktree.
- A **named workspace group** owns its member checkouts. At creation, every member gets a new branch with one shared name. After that, a member may switch branches: membership refers to the worktree, not the branch. The branch on the group is a record of the creation, not an identity.
- The source list defines the members of `default` and the members of future groups. A change to the source list changes `default` only. An existing named group keeps the members it was created with.
- A named group has no operation to add or remove one member. A group is created and deleted as a whole.

### Rows

The Workspace keeps the four-level hierarchy. The Workspace is a Project without a row of its own: its header is not selectable and opens no terminal. Each selectable row is a real `Worktree` row, so Tabs, Panes, notifications, agent state, and `codans tree` work as for any Worktree. `Worktree.workspaceSlot` gives the group and the role of each row:

| Role | Path of the row | One per |
|---|---|---|
| `groupTerminal` | The group directory | group |
| `reference` | The canonical main checkout of the source project | source project, in `default` |
| `member` | `<root>/<group folder>/<project name>` | source project, in a named group |

- A terminal of a group row starts in the group directory. A terminal of a member or reference row starts in that checkout.
- The catalog never stores a path through a symbolic link. Inside one Workspace, each row has a unique canonical path, so the reconcile matches rows by path and keeps their IDs.
- A reference row and the main row of the source Project have the same path. Only `member` rows count as Workspace membership: a source Project shows the checkout of a named group as a mirror row with a Workspace marker, but its main checkout gets no marker and no guard.

### On disk

```
<root>/
  .codans/workspace-groups.json      manifest
  default/app -> /Users/me/dev/app   symbolic link to each source main checkout
  feat-abc/app/                      member checkout (linked worktree of app)
  feat-abc/lib/
```

The group folder comes from the group name with the same rule as the Workspace folder from its title: lowercase, and each run of other characters becomes one dash. So `feat/abc` is the folder `feat-abc`. The group name and the default branch name keep the original text. The `default` links let a group terminal reach all main checkouts. The default root of a new Workspace is `~/.codans/workspaces/<folder>`, and a source cloned from a remote goes to `~/.codans/sources/<repository>`.

## Sources of truth and the reconcile

Three stores hold Workspace data, each for one kind of fact:

- **The manifest** (`<root>/.codans/workspace-groups.json`) defines the source list, the groups, the members of each named group, and how each member was created (base ref, and whether the group created the branch).
- **git** gives the live facts: the current branch of each checkout and the repository it belongs to. The reconcile reads them each time. A manifest that is wrong or edited by hand can give a wrong name, but it cannot make the app act on the wrong repository.
- **The catalog** holds the rows (with their Tabs and Panes) and `Project.workspaceGroups`: a copy of the group records, so the sidebar can draw the groups at launch before the reconcile, plus UI state (`isExpanded`, and `deletion` while a delete is not complete).

The Workspace reconcile runs in the same places as the plain reconcile, but it branches off **before the git-root probe**. A Workspace root is never probed for a git root: if the root were inside a repository, the probe would adopt that repository, and the plain reconcile would archive every row.

The reconcile reads the manifest, syncs the `default` links, observes each expected row (exists, branch, repository root), and merges into the catalog:

- It writes the group records from the manifest and keeps the UI state by group ID.
- It updates `branch` and `sourceGitRoot` of a row in place. It never renames a row, and never changes its ID when the branch changes.
- It adds a row for each expected directory that exists and has no row.
- A `member` row whose directory is gone is archived. A `reference` row whose source is gone stays, marked unavailable in memory: the source is not the Workspace's to archive.
- Rows that the manifest does not name stay as they are and are logged. The reconcile never deletes a row.
- Link sync creates, retargets, and removes only symbolic links. It never touches another entry in the `default` folder.

## Persisted formats

- **Catalog.** `Project.isWorkspace`, `Project.workspaceGroups`, `Worktree.workspaceSlot`, and `Worktree.sourceGitRoot` are optional on decode and are not written at their default values. `sourceGitRoot` is saved so that branch rules and Pull Request fetching can find the repository of a row at launch, before the reconcile. A catalog from before groups migrates on load: the old root row becomes the group row of a named group `existing`, every other row becomes its member, and all row, Tab, and Pane IDs stay. See [Architecture › Persistence](../architecture.md#persistence) for the catalog version rules.
- **The Workspace flag is sticky.** When the catalog loads, a local Project whose root holds a manifest gets the flag back, because a build that does not know the flag can drop it. A Workspace whose manifest is missing, unreadable, invalid, or of a newer schema stays a Workspace in the failed state ("Created by a newer Codans" for a newer schema). It does not reconcile or write, and it never becomes a folder Project.
- **Manifest.** The current schema is 2, in `workspace-groups.json`. Decoding is strict on structure and tolerant only on optional fields, and validation rejects bad paths: each group and member path is relative, normalized, inside the root, and unique, and the name `default` is reserved. A root with only the schema 1 file (`workspace.json`) is migrated: the reconcile writes the schema 2 file with an `existing` group that holds the old members, and does not change the schema 1 file. Schema 1 is never written and never used as a fallback when the schema 2 file exists. The migration is deterministic, so a repeated run, or a second app instance on the same root, gives the same group IDs.
- The `existing` group has the path `.`: its group directory is the Workspace root. Its members can be on different branches. Deleting it removes its member checkouts but never the root.

## Operations

All operations go through `WorkspaceClient`. The sidebar sheets, the Workspace Settings, and the `workspace.*` IPC methods behind `codans workspace` call the same client, so the GUI and the CLI apply the same checks.

### Create a Workspace, add or remove a source project

New Workspace… (in the Add Project menu of the sidebar, the New Agent project menu, and the command palette) asks for a title, a location, and the source projects: a registered local Project, a local folder, or a remote URL. A folder inside a repository resolves to its repository root. The client refuses a root inside a git repository, a bare repository, and a clone folder that holds something other than a clone of that remote (a clone of the same remote is reused). It writes a manifest with only `default`, creates the links, registers the Project, and reconciles. On failure it deletes only what it created: the root and the clones of this run.

Add Project… on the Workspace header and in the Projects section of Workspace Settings adds a source. Remove from Workspace… on a reference row, and Remove in Settings, remove a source. Both change only the source list, the links, and the reference rows. Remove never deletes the source directory and never calls checkout deletion.

### Create a named group

New Group… (the `+` on the Workspace header, or `codans workspace group create`) takes a name, one branch name for all members (the sheet uses the group name when it is empty), and for each source project: base ref, fetch, copy ignored files, copy untracked files. The defaults come from the settings of each source Project, or the global settings for an unregistered source. The GUI does not start agents for the members; the CLI `--agent` option starts one after the group exists.

1. **Preflight.** Blocks on: a reserved or duplicate name, a group folder that exists, a local branch with that name in any source project (named per project), or a base ref that does not exist. The client runs it again before any I/O.
2. **Checkouts.** For each source project in order: optional fetch, then a new linked worktree on the new branch in the group folder. A ledger records each folder, branch, and worktree it creates.
3. **On failure or cancel,** the ledger is undone in reverse order. Nothing is written to the manifest or the catalog. Paths that the rollback could not remove are reported with the reason.
4. **When all checkouts exist,** the manifest is written and the Workspace reconciles. Only then do the setup scripts run, one per member. A failed script keeps the group and is reported.

### Delete a named group

Delete Group… on a named group row (Retry Deletion… while a delete is not complete), or `codans workspace group delete`. `default` has no delete.

The **check** runs first and has no side effects. For each member it looks for uncommitted changes, unpushed commits (ahead of the upstream, or with no upstream, commits that no other branch or remote ref holds), and busy terminals in the group rows. It also lists entries in the group folder that are not member checkouts, and folders left by an earlier removal that the source repository no longer lists. Rules:

- A risk needs explicit acknowledgment ("Discard these changes and stop the terminals", or `--discard`).
- A check that cannot run blocks the delete and offers Retry. Unknown is never treated as safe.
- The delete runs the check again on the server side, so an IPC client cannot skip the acknowledgment.
- The optional branch delete offers only branches the group created, and never the default branch of the repository or a branch that another worktree has checked out.

The **delete** records `deletion` in the manifest and the catalog, stops the terminals of all group rows, then removes each member through its source repository (forced). A failed member stays in the manifest with its row and its reason, and the delete continues with the next member. The group folder, the group record, and the group row go only when every member is gone. Otherwise the group row shows "Deletion incomplete" with Retry. The failure reasons are in memory only; after a restart, Retry runs the check again.

### Remove a Workspace

Remove Workspace… on the Workspace header, or `codans workspace remove`, gives two choices:

- **Remove from Sidebar** removes the catalog entry. Nothing on disk changes.
- **Delete Workspace Files…** checks all named groups and the busy terminals of the `default` rows together, with one acknowledgment. It deletes each named group as above, then the `default` links and folder, then the root when only `.codans` is left in it. The catalog entry goes only when every group is gone. A partial failure keeps the Workspace and the failed groups in their `deletion` state.

Neither choice deletes a source main checkout.

### Ownership rule for deletion

`WorkspaceOwnership` is the single check before any Workspace path is deleted. A path is owned only when it is strictly inside the root (compared without symlink resolution), it is a group or member path that the manifest records, no component from the root down is a symbolic link, and its canonical form is not inside a source project. The root itself is never owned. Every delete path must call this check, so that a delete cannot follow a `default` link into a source checkout.

## What the plain lifecycle refuses

Workspace rows belong to the Workspace operations. The plain Worktree lifecycle refuses them:

- The sidebar shows no Archive, Remove, or Delete on any Workspace row, and the reducer guard also refuses the keyboard chords.
- A mirror row of a named-group checkout in its source Project has no Archive or Remove either. The "All Merged Worktrees" items of the Project menu leave it out.
- `hierarchy.createWorktree` on a Workspace returns `invalidParams`. `hierarchy.removeWorktree` on a Workspace row or a mirror row returns `conflict`, with a pointer to `codans workspace drop` or `codans workspace group delete`.

## Pane variables

A Pane in a Workspace row gets `CODANS_WORKSPACE_ROOT` (the root). A Pane in a row with a slot also gets `CODANS_WORKSPACE_GROUP` (the group name) and `CODANS_WORKSPACE_GROUP_DIR` (the canonical group directory). In other Projects the app removes these names, also when the Project `envVars` set them, so their presence means "inside a Workspace". `CODANS_ROOT_PATH` is the Workspace root.

## Pull Requests

A Workspace has one fetch unit for each source repository, not one for the Project. The units come from the `sourceGitRoot` of the reference and member rows; group rows have no repository and are left out. The ID of a unit is derived from the Workspace ID and the repository root, so it is stable across launches. The group row shows a summary of the Pull Requests of its own rows only ("3 PRs · 1 merged"), and a branch summary (one branch name, or "N branches").

## Traps

- **Old builds share the dev catalog.** A build without Workspace support runs the git-root probe on the root. This is why a Workspace root must not be inside a repository, and why the flag is restored from the manifest at load.
- **A forced removal that fails half way** can remove the worktree registration and leave a plain folder. The next check reports it as "Folder left by an earlier removal"; after acknowledgment, the delete removes the folder through the ownership check and runs `git worktree prune` in the source.
- **Remove a source before you reconcile.** The reconcile leaves rows the manifest does not name, so removing a source must remove its reference row itself.
- **A clone from a remote stays** after its source is removed or the Workspace is deleted. Only a failed creation deletes the clones it made.
- **A reference row is the source's checkout.** Files changed in it are changed in the source Project, and a reference row has no Archive or Remove.

## Shape of the implementation

```
 Sidebar sheets, Workspace Settings ──┐
 WorkspaceHandlers (workspace.*)    ──┴─► WorkspaceClient ──► manifest + links (CodansCore/Workspace)
                                              │            ──► GitWorktreeClient (checkouts, removal)
                                              └─► HierarchyClient ──► HierarchyManager (rows, group records)
 ProjectReconciler ── manifest health ──► HierarchyClient.reconcileWorkspace
```

`CodansCore/Workspace/` holds the pure parts: the manifest types and store, the migration, link sync, the ownership check, and the membership index. It starts no process. `WorkspaceClient` orchestrates every mutation and owns rollback and the deletion check. `HierarchyManager` is the single owner of the rows and the group records, and starts no process.
