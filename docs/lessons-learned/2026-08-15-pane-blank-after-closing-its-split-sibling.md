# Lessons Learned: a pane goes blank after its split sibling is closed

**Status:** Resolved
**Date:** 2026-08-15
**Area:** App / SwiftUI ↔ AppKit bridge (`PaneHostView`, `SplitViewportView`)
**Fix:** `fix(panes): host each pane surface in its own container view`

## Summary

Tab with two panes — an agent (Claude Code) on the left, a run-command pane on
the right. Pressing the header's **Stop** button closed the run pane as
expected, but the surviving agent pane rendered **empty**. Its process was
untouched: switching to another worktree and back brought the full terminal
content straight back.

Root cause is in the SwiftUI ↔ AppKit bridge, not in the terminal or the
catalog. A Pane's `GhosttySurfaceView` is created once per Pane and retained by
`TerminalEngine`'s registry, and `PaneHostView.makeNSView` handed **that shared
instance** straight to SwiftUI. Closing one leaf of a split collapses the
`SplitTree`, so the surviving leaf moves to a different structural position and
SwiftUI tears its host down and builds a new one. For a moment two hosts
reference the same NSView; whichever teardown runs last detaches the view the
other one is showing. The result is a live surface with no superview — an empty
pane — and because `updateNSView` was intentionally a no-op, nothing ever
re-attached it. Only a full remount (tab / worktree switch) rebuilt the host and
put the view back.

## Impact

- Any Tab where a split collapses back to a single pane: Stop on a run pane,
  closing a split with ⌘W / the context menu, a script's `onFinished`
  auto-close.
- Timing-dependent — it depends on SwiftUI's mount/teardown order for the two
  hosts — so it looks intermittent, which is what made it hard to pin down.
- The terminal content is never lost: the surface and its `zmx` daemon keep
  running, the pane just stops being on screen.

## Why it was hard

The symptom (blank pane, live process, healed by a worktree switch) is
consistent with several very different mechanisms. What was ruled out, with
evidence:

| Hypothesis | Probe | Verdict |
|---|---|---|
| `stopScript` closes the wrong pane / whole tab | read the reducer + `codans tree` after a scripted Stop | not it — only the run pane leaves the catalog |
| Surviving surface keeps a stale grid (no reflow) | `tput cols` in the surviving pane before/after collapse | not it — full width, correctly reflowed |
| ghostty occlusion stuck `false` after the rebuild | instrumented `recomputeOcclusion`, watched a live collapse | not it — occlusion returns to `true` on re-attach |
| Terminal screen cleared by a transient 0-size resize | instrumented `pushGeometry` | not it — sizes stay sane |

The decisive evidence came from a temporary `os_log` in `GhosttySurfaceView`
(`viewDidMoveToWindow` / `viewDidMoveToSuperview` / occlusion / geometry) plus a
scripted collapse driven through the real UI. It showed the surviving pane's
surface view being **re-parented into a brand-new host and passing through a
window-less state** on every collapse:

```
DIAG moveToSuperview pane=9689C6CA superview=NSView window=true
DIAG moveToWindow    pane=9689C6CA window=false   ← detached
DIAG occlusion       pane=9689C6CA visible=false
DIAG moveToWindow    pane=9689C6CA window=true    ← re-attached 35 ms later
```

That re-attach is what usually saves the pane. When the teardown lands the other
way round, nothing puts the view back.

Note the two failed reproduction attempts, worth skipping next time: a plain
`NSHostingView` harness that flips an `if/else` around a shared NSView does
**not** reproduce it (SwiftUI tears the old host down first there), and neither
does a scripted Run/Stop with `top` in the surviving pane — `top` repaints on a
timer, so it masks anything transient.

## The fix

`PaneHostView` no longer hands the shared surface view to SwiftUI. Each host
gets its own `PaneSurfaceContainerView` and re-parents the surface into it:

- `makeNSView` returns an **empty** container. Adoption happens in
  `updateNSView`, which SwiftUI runs with the container already in the tree, so
  the hand-off is a single move rather than a detach/attach pair.
- Teardown (`dismantleNSView`) never touches the surface — it can only ever drop
  an empty container, so mount/teardown order stops mattering.
- `adopt` carries a monotonic sequence number so a stale host that receives one
  last `updateNSView` cannot pull the surface back into a dying container.
- `layout()` re-adopts a surface that was detached elsewhere, so the pane
  recovers on the next layout pass instead of staying blank until a remount.

## Verification

- `CodansTests/PaneHostViewReparentTests` — five cases covering the SwiftUI
  collapse, container sizing, idempotent adoption, the stale-host ordering rule,
  and recovery-on-layout.
- Full `Codans` scheme: 1106 tests, only the pre-existing
  `HierarchyManagerAgentIdentityTests` / `PaneHostFeatureTests` baseline
  failures.
- Live: scripted Run → Stop against a real Claude Code pane in a dev instance
  (isolated `CODANS_CONFIG_DIR` + socket); the surviving pane reflows and keeps
  rendering, focus and typing still land in the right pane.

## How to recognize a recurrence

A pane renders as flat terminal background while `codans pane read <id>` still
returns its full content, and switching tab/worktree away and back restores it.
That combination means the surface is alive but off the view tree — look at the
SwiftUI hosting layer, not at ghostty or zmx.

To watch it live, log `viewDidMoveToWindow` / `viewDidMoveToSuperview` in
`GhosttySurfaceView` and drive a collapse from the real UI; a surface that ends
on `window=false` with no following `window=true` is the bug.
