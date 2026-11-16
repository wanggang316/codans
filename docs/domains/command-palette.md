# Command Palette

The command palette ("Quick Action") is a keyboard-first search overlay over the main window. The user types part of a command name, and the palette runs the selected command. It adds no new capability: each item is an action that the app already offers in a menu, the sidebar, the header, or a Ghostty keybind. The palette makes these actions fast to find and to run without the mouse.

Availability: Available.

## Scope and ownership

This page owns how the palette opens, how it builds and ranks its items, how an item runs, and the recency record. Other pages own the neighbor topics:

| Topic | Owner |
|---|---|
| The chord that opens the palette and the chords shown beside items | [Keyboard Shortcuts](keyboard-shortcuts.md) |
| What each Worktree and Project action does | [Worktree](worktree.md) |
| Workflow items and the Workflows switch | [Workflow](workflow.md) |
| Agent profile launch and Hand Off | [Agent Profiles and Handoff](agent-profiles-and-handoff.md) |
| Project and global commands | [Project Commands](project-commands.md) |
| Open in editor, Reveal in Finder | [Editor Integration](editor-integration.md) |

## Open and close

Two entry points toggle the palette: the "Command Palette" item of the app menu (with its chord), and a Ghostty keybind bound to `toggle_command_palette`, which reaches `RootFeature` through the pane action router. Both send the same toggle action. The palette is an overlay in the main window `ZStack`, not a sheet.

While the palette is open, it owns the keyboard. If a terminal surface takes first responder behind the overlay, the query field takes the focus back, so typing and IME input never go to a pane. Esc, a click outside the card, or the toggle chord closes it. Up and Down move the selection and wrap at the ends. Return runs the selected item; on an empty list, Return does nothing. A click on a row runs that row.

Each open starts with an empty query and the first item selected. The query and the selection are not saved.

## Items are built from live state

The palette holds no registry of commands. On each open, a pure function builds the full list from the live catalog snapshot, the current selection, the installed editors, and the `settings.json` snapshot. An item exists only when its action is possible in the current context:

| Context | Item groups |
|---|---|
| Always | App actions (open project, clone, new workspace, new agent, settings, updates, quit); one "Switch to Worktree" item per visible Worktree of each Project, except the selected one |
| Workflows switch on and a run is active | "Cancel Workflow" per active run |
| A Project is selected | Project maintenance (settings, prune, merged batches, remove) |
| A Worktree is selected | Worktree actions, open-in targets (default editor, each installed editor, Finder), project and global commands, one "Launch Agent" per enabled agent profile, Hand Off; workflows the Worktree can start, only with the Workflows switch on and only for a local Project |
| A source pane is known | Window actions and tab actions; pane actions that depend on the focused split only when the focus is precise (see below) |

The builder also drops items whose action the context does not support: for example, no "New Worktree" for a Project without a git root, no archive, delete, or merged batches for a Workspace row, and no pin item for the main checkout.

The list is built once per open, not on each keystroke. A change of state while the palette is open does not update the list. The build runs one run-loop tick after the overlay appears, so that the query field paints at once; until the build ends, the card shows only the query field, not an empty-result hint.

### Source pane and precise focus

Pane and window items need a source pane. A Ghostty keybind supplies its pane. A menu open uses the last-focused pane of the selected Tab, and falls back to the first leaf of that Tab. The focus is **precise** when the pane came from the keybind or from the last-focused record. Split, focus-direction, zoom, and close-pane items appear only with precise focus, so that the palette never offers "Focus Pane Left" from the wrong pane. Tab and window items are safe with the fallback, because every leaf of a Tab resolves to the same Tab and window.

### Captured selection

Items that start work in a Worktree (project and global commands, agent profile launches, workflow starts) carry the Project and Worktree IDs from the build. They run in that Worktree even if the selection changes before activation. The other Worktree and Project items carry no target and resolve the current selection when they run.

## Item identity

Each item has a string `id` that is stable across launches. It is the key of the recency record. Static commands use fixed IDs (`app.open-settings`, `git.toggle-viewer`). Items for an entity use the entity's stable ID, never a position: `worktree.select.<WorktreeID>`, `editor.open.<EditorID>`, `project.script.<ProjectID>.<scriptID>`. A global command uses only its script ID, because it is the same entry in each Worktree. A pane item names the operation, not the pane (`pane.split.right`).

Rule: a new item must use an ID that does not change when its entity moves or is renamed, or recency for that item is lost.

## Ranking

The scorer is a pure function. It gives each item an integer score or drops it. The query matches the visible title and, at the same level, hidden search text and search terms of the item. For example, a "Switch to Worktree" item carries its Project name and, for a Remote Project, the host authority, so a Project or host query lists those Worktrees. The subtitle is only a fallback.

Scores fall in fixed bands, from strong to weak:

1. The query is a contiguous substring of the title (case-insensitive). A shorter title and an earlier position rank higher.
2. The query is a subsequence of the title. Characters after a separator or at a word start rank higher; a wide span ranks lower.
3. The query is a subsequence of the subtitle.

A query in double quotes allows only band 1.

**Recency** adds a bonus that decays by half each week and ends after 30 days. **Invariant:** the bonus is smaller than the gap between two bands, so recency reorders items only inside a band and never lifts a weak match over a strong one. Do not merge the bands into one weighted sum. An optional priority tier on an item adds a small bonus under the same limit; the built items do not set one.

With an empty query, the list shows all items in recency order. Destructive items (Quit, Delete Worktree, Archive Worktree, Remove Project, close tab, pane, or window, the merged batches, Cancel Workflow) are hidden until the query matches them, so a bare open never shows them.

Ties sort deterministically: items without a sidebar position first, by title; then "Switch to Worktree" items in sidebar order (Project, then Worktree row), so that the Worktrees of one Project stay together.

## Running an item

Activation stamps the item in the recency record, closes the palette, and sends `delegate(.activate(kind))`. `RootFeature` maps each kind to the action or client call that the menu, the sidebar, or the header already uses: for example, "Switch to Worktree" sends the sidebar's row-tap action (and reveals the row), and a project command calls the same run-script effect as the header Run button.

Rule: a palette item has no implementation of its own. It sends the action that another entry point sends, and failures show through that action's own path (a status bar warning for a failed command or agent launch). The palette has no error state and closes whatever the result.

## Recency storage

Only the recency record is saved: a map from item ID to the time of the last run, in `UserDefaults.standard` under the key `commandPaletteRecency`. It is not part of `settings.json`. The app reads it on open and writes it on activation and on close.

On each open, the record is pruned. An entry whose ID has a dynamic prefix (`worktree.select.`, `editor.open.`) and that is not in the new item list is removed, because its entity is gone. Other IDs stay. The record is then capped at 200 entries, newest first. Because the IDs follow the entity and pruning follows the live list, recency survives a move of a Worktree and is reclaimed when the Worktree is deleted.

## Traps

- Project, global command, agent, and workflow IDs are not in the dynamic prefix list. Their entries stay after the entity is deleted, until the 200-entry cap evicts them.
- An item added for a new feature action must be added by hand to the builder and to the `RootFeature` route. Nothing checks that the palette covers every action.
- "Toggle Git Viewer" opens the Worktree in the external git client chosen in Settings, and falls back to the in-app diff when no client is set. "Show Changes" always opens the in-app diff. See [Git Diff Viewer](git-diff-viewer.md).

## Shape of the implementation

```
 app menu ──────────┐
 Ghostty keybind ───┴─► RootFeature ──appeared(selection, catalog, editors, recency, pane)──► CommandPaletteFeature
   (pane router)          ▲    │                                                              │  build items (pure)
                          │    └── load / save recency (UserDefaults)                         │  prune, score, filter
                          └──────────────── delegate(.activate(kind)) ◄───────────────────────┘
                     route(kind) ──► existing sidebar, worktree, editor, pane, window actions and clients
```

All parts live in `apps/mac/codans/App/Features/CommandPalette/`. `CommandPaletteItems` (builder) and `CommandPaletteFuzzyScorer` are pure functions without TCA. `CommandPaletteFeature` holds the query, the selection, and the filtered list. `RootFeature` owns the presentation, the source pane, the recency storage, and the route table.
