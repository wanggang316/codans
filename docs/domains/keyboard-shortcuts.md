# Keyboard shortcuts

codans keeps all of its own keyboard shortcuts in one registry. Each command has a stable id and one default chord. The user can rebind, disable, or reset any command in Settings → Shortcuts. The menu bar, the sidebar, the tab bar, tooltips, and hints all read the same resolved bindings, so a change in Settings shows everywhere at once, with no restart.

## Scope and ownership

This page owns the registry, the binding model, conflict detection, the `shortcuts.json` file, and the paths by which a chord reaches its command.

Neighbor topics:

- The Settings window and its other panes: [Settings](settings.md).
- How the command palette shows chords: [Command palette](command-palette.md).
- Key handling inside libghostty: [Terminal runtime](terminal-runtime.md).
- The chords of Project and Global commands, which the user sets on each command: [Project commands](project-commands.md).

## Registry and binding model

`CommandID` is a closed enum. `ShortcutSchema.app` has exactly one entry for each case: title, category, scope, and default binding. The Settings pane groups and orders its rows from the schema, not from `CommandID.allCases`. The default chords are not listed here: the schema and the Settings pane are the list.

Rules:

- Add each new app shortcut as a `CommandID` case plus one schema entry. Do not hard-code a chord at a call site.
- The raw value of a `CommandID` is the key in `shortcuts.json`. Rename the Swift identifier if necessary, but pin the old raw value with `= "..."` (example: `toggleDiffInspector = "toggleGitViewer"`). A changed raw value makes every stored override for that command unreadable.
- Numbered commands (`switchToTab1`…, `selectWorktreeAt1`…, `focusAgentAt1`…) are separate cases, so each one is its own JSON key and each switch over them stays exhaustive.
- Two schema defaults must not share a chord. The schema audit tests enforce this and pin every default against a golden table, so a change to a default is always on purpose.

A `ShortcutBinding` stores the **physical key** (a virtual key code) and a modifier set, not the typed character. The binding then stays on the same physical key when the user changes input source. `CodansCore` holds the model with no SwiftUI or AppKit types; `ShortcutDisplay` converts at the edge, with two different layout translations on purpose:

- **Display** asks the active keyboard layout which character the key makes, so the keycap matches what is printed on the user's keyboard. If that fails it uses the ASCII-capable layout, then a hex stub such as `<0x4A>`, so a row is never blank.
- **Binding** asks the ASCII-capable layout that macOS pairs with the active input source, because SwiftUI's `.keyboardShortcut` matches the typed character. The chord then still fires while a non-ASCII input source (Pinyin, Hangul) is active.

Do not merge the two into one layout. Users of other layouts then see the wrong keycap, or press the key and get nothing.

### Three states

A command is in one of three states:

| State | In `shortcuts.json` | Effect |
|---|---|---|
| Default | no entry | the schema default applies |
| Overridden | entry with `isEnabled: true` | the user's chord applies |
| Disabled | entry with `isEnabled: false` | no chord fires; the stored chord is kept |

Disabled is not the same as absent. It is the only way to say "I do not want this default, and I give it no other key". A disabled entry keeps its chord, so Enable Shortcut restores it. `ShortcutResolver` merges the schema and the overrides into the `ResolvedShortcutMap` and marks each row with its source (schema default or user override). The Settings pane shows the reset button only on an overridden row.

An override equal to the schema default is not stored: the store drops it and the row goes back to Default.

## Conflict detection

A recorded chord passes these checks in order:

1. **Recorder rule.** At least one of ⌘, ⌥, or ⌃ must be present. ⇧ alone is rejected, because it would take over normal typing. A modifier key alone is not a chord.
2. **macOS system chords.** Read from the system's symbolic hotkeys (Spotlight, Mission Control, input source switch). The parse is lenient: an unknown format gives an empty set, not a block.
3. **AppKit standard menu chords.** A fixed list: ⌘Q, ⌘W, ⌘H, ⌘M, ⌘,, ⌘?.
4. **Other registry commands.** Only enabled, configurable rows count.

Checks 2 and 3 reject the chord with a message in the recorder. Check 4 does not reject: it asks "Replace Existing Shortcut?". On confirm, the store gives the chord to the new command and disables the old holder, in one save. The recorder swallows every key press while it records, so recording ⌘W does not close a Tab.

### Cascading reset

Reset of command A clears A's override. A's default can then equal B's override. `ShortcutResetPlanner` computes the result first: it clears each user override that now collides, repeats until no collision is left, and returns the list. When the list is not empty, the confirmation names the commands it also resets. A reset without the cascade can leave two commands on one chord with nothing in the UI to show it. Restore Defaults clears every override.

## Storage

`ShortcutsStore` is the single writer of `shortcuts.json` in the config root (`~/.codans/config/`, or `~/.codans-dev/config/` for Debug; see [Environment](environment.md)). It writes atomically after a short debounce and flushes at quit. The file is sparse: it holds only overrides.

```json
{ "version": 1,
  "overrides": { "toggleGitViewer": { "keyCode": 5, "modifiers": ["command"], "isEnabled": false } } }
```

Shortcuts are a separate file, not a field of `settings.json`. A recorder commit writes at once and must not merge with a Settings edit. The file has its own version, so it never forces a migration of `settings.json`.

How a file is read:

- **Unknown version, or a decode error** (bad JSON, an unknown modifier token, an unknown command key): the store moves the file to `backups/` and starts with no overrides. All overrides are lost, not only the bad entry.
- **Retired command ids** in a short list are dropped on read, so the rest of the file loads. When you remove a `CommandID`, add its raw value to that list, or the next read discards every override.
- **Backup fails:** the store starts empty and does not write, so the original file stays for a newer build or a manual fix.

## How a chord reaches its command

```
 key press in the main window
   │
   ├─ local monitor (localHotkeys) ── ⌥-only chords of an open Agents View ──► action
   │
   ├─ focused terminal Pane: performKeyEquivalent
   │     1. main menu key equivalents ──► registry commands, Project/Global commands
   │     2. libghostty keybinding ──────► terminal (tab/split actions go to codans)
   │     3. otherwise ──────────────────► typed into the terminal
   │
   └─ other focus: SwiftUI key equivalents (menu, sidebar and tab-bar buttons)
```

Rules:

- **A chord that must work while a terminal Pane has focus goes into the main menu.** The terminal Pane is the first responder most of the time and takes key presses as input. Menu key equivalents are checked before the Pane's own bindings. Most registry commands are menu items in `MainWindowCommands`; the sidebar filter and row chords are bound on buttons in the sidebar view.
- **A chord with ⌥ and no ⌘ or ⌃ cannot be a key equivalent.** AppKit sends it to the first responder as text. The Agents View `focusAgentAt` chords therefore use `localHotkeys`, a window-local key monitor that matches the physical key. It is installed only while the panel is open, and it lets the press through while a text field has focus.
- **A window-wide menu chord must not use a key that a terminal or a text field already uses** (for example ⌘⌫, delete to line start). The menu takes such a key before the focused control. Do not enable or disable the menu item by focus to free the key: the chord then has two behaviors in one window. See [ADR 0011](../adrs/0011-worktree-archive-and-delete-chords-are-window-wide.md).
- **Close Tab follows the key window.** In Settings or a Diff window it closes that window; in the main window it closes the active Tab.
- **Previous / Next Tab go through `selectTab`.** A direct write of the selected Tab skips the focus restore, and the Tab opens without its remembered Pane.

### ⌘W

AppKit's File ▸ Close item owns ⌘W. SwiftUI cannot remove it, and its presence also takes ⌘W away from the Close Tab menu item. codans keeps the item and wraps the main window's delegate (`MainWindowCloseInterceptor`). Each close passes through `windowShouldClose`. When the current event is the ⌘W key press, the app closes the focused Pane (in a split Tab) or the active Tab and keeps the window. Only when nothing is left to close does ⌘W close the window. The red button and a click on File ▸ Close still close the window.

### Terminal keybindings

The menu wins over the terminal's own bindings. ⌘T and ⌘W do the codans action, not the libghostty one. This is intended. A libghostty binding that no menu item claims still reaches libghostty, and its tab and split actions are routed into the codans hierarchy. codans removes one libghostty default in its config overrides: ⌘⏎ (toggle fullscreen), so that the chord reaches the program in the Pane. Other libghostty bindings (scrollback, copy) are not in the registry.

## Display

Every chord string comes from the resolved map, so a rebind or a disable shows in menus, tooltips, and hints at once. A tooltip with a chord has the form `Name (chord)`, for example `Back (⌘[)`, and is built by `ShortcutDisplay.tooltip`; do not write a chord into UI text by hand. When the user holds ⌘ alone for about half a second, controls with a chord show it as a hint. Any other key during the hold hides the hints until ⌘ is released.

## Traps

- ⌘, (Open Settings) and ⌘W (Close Tab) are registry defaults, but both are on the AppKit reserved list. The recorder rejects them, also for their own command. Reset is the only way back to them.
- ⌘W is handled by the window close path, not by the Close Tab binding. A user who rebinds Close Tab still gets the Pane → Tab → window close on ⌘W.
- Enable Shortcut does not check for conflicts. A command that lost its chord in a Replace, and is then enabled again, shares that chord with the new holder.
- A Project or Global command chord is checked against the registry when it is recorded. A registry rebind is not checked against Project or Global command chords, so the two can collide.
- Some schema scopes (`systemFixed`, `localOnly`) exist, but every current entry is configurable.

## Shape of the implementation

```
 CodansCore/Shortcuts         CommandID, ShortcutSchema, ShortcutBinding,
 (no SwiftUI / AppKit)        resolver, reset planner, conflict detectors
          │ pure data
 App/Shortcuts                ShortcutsStore (file, resolved map), ShortcutDisplay,
                              recorder, appKeyboardShortcut, localHotkeys
          │ resolved map (environment, Commands argument)
 MainWindowCommands, sidebar, tab bar, Agents View, Settings → Shortcuts
```

`ShortcutsStore` owns the overrides and rebuilds the resolved map on each change. Views read the map from the environment; `Commands` receive it as an argument, because a `Commands` body cannot read the environment.
