# 0010. The Archive and Delete Worktree chords work in the whole main window

Status: Accepted

## Context

Archive Worktree and Delete Worktree are main-menu commands that act on the
selected Worktree. Their default chords are `⌘⌫` and `⌘⇧⌫`.

`⌘⌫` is also the standard "delete to the start of the line" key in a terminal
Pane and in every text field. To keep that key for the terminal, the menu
items are enabled only while the sidebar holds first responder
(`SidebarFocusObserver`).

The selection and the keyboard focus are different things. A Worktree stays
selected while the focus is in a terminal Pane, and the focus is in a terminal
Pane most of the time. In that state the chords do nothing, although the
window shows a selected Worktree.

Archive shows an explanation dialog one time per session and then runs with no
confirmation. Archive stops the daemons of all Panes of the Worktree, so the
agent sessions in those Panes are lost.

## Decision

1. **Scope.** The two commands are enabled when the main window is the key
   window and a Worktree is selected. The location of the keyboard focus in the
   main window (sidebar, terminal Pane, diff, editor, composer) does not change
   this. The commands stay disabled in the Settings window and while a sheet or
   popover is the key window.
2. **Default chords.** Archive Worktree is `⌃⌘⌫`. Delete Worktree is `⌃⌘⇧⌫`.
   These chords have no meaning in a terminal or a text field, so `⌘⌫` and
   `⌘⇧⌫` always go to the focused control. A user override stays as the user
   set it.
3. **No focus gate.** The sidebar first-responder gate is removed. A chord has
   one behavior in the whole main window.
4. **Archive confirmation.** Archive Worktree shows a confirmation dialog each
   time, from each interactive entry point (chord, main menu, row context menu,
   command palette). The once-per-session explanation is removed. The CLI and
   the automatic archive of merged Worktrees do not show the dialog.

## Reasons

- The command name says "current Worktree". The current Worktree is the
  selection, not the focused view.
- A gate on focus makes one chord do two different things in one window. The
  user cannot see which one applies.
- A chord that a text control already uses cannot be window-wide without
  taking the key from that control.
- A window-wide chord is easier to press by accident. An archive that runs
  with no confirmation can stop live agent sessions.

## Trade-offs

- Users who learned `⌘⌫` in the sidebar must learn the new chords. Settings
  lets them bind `⌘⌫` again; that binding then also fires in a terminal Pane.
- Each archive needs one more key press.

## Reconsider when

- A command can have two bindings with different scopes.
- Archive keeps the Pane sessions alive, so an accidental archive costs
  nothing.
