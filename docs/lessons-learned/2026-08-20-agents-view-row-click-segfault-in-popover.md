# Lessons Learned: clicking an Agents View row segfaults inside the hover card

**Status:** Resolved
**Date:** 2026-08-20
**Area:** App / SwiftUI ↔ AppKit bridge (`AgentStateRowView`, `AgentSessionSummaryCard`)
**Fix:** `fix(agents-view): present the hover summary card from a frozen snapshot`

## Summary

Clicking a row in the Agents View panel killed the app instantly —
`EXC_BAD_ACCESS (SIGSEGV)` at address `0x0` on the main thread, with no in-app
frame anywhere in the stack:

```
0   ???                    0x0
1   __CFRUNLOOP_IS_CALLING_OUT_TO_AN_OBSERVER_CALLBACK_FUNCTION__
2   __CFRunLoopDoObservers
3   _CFRunLoopRunSpecificWithOptions
4   -[NSMoveHelper _doAnimation]
5   -[NSResizeMoveHelper animateResizeToFrame:]
6   -[NSWindow setFrame:display:animate:]
7   -[NSPopover _setContentView:size:canAnimate:]
8   SwiftUI.PopoverHostingView.updateAnimatedWindowSize(_:)
9   SwiftUI.NSHostingView.windowDidLayout()
...
16  -[NSWindow(NSConstraintBasedLayoutInternal) layoutIfNeeded]
17  __NSWindowGetDisplayCycleObserverForLayout_block_invoke
19  NSDisplayCycleFlush
20  CA::Transaction::run_commit_handlers(CATransactionPhase)
```

Read from the bottom up: a CoreAnimation commit runs AppKit's display cycle,
the display cycle lays out the popover's window, SwiftUI notices its hosted
content wants a different size, and asks AppKit to resize the popover window
**with animation**. `-[NSWindow setFrame:display:animate:]` spins a *nested run
loop* to drive that animation — from inside the CATransaction commit handler.
Re-entering the update cycle that way calls a run-loop observer whose callback
pointer is already `NULL` (the registers name `UC::LoopTapCFRunLoop` and carry
the freed-memory scribble `0xa1a1a1a1`), and the process dies.

The popover is the Agents View hover summary card — the only popover in the app
whose content changes after it is presented.

## Root cause

The card was a live view onto its sources, and every iteration of it had at
least one thing that changed the card's **height** while it was on screen:

- the first iteration (v0.4.20) called `viewportSnapshot()` on every render, so
  the terminal tail (0–8 lines) tracked the pane as the agent worked;
- the session-task iteration replaced that with an async `.task` scan whose
  result (`session`) lands *after* the popover opens, adding a divider, a
  2-line title and a footer in one step — a guaranteed resize on nearly every
  card, typically 100 ms–seconds after it opens (SSH for Server projects);
- the activity line followed the pane's OSC title live, appearing and
  disappearing as the agent worked;
- a `TimelineView(.periodic(by: 1))` re-laid-out the card once a second.

Any of those makes SwiftUI request an animated popover-window resize from
inside the display cycle — the mechanism above.

The click supplied the second half. The row's `Button` action both dismissed
the popover and ran the full focus cascade
(`selectProject → selectWorktree → selectTab → focusPane → focusSurfaceView`,
which tears down and rebuilds pane surfaces) synchronously. Landing that
cascade on a stack that already holds a nested run loop and a half-torn-down
popover is what turned a fragile path into a crash.

## The fix

Two changes, both in the AgentState feature:

1. **The card is a still frame, not a live view.**
   `AgentSessionSummarySnapshot` holds everything the card renders — entry,
   names, the featured session, the filtered activity line, both ages already
   formatted. It is built by the row's hover-dwell task, and the session scan
   happens *there*, before presentation: `.popover(item:)` opens a card that is
   already complete, so its rendered size **cannot change** while it is up.
   The ticking `TimelineView` went with it; a per-second re-layout of a popover
   is the same hazard on a slower clock.
   Cost: hovering a Server-project row now waits for the SSH scan before the
   card appears, instead of opening an empty card that grows.
2. **The focus cascade leaves the click's stack.** `handleTap` clears the card
   and hands `onTap()` to the next main-loop turn, so pane teardown/rebuild
   never runs inside the SwiftUI transaction that is closing the popover.
   `onDisappear` now also clears the snapshot, so a row that leaves the list
   (re-sort, pane closed) can't strand a popover on a dead anchor.

## Rule for the codebase

**A SwiftUI `.popover` must not change size while presented.** If its content
comes from live state or from an async load, resolve it *before* presenting and
render from that snapshot. The Agents View card was the only one doing this,
but any popover that opens on a spinner and then fills in — PR checks, GitHub
badges, session history — is one async completion away from the same shape.

## Verification

- `AgentSessionSummarySnapshotTests` — age frozen at capture, redundant OSC
  titles dropped, session age formatted only when a session is featured.
- `make mac-build` clean; `AgentSummaryCardFormat` tests still pass.
- The crash itself is a race and was **not** reproduced deterministically; the
  diagnosis rests on the crash report's frame chain, which names the mechanism
  unambiguously (animated popover window resize driven from
  `NSHostingView.windowDidLayout` inside a CA commit).

## How to recognize a recurrence

A crash report with `PopoverHostingView.updateAnimatedWindowSize` above
`-[NSWindow setFrame:display:animate:]` and `NSMoveHelper _doAnimation` below a
`CA::Transaction` commit is this bug, whatever the top frame looks like — the
faulting address will be garbage or `0x0` because the freed observer is a system
object, so there will be no in-app frame to blame. Find the popover whose
content changed size, not the code near the crash.
