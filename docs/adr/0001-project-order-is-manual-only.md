# 0001. Project order is manual only

Status: Accepted

## Context

The sidebar shows Projects as blocks: a Project row, followed by its worktree
rows as sibling List rows. Users reorder Projects through a separate reorder
session that the sidebar footer button opens. The session hides worktree rows
so that `ForEach.onMove` indices match `catalog.projects`.

The catalog stores a `ProjectSortMode` (`joinOrder`, `activeFirst`, `manual`)
and a per-Project `manualOrder`. The UI exposes only `manual`. The default mode
is `joinOrder`, so a user who never reorders sees Projects sorted by `addedAt`.

## Decision

1. **One order.** The Project order is the order of the `catalog.projects`
   array. There is no sort mode and no `manualOrder` field.
2. **Load-time materialization.** When a catalog has `projectSortMode` set to
   `joinOrder` or `activeFirst`, the load sorts `catalog.projects` one time
   with that mode. The order the user sees does not change. The decoder ignores
   `projectSortMode` and `manualOrder`. The encoder does not write them.
3. **Direct drag.** The user drags a Project row in the normal sidebar. There
   is no reorder session and no footer sort button.
   - A drag starts from any point on the Project row. There is no drag handle.
   - The drag moves the full Project block. Its worktree rows move with it. The
     expanded or collapsed state does not change.
   - The insertion indicator shows only between Project blocks. Over a worktree
     row, it snaps to the nearest Project block boundary.
   - Workspace Projects and Projects that failed to load are draggable.
4. **Drag under filters.** A drop resolves to "before or after visible Project
   X" by `ProjectID`, then applies to the full `catalog.projects` array. Drag
   is available for every sidebar filter and Tag filter. Hidden Projects keep
   their relative positions.
5. **No non-drag alternative.** There is no menu or keyboard command to move a
   Project.
6. **New Projects** go to the end of `catalog.projects`.

## Reasons

- With the footer button removed, no UI can select `joinOrder` or
  `activeFirst`. Keeping them keeps dead code and a second source of order.
- The array order is already the source of order for worktrees inside a
  Project segment (see [Worktree](../design-docs/worktree.md)). One rule for
  both levels is easier to keep correct.
- Finder and Xcode navigators reorder sidebar items by direct drag, not by an
  edit mode.
- A drop resolved by `ProjectID` does not depend on row indices. Thus a filtered
  list cannot point a move at the wrong Project.

## Trade-offs

- An older build that reads a catalog written under this decision finds no
  `projectSortMode`, uses `joinOrder`, and shows Projects in `addedAt` order.
  The array order on disk stays correct.
- Projects move as blocks of sibling rows, so `ForEach.onMove` does not apply.
  The drag uses `.draggable` / `.dropDestination` and draws its own insertion
  indicator. Before the implementation, a prototype must show that this
  indicator matches the native sidebar indicator.
- A drop under a filter can put a visible Project next to hidden Projects in a
  position that the user did not see.
- Users who use only the keyboard cannot reorder Projects.

## Reconsider when

- Users ask for an automatic order (for example, by recent activity).
- The sidebar moves to `NSOutlineView`, where native block drag is available.
- Accessibility needs a non-drag path to reorder Projects.
