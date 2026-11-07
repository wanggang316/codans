# 0008. The sidebar disclosure animation fades rows and turns the chevron fast

Status: Accepted. Supersedes decisions 3 and 4 of
[ADR 0007](0007-sidebar-animates-user-expansion-only.md).

## Context

ADR 0007 made user toggles animate with the native `NSOutlineView` expand and
collapse animation and the system duration, and turned the chevron over the
same duration. In the Debug build the owner found that it did not feel right.
The child rows slide in from under their parent, and the chevron turns
slowly.

The owner gave a reference recording of the sidebar animation they want. Its
frames show this:

- **Expand, about 0.25 s.** The child rows fade in (opacity 0 → 1) at their
  final positions. The rows below slide down with an ease-out curve: fast at
  the start, slow at the end, no overshoot.
- **Collapse, about 0.2 s.** The child rows fade out while they move up a few
  points. The rows below slide up over them.
- **Chevron, about 0.05 s.** It turns at the start, much faster than the rows.

This is the row animation of a SwiftUI `List` on macOS, which inserts and
removes table rows with a fade.

## Decision

1. **Rows.** A user toggle inserts or removes the child rows with the table's
   fade animation (`NSTableView.AnimationOptions.effectFade`). The other rows
   move with the same animation. On collapse, the child rows also move up
   10 pt while they fade: the outline adds that move to their layers, because
   the table's `.slideUp` moves them by their whole height. Expand runs
   0.25 s and collapse 0.2 s, both ease-out.
2. **How.** `NSOutlineView` has no fade expand. For an animated open, the
   outline opens the row while its data source reports no children, then
   inserts the children, and the children of each open child. For an
   animated close, it removes the children, then closes the row. The open
   state still comes only from the catalog.
3. **Chevron.** The chevron turns in 0.06 s with an ease-out curve, at the
   start of the row animation.
4. **Unchanged from ADR 0007.** Only user toggles animate (decision 2), with
   the same rule on every level (decision 1). Reduce Motion makes every change
   instant (decision 5). A toggle during an animation goes to the latest
   catalog state and does not queue (decision 6).

## Reasons

- The owner chose the look from a recording; the fade and the curve are what
  made the native outline animation feel wrong.
- Table row inserts and removals animate other rows with them, and a later
  change turns them around, so a fast second toggle needs no extra code.
- Inserting rows with no children first keeps the outline's own open state in
  step with the catalog at every moment, so the keyboard and accessibility
  read the same state as before.

## Trade-offs

- The times are constants in code (`SidebarDisclosureTiming`), not the
  system values. They need a change if the reference changes.
- The 10 pt lift is a layer animation the outline adds next to the table's
  own fade. It is not kept on the layer, because the table reuses row views.

## Reconsider when

- The sidebar leaves `NSOutlineView`.
- AppKit adds an expand animation that fades rows.
