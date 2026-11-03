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
2. **Load-time materialization.** The encoder writes `"projectOrder": "array"`
   to mark a catalog whose array is the Project order. A catalog without the
   marker comes from an older build: the load sorts `catalog.projects` one time
   with its `projectSortMode` (`joinOrder` when the key is missing, because the
   older encoder omitted the default). The order the user sees does not change.
   The encoder does not write `projectSortMode` or `manualOrder`.
3. **Direct drag.** The user drags a Project row in the normal sidebar. There
   is no reorder session and no footer sort button.
   - A drag starts from any point on the Project row. There is no drag handle.
   - The drag moves the full Project block. Its worktree rows move with it. The
     expanded or collapsed state does not change.
   - The insertion indicator shows only between Project blocks. Over a worktree
     row of another block, the native outline shows no indicator and refuses
     the drop.
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

- An older build that reads a catalog written under this decision ignores the
  `projectOrder` marker, finds no `projectSortMode`, uses `joinOrder`, and shows
  Projects in `addedAt` order. The array order on disk stays correct. When the
  older build saves, the marker is gone, and the next load here sorts by
  `addedAt` again: the order that build showed.
- Each Project with child rows is a `Section(isExpanded:)` whose header is the
  Project row, so the outer `ForEach.onMove` moves the whole block and
  `NSOutlineView` draws the native indicator. Row-level `.draggable` /
  `.onDrop` and `ForEach.dropDestination` were tried first and did not match
  the native sidebar (drags started once per launch, the indicator lagged or
  showed inside blocks). The costs of the Section form:
  - The system Section chevron is the disclosure control; there is no custom
    chevron.
  - Native Section spacing leaves a gap above each Section header.
  - A Project with no child rows, or one that failed to load, is one plain
    row. A Section header cannot be selected with a click, and these rows must
    stay selectable. A plain row gets no Section gap above it.
- A drop under a filter can put a visible Project next to hidden Projects in a
  position that the user did not see.
- Users who use only the keyboard cannot reorder Projects.

## Reconsider when

- Users ask for an automatic order (for example, by recent activity).
- The Section form limits the sidebar (for example, a selectable row that
  needs child rows, or block spacing that a plain row cannot get). Then move
  the sidebar to an `NSOutlineView`, where block drag and row layout are under
  direct control.
- Accessibility needs a non-drag path to reorder Projects.
