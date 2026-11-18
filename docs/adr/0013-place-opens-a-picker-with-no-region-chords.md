# 0013. Place opens a picker, and the Place regions have no default chords

Status: Accepted

Supersedes [0012](0012-place-chords-avoid-the-magnet-modifiers.md).

## Context

Place moves the focused Pane into a half, a third, or two thirds of its Tab.
There are 14 Place regions: four halves, three thirds in each direction, and
two two-thirds regions in each direction.

[ADR 0012](0012-place-chords-avoid-the-magnet-modifiers.md) gave the four
halves the default chords `⌃⌘←`, `⌃⌘→`, `⌃⌘↑`, `⌃⌘↓`. `⌃⌘↑` and `⌃⌘↓` are the
default chords of Select Previous Worktree and Select Next Worktree. To keep
both, the Worktree chords had to move, which changes a habit of existing
users. A chord for each region also makes the user learn 14 chords for an
operation that is not frequent.

Arrange already uses a picker: `⌘⌥L` opens the Layout picker, and a digit
applies a preset. The same model works for Place.

## Decision

1. `⌘⌥K` opens the Place picker. It is a separate overlay from the Layout
   picker, with the same look and keys: arrows and Return, Esc to close.
2. The Place picker shows each region as a thumbnail with a fixed key, in this
   order: `1`–`9`, then `A`, `B`, `C`, and so on. A key applies its region
   immediately. A region that the current Pane count cannot fill (a center
   third needs three or more Panes) is not shown, and the other regions keep
   their keys.
3. The Place regions have no default chords. Each region stays a command in
   the Command Palette and the Layout menus, and the user can bind it in
   Settings → Shortcuts.
4. Select Previous Worktree and Select Next Worktree keep `⌃⌘↑` and `⌃⌘↓`.
5. `⌃⌥` stays unused for layout defaults, because Magnet and similar window
   managers hold it as a global hotkey.

## Trade-offs

Placing a Pane takes three key presses (open, key, done) instead of one. A
user who places Panes often can bind the regions they use.

## Reconsider when

Users ask for one-chord Place for a region often enough to justify a default
chord group that has no conflict with the system, global window managers, or
the existing codans chords.
