# 0011. A layout transition resizes each terminal one time

Status: Accepted

## Context

Arrange and Place change the frames of all Panes of a Tab. An animated change
reads better than an instant one, so each Pane frame moves from its old
rectangle to its new rectangle in about 200 ms with an ease-out curve.

A terminal surface that gets a new size reflows its grid. A resize on each
animation frame causes about a dozen reflows per Pane per transition. The cost
grows with the scrollback size, and the zmx daemon of a Pane can exit when a
reflow runs out of memory.

## Decision

1. During a layout transition the Pane views animate their frames, and the
   terminal surfaces keep their old grid size.
2. When the transition ends, each surface whose size changed gets one resize to
   its final size.
3. When the system setting "Reduce motion" is on, the new layout appears with
   no transition and each surface gets one resize.

## Consequences

- During the transition the terminal content does not fill its Pane exactly.
  The mismatch shows for about 200 ms only.
- A program in the Pane gets one `SIGWINCH` per transition, not one per frame.

## Reconsider when

The surface can reflow cheaply on each frame, or a transition becomes longer
than a short animation.
