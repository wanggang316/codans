# Settings

Settings holds the preferences of the user: global values, and values for one Project that replace a global value. It has two faces. The **Settings window** is a standalone window (`Window(id: "settings")`, `⌘,` by default) with one sidebar row for each global pane and one row for each Project. The **settings store** is the file `settings.json` in the config root, which the user can also edit by hand. This page owns the store, its rules, and the map of panes. Each feature page owns the meaning of its own settings.

## Scope and ownership

This page owns the `Settings` model, `settings.json` and its version, recovery of a broken file, the rule for Project values and global values, and the Settings window shell.

| Neighbor topic | Owner |
|---|---|
| Config root, state root, and the Debug and Release copies | [Environment](environment.md) |
| Shortcut overrides (`shortcuts.json`) | [Keyboard shortcuts](keyboard-shortcuts.md) |
| Meaning of the notification switches | [Notifications](notifications.md) |
| Git Platform aliases and Pull Request defaults | [Git Platform](git-platform.md) |
| The Host list | [Remote projects](remote-projects.md) |
| Agent profiles | [Agent profiles and handoff](agent-profiles-and-handoff.md) |
| Workflow bindings and trust | [Workflow](workflow.md) |
| Other stores and their file formats | [Architecture › Persistence](../architecture.md#persistence) |

## The model

`Settings` is one value tree. It has a top-level `version`, a few global sections, and one map for Projects:

```
Settings (version 3)
├── general        appearance, editor, quit, updates, Git Platform aliases, global commands, ...
├── worktree       defaults for worktree creation and cleanup
├── notifications  delivery switches and indicators
├── developer
├── agents         agent profiles
├── workflows      workflow switches, bindings, trust
└── projects: [ProjectID: ProjectSettings]
        ├── defaultEditor, worktreesDirectory      (nil = use the global value)
        ├── envVars, scripts
        └── git: GitProjectSettings?               (Git-only overrides and lifecycle scripts)
```

Rules:

- **The key is the Project.** Per-Project values are keyed by `ProjectID`, never by a repository or a path. When a Project leaves the catalog, its whole entry is removed from `projects`.
- **Preference, not structure.** `settings.json` holds what the user prefers. The name, icon, color, tags, and members of a Project, and the Host list, are in `catalog.json`, and their controls write through `HierarchyManager`. A value that shows in the Settings window does not for that reason belong in `settings.json`.
- **Git values nest; they are not a separate kind.** Values that apply only to a Git Project are in the optional `git` subtree. The common fields stay at the top of `ProjectSettings`. When the user runs `git init` or deletes `.git`, the Project kind changes but no data moves: the `git` subtree only starts or stops to apply.
- **Empty is absent.** Before each save, an entry with no value set is removed, and an empty `git` subtree becomes `nil`. The file does not collect `{}` objects.
- **New fields are additive.** Each section and each optional field decodes to its default when the key is missing. A new field must follow this pattern, so that a file from an older build still loads without a version change.

## Project value or global value

Each field of `ProjectSettings` and `GitProjectSettings` that can replace a global value is optional. `nil` means "use the global value". There is no central resolver: the reader of a value applies `project ?? global` at the point of use. Examples:

- `defaultEditor` falls back to `general.defaultEditorID`.
- `worktreesDirectory` falls back to `worktree.defaultWorktreesDirectory`, then to the built-in default.
- `git.fetchRemoteOnWorktreeCreate` and `git.copyIgnoredOnWorktreeCreate` fall back to the `worktree` section.

Read a Project value through `settings.projects[pid]`. Do not look for it on `Project`; the catalog does not carry it. A new reader that reads only the global value ignores the Project override, and the user sees a setting that has no effect.

`envVars` and `scripts` have no global value to replace. Global commands are a separate list in `general`; surfaces that show commands show both lists.

The sections of a Project page depend on its `ProjectKind`, which is derived from the catalog and not stored. A directory Project shows General, Editor, Environment, and Commands. A Git Project and a Remote Project also show Worktree, Git Platform, and Lifecycle. A Workspace shows its member Projects in place of the Git sections.

## One writer

`SettingsStore` is the only writer of `settings.json`. It owns the whole tree in memory. Every write is a section mutator (`mutateGeneral`, `mutateProject`, and others) that changes the tree and schedules one debounced save of the **whole** tree. The Settings panes, the worktree header, the command palette, and the CLI handlers (for example `project.addScript`) all write through this store. Per-Project writes from reducers go through the `SettingsWriter` seam, which calls `mutateProject`.

Rules:

- Do not add a second writer of this file. Two stores that each write their own part of one file erase the keys of the other on each save. When a feature needs its own file with its own owner, give it a separate file, as `catalog.json` and `shortcuts.json` are.
- A reader outside the store must not decode the raw file. It reads the live value from the store.
- The save is an atomic rename through `AtomicFileStore`. The file is created with mode `0600` inside that write. Do not add a `chmod` after the write: it opens a window in which the file has a wider mode.

What follows from one writer with no file watch:

- **A hand edit while the app runs is lost.** The store does not watch the file. It does not read the file again until the next launch, and its next save, or the flush at quit, writes the in-memory tree over the edit. Quit the app before you edit `settings.json`.
- **Two instances of one build channel do not see each other.** Each loads the file at launch and saves its own full tree. The last save wins, and a change made in one instance is lost when the other saves.
- **An older build removes keys it does not know.** The version stays 3 when a field is added, so an older build loads a newer file, drops the unknown keys, and writes the file without them on its next save. Debug builds of different branches share one `codans-dev` config root, so this happens during development.

## Load, version, and recovery

`SettingsMigration.load` reads the file once at launch. `Settings.currentVersion` is 3. Every outcome keeps the source data recoverable before defaults are used:

| File on disk | Result |
|---|---|
| None | Defaults. The file is written on the first change. |
| Version 3 | Used as it is. The file is not written again. |
| Version 1 or 2 | Migrated to version 3. The original moves to `backups/settings.migrated-v<N>-<ts>.json`, then the new file takes its place. |
| Other version, older or newer | The file moves to `backups/settings.unsupported-v<N>-<ts>.json`. Defaults are used. |
| Not valid JSON, or a section of the wrong shape | The file moves to `backups/settings.corrupt-<ts>.json`. Defaults are used. |
| Backup or migration step fails | Defaults in memory, and saving is off for the session. The original stays at its path. |

The backups are in the config root, and the newest five are kept for each reason. A Project key that is not a valid `ProjectID` is dropped with a log line; the rest of the file loads. To recover settings, quit the app and copy a backup back to `settings.json`.

After the load, a `general.defaultEditorID` that is not in the built-in editor registry is reset, and the clean value is saved.

## The Settings window

The window is one `NavigationSplitView` driven by `SettingsWindowFeature`. The sidebar selection is not saved: when the window closes, the selection is cleared, and the window opens again on General. Project rows come from the live catalog. When a Project leaves the catalog, its page state is removed, and a selection on it goes back to General.

Global panes, in three groups in the sidebar:

| Pane | Owns | Owner page |
|---|---|---|
| General | Appearance, default editor and Git viewer, quit behavior, crash reports | [Appearance](appearance.md), [Editor integration](editor-integration.md), [Terminal runtime](terminal-runtime.md), [Crash reporting](../runbooks/crash-reporting.md) |
| Git Platforms | CLI status, capabilities, aliases, merge defaults | [Git Platform](git-platform.md) |
| Worktrees | `worktree` defaults | [Worktree](worktree.md) |
| Terminal | A managed block in the Ghostty config file, not `settings.json` | [Appearance](appearance.md) |
| Notifications | `notifications` | [Notifications](notifications.md) |
| Global Commands | `general.globalScripts` | [Project commands](project-commands.md) |
| Shortcuts | `shortcuts.json` | [Keyboard shortcuts](keyboard-shortcuts.md) |
| Updates | Update channel and checks, copied to Sparkle | [Updates and release](updates-and-release.md) |
| About | Version information; stores nothing | — |
| Agents | `agents` | [Agent profiles and handoff](agent-profiles-and-handoff.md) |
| Integrations | Links for the CLI and the bundled skills; stores nothing in `settings.json` | [CLI](cli.md) |
| Workflows | `workflows` | [Workflow](workflow.md) |
| Remote Hosts | The Host list in `catalog.json` | [Remote projects](remote-projects.md) |

Each Project has one page. Its General section writes identity to the catalog. Its other sections write `projects[pid]` through `SettingsWriter`.

## Traps

- **"I set it, but nothing changed."** First check which app is running and which config root it uses: a Debug build reads `~/.codans-dev/config/settings.json`, not the Release file. Then check for a second instance or a hand edit made while the app ran.
- **The crash-reporting bootstrap reads the file directly.** Sentry starts before `SettingsStore` exists, so it decodes `settings.json` itself, read-only, and uses defaults when the file is not version 3. Do not copy this pattern for other readers.
- **Saving stays off after a failed backup.** Changes in the window then apply for the session only. The log of the `com.gumpw.codans.persistence` subsystem shows the reason.

## Implementation shape

The model and its migration are in `CodansCore/Settings/`: `Settings` is the root, `SettingsMigration` owns load, migration, and backup. The app owns the live value: one `SettingsStore`, created at launch next to the catalog store and flushed at quit. Views read it through the environment; reducers read and write through `SettingsWriter`; IPC handlers call the store directly. The window is `App/Features/Settings/`: `SettingsSection` lists the rows, `SettingsWindowFeature` holds the selection and the Project page states, and each pane is its own view or reducer.
