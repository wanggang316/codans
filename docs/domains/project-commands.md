# Project Commands

A command is a saved shell command line that the user runs with one click or one chord, in the Worktree that is selected. Most projects already name their entry points in a manifest (`package.json` scripts, Makefile targets, justfile recipes), so the app reads those manifests and offers their entries as suggestions. This page covers the command model, how a command runs and stops, the suggestions, and command icons.

Availability: Available.

## Scope and ownership

| Topic | Owner |
|---|---|
| `settings.json`, `SettingsStore`, the Settings window | [Settings](settings.md) |
| Registry shortcuts and the chord recorder | [Keyboard Shortcuts](keyboard-shortcuts.md) |
| Header layout and the toolbar slots | [Main Window](main-window.md) |
| Process entries and their icons, busy signals | [Terminal Runtime](terminal-runtime.md) |
| `childExited` and the shell wrapping | [Pane Shell Integration](pane-shell-integration.md) |
| Command items in the palette | [Command Palette](command-palette.md) |
| `codans project commands` (`list`, `add`, `edit`, `rm`) | [CLI](cli.md) |

## Model

There are two lists of the same type, `ScriptDefinition`:

- **Project commands**: `projects[<ProjectID>].scripts` in `settings.json`. They belong to one Project and show only when a Worktree of that Project is selected.
- **Global commands**: `general.globalScripts`. They belong to no Project and run in whichever Worktree is selected.

A command holds:

- `name`, `command` (one or more shell lines), and `kind` (`run`, `test`, `deploy`, `lint`, `format`, `custom`). The kind gives the default name, icon, and tint.
- `systemImage` and `tintColor`: optional overrides of the kind defaults. `systemImage` is an SF Symbol name or `mark:<tool>` (see [Command icons](#command-icons)).
- `target`: `newTab` (default), `split` (with a `direction`), or `focused` (type into the focused Pane).
- `onFinished`: `none`, `closeTab`, or `closePane`. It applies only to a matching spawning target: `closeTab` with `newTab`, `closePane` with `split`. Any other pair reads as `none`, also for a hand-edited file.
- `focus`: whether a spawned Tab or Pane takes the focus. Off, the run starts in the background.
- `keyboardShortcut`: an optional chord.

Fields at their default value are not written. Each command has a UUID; a run, a palette item, and a run Pane all key on it.

Rules for Project commands:

- **At most one command per preset kind.** `custom` has no limit. The `+` menu offers only the preset kinds that are free.
- **The built-in Run.** A Project with no `run` command shows a virtual Run row (fixed ID, default chord ⌘R) in the Commands table. It is not saved until the user edits it or a suggestion fills it.
- **Order is the user's.** The first command in the list is the primary command of the header Run button. Drag order is the only control; the kind does not promote a command.

Global commands have no kind presets and no built-in Run. The Global Commands pane adds `custom` commands only.

## Running a command

Entry points: the Run split button in the header, the Worktree menu of the menu bar (each command, with its chord, plus "Stop Command" on ⌘.), and the [command palette](command-palette.md). All use one pipeline in `HierarchyClient`. The working directory is the Worktree path. The environment is the resolved environment of the Project ([Environment](environment.md)).

**The run Pane.** A `newTab` or `split` run records its Pane as the run Pane of the pair (Worktree, command ID). The Pane row stores `runScriptID` in the catalog, so the link survives a relaunch. The next run of the same command in that Worktree:

```
run (worktree, command)
  ├─ run Pane exists and is busy  ─► select it (if focus); send nothing
  ├─ run Pane exists and is idle  ─► bring up its surface, type the command again
  └─ no run Pane                  ─► spawn per target, record the run Pane
```

- "Busy" uses the same signals as the Tab spinner ([Terminal Runtime](terminal-runtime.md)). An agent that emits progress in a run Pane also reads as busy.
- `focused` types into the focused Pane of the selected Tab. It records no run Pane, so it has no Run/Stop state and no `onFinished`. With no focused Pane, `focused` and `split` fall back to a new Tab.

**Run and Stop.** While the run Pane of a command is busy, its rows and the header button show "Stop <name>" in red. Stop sends an interrupt (Ctrl-C, as a key event) and then closes the run surface: the whole Tab if the run Pane is its only Pane, else only the Pane. Stop is a teardown, not a pause; the next run spawns a new surface. ⌘. stops the command that runs in the current Worktree; it is disabled while nothing runs, so that ⌘. still reaches the terminal. Archive and removal of a Worktree stop its running commands ([Worktree](worktree.md)).

**Finished.** With a close policy, the command is sent as `<command>; exit`, so that the shell exits when the command ends. The policy fires on `paneInfoChanged(.childExited)`, not on `paneExited`: libghostty keeps the surface open after the child exits. The listener subscribes before the spawn, because the event stream does not replay and a short command can end first.

**The header button.** The primary half runs (or stops) the first Project command. With no Project command, it opens Manage Project Commands. The tooltip shows the chord. The dropdown has three sections: Project (commands, then "Manage Project Commands…"), Global (commands, then "Manage Global Commands…"), and Config Files (suggestions). The Project and Global sections always show, so the Manage items stay reachable when a list is empty. The dropdown is an AppKit `NSSegmentedControl` with view-backed menu rows (`RunSplitButton`), because a SwiftUI `Menu` cannot show two-line rows with a second click target. The menu is rebuilt from live state each time it opens.

**Chords.** A command chord is a main-menu key equivalent, so it fires while a terminal Pane has focus. When it is recorded, the chord is checked against macOS reservations, the AppKit standard menu chords, the registry, and the other commands **of the same list**.

## Command suggestions

The suggestions are not saved and do not follow later manifest changes. Adding one copies it into a command; after that it has no link to the manifest. No external tool runs for detection (no `just --list`, no `npm`); the app only reads files.

**Parsers.** Each ecosystem is one `CommandSuggestionParser` in `CodansCore/Settings/CommandSuggestion/`. A parser declares a `ManifestRequest` (files to read, and files to probe for presence only, such as lockfiles) and turns a `ManifestSnapshot` into suggestions. Parsers are pure: no file system access. Thus they run on literal test fixtures and run unchanged for a Remote Project. A manifest that does not parse gives no suggestions; it never fails the scan. `CommandSuggestionRegistry.standard` lists the parsers in menu order: script runners (package.json, deno, composer, Makefile, justfile, Taskfile, mise, pyproject, Compose) first, then fixed toolchain verbs (Cargo, Go, SwiftPM). Each parser also infers a kind from the entry name (`dev` gives `run`, `test:unit` gives `test`).

To add an ecosystem: add one parser, register it in `standard` (the position is the menu position), cover it with fixtures, and map its runner in `CommandIconCatalog` if it is new. The readers, the UI, and adoption do not change.

**Reading.** The registry merges the requests of all parsers, and one read answers all of them. The read walks the checkout breadth-first to 3 levels below the root. It skips hidden directories, symlinked directories, and dependency or build output directories (`node_modules`, `vendor`, `target`, `dist`, and others), and it skips files over 1 MiB. A Remote Project reads on its host in one SSH call that walks with the same rules; a timeout, an error exit, or too much output gives an empty snapshot, which shows as "no suggestions", never an error.

**Subdirectories.** Each directory with a manifest gives its own groups. A nested group has the manifest's relative path as its title (`apps/web/package.json`), and its commands start with `cd <dir> && `, so all commands run from the Worktree root. A workspace member without its own package manager declaration or lockfile uses the nearest enclosing one.

**Where to read.** The scan reads one checkout: the given Worktree, else the Project's selected Worktree, else the Project root. Branches can carry different manifests, so the scan prefers the checkout in use. The Settings Commands section scans each time it appears (from the Worktree the user last focused); the header scans when the selected Worktree changes. Both menus have Refresh. There is no file watch. A new scan cancels the one in flight, and the header drops a result that arrives for a Worktree it has left.

**Where suggestions appear.**

- Settings → Project → Commands, the `+` menu, section "From Project": a click adds the command.
- The header Run dropdown, section "Config Files": one submenu per manifest. A click on a row runs the entry in a new Tab without saving it. The `+` at the row end adds it, and the menu stays open. An added entry shows `✓`, and a click runs the saved command, so it shares the Run/Stop state. An unsaved run uses a stable ID made from the suggestion, so a second run reuses the same run Pane.
- Settings → Global Commands, the `+` menu, section "Suggested": a fixed list of everyday commands (`GlobalCommandSuggestions`: Git, GitHub CLI, Docker, System, Homebrew). Global commands have no Project, so this list is not detected from files. **Only non-destructive commands go in this list**; a test rejects `reset --hard`, force pushes, `branch -D`, prune and remove verbs, and similar.
- The command palette does not list suggestions.

**Adoption rules** (`CommandSuggestionAdoption`):

- A command whose trimmed `command` equals the suggestion counts as added. The menu shows it as added and adds no copy.
- A `run` suggestion fills the virtual built-in Run (saved at the top, with ⌘R) or an existing Run with an empty command. If a non-empty Run exists, it is added as `custom`.
- Any other preset kind that is taken becomes `custom`, to keep one command per preset kind.
- If the name is taken, the source qualifies it (`dev (apps/web/package.json)`), then a number.
- A Global suggestion is always added as `custom` with its icon.

## Command icons

`CommandIconCatalog` (`CodansCore/Settings/CommandIcon/`) is one table from command words to icons. Suggestions and the foreground process list use it. For a manifest entry it resolves, most specific first:

1. The entry is named after a tool (`storybook`, `docker:up`): the tool mark.
2. The entry names an action (`build`, `test:unit`, `lint`, `migrate`): the SF Symbol of the action. Actions come before the runner so that a dozen entries of one manifest do not all show the npm mark.
3. The entry body calls a known tool (`prisma generate`): the tool mark.
4. The runner (`pnpm run`, `make`, `cargo`): the runner's mark.

A tool mark is a `ToolMark` case with a `tool-<raw>` image set in the app asset catalog: monochrome, template rendering, on a 24-by-24 view box, so it takes the command tint like an SF Symbol. The artwork comes from Simple Icons (CC0); `mise` is drawn in-house.

**Storage.** `systemImage` holds an SF Symbol name or `mark:<raw>`, the same pattern as the `agent:` prefix of Tab icons. A mark that this build does not know falls back to the kind default; an older build draws nothing for it. Adoption writes the icon only when it differs from the kind default.

**Rendering.** Every view that draws a command icon goes through `CommandIconRef` and the shared glyph views. Menus and the toolbar re-template asset images and drop their color, so menu and toolbar code bakes the tint into a non-template image (`CommandIconImage.tinted`). A baked image does not invert on a highlighted menu row; the view-backed rows draw a selected-color glyph themselves.

**To add a tool mark:**

1. Add a `ToolMark` case. Its raw value is saved as `mark:<raw>`, so never rename a shipped case. Map its executable names in `CommandIconCatalog`.
2. Add `tool-<raw>.imageset` with the upstream SVG and the same image set properties (template rendering, preserved vector). Prefer Simple Icons; draw a mark only when no Simple Icons or SF Symbol glyph fits, as one filled path on the 24-by-24 grid.
3. Check it at menu size in light and dark. Illustrations and thin wordmarks read as noise at that size; leave them out.
4. Record the source of the artwork.

Tests check that each `ToolMark` is reachable from the table and has a bundled template asset.

## Traps

- A registry rebind is not checked against Project or Global command chords, so the two can collide ([Keyboard Shortcuts](keyboard-shortcuts.md)).
- The chord check compares a command only with its own list. A Project command and a Global command can share a chord.
- With the virtual built-in Run only, the Project has no saved command: the header button opens Manage Project Commands, and ⌘R is not bound until the Run row is saved.
- `focused` commands have no Stop, and ⌘. does not see them.
- A run Pane whose command was deleted shows the terminal icon and is no longer reused.
- A suggestion counts as added by its exact command text. A saved command that differs only in arguments or quoting shows the suggestion as not added.

## Shape of the implementation

```
 CodansCore: parsers ─► CommandSuggestionRegistry ◄─ ManifestSnapshot
             CommandSuggestionAdoption, CommandIconCatalog   (pure)
                    ▲
 App: CommandSuggestionClient ─► ManifestReader (local | SSH)
      Settings Commands panes, WorktreeHeaderFeature + RunSplitButton
                    │ run / stop (via RootFeature)
                    ▼
      HierarchyClient run pipeline ─► HierarchyManager (run Pane index, runScriptID)
```

All logic that decides what a suggestion is, how it becomes a command, and which icon it gets lives in `CodansCore` and has no I/O. The app layer reads files and runs commands. `SettingsStore` owns the saved lists; `HierarchyManager` owns the run Pane links.
