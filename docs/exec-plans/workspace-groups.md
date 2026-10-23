# Workspace Groups Execution Plan

## Objective

Implement spec issue #268: a Workspace holds a starred `default` group and
named groups; each group expands to its member checkouts. Terms are in
[GLOSSARY.md](../../GLOSSARY.md); product rules are in
[workspace.md](../design-docs/workspace.md) ("工作区组设计"). This plan
resolves what the spec defers: schema, migration, runtime mapping,
orchestration API, sidebar, settings, CLI/IPC, deletion preflight, and tests.

## Base branch and catalog version

Build on `main` (integration branch `feat/workspace-groups`). The catalog
model is the current one: `Worktree.tabs`, each `Tab` with a split tree of
`Pane`s.

- `main` has catalog version 3. `Catalog.init(from:)` rejects every other
  version (`Catalog.swift:61`), and `CatalogStore.load` moves such a file to
  `backups/` and starts empty. There is no migration path.
- This work migrates the catalog from version 3 to version 4 and adds a
  minimal migrate-on-load path (see "Catalog load path").

## Coordination with #265

PR #265 (pane layout) also claims catalog version 4 with its own v3 → v4
migration and loader. Whichever PR lands second renumbers its schema to the
next version and chains its migration after the other one (v3 → v4 → v5),
and reuses the other loader instead of keeping two. Keep the workspace
migration a separate pure function on a decoded `Catalog` so it can move
behind either migration without changes.

## Persisted schema

### Catalog version 4

Two new fields. Both use `decodeIfPresent` with a default, and the encoder
omits them at the default value.

| Type | Field | Meaning |
|---|---|---|
| `Project` | `workspaceGroups: [WorkspaceGroupRecord]` | Workspace only. Ordered: `default` first, then named groups in creation order. A cache of the manifest for synchronous launch rendering, plus UI state. |
| `Worktree` | `workspaceSlot: WorkspaceSlot?` | Workspace rows only. `{ groupID, role }` with `role ∈ { groupTerminal, reference, member }`. |

`WorkspaceGroupRecord`: `id: WorkspaceGroupID`, `name`, `kind ∈ { default,
named }`, `isExpanded` (default `false`), `deletion: GroupDeletionState?`
(present while a destructive delete has unresolved items).

- `WorkspaceGroupID` lives in `CodansCore/IDs.swift` next to the other IDs.
- Roles: `groupTerminal` is the row for the group directory (one per group).
  `reference` is a default member; its `path` is the source main checkout.
  `member` is a checkout that the group owns (named groups, including the
  migrated `existing` group).
- The version bump stops version 3 builds from reading the file, so they
  cannot strip the new fields. Unknown-field tolerance alone does not
  protect the data. Version 3 builds move a version 4 file aside and start
  empty; this is existing released behavior and the migration backup (below)
  keeps the version 3 copy for a downgrade.

### Manifest version 2

New file `<root>/.codans/workspace-groups.json` (`WorkspaceLayout`
constant). New builds never write `<root>/.codans/workspace.json` (version 1)
again. Version 1 writers discard unknown keys; a separate file keeps their
writes and the new data apart, and the untouched version 1 file stays the
pre-migration copy.

```json
{
  "schemaVersion": 2,
  "title": "Checkout Flow",
  "description": "optional",
  "taskLinks": [],
  "projects": [
    { "name": "app", "sourceGitRoot": "/Users/me/dev/app" },
    { "name": "lib", "sourceGitRoot": "/Users/me/.codans/sources/lib", "remoteURL": "git@github.com:org/lib.git" }
  ],
  "groups": [
    { "id": "…", "name": "default", "kind": "default", "path": "default" },
    { "id": "…", "name": "existing", "kind": "named", "path": ".", "origin": "migrated",
      "members": [
        { "id": "…", "name": "app", "path": "app", "sourceGitRoot": "/Users/me/dev/app",
          "checkoutMode": "newBranch", "branch": "feat/checkout", "baseRef": "origin/main" }
      ] },
    { "id": "…", "name": "fix-login", "kind": "named", "path": "fix-login", "branch": "fix/login",
      "createdAt": "2026-10-23T00:00:00Z",
      "members": [
        { "id": "…", "name": "app", "path": "fix-login/app", "sourceGitRoot": "/Users/me/dev/app",
          "checkoutMode": "newBranch", "branch": "fix/login", "baseRef": "origin/main",
          "createdBranch": true }
      ] }
  ],
  "createdAt": "…",
  "updatedAt": "…"
}
```

- `projects` is the source list. It defines `default` membership and the
  member set of future groups. Named groups keep their own `members`.
- `default` has no `members`; they derive from `projects`. There is exactly
  one `default` group. The name `default` is reserved for it.
- `path` values are relative to the root, lexically normalized, and must not
  escape it. `.` is valid only for a migrated group. Group and member paths
  are unique; no member path is inside another group's directory.
- `createdBranch` records that the group created the branch. Deletion uses
  it to decide which branches it may offer to delete (see Deletion).
- `branch` on a group is the creation-time branch. It is a record, not
  identity; members keep their own live branch.
- Decoding is strict on structure and tolerant only on optional fields.
  `validate()` rejects the rules above with typed errors.

### Unsupported and damaged versions

| Input | Behavior |
|---|---|
| Catalog version < 3 | Unchanged rule: move to `backups/`, start empty. |
| Catalog version 3 | Migrate in memory to 4, copy the original to `backups/`, write version 4 at once. |
| Catalog version > 4 | Leave the file in place, keep a copy in `backups/`, disable saving, start empty, and show an alert at launch ("Created by a newer Codans; changes are not saved"). |
| Manifest v2 `schemaVersion` > 2 | Project `loadState = .failed("Created by a newer Codans")`. No reconcile, no writes, no fallback to version 1. |
| Manifest v2 unreadable or invalid | Same `.failed` state with the reason. Never re-migrate from version 1 over it. Retry re-reads. |
| Only version 1 present | Migrate (below). |
| Neither file | Existing D4 rule: `.failed`, marker kept. |

`WorkspaceManifestStore.hasManifest` returns true for either file, so
`WorkspaceMarkerRepair` and add-folder detection see both layouts.

## Migration

### Catalog load path

Small and rule-based; no general framework.

- `Catalog.DecodingIssue` gains `newerVersion(Int)`. `Catalog.init(from:)`
  accepts version 3 and 4; it records the source version so the store knows
  a migration is due. Version 3 decodes with the same tolerant field rules
  (the new fields are absent).
- `CatalogMigrationV3ToV4.migrate(_ catalog: Catalog) -> Catalog`
  (`CodansCore/Persistence/`) is pure and runs on the decoded value.
- `CatalogStore.load`:
  1. Decode. Version 3 → migrate in memory.
  2. Copy the original file with `StoreBackup.prepareURL(…, reason:
     .migrated(fromVersion: 3))` (copy, not move). If the copy fails,
     disable saving and return the migrated catalog in memory only.
  3. Write version 4 at once (`saveNow`), then run the existing repairs
     (`RemoteHostSidecar`, `WorkspaceMarkerRepair`).
  4. `newerVersion` → copy to `backups/` (reason `.unsupported`), leave the
     file, set `persistenceEnabled = false` and `loadIssue = .newerVersion`,
     return `.default`. `CodansApp` shows one alert at launch.
  5. Other decode errors keep the current rule (move aside, start empty).
- Repeat execution: the migration is deterministic. A crash before step 3
  re-runs it on the same version 3 file with the same result; an extra backup
  copy is harmless (`StoreBackup.prune` keeps the count bounded).

### Catalog 3 → 4 workspace rows

For each Project with `isWorkspace`:

1. Create the group records `default` and `existing` with deterministic IDs:
   `WorkspaceGroupID.derived(rootPath:, key:)` = first 16 bytes of
   SHA-256 of `"codans.workspace-group|<key>|<rootPath>"` (same technique
   as `workspaceFetchGroupID`). Keys: `default`, `existing`.
2. The row at `rootPath` becomes `existing`'s `groupTerminal`. It keeps its
   ID, tabs, panes, and pane IDs (session identity).
3. Every other row becomes `existing`'s `member`, archived rows included.
4. `selectedWorktreeID` is unchanged, so selection stays on the same row.

A workspace with no rows other than the root still gets `existing`, so the
root row keeps its sessions.

### Manifest 1 → 2 (`WorkspaceManifestMigration`, CodansCore)

Runs inside the workspace reconcile (`HierarchyClient.reconcileWorkspace`)
through `WorkspaceManifestStore.loadOrMigrate(rootPath:)`:

1. If version 2 exists, load it. Stop.
2. Load version 1. Build version 2 in memory: `projects` = distinct
   `sourceGitRoot` values of the entries (name from the entry's repository
   folder, deduplicated with `-2`); `existing` group (`path: "."`) = every
   entry as a `member`, `createdBranch` absent (unknown); `default` group
   with `path` = first free name of `default`, `default-2`, … under the root.
   Group IDs use the same derivation as the catalog migration. Member IDs
   derive from `rootPath` and the member path.
3. A version 1 manifest with no entries still yields `existing` (no
   members), to match the catalog migration.
4. Write version 2 atomically (`AtomicFileStore`). Do not modify, move, or
   delete version 1.

Repeat execution: step 1 makes it a no-op once version 2 exists. A crash
before the write repeats the same deterministic result. A second app
instance (dev or test channel) on the same root computes the same IDs.

### Default links

`WorkspaceDefaultLinks.sync(rootPath:manifest:)` (CodansCore, FileManager
only) runs after every manifest load in the reconcile and after source-list
changes:

- Create the default directory if missing; create `<default>/<name>` →
  `sourceGitRoot` for each project.
- Replace a link only when it is a symbolic link with a different target.
- Remove a link only when it is a symbolic link and its project is no longer
  listed.
- Never touch a non-link entry; log it and report it as a reconcile note.

## Runtime mapping

The four-level hierarchy stays. A Workspace is still one `Project`. Every
selectable row is a `Worktree`, so tabs, panes, notifications, agent state,
and `codans tree` keep their paths.

| Sidebar row | Catalog row | `path` | Terminal cwd | Git target |
|---|---|---|---|---|
| Workspace header | `Project` only (no row) | — | — | — |
| Group | `Worktree`, role `groupTerminal` | group directory (canonical) | group directory | none |
| Default member | `Worktree`, role `reference` | source main checkout (canonical) | same | source repository |
| Named member | `Worktree`, role `member` | `<root>/<group>/<name>` (canonical) | same | `sourceGitRoot` |
| Migrated `existing` | `groupTerminal` = old root row | Workspace root | Workspace root | none |

Rules:

- `Project.rowWorktree` returns nil for a workspace. The header is not a
  terminal and is not selectable. `childWorktrees` is not used for a
  workspace; the sidebar uses the group projection (below).
- `HierarchyManager.addProject(isWorkspace:)` no longer seeds a root row for
  a new workspace. New workspace creation registers groups through the
  reconcile.
- Canonical path rules:
  - Never store a path that goes through a default link. A reference row
    stores the canonical source path; the default group row stores the
    canonical default directory.
  - Inside one workspace Project, the canonical path is unique per row, so
    the reconcile still matches rows by canonical path and keeps their IDs.
  - A reference and the source Project's main row share one canonical path.
    `Catalog.workspaceMembership` (command guards) and
    `WorkspaceMembershipIndex.update` (display, cached in
    `HierarchyManager.workspaceMemberships`) count only role `member`; the
    index must also rebuild when slots change, not only when paths change. A source main row therefore gets no workspace badge and
    no mirror guard, and `removeMirrorRows` can never select it.
  - Ownership for deletion is lexical: a path is owned only when its
    standardized form (no symlink resolution) is inside the canonical root,
    is a recorded group or member path, `lstat` says it is not a symbolic
    link, and its canonical form is not equal to or inside any
    `sourceGitRoot` of `projects`. `WorkspaceOwnership` (CodansCore) is the
    single check; every deletion path calls it.
- Environment: panes in workspace rows keep `CODANS_ROOT_PATH` = root and
  `CODANS_WORKSPACE_ROOT`. Add `CODANS_WORKSPACE_GROUP` (group name) and
  `CODANS_WORKSPACE_GROUP_DIR` (canonical group directory) to
  `CodansEnvironment.Key` / `BuiltinEnvVar`. Other Projects remove them.
- Reconcile (`HierarchyManager.reconcileWorkspaceGroups`, replaces
  `reconcileWorkspaceChildren`) takes the manifest groups plus observations
  (canonical path, exists, live branch, `repositoryRoot`) and:
  - writes `workspaceGroups` from the manifest, keeping `isExpanded` and
    `deletion` by group ID;
  - matches each expected row by canonical path, sets its `workspaceSlot`,
    refreshes `branch` / `sourceGitRoot` in place, never renames;
  - appends missing rows for existing directories;
  - soft-archives `member` rows whose directory is gone (D9); keeps
    `reference` rows whose source is gone and marks them unavailable
    (transient), because the source is not the Workspace's to archive;
  - leaves rows the manifest does not name unchanged and logs them;
  - never deletes rows.
- `HEAD` watchers: a reference shares the source main path; the existing
  double-mount acceptance covers it.
- GitHub: `RootFeature.gitHubFetchUnits` keeps grouping by
  `Project.repoRoot(for:)`; `groupTerminal` rows have no repo root and are
  skipped. The pull-request summary moves from the Workspace header to each
  group row and counts that group's rows only.
- Notifications rollup (`CodansApp` `RollupIndex` input): group rows are
  visible when the Workspace is expanded; member rows only when their group
  is expanded.

All `HierarchyManager` / `HierarchyClient` changes for this feature belong
to the runtime ticket. Later tickets call the new client closures and do not
edit those files.

New `HierarchyClient` closures (forwarding to `HierarchyManager`):
`setWorkspaceGroupExpanded(projectID, groupID, Bool)`,
`setWorkspaceGroupDeletion(projectID, groupID, GroupDeletionState?)`,
`removeWorkspaceRows(projectID, worktreeIDs)` (tears down surfaces, removes
rows, never touches disk), `workspaceGroupBusyPanes(projectID, groupID)`
(pane IDs where `HierarchyManager.paneIsBusy` is true, run-script panes
included), and the reworked
`addWorkspaceProject(name, rootPath)`.

## WorkspaceClient orchestration API

`WorkspaceClient` stays the only mutation route for GUI and IPC. Declare
the full surface in the runtime ticket (unimplemented stubs), then implement
each part in its own file (`WorkspaceClient+Sources.swift`,
`WorkspaceClient+Groups.swift`, `WorkspaceClient+Deletion.swift`) so
parallel tickets do not edit the same lines.

| Closure | Behavior |
|---|---|
| `createWorkspace(WorkspaceSourcePlan) async throws -> ProjectID` | Validate root (D12/D17), resolve sources to main checkouts (local Project, local path normalized to repository root, or remote clone per D19/D20), write manifest v2 with `default` only, sync links, register, reconcile. No branch is created or switched. Rollback: created root and clones only. |
| `addSource(projectID, WorkspaceSource) async throws` | Append to `projects`, sync links, reconcile. Named groups unchanged. |
| `removeSource(projectID, sourceGitRoot) async throws` | Remove from `projects`, unlink, `removeWorkspaceRows` for the reference row. Never calls checkout deletion; never touches the source directory. |
| `groupCreationDefaults(projectID) async -> [MemberCreationOptions]` | Per source: base ref (project override, else default remote branch), fetch, copy ignored, copy untracked, agent profile, setup command — the same sources `CreateWorktreeFeature.seeded` uses; unregistered sources use global settings. |
| `preflightGroup(WorkspaceGroupPlan) async -> WorkspacePreflight` | Collected issues per project: branch syntax, local branch exists (blocks, names the project), base ref missing, directory exists, name reserved or duplicate. |
| `createGroupStream(WorkspaceGroupPlan, token) -> AsyncThrowingStream<WorkspaceCreationEvent, Error>` | See phases below. `cancelCreation(token)` reused. |
| `checkGroupDeletion(projectID, groupID) async -> GroupDeletionCheck` | Preflight (see Deletion). |
| `deleteGroup(projectID, groupID, GroupDeletionRequest) async throws -> GroupDeletionOutcome` | Destructive delete; re-runs the check. |
| `removeWorkspace(projectID, WorkspaceRemovalRequest) async throws -> WorkspaceRemovalOutcome` | `sidebarOnly` or `deleteOwnedFiles`. |

`createGroupStream` phases:

1. Preflight again; any blocking issue fails before I/O.
2. Checkout phase, per member in source order: optional fetch (D21), then
   `GitWorktreeClient.createWorktreeStream` with `pathOverride` =
   `<root>/<group>/<name>`, `copyIgnored` / `copyUntracked` from the member
   options, and `setupCommand: nil`. Record ledger steps
   (`createdDirectory`, `createdBranch` only when the branch did not exist
   before, `addedWorktree`).
3. Any checkout failure or cancel: roll back the ledger in
   `Task.detached` (existing pattern), emit `rolledBack(failures)` with each
   residual path and reason, and finish with the error. Nothing is written
   to the manifest or catalog.
4. All checkouts done: write the group to manifest v2, reconcile, emit
   `registered(groupID, memberRowIDs)`.
5. Setup phase: run each member's setup command in its directory
   (extract the setup runner from `createWorktreeStream` into
   `GitWorktreeClient.runSetupScript`). A failure emits
   `setupFailed(member, reason)`; the group stays.
6. The stream finishes with `GroupCreationResult` (member row IDs, agent
   profile per member, setup failures). The caller launches agents through
   the existing `launchAgentInWorktree` path in `RootFeature`, after the
   stream ends, so no agent starts before all checkouts exist.

The old `create` / `add` / `drop` / `remove` closures and the
`WorkspacePlan` checkout-mode creation are replaced. Keep
`WorkspaceMaterializationLedger`, `RemoteHeads`, clone, and fetch helpers.

## Deletion

### Preflight (`GroupDeletionCheck`)

For each `member` row of the group, collected without side effects:

- Uncommitted changes: `git status --porcelain=v1 -z --untracked-files=all`
  (`GitCommand.status`) count.
- Unpushed commits: with an upstream, `git rev-list --count @{upstream}..HEAD`;
  without one, `git rev-list --count HEAD --not --exclude=refs/heads/<branch>
  --branches --remotes` (commits no other ref holds); detached HEAD uses
  `HEAD --not --branches --remotes`.
- Running terminals: busy contents in the member rows and the group row
  (`workspaceGroupBusyPanes`).
- Group directory content: entries in the group directory that are not
  member checkouts (named groups only; never for path `.`).
- Branches the delete-branch option would delete: the member's current
  branch only when `createdBranch` is true, the branch is not checked out in
  another worktree, and it is not the repository's default branch. The
  confirmation lists them.

A check that fails (git error, missing repository) is a `checkFailed` item.
Any `checkFailed` blocks deletion; the UI offers Retry. Risks require
`acknowledgeRisks: true` in the request. `deleteGroup` re-runs the check and
throws `risksNotAcknowledged(check)` or `checkFailed(check)`, so IPC cannot
skip it.

### Execution

1. Set `deletion = { deleteBranches, startedAt }` on the group (catalog) and
   in manifest v2.
2. Tear down surfaces of all group rows.
3. Per member: `GitWorktreeClient.removeWorktree(repoRoot: sourceGitRoot,
   path)` (relocate-then-prune, force), delete the branch if selected, remove
   the member from the manifest, remove its row and mirror rows
   (`removeMirrorRows`, members only). A failure keeps the member and its
   row and is recorded with its reason.
4. If every member is gone: delete the group directory only when
   `WorkspaceOwnership` allows it and the path is not `.`; remove the group
   from the manifest and remove its terminal row. A migrated `existing`
   group keeps the root directory and `.codans`.
5. Otherwise keep the group with `deletion` set. The sidebar shows it with
   the failed members, their reasons (transient) and Retry. After a restart
   the group shows "Deletion incomplete" and Retry re-runs the check.

`default` cannot be deleted (`cannotDeleteDefault`).

### Workspace removal

- `sidebarOnly`: remove the catalog entry. Disk unchanged.
- `deleteOwnedFiles`: check every named group (one combined check, same
  acknowledgment rules), delete each named group as above, unlink default
  links and remove the default directory, then delete the root only when
  every group is gone and `WorkspaceOwnership` allows it. Remove the catalog
  entry only on full success. On partial failure keep the Workspace with the
  failed groups in their `deletion` state.
- Both actions keep every source main checkout.

## Sidebar projection and selection

- `Catalog+Sidebar`: add `Project.workspaceSidebarRows` → ordered
  `[WorkspaceSidebarRow]`: `.group(record, terminalRow)` followed, when the
  group is expanded, by `.member(row)`. `default` first. Archived rows and
  rows without a slot are left out (rows without a slot stay visible in
  `codans tree`).
- Indentation: header 0, group rows 14 (current child inset), members 28.
- `Catalog.sidebarFilter` (All / categories / pull-request filter) applies
  to member rows; a group row stays visible while any of its members
  matches, and the group is shown expanded for the filtered view only.
- Group row: name, star (`star.fill`) for `default` placed before the name,
  member count, branch summary (single branch name, or "N branches"),
  pull-request summary, disclosure chevron on hover. Selecting it selects
  the `groupTerminal` row (List `.tag(worktreeID)`).
- Member row: branch on the first line, folder name on the second
  (`rowLabels`), reference rows show an `arrow.up.right` link glyph.
- Header row: not selectable; click toggles Workspace expansion. Controls on
  the right: `+` (New Group…), `⋯` (Workspace Settings…, Add Project…,
  Remove Workspace…), expand chevron.
- Groups start collapsed (`isExpanded` default false) and toggle
  independently (`toggleWorkspaceGroupExpansion`).
- Selection reveal: selecting a member in a collapsed group (CLI, palette,
  restored selection, notification) expands that group first, like the
  existing Project reveal.
- Context menus: group row → Delete Group… (named), Pin; member row → no
  Archive / Remove / Delete; `default` reference → Remove from Workspace…
  (calls `removeSource`).
- `HierarchySidebarFeature` guards repeat the UI rules
  (`worktreeArchiveTapped` / `worktreeRemoveTapped` reject every workspace
  row; shortcuts cannot bypass them).

## Settings

The Workspace settings `workspace` section ("Projects") lists the source
projects of `projects`: name, source path, live branch of the reference.
Add Project… opens the add-source sheet; Remove calls `removeSource` after a
confirmation that names the running terminals of the reference row. Group
creation defaults come from each source Project's existing settings; no new
settings keys.

## CLI and IPC

Methods go through `WorkspaceHandlers` → `WorkspaceClient` only. Wire types
in `CodansIPC/WireTypes/WorkspaceWireTypes.swift`.

| Method | CLI | Change |
|---|---|---|
| `workspace.create` | `codans workspace create <title> --project <path>…` | Sources only. Branch or checkout fields → `invalidParams` ("branches belong to `workspace group create`"). |
| `workspace.add` | `codans workspace add <workspace> <path>` | Adds a source project (default reference). |
| `workspace.drop` | `codans workspace drop <workspace> <project>` | Removes a source project. A named member → `conflict` ("delete its group"). |
| `workspace.createGroup` (new) | `codans workspace group create <workspace> <name> --branch <b> [--base <project>=<ref>]… [--no-fetch] [--copy-ignored] [--copy-untracked] [--agent <profile>]` | Waits for the result; reports setup failures. |
| `workspace.checkGroupDeletion` (new) | `codans workspace group delete … --dry-run` | Returns the check. |
| `workspace.deleteGroup` (new) | `codans workspace group delete <workspace> <group> [--delete-branches] [--discard]` | Without `--discard`, risks → `conflict` with the risk list; exit 1. |
| `workspace.remove` | `codans workspace remove <workspace> [--delete-files] [--discard]` | `deleteFiles` now means delete owned files; source checkouts kept. |
| `workspace.describe` | `codans workspace show` | Returns `projects` and `groups[{id, name, isDefault, path, deletion, members[{name, path, branch, sourceGitRoot, role}]}]`. |
| `hierarchy.describe` | `codans tree [--json]` | Worktree gains `workspaceGroup {id, name, role}`; text output nests group rows. |
| `hierarchy.removeWorktree` / `createWorktree` | — | Any workspace row → `conflict` / `invalidParams`. |

Update `skills/codans-cli/SKILL.md` and `docs/design-docs/cli.md` with the
new verbs. Old flag shapes fail with a clear message; no silent forwarding.

## Tickets and sequence

1. Core schema, migrations, and the catalog load path (CodansCore,
   `CatalogStore`, launch alert in `CodansApp`).
2. Runtime mapping and reconcile (owns `HierarchyManager`, `HierarchyClient`,
   `ProjectReconciler`, env keys; declares the
   `WorkspaceClient` surface; extracts the test fixture).
3. Sources and group creation in `WorkspaceClient`.
4. Deletion preflight, group deletion, Workspace removal in `WorkspaceClient`.
5. Sidebar projection, selection, expansion, header controls, GitHub summary.
6. IPC and CLI.
7. Add-Workspace and New-Group sheets, agent launch wiring.
8. Deletion dialogs, Workspace removal dialogs, Settings source list.
9. Native acceptance flow and documentation status.

Edges: 1 → 2; 2 → 3, 4, 5; 3 + 4 → 6; 3 + 5 → 7; 4 + 5 → 8; 6 + 7 + 8 → 9.

## Test strategy

- CodansCoreTests (host-free): manifest v2 codec and `validate()`;
  manifest 1 → 2 (different member branches, `default` name collision,
  empty manifest, determinism); catalog 3 → 4 with legacy fixtures (IDs,
  paths, branches, tabs, pane IDs, selection preserved); `WorkspaceOwnership` (symlinked default
  paths, `.` group, paths outside root); `WorkspaceDefaultLinks` on a temp
  directory; sidebar projection (`CatalogSidebarTests`).
- `CatalogStore` tests (`PersistenceVersioningTests` pattern): version 3
  file migrates with a backup copy and writes version 4; repeat load does not
  duplicate groups; version 5 stays in place, saving off, issue reported;
  failed backup copy disables saving; damaged file never returns a silently
  saved empty catalog.
- `HierarchyManagerWorkspaceTests` / `HierarchyClientWorkspaceReconcileTests`
  (real git): migrated identity (row IDs, panes, tabs, selection) after
  reconcile and after reload; repeat reconcile is stable; branch switch keeps
  member identity; missing source keeps the reference; membership excludes
  references; env vars per role.
- `WorkspaceClientTests` seam (real git, real `CatalogStore`,
  `FakeHierarchyRuntime`): add Workspace without branch creation or switch;
  source add/remove changes `default` only; group creation with per-project
  base/fetch/copy settings; branch conflict names the project; checkout
  failure rolls back all members and reports residuals; setup failure keeps
  the group; setup runs only after every checkout exists (ordering is the
  contract); deletion with dirty files, unpushed commits, busy terminals,
  failed check, partial failure, retry; source checkouts and other groups
  intact, including the migrated root group and default links.
- TCA TestStore: `CreateWorkspaceFeatureTests` (add mode, group form
  defaults, per-project errors, retained input, progress, failure and
  residual display); `HierarchySidebarFeatureTests` (initial collapse,
  independent expansion, selection and reveal, guarded deletion, retry).
  Stub new `HierarchyClient` closures in sidebar tests (see notes).
- `WorkspaceHandlersTests` / `WorkspaceCommandsTests`: one contract test per
  new or changed method, plus rejection of old shapes and of unacknowledged
  risks.
- Native acceptance (final ticket): isolated dev instance only. Add two
  projects, expand `default`, open group and member terminals and check
  cwd, create two named groups, switch a member branch, change source
  membership, restart, delete a group with a visible risk, observe a failed
  item retained. Check indentation, star placement, header controls, and
  selection with screenshots.
- Per ticket: format and lint changed files only; run the affected suites
  with `-only-testing:` at suite level and check the test count. Report
  automated results, migration evidence, and native acceptance separately.

## Status

Planned. No implementation yet.
