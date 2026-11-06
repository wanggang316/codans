# 0007. The sidebar animates expand and collapse only when the user asks

Status: Accepted

## Context

The sidebar is an `NSOutlineView` ([ADR 0002](0002-sidebar-outline-with-host-level.md)).
The catalog owns which rows are open: `Project.isExpanded`,
`WorkspaceGroup.isExpanded`, and `collapsedSidebarHosts`.
`SidebarOutline.applyExpansion` applies that state to the outline. The move to
`NSOutlineView` kept the old `List` behavior, so rows open and close at once,
with no animation.

The open state changes for two kinds of reasons:

- **User toggles.** A click on a Host row, on a Project row or its chevron, or
  on a Workspace group row.
- **Programmatic changes.** A reveal (palette, notification, Agents View) opens
  the Host and Project of the selected row and then scrolls it to the center.
  A launch restores the saved state. A filter change rebuilds the tree. The CLI
  or another catalog write can change the state.

The outline sees only the new catalog state. It cannot tell the two kinds
apart from the state alone.

## Decision

1. **Levels.** Host, Project, and Workspace group rows all animate, with one
   rule for all three.
2. **Only user toggles animate.** Programmatic changes stay instant. The user
   toggle carries its intent from the reducer to the outline; the outline does
   not infer it from a state diff.
3. **Native animation.** The outline uses its own expand and collapse
   animation (child rows slide in or out, rows below move) with the system
   duration. No custom drawing or timing.
4. **Chevron.** The chevron turns from 0° to 90° in step with the rows, with
   the same duration.
5. **Reduce Motion.** When the system Reduce Motion setting is on, rows and
   chevron change at once.
6. **Interruption.** A toggle during an animation goes to the latest catalog
   state and can reverse the animation in progress. Toggles do not queue, and
   the row stays clickable.

## Reasons

- One rule on every level keeps one tree from looking inconsistent.
- A reveal scrolls right after it opens rows. An expand animation that runs
  with the scroll makes the rows jump. At launch, the tree must not open level
  by level.
- The native animation matches Finder and Xcode sidebars and needs no tuning.
- A chevron that jumps while the rows slide looks out of step.
- Other sidebar animations (shimmer, run-script ping dot) already respect
  Reduce Motion.
- The native outline animation can be interrupted. A queue makes fast clicks
  feel slow.

## Trade-offs

- The duration and curve cannot be tuned.
- The animated-or-not intent is one more value that passes from the reducer to
  the outline, next to the catalog state.

## Reconsider when

- A programmatic change needs to show the user where rows went, for example a
  reveal far from the current scroll position.
- The sidebar leaves `NSOutlineView`.
