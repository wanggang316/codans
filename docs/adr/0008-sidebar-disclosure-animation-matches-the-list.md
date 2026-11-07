# 0008. The sidebar disclosure animation follows the owner's reference

Status: Accepted. Supersedes decisions 3 and 4 of
[ADR 0007](0007-sidebar-animates-user-expansion-only.md).

## Context

ADR 0007 made user toggles animate with the native `NSOutlineView` expand and
collapse animation and the system duration, and turned the chevron over the
same duration. In the Debug build the owner found that it did not feel right.

The owner gave a reference recording of the sidebar animation they want. The
recording was measured frame by frame, at its real frame times: the position
of a row's text (2 px = 1 pt) and its ink (the sum of its contrast with the
background, which grows in step with opacity).

- **Rows below the toggled row** move like a critically damped spring with
  ω ≈ 23 /s (a response of about 0.27 s), in both directions: half of the
  distance after about 85 ms, 90 % after 180 ms, 99 % after 300 ms. The fit is
  within 1 % at every frame.
- **Expand, child rows.** They are hidden for about 55 ms, about 14 pt above
  their place. Then they fade in (about 30 % at 60 ms, 65 % at 95 ms, 95 % at
  145 ms) while they slide down on the same spring (about 10 pt above at 95 ms,
  4.5 pt at 145 ms, 1 pt at 245 ms).
- **Collapse, child rows.** They fade out about linearly (about 90 % at
  45 ms, 55 % at 95 ms, 45 % at 110 ms) while they move up faster and faster
  (about 1 pt at 45 ms, 2 pt at 60 ms, 5 pt at 95 ms, 7 pt at 110 ms). They
  are gone at about 125 ms. The rows below slide up over them.
- **Chevron.** It turns at the start, in about 50–60 ms.

## Decision

1. **Rows below.** A user toggle inserts or removes the child rows inside one
   table update. The table moves the other rows over 0.32 s on the cubic curve
   (0.30, 0.40, 0.15, 0.98), the closest fit to the spring above (within
   about 0.6 %). `NSTableView` animates rows with a duration and a curve, not
   a spring.
2. **Child rows.** The table's own fade of inserted and removed rows runs over
   the whole update, so the outline adds its own fade and move to the child
   row layers after the table's, with the shapes measured above. The times
   and distances are in `SidebarDisclosureTiming`. A close starts from the
   opacity and offset an open that is still running has reached, so a fast
   second toggle turns the animation around without a jump.
3. **How rows open.** `NSOutlineView` has no expand animation like this. For
   an animated open, the outline opens the row while its data source reports
   no children, then inserts the children, and the children of each open
   child. For an animated close, it removes the children, then closes the row.
   The open state still comes only from the catalog.
4. **Chevron.** The chevron turns in 0.06 s with an ease-out curve, at the
   start of the row animation.
5. **Unchanged from ADR 0007.** Only user toggles animate (decision 2), with
   the same rule on every level (decision 1). Reduce Motion makes every change
   instant (decision 5). A toggle during an animation goes to the latest
   catalog state and does not queue (decision 6).

## Reasons

- The owner chose the look from a recording, so the numbers come from that
  recording, measured with the same method on both recordings.
- Table row inserts and removals move the other rows in one animation, and a
  later change turns them around.
- Inserting rows with no children first keeps the outline's own open state in
  step with the catalog at every moment, so the keyboard and accessibility
  read the same state as before.

## Trade-offs

- The times are constants in code, not system values. They need a change if
  the reference changes.
- The rows below follow a cubic curve, not a real spring, so they differ from
  the reference by up to about 0.6 % of the distance.
- The child row animations are layer animations next to the table's own. They
  are not kept on the layer when they end, because the table reuses row
  views.

## Reconsider when

- The sidebar leaves `NSOutlineView`.
- AppKit can animate table rows with a spring.
