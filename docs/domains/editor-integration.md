# Editor Integration

codans does not edit code. It hands a Worktree, or one file of it, to an external tool: an editor, a terminal app, a git client, or Finder. This domain knows which tools exist and which are installed, decides which tool a request goes to, and launches it in the correct way for a local Worktree, a Worktree on a remote Host, or a Pane.

## Scope and ownership

This page owns the tool registry, default resolution, the three launch paths, the external Git Viewer, and the `editor.*` IPC methods. Neighbor topics:

| Topic | Owner |
|---|---|
| Header layout and the toolbar slot of the Open button | [Main Window](main-window.md) |
| The settings store and its file format | [Settings](settings.md) |
| The built-in diff window | [Git Diff Viewer](git-diff-viewer.md) |
| `codans open` syntax and exit codes | [CLI](cli.md) |
| SSH transport and Host records | [Remote Projects](remote-projects.md) |
| Click on a file path in a terminal | [Pane Shell Integration](pane-shell-integration.md) |

## Registry and discovery

`EditorRegistry` is a fixed, built-in list. Each entry has an `EditorID` (for example `cursor`, `zed`, `intellij`, `ghostty`, `fork`, `finder`), a display name, a bundle identifier with optional alternates, and a launch mode. There are no user-defined tools. The entries fall in four categories: editors (including Xcode), terminals, git clients, and Finder, plus the `$EDITOR` pseudo-entry. The registry also holds two orders: the priority walk for automatic choice and the menu order for display. They are separate on purpose.

- An entry is **installed** when Launch Services finds an app for its primary or an alternate bundle identifier. The installed list (`EditorDescriptor`, with the resolved `.app` URL) is the only signal; an absent descriptor means "not installed".
- `$EDITOR` has no bundle and is always in the installed list.
- The live service caches the installed list. Settings and `editor.describe` clear the cache, so a new app shows there without a restart. Other entry points can use the old list until the next clear.

## Default resolution

Three sources decide the default tool, in this order:

1. The **Project override**: `projects[<ProjectID>].defaultEditor` in `settings.json`, set in Project Settings › General, or by a pick from the header Open menu.
2. The **global default**: `general.defaultEditorID`, set in Settings › General.
3. The **priority walk** over the installed list: editors, then Xcode, terminals, git clients, and Finder last. Finder is always installed, so a local walk always ends.

Rules:

- A stored default is advisory. A source whose tool is not installed is skipped, not reported. Callers filter the Project override and the global default against the installed list before they pass a `preferred` tool to the service.
- An explicit choice is strict. A tool that the user picked by name (a menu row, `codans open --in`) and that is not installed gives `notInstalled`.
- Do not pass Finder as the fallback `preferred`. Pass nothing, so that the service walks the priority list; Finder as `preferred` would stop the walk before installed editors.
- The Open button label and the Open action must name the same tool. The label uses a pure mirror of the service cascade (`EditorFeature.resolveDefault`, or `resolveRemoteDefault` for a Remote Project). A change to one cascade must change its mirror.
- At load, Settings resets a `general.defaultEditorID` or a Project override that is not in the registry, and resets an unknown Git Viewer ID to Built-in. A known ID of an app that is not installed stays.

## Launch paths

```
 request (Worktree path, ProjectID?, preferred?)
    |
    +-- preferred is $EDITOR ----------------> new Tab + Pane, initial command "$EDITOR"
    +-- Project is on a remote Host ---------> SSH editor: bundled CLI via CommandRunner
    +-- otherwise ---------------------------> local app via Launch Services
```

**Local app.** The path must be an existing local directory, else `notADirectory`. Most apps receive the directory URL through `NSWorkspace.open`. JetBrains IDEs receive the path as an application argument in a new instance, because they ignore a URL and open their last project. Success means that macOS accepted the request, not that the tool loaded the project.

**SSH editor.** For a Worktree of a Remote Project, only tools with an SSH remote entry point qualify: Zed (an `ssh://[user@]host[:port]/path` URL) and the VS Code family (`--remote ssh-remote+<destination> <path>`). The service runs the CLI inside the app bundle (never a CLI on `PATH`) through the shared `CommandRunner`, with a timeout. Exit code 0 is success; other results are `launchFailed`, with stderr as the reason when there is one. The VS Code family cannot carry a non-default port on the command line, so it does not qualify for such a Host; the user puts the port in `~/.ssh/config`. The remote path is not checked on this Mac.

- Remote resolution uses the same three sources, but each tier skips a tool that cannot express the Host, **including an explicit choice**. There is no Finder fallback. If no tool qualifies, the result is `launchFailed`.
- For a Remote Project, the header Open button and the sidebar "Open in" items list only SSH-capable editors, show a VS Code family row as disabled with the reason when the port is not the default, and are hidden when no SSH-capable editor is installed.

**`$EDITOR` in a Pane.** The service cannot open `$EDITOR`, because it has no Tab or Pane context. `EditorFeature` sends a delegate, and the root reducer creates a Tab in the Worktree, opens a Pane with the initial command `$EDITOR`, and selects it. The shell of the Pane expands the variable. For a Remote Project the Pane runs on the Host, so the editor runs there. `editor.open` with `editor` returns `launchFailed`.

## Opening a file at a line

The diff window, the workflow files list in Settings, and terminal file links open one file. Resolution is the same as for a directory, through `ProjectEditorContext`, which also supplies the Host of a Remote Project.

- The relative path must stay in the Worktree: no absolute path, no empty, `.`, or `..` segment, no NUL. A local file must exist, must not be a directory, and must resolve (after symlinks) inside the Worktree.
- Only editors, Xcode, and Finder can open a file. A terminal, a git client, or `$EDITOR` as the resolved tool gives `launchFailed`.
- The line is best effort. The VS Code family, Zed, and Sublime Text get `path:line` through their bundled CLI; JetBrains gets `--line`. Other apps open the file at the top. A file name that contains `:` never gets a line.
- The diff window opens only the current side of a file that is not deleted. It sends a line only for comparisons of uncommitted changes, and only when the displayed text still equals the file on disk; else it opens the file without a line. Its message says that line navigation depends on the editor.

## External Git Viewer

Settings › General › Default Git Viewer is a separate setting, `general.defaultGitViewerID`. Its default is Built-in (`"built-in"`), the built-in diff window; the other choices are the installed git clients. Toggle Git Viewer (default ⌘G, also in the menu and the command palette) reads it:

- Built-in opens the diff window of the current Worktree.
- An external ID opens the Worktree directory in that client through the normal open path. For a Remote Project this is remote resolution, so a git client falls through to an SSH-capable editor.
- An external ID that is known but not installed does nothing.

The client receives only the directory; codans delegates all git history and staging work to it. Show Changes in the Worktree menu always opens the built-in window.

## Entry points

| Entry point | Behavior |
|---|---|
| Header Open button (toolbar of the main window) | Primary click opens the default. The menu lists installed tools by category; a pick saves it as the Project override, then opens it in the selected Worktree. |
| Sidebar Worktree menu | "Open in <tool>" opens the default; the "Open in" submenu opens one tool and saves nothing. |
| Open in Editor command (⌘O, menu, palette) | Opens the default for the selected Worktree. The palette also has one "Open in <tool>" item per installed tool. |
| `codans open [--in <id>] [<path>]` | Calls `editor.open` with an absolute local directory (default: the current directory). Without `--in`, the handler uses the override of the Project that contains the path, if installed. No Host, no file, no line. |

The other IPC methods are `editor.describe` (the installed list, which also clears the cache), `editor.setGlobalDefault`, and `editor.setProjectDefault` (rejects an unknown Project). They write the same settings as the UI.

## Failure behavior

`EditorError` has three cases: `notInstalled` (explicit local choice missing), `notADirectory` (local path missing), and `launchFailed` (Launch Services error, no SSH-capable tool, CLI failure or timeout, invalid file path, `$EDITOR` without a Pane). In the app, each outcome becomes `EditorFeature.lastOpenResult`: success and failure show a short toast at the bottom of the window and a message in the toolbar status slot. IPC maps each case to an error of the same name. A failed file open from a terminal link or the workflow list reveals the file in Finder instead.

## Traps

- When two apps have the same bundle identifier, Launch Services picks one.
- A found bundle does not prove that its bundled CLI path or arguments still match the app version; a remote open can then fail.
- `codans open` on a Worktree of a Remote Project fails with `notADirectory`, because the path is not on this Mac.
- The palette lists all installed tools for a Remote Project too; a tool that cannot reach the Host falls through to one that can.

## Shape of the implementation

`App/Clients/Editor/` holds the registry, the `EditorService` protocol and its live actor (discovery cache, local and remote resolution, launch), and the pure argument builders for SSH and file opens. Launch Services sits behind `AppLauncher` and processes behind `CommandRunner`, so tests launch nothing. `EditorFeature` holds the installed list and the global default for the views, resolves Project overrides, chooses the launch path, and records the outcome; `RootFeature` routes the entry points into it and creates the `$EDITOR` Pane. The service reads no catalog: callers pass a URL or a Host and a path.
