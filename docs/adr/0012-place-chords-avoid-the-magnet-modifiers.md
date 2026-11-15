# 0012. The Place chords do not use the Magnet modifiers

Status: Accepted

## Context

Place moves the focused Pane into a half, a third, or two thirds of its Tab.
The window manager Magnet uses `⌃⌥` with arrows and letters for the same
regions of a screen. Magnet registers these chords as global hotkeys, so they
never reach codans when Magnet runs. Many users of codans also use Magnet or a
similar window manager.

`⌃⌘F` is the system chord for full screen, so the Magnet letter group
(`D`/`F`/`G` for thirds, `E`/`T` for two thirds) cannot move to `⌃⌘` either.

## Decision

1. The four half regions have default chords `⌃⌘←`, `⌃⌘→`, `⌃⌘↑`, `⌃⌘↓`.
2. The third and two-thirds regions have no default chord. The user can bind
   them in Settings → Shortcuts, and they are in the Command Palette.

## Implementation note

`⌃⌘↑` and `⌃⌘↓` are already the default chords of Select Previous / Next
Worktree (ADR 0002). Two commands cannot share a default chord, so the top and
bottom halves ship with no default chord, like the thirds. Only the left and
right halves have default chords: `⌃⌘←` and `⌃⌘→`.

## Reconsider when

A chord group for thirds is found that has no conflict with the system, with
common global window managers, or with the existing codans chords.
