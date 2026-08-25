# Lessons Learned: a full disk soft-archived every worktree in four projects

**Status:** Resolved
**Date:** 2026-08-25
**Area:** Runtime / worktree reconcile (`HierarchyManager.reconcileDiscoveredWorktrees`, `CatalogStore`, `AtomicFileStore`)
**Fix:** `fix(reconcile): never sweep stale worktrees on an empty discovery set`

## Summary

The boot volume filled up. Seven minutes later, nine worktrees across four
projects vanished from the sidebar — soft-archived, panes torn down, agents
killed. Every one of the directories was still on disk with an intact `.git`
file, and `git worktree list` reported all of them correctly once there was
space again.

Timeline, reconstructed from `archivedAt` stamps in `catalog.json` and the
unified log:

| Time | Event |
|---|---|
| 10:49:37 | macOS fires a **urgency 3 (HIGH)** CacheDelete on `/System/Volumes/Data`; only 976 KB reclaimable |
| 10:56:47.220–48.418 | 9 worktrees across 4 projects flip to `archived` — sub-millisecond apart, spanning projects |
| 11:09:38 | Second HIGH-urgency disk-pressure callback |

The signature that identifies it: **in every affected project the only survivor
was the main checkout**, and none of the archived rows were pinned. That is
exactly what `reconcileDiscoveredWorktrees` does when handed zero entries — it
skips the root and pinned rows and archives everything else.

Nothing was logged. The reconcile path only logs when discovery *throws*, and
this discovery did not throw.

## Root cause

Two independent defects lined up.

**1. `wt ls --json` cannot report that git failed.** The bundled `wt` script
(third-party submodule `khoi/git-wt`) reads git through a process substitution:

```bash
# ThirdParty/git-wt/wt — worktree_entries()
done < <(git worktree list --porcelain)
```

A process substitution's exit status is invisible to `set -euo pipefail`. When
git dies — as it does under ENOSPC — the loop simply reads nothing, the
function returns 0, and `cmd_ls` prints an empty JSON array. Reproduced with a
`git` shim that fails only `worktree list`:

```
$ wt ls --json
stdout=[[]]
exit=0
```

The caller receives a **successful, well-formed, empty** response. There is no
error to catch and no exit code to check.

**2. codans treated that empty set as ground truth.** The bidirectional sync in
`reconcileDiscoveredWorktrees` interprets "row not in the discovered set" as
"the worktree was removed outside the app" and soft-archives it — including
`runtime.closeSurface` on every pane, which is what killed the running agents.
There was no sanity check on whether the discovery could be believed.

The existing test `reconcileNeverArchivesMainCheckout` already carried the
comment *"even when `entries` is empty (e.g. transient git error)"* — the
failure mode was anticipated, but only the main checkout was defended.

### Collateral damage found while investigating

`~/.config/codans/` still held the debris of an earlier disk-full event on
2026-08-06:

- `catalog.json.broken-2026-08-06T06:20:50Z` — `CatalogStore.backupBrokenFile()`
  ran on a **save** failure and *moved the live catalog aside*. Its only caller
  was the `scheduleSave` catch block, so ENOSPC → write fails → the last good
  catalog is renamed away → next launch finds no file and loads `.default`, an
  empty project list. A transient full disk was one relaunch away from wiping
  every project.
- Two zero-byte `.catalog.json.tmp-*` files — `AtomicFileStore.writeAndFsync`
  cleaned up its temp file on rename failure but not on write/fsync failure, so
  every failed save leaked one into the directory that had no bytes to spare.

## The fix

1. **Empty discovery is never actionable** (`HierarchyManager`). A healthy repo
   always reports at least the main checkout, so zero entries can only mean
   discovery failed. The reconcile now returns append-only in that case and
   logs at `.error`. `wt` is a third-party submodule, so the invariant has to
   live on this side of the boundary.
2. **Auto-archive leaves a breadcrumb.** It is the one reconcile outcome the
   user did not ask for and it is silent in the UI, so it now logs a `.notice`
   with the count and the discovered-set size. This incident had to be
   diagnosed by archaeology on `archivedAt` timestamps because nothing else
   existed.
3. **A failed save no longer destroys the good catalog.** `AtomicFileStore.write`
   only ever renames a fully-written temp file over the target, so a failed save
   means the previous file is intact and is the best copy available.
   `backupBrokenFile()` is gone.
4. **Temp files are cleaned up on write/fsync failure too.**

## Rule for the codebase

**An empty result from an external command is a claim that needs a witness.**
Shelling out gives you three outcomes, not two: success, thrown failure, and
*success-shaped failure*. Before letting a command's output drive a destructive
action, ask what invariant the output must satisfy if the command really ran —
here, "a git repo has at least one worktree" — and enforce it locally. This
applies to every `GitWorktreeClient` closure whose result feeds catalog
mutation, not just `lsWorktrees`.

Corollary: **write failures are not corruption.** Do not respond to a failed
save by touching the previous copy. Atomic-rename persistence means the old file
is the survivor, not the casualty.

## Verification

- `reconcileSkipsStaleSweepWhenDiscoveryIsEmpty` — empty entries archive nothing.
- `reconcileKeepsPanesWhenDiscoveryIsEmpty` — and tear down no surfaces.
- Existing coverage still holds: a non-empty discovery still sweeps stale rows
  (`reconcileArchivesStaleRows`), skips pinned rows, and stays idempotent.
- The `wt ls --json` swallow was reproduced directly with a failing-git shim
  (transcript above); the codans-side guard makes that output harmless.

## How to recognize a recurrence

Worktrees disappear in a batch, and in each affected project **the only survivor
is the main checkout**, with the directories still present on disk. Check
`archivedAt` in `catalog.json` — reconcile-driven archiving stamps a whole
project within microseconds, whereas a user-driven batch (Archive all merged)
is seconds apart and leaves the *unmerged* rows behind. With this fix in place
the log now answers it directly:

```
log show --predicate 'subsystem == "com.gumpw.codans.hierarchy" AND category == "reconcile"'
```

An `empty discovery set — skipping stale sweep` line means the guard caught it.
