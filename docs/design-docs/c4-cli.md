# Design Doc: C4 — CLI (`tc`)

**Status:** Draft
**Author:** Claude (autonomous, on behalf of Gump)
**Date:** 2026-04-20

## Context and Scope

[Capability C4](../product-spec.md#core-capabilities) is the command-line interface injected into every Pane. It is the **programmable user surface** for controlling the running touch-code app from inside any shell — creating Spaces, adding Projects, spinning up Worktrees, opening Panes, routing text across Panes, invoking hooks, handing a Worktree off to an external editor, and installing the published Agent Skill into a coding agent's directory.

The CLI exists because this product is a terminal-first orchestrator for CLI-agent power users. Every workflow touch-code enables — `tc pane open`, `tc send`, `tc broadcast`, `tc open`, `tc skill install --claude-code` — has to be reachable from the same shell the user already lives in. A coding agent reading the [published Skill](../product-spec.md#core-capabilities) (C5) learns *how* to drive touch-code exclusively through `tc`; the app's GUI is a complement, not a replacement.

Sibling components already defined:
- **[TouchCodeCore](../architecture.md#tuist-targets-under-appsmac)** — leaf package with all domain types (`Space`, `Project`, `Worktree`, `Tab`, `Pane`, IDs). The CLI depends on this for wire types.
- **[TouchCodeIPC](../architecture.md#ipc)** — JSON-RPC wire protocol over Unix socket (Release: `/tmp/touch-code-$UID.sock`; Debug: `/tmp/touch-code-dev-$UID.sock`). The CLI is the reference client; the app is the reference server. This doc adds the `hierarchy.*`, `terminal.*`, `git.*`, `skill.*`, `system.*`, and `hook.*` method contracts.
- **[HierarchyManager / CatalogStore](0001-terminal-and-hierarchy.md)** — the app-side writers for every mutation the CLI triggers. Every CLI subcommand anchors to one method on `HierarchyManager` or one `Process`-driven call (for `git`, `open`).
- **[C3 lifecycle hooks](c3-lifecycle-hooks.md)** — defines `HookEvent`, `HookSubscription`, `HookEnvelope`, and the `hook.*` RPC methods. This doc wires those to the `tc hook …` subcommand surface.
- **[Architecture](../architecture.md)** — dependency direction (`tc` may import `TouchCodeCore` and `TouchCodeIPC` only; never `Runtime`, `Hooks`, `Git`, or `App`), invariants (`tc` is stateless; identifiers are UUIDs resolved from convenience aliases; all IPC through the socket).

Open questions from the product spec and architecture that this doc resolves:
- **Product-spec Open Q #1** — *CLI binary name.* Resolved: **keep `tc` as the primary; `tcode` as fallback installed automatically when `tc` is already claimed.** See [Decisions](#decisions) §D1 and the [Collision check](#collision-check-plan-for-tc--tcode) section.
- **Architecture Open Q #3** — *CLI binary distribution.* Resolved: install into `/usr/local/bin/{tc,tcode}` from the Settings → Developer pane via a single macOS administrator-authorization dialog. See [Decisions](#decisions) §D3 and the dedicated design doc [`cli-install-system-bin.md`](cli-install-system-bin.md).
- **Architecture Open Q #5** — *IPC backpressure for CLI clients.* Resolved: per-connection bounded in-flight queue of 64; additional requests block up to 2s then fail with `IPCError.overloaded`. See [Decisions](#decisions) §D11.

Out of scope (owned elsewhere):
- **Runtime-side implementation** of any RPC method — the app-side `SocketServer` routing lives under `apps/mac/touch-code/App/Features/Socket/` and is implemented per exec-plan. This doc defines the *contract*, not the server handlers.
- **GUI / deep-link equivalents** — `touch-code://` URLs are routed through the same IPC methods ([Architecture §URL scheme](../architecture.md#url-scheme)); the URL-scheme parser is owned by the deeplink feature, not by `tc`.
- **Skill-package content** — `touch-code-skill/` is an independent directory with its own `SKILL.md`. This doc defines the *install verb* (`tc skill install`) and the filesystem layout it writes to, not the Skill's documentation content.

## Goals and Non-Goals

### Goals

- **Cover the full verb set the product spec promises.** Spaces, Projects, Worktrees, Tabs, Panes, cross-pane `send`, cross-pane `broadcast`, skill install, external editor `open`, lifecycle hooks. Every verb in the product spec C4 row has a subcommand.
- **Machine-friendly by default, human-friendly on a TTY.** Default output on stdout-is-TTY is compact plain text; `--json` emits JSON matching the RPC result schema 1:1 so agents never have to scrape.
- **Stateless thin RPC client.** `tc` never reads, writes, or caches any persistent file of its own. The only exception is `tc skill install`, which copies bundled skill files into the agent's skill directory — a one-shot write, not ongoing state.
- **In-Pane ergonomics.** Every command defaults to "the current Pane / Tab / Worktree" by reading env vars the app injected. Explicit flags (`--pane`, `--tab`, `--worktree`) override. Commands run from a plain shell (no env) ask interactively or fail with a precise error.
- **Convenience aliases resolve to UUIDs before any mutation.** Users can address "pane 2 in the current tab" with `tc pane focus 2`; internal code always sees `PaneID`. The resolver is a small pure module in `tc` that calls read-only IPC methods.
- **One wire protocol, two transports.** The CLI speaks JSON-RPC over Unix socket. Deep-link URLs (`touch-code://…`) map onto the same methods on the app side. A CLI-authored command and a deep-link-authored command are indistinguishable downstream.
- **Completion and discoverability.** `tc --generate-completion-script` writes zsh / bash / fish completions; `tc --help` surfaces grouped subcommands; `tc <verb> --help` shows inline examples for every verb.
- **Fail fast and legibly.** Socket missing → "touch-code is not running. Start it from Spotlight or run `open -a touch-code`." Schema mismatch → "`tc` v0.2.0 cannot speak to touch-code v0.1.5 — hook.install was added in v0.2.0." Exit codes are stable and enumerable.

### Non-Goals

- **Local-only fallback or read-only mode without the app running.** `tc` is a controller; if the app isn't running it errors. It does not spawn the app in every command path (only `tc open` / `tc pane open --launch-app` may, see [Decisions](#decisions) §D4).
- **Scripting language embedding.** No `tc eval '<js>'`. Scripting happens through hook handlers (see [C3](c3-lifecycle-hooks.md)).
- **Package management.** `tc` does not install touch-code itself — Sparkle / DMG handle that. The only installation `tc` performs is copying Skill directories via `tc skill install`.
- **Multi-app discovery.** One running touch-code per user. Two instances is an error state the socket-discovery probe reports as "ambiguous"; the user is instructed to quit one.
- **File-system editing.** No `tc file open` or `tc file edit`. Editor integration is strictly *directory-level* ([Product spec C8 / Open Q #7](../product-spec.md#open-questions)); `tc open [--in <editor>]` opens the Worktree directory.
- **Remote control.** No TCP, no SSH. The socket is local; remote workflows are out-of-scope for v1.
- **Interactive UIs.** No TUI menus. A missing required argument errors; an `--interactive` flag is explicitly rejected at parser level. Agents don't interact; humans script.
- **Shell function or alias shimming.** `tc` is a real binary. We do not ship a `eval "$(tc init zsh)"` shell-integration layer in v1; integration points remain the env vars and the completion script.

## Design

### Overview

`tc` is a single ArgumentParser-rooted binary that resolves a subcommand path, builds a typed RPC request, opens the Unix socket (or errors), sends a newline-framed length-prefixed JSON envelope, reads the response, optionally streams further responses (for `hook tail` etc.), and renders to stdout.

**Why this shape:**

- **ArgumentParser is the single framework.** Both reference projects (supacode, supaterm) use Apple's ArgumentParser. Subcommand composition, completion-script generation, `--help`, and `--version` are all built-in. No custom dispatch loop.
- **Thin RPC client, not a microshell.** Every subcommand is ~30-60 lines of code that translates args → `IPC.Request` → renderer. Logic lives app-side on purpose: we never want "two sources of truth" about whether a Worktree can be deleted.
- **JSON-RPC with typed method enum.** `IPC.Method` is a Swift enum in `TouchCodeIPC`; both client and server switch over the same value. No stringly-typed method names sprinkled across call sites.
- **Aliases are convenience; UUIDs are truth.** An `AliasResolver` pre-flights every command that names a Pane/Tab/Worktree by anything other than a UUID. Resolution is one read-only IPC round trip (`hierarchy.resolveAlias`). The resolver is offline-first for pure-UUID strings (no round-trip).
- **Output is a renderer step, not interleaved print calls.** Every command returns a `Rendered` value the top-level entry point prints exactly once. Text and JSON modes are separate rendering paths over the same result type, so we cannot accidentally ship a command that only works in one mode.

### System Context Diagram

```
  ┌──────────────────────┐        ┌──────────────────────────┐
  │ user shell / agent    │        │ touch-code app           │
  │  (inside any Pane)   │        │   IPC.SocketServer       │
  │                       │        │   ├── hierarchy.*        │
  │  $ tc pane open …    │        │   ├── terminal.*         │
  │       │               │        │   ├── git.*              │
  │       ▼               │        │   ├── skill.*            │
  │  tc binary            │        │   ├── hook.*             │
  │   (ArgumentParser)    │   socket   │   └── system.*           │
  │       │               │──────►│   ────── routes ─────    │
  │   AliasResolver       │  JSON │    HierarchyManager      │
  │   RPCClient           │       │    TerminalEngine        │
  │   Renderer            │       │    HookDispatcher        │
  │       │               │       │    GitWorktreeCLI        │
  │       ▼               │       │    SkillInstaller        │
  │   stdout (text / JSON) │       │                          │
  │   stderr (errors)     │       └──────────────────────────┘
  └───────────────────────┘

  Socket path resolution order:
    1. $TOUCH_CODE_SOCKET_PATH          (set by the app in every Pane's env)
    2. build-channel default socket     (Debug: /tmp/touch-code-dev-$UID.sock; Release: /tmp/touch-code-$UID.sock)
    3. launch + wait up to 10s          (only when --launch-app or `tc open` passed)

  Injected env vars inside every Pane:
    TOUCH_CODE_SOCKET_PATH, TOUCH_CODE_SPACE_ID, TOUCH_CODE_PROJECT_ID,
    TOUCH_CODE_WORKTREE_ID, TOUCH_CODE_WORKTREE_PATH, TOUCH_CODE_TAB_ID,
    TOUCH_CODE_PANE_ID
```

### Collision check plan for `tc` / `tcode`

**Surface.** The binary ships as `tc` with `tcode` as a *peer* symlink. Both are symlinked into `/usr/local/bin/` by the user from Settings → Developer; the privileged write is one admin-auth dialog. If a foreign `tc` already exists at `/usr/local/bin/tc`, the installer aborts with `.collision(owner:)` and no symlinks are written; the user removes the foreign tool or accepts using `tcode` only.

**Detection (read-only; runs on every Settings card render):**

1. Inspect `/usr/local/bin/tc` and `/usr/local/bin/tcode` without privileges via `lstat` / `readlink`. Classify each as `absent` / `ourSymlink` (resolves to our bundled binary) / `foreign`. See `CLIInstallerClient.inspect(_:)`.
2. Any `foreign` classification is reported as `.collision(owner:)`; the install button retries (the user is expected to clear the collision themselves before retrying).
3. `which -a tc` is no longer used; the unprivileged inspect on the canonical path is sufficient and avoids spawning a process per Settings render.

**User prompt.** On collision the Settings card's `ErrorRow` reads: "Another file exists at `/usr/local/bin/tc`. Rename or remove it, then retry — touch-code will not overwrite a tool it did not install." (See `CLIInstallError.destinationExistsNotOurs.errorDescription`.) No system-level dialog appears for collisions — only for the actual privileged install.

**Test matrix.** Unit tests cover four scenarios via `RecordingPrivilegedShell` in `CLIInstallerClientTests.swift`: (a) fresh machine, both absent, (b) collision on `tc` only, (c) collision on `tcode` only, (d) idempotent re-install when both already point at our bundle. Manual smoke verifies a real Homebrew `tc` collision case.

**Documentation.** The published Skill and README use `tc` in examples but open with a one-line note: "If your system already has a `tc` command, use `tcode` — the subcommands are identical." All shell completion files ship with both names installed.

**Removal.** Settings → Developer's Uninstall button runs the symmetric privileged script (`rm /usr/local/bin/tc /usr/local/bin/tcode`) when both are ours. Foreign entries are refused with the same collision error. Legacy `~/.local/bin/{tc,tcode}` symlinks from prior versions are cleaned up automatically as part of Install (see [`cli-install-system-bin.md`](cli-install-system-bin.md) §Migration).

### API Design

Every subcommand maps to a single IPC method call (sometimes preceded by a read-only resolve call). The table below is the complete verb set; each row lists the subcommand path, the IPC method, the underlying `HierarchyManager` / `TerminalEngine` / `HookDispatcher` / `GitWorktreeCLI` entry point it drives, and the most-used arguments.

Columns:
- **Subcommand** — what the user types.
- **IPC method** — the `IPC.Method` dispatched; added to `TouchCodeIPC` if not already defined.
- **Anchors to** — the existing/new HierarchyManager/Runtime/Git entry point.
- **Args** — the main required + optional flags.

#### `tc space …`

| Subcommand                  | IPC method              | Anchors to                                     | Args                                           |
|-----------------------------|-------------------------|------------------------------------------------|------------------------------------------------|
| `tc space list`             | `hierarchy.listSpaces`  | `CatalogStore.load().spaces` (read-only)       | `[--json]`                                     |
| `tc space create NAME`      | `hierarchy.createSpace` | `HierarchyManager.createSpace(name:)`          | `NAME`, `[--activate]`                         |
| `tc space rename ID NAME`   | `hierarchy.renameSpace` | `HierarchyManager.renameSpace(_:name:)`        | `ID` (alias ok), `NAME`                        |
| `tc space remove ID`        | `hierarchy.removeSpace` | `HierarchyManager.removeSpace(_:)`             | `ID`, `[--force]`                              |
| `tc space activate ID`      | `hierarchy.activateSpace` | `HierarchyManager.activateSpace(_:)` (new)   | `ID`                                           |
| `tc space show [ID]`        | `hierarchy.describeSpace` | read-only projection                          | `[ID]` defaults to `$TOUCH_CODE_SPACE_ID`      |

Example: `tc space create "day job" --activate` → resolves to `POST {"method": "hierarchy.createSpace", "params": {"name": "day job", "activate": true}}`; prints the new SpaceID on stdout in text mode, `{"id": "uuid", "name": "day job"}` in JSON mode.

#### `tc project …`

| Subcommand                        | IPC method                   | Anchors to                                           | Args                                                    |
|-----------------------------------|------------------------------|------------------------------------------------------|---------------------------------------------------------|
| `tc project list`                 | `hierarchy.listProjects`     | `CatalogStore.load().spaces[*].projects`             | `[--space ID] [--json]`                                 |
| `tc project add PATH`             | `hierarchy.addProject`       | `HierarchyManager.addProject(rootPath:)`             | `PATH`, `[--space ID] [--name NAME] [--editor NAME]`    |
| `tc project remove ID`            | `hierarchy.removeProject`    | `HierarchyManager.removeProject(_:)`                 | `ID`, `[--force]`                                       |
| `tc project rename ID NAME`       | `hierarchy.renameProject`    | `HierarchyManager.renameProject(_:name:)`            | `ID`, `NAME`                                            |
| `tc project set-editor ID NAME`   | `hierarchy.setProjectEditor` | `HierarchyManager.setDefaultEditor(_:editor:)`       | `ID`, `NAME` (vscode/cursor/zed/xcode/subl/finder)      |
| `tc project show [ID]`            | `hierarchy.describeProject`  | read-only                                            | `[ID]` defaults to `$TOUCH_CODE_PROJECT_ID`             |

`tc project add` implicitly runs `git rev-parse --show-toplevel` via the app-side `GitWorktreeCLI.discoverGitRoot`; for non-git directories (product-spec Open Q #3 leaning — *allow, but Worktree-less*) the Project is created with a single synthetic Worktree and `supportsWorktrees: false`.

#### `tc worktree …`

| Subcommand                              | IPC method                | Anchors to                                                         | Args                                                          |
|-----------------------------------------|---------------------------|--------------------------------------------------------------------|---------------------------------------------------------------|
| `tc worktree list`                      | `hierarchy.listWorktrees` | `CatalogStore.load()` + `GitWorktreeCLI.listWorktrees`              | `[--project ID] [--json]`                                     |
| `tc worktree create BRANCH`             | `hierarchy.createWorktree`| `HierarchyManager.createWorktree(projectID:branch:path:)`           | `BRANCH`, `[--project ID] [--path PATH] [--from-branch BASE]` |
| `tc worktree remove ID`                 | `hierarchy.removeWorktree`| `HierarchyManager.removeWorktree(_:keepDirectory:)`                 | `ID`, `[--keep-directory] [--force]`                          |
| `tc worktree activate ID`               | `hierarchy.activateWorktree`| `HierarchyManager.selectWorktree(_:)`                             | `ID`                                                          |
| `tc worktree rename ID NAME`            | `hierarchy.renameWorktree`| `HierarchyManager.renameWorktree(_:name:)`                          | `ID`, `NAME`                                                  |
| `tc worktree show [ID]`                 | `hierarchy.describeWorktree`| read-only                                                        | `[ID]` defaults to `$TOUCH_CODE_WORKTREE_ID`                  |
| `tc worktree prune`                     | `hierarchy.pruneWorktrees`| `HierarchyManager.pruneWorktreesMissingOnDisk(project:)`            | `[--project ID]`                                              |

Default `--path` resolution for `tc worktree new` is server-side: the daemon expands the project's configured `worktreesDirectory` (from `settings.json`, falling back to `~/.touch-code/repos/<projectName>`) and appends the sanitized branch name, mirroring the Create Worktree sheet. The response includes the resolved absolute path. Pass `--path` to override.

#### `tc tab …`

| Subcommand                      | IPC method            | Anchors to                                                    | Args                                                  |
|---------------------------------|-----------------------|---------------------------------------------------------------|-------------------------------------------------------|
| `tc tab list`                   | `hierarchy.listTabs`  | `CatalogStore.load()` filtered to `--worktree`                | `[--worktree ID] [--json]`                            |
| `tc tab create [NAME]`          | `hierarchy.createTab` | `HierarchyManager.createTab(in:name:)`                        | `[NAME]`, `[--worktree ID] [--activate]`              |
| `tc tab close ID`               | `hierarchy.closeTab`  | `HierarchyManager.closeTab(_:)`                               | `ID`, `[--force]`                                     |
| `tc tab activate ID`            | `hierarchy.activateTab`| `HierarchyManager.selectTab(_:)`                             | `ID`                                                  |
| `tc tab rename ID NAME`         | `hierarchy.renameTab` | `HierarchyManager.renameTab(_:name:)`                         | `ID`, `NAME`                                          |
| `tc tab show [ID]`              | `hierarchy.describeTab`| read-only                                                    | `[ID]` defaults to `$TOUCH_CODE_TAB_ID`               |

#### `tc pane …`

| Subcommand                                 | IPC method                  | Anchors to                                                          | Args                                                                     |
|--------------------------------------------|-----------------------------|---------------------------------------------------------------------|--------------------------------------------------------------------------|
| `tc pane list`                            | `hierarchy.listPanes`      | `CatalogStore.load()` filtered to `--tab`                           | `[--tab ID] [--worktree ID] [--json]`                                    |
| `tc pane open [CMD]`                      | `hierarchy.openPane`       | `HierarchyManager.openPanel(in:tab:workingDirectory:initialCommand:)`| `[CMD]`, `[--tab ID] [--cwd PATH] [--activate] [--label TAG]...`         |
| `tc pane split`                           | `hierarchy.splitPane`      | `HierarchyManager.splitPanel(_:direction:)`                         | `[--pane ID] [--direction h|v] [--ratio 0.5]`                           |
| `tc pane close ID`                        | `hierarchy.closePane`      | `HierarchyManager.closePanel(_:)`                                   | `ID`, `[--force]`                                                        |
| `tc pane focus ID`                        | `hierarchy.focusPane`      | `HierarchyManager.focusPanel(_:)`                                   | `ID`                                                                     |
| `tc pane resize PANE AXIS PX|CELLS`      | `hierarchy.resizePane`     | `HierarchyManager.resizeSplit(containingPanel:axis:deltaPx:)`       | `PANE`, `AXIS` (x/y), value (`+10px`/`-3cells`)                         |
| `tc pane zoom ID`                         | `hierarchy.zoomPane`       | `HierarchyManager.zoomPanel(_:)`                                    | `ID`                                                                     |
| `tc pane unzoom`                          | `hierarchy.unzoomPane`     | `HierarchyManager.unzoomPanel(tab:)`                                | `[--tab ID]`                                                             |
| `tc pane retry ID`                        | `terminal.retryPane`       | `TerminalEngine.retryPanel(id:)`                                    | `ID`                                                                     |
| `tc pane label ID TAG...`                 | `hierarchy.setPaneLabels`  | `HierarchyManager.setPanelLabels(_:labels:)`                        | `ID`, `TAG...`, `[--replace]`                                            |
| `tc pane show [ID]`                       | `hierarchy.describePane`   | read-only                                                           | `[ID]` defaults to `$TOUCH_CODE_PANE_ID`                                |
| `tc pane info`                            | `hierarchy.describePane`   | read-only                                                           | alias for `tc pane show` with terser output                             |

`tc pane open` is the most-used command; defaults:
- `--tab` falls back to `$TOUCH_CODE_TAB_ID`, then to the active Tab in the active Worktree.
- `--cwd` falls back to the Worktree's `path`.
- `CMD` falls back to the user's default login shell.
- `--activate` is default-on (focus the new Pane) unless `TOUCH_CODE_PANEL_OPEN_NO_ACTIVATE=1`.

#### `tc send` / `tc broadcast`

| Subcommand                                          | IPC method               | Anchors to                                                   | Args                                                                 |
|-----------------------------------------------------|--------------------------|--------------------------------------------------------------|----------------------------------------------------------------------|
| `tc send TARGET TEXT`                               | `terminal.sendInput`     | `TerminalEngine.sendInput(paneID:text:raw:)`                | `TARGET` (UUID / index / label), `TEXT`, `[--raw] [--newline]`       |
| `tc send TARGET --stdin`                            | `terminal.sendInput`     | same                                                         | `TARGET`, reads stdin until EOF                                      |
| `tc broadcast --tab ID TEXT`                        | `terminal.broadcastInput`| `TerminalEngine.broadcastInput(scope:text:raw:)`             | `--tab ID`, `TEXT`, `[--raw] [--newline]`                            |
| `tc broadcast --worktree ID TEXT`                   | `terminal.broadcastInput`| same                                                         | `--worktree ID`, `TEXT`, `[--raw] [--newline]`                       |
| `tc broadcast --label TAG TEXT`                     | `terminal.broadcastInput`| same                                                         | `--label TAG`, `TEXT`, `[--raw] [--newline]`                         |
| `tc broadcast --space ID TEXT`                      | `terminal.broadcastInput`| same                                                         | `--space ID`, `TEXT`, `[--raw] [--newline]`                          |

`TEXT` is the literal argv string; `--raw` sends bytes verbatim without appending newline; `--newline` appends `\r\n` (default is no appended newline, matching `printf`). Only one broadcast scope flag may be present; mutual exclusion enforced by ArgumentParser.

Behaviourally, `tc send` and `tc broadcast` use the same IPC method (`terminal.sendInput`) under the hood — broadcast is a server-side fan-out with a `scope` discriminator, saving the client from enumerating targets.

#### `tc skill …`

| Subcommand                           | IPC method               | Anchors to                                          | Args                                                              |
|--------------------------------------|--------------------------|-----------------------------------------------------|-------------------------------------------------------------------|
| `tc skill list`                      | `skill.listAgents`       | `SkillInstaller.listAgents()`                       | `[--json]`                                                        |
| `tc skill install --claude-code`     | `skill.install`          | `SkillInstaller.install(agent:mode:)`               | one of `--claude-code` / `--codex` / `--pi`, `[--symlink] [--force]`|
| `tc skill uninstall --claude-code`   | `skill.uninstall`        | `SkillInstaller.uninstall(agent:)`                  | one of the three flags                                            |
| `tc skill path`                      | `skill.bundlePath`       | read-only (inside app bundle resources)             | `[--json]`                                                        |
| `tc skill check`                     | `skill.check`            | `SkillInstaller.check(agent:)`                      | `[--claude-code|--codex|--pi]` (default: all)                     |

`tc skill install --claude-code` by default **symlinks** the app-bundled skill at `<app>/Contents/Resources/touch-code-skill/` into `~/.claude/skills/touch-code/`. With `--symlink=false` it copies. Version alignment is enforced by the app refusing to symlink if the target agent's skills directory belongs to a different user or if the target already exists with non-touch-code content.

#### `tc open …`

| Subcommand                                        | IPC method              | Anchors to                                              | Args                                                                        |
|---------------------------------------------------|-------------------------|---------------------------------------------------------|-----------------------------------------------------------------------------|
| `tc open [--in EDITOR]`                           | `system.openInEditor`   | `ExternalEditor.open(worktreeID:editor:)`               | `[--worktree ID] [--in EDITOR]`                                             |
| `tc open --path PATH [--in EDITOR]`               | `system.openPath`       | `ExternalEditor.openPath(path:editor:)`                 | `--path PATH`, `[--in EDITOR]`                                              |
| `tc open finder`                                  | alias for `--in finder` | same                                                    |                                                                             |

`EDITOR` is one of `vscode|cursor|zed|xcode|subl|finder|<custom>`. Custom entries read from `settings.json.externalEditors[NAME]` — user-defined templates like `"windsurf": "/Applications/Windsurf.app/Contents/MacOS/Windsurf %p"` where `%p` expands to the path. Resolves product-spec Open Q #7's leaning: built-in allowlist + user templates.

Default editor: project-level (`Project.defaultEditor`) wins over global (`settings.json.defaultEditor`), which falls back to `vscode` if installed else `finder`.

#### `tc hook …`

All hook verbs map to the `hook.*` RPC methods defined in [C3 §IPC wire protocol additions](c3-lifecycle-hooks.md#ipc-wire-protocol-additions).

| Subcommand                                         | IPC method        | Args                                                                    |
|----------------------------------------------------|-------------------|-------------------------------------------------------------------------|
| `tc hook list`                                     | `hook.list`       | `[--event E] [--pane ID] [--json]`                                     |
| `tc hook install FILE` / `tc hook install -`       | `hook.install`    | reads one subscription JSON from FILE or stdin                          |
| `tc hook remove ID`                                | `hook.remove`     | `ID`                                                                    |
| `tc hook enable ID` / `tc hook disable ID`         | `hook.enable`     | `ID`                                                                    |
| `tc hook reload`                                   | `hook.reload`     |                                                                         |
| `tc hook test ID [--payload PATH]`                 | `hook.test`       | `ID`, `[--payload PATH]` (synthetic envelope)                           |
| `tc hook fire EVENT [--pane ID] [--data JSON]`    | `hook.fire`       | `EVENT`, scope flags, `[--data JSON]`                                   |
| `tc hook recent [--limit N]`                       | `hook.recent`     | `[--limit N]`                                                           |
| `tc hook tail [--event E]`                         | `hook.events`     | *(streaming)* — reads the `hook.events` stream; prints NDJSON           |
| `tc hook edit`                                     | local file op     | opens `~/.config/touch-code/hooks.json` in `$EDITOR`; followed by reload|

#### Read-only helpers (no user-facing verb)

These RPCs are invoked by `tc` internals (the `AliasResolver`, `--version`, the handshake) rather than by a top-level verb. Documented here so the planner can generate stubs alongside the user-facing commands.

| IPC method                      | Anchors to                                                | Purpose                                                                 |
|---------------------------------|-----------------------------------------------------------|-------------------------------------------------------------------------|
| `system.hello`                  | `SocketServer.handshake(_:)`                              | Connection-scoped handshake; first frame of every connection (see [Wire protocol](#wire-protocol)) |
| `hierarchy.resolveAlias`        | `AliasResolverService.resolve(_:contextPaneID:)`         | Convert `{kind, value, contextPaneID}` → canonical UUID; backs every non-UUID alias in `AliasResolver` |
| `hierarchy.resolvePaneLabel`   | `HierarchyManager.panelsMatching(label:)`                 | List panes carrying a label; internal path for `@label` aliases         |
| `hierarchy.resolveWorktreeGlob` | `HierarchyManager.worktreesMatching(pathGlob:)`           | Resolve a path glob to Worktree UUIDs                                    |

#### `tc system …` (utility)

| Subcommand               | IPC method              | Purpose                                                                      |
|--------------------------|-------------------------|------------------------------------------------------------------------------|
| `tc system status`       | `system.status`         | App version, socket path, connected-clients count, uptime                    |
| `tc system ping`         | `system.ping`           | Health probe; exit 0 if responsive                                           |
| `tc system version`      | `system.version`        | Bundle version + build; compatible with `tc --version`                        |
| `tc system quit`         | `system.quit`           | Gracefully quit the app (same as Cmd-Q)                                       |
| `tc system launch`       | *(local)*                | Launch the app via `open -a touch-code` if not running; wait up to 10s        |
| `tc system sockets`      | *(local)*                | Print discovered socket paths and the one in use; no app round-trip          |

#### Globals

Every subcommand accepts:
- `--json` — machine-readable output.
- `--socket PATH` — override `$TOUCH_CODE_SOCKET_PATH` discovery.
- `--verbose` / `-v` — log to stderr at `debug`; repeat for `trace`.
- `--no-color` — disable ANSI colour in human mode.
- `--timeout SECONDS` — client-side timeout override (default 10s for unary, unlimited for streaming).
- `--help` / `-h` — inline help for this verb.

And the top-level `tc`:
- `--version` / `-V` — prints binary and requests app version when socket is reachable.
- `--generate-completion-script zsh|bash|fish` — stdout completion script.
- `--man` — prints groff man page to stdout (pipable to `man -l -`).

### Wire protocol

Reuses the envelope spec from [architecture §IPC](../architecture.md#ipc). Additions:

- **Request framing** remains length-prefix newline header. `TouchCodeIPC.Framing` is unchanged.
- **Method enum.** Expanded `IPC.Method` covers every RPC listed above. Method strings are lowercase-dotted (`hierarchy.createSpace`, `terminal.sendInput`).
- **Streaming termination contract (shared with [C3 §IPC wire protocol additions](c3-lifecycle-hooks.md#ipc-wire-protocol-additions)).** Server-streaming methods (`hook.events`, and any future stream) set `stream: true` on the request. The server emits `{id, stream: true, result: …}` frames. The stream ends when **either** side closes its write half:
  - *Server-initiated graceful end.* Server sends a final `{id, stream: false, error?: …}` frame, then shuts down its write side. Client reads EOF after the final frame and exits cleanly.
  - *Client-initiated end.* Client shuts down its write side (`shutdown(SHUT_WR)`). Server observes the EOF, flushes any in-flight frames, sends a final `{id, stream: false}` frame (no error), closes its write side. Client reads up to the final frame, then EOF.
  - *Abrupt socket close on either side.* The other end treats it as end-of-stream with an implicit `.internal` error; the CLI maps this to a stderr warning ("server closed stream") and exits with code 0 (documented in [Error handling](#error-handling-model) §R9). No re-send.
  Clients that don't understand streaming and call a streaming method get back a single `{id, stream: false, error: "streamingNotSupported"}` response and no further frames.
- **Error codes.** `IPCError` extends to include:
  - `.unknownMethod(String)` — method not recognised.
  - `.invalidParams(String, path: [String]?)` — decode failure with JSON path.
  - `.notFound(kind: String, id: String)` — hierarchy lookup miss.
  - `.conflict(reason: String)` — e.g., directory already exists.
  - `.unsupported(reason: String)` — e.g., worktree op on non-git project.
  - `.internal(String)` — opaque; stderr log only.
  - `.overloaded` — backpressure (see [Decisions](#decisions) §D11).
  - `.versionMismatch(client: String, server: String)` — schema incompatibility.
- **Compatibility handshake.** The handshake is a dedicated first-frame RPC, `system.hello` — **not** a per-request header (a per-request header would double-encode version info for every call and conflict with the "one stream per connection" rule in [D10](#decisions)). Connection opens → client sends `{"id": "h0", "method": "system.hello", "params": {"clientVersion": "0.2.0", "clientBinary": "tc"}}` → server responds `{"id": "h0", "result": {"serverVersion": "0.2.0", "appBundleVersion": "0.2.0+142", "protocolMajor": 1, "protocolMinor": 3, "deprecatedMethods": [...]}}`. Major-version skew surfaces as `.versionMismatch`; minor-version skew surfaces as a stderr warning the CLI prints once per session. After `system.hello`, the connection carries exactly one unary call or one stream (per [D10](#decisions)); subsequent calls open fresh connections, each with its own `system.hello`. The `tc` client batches handshake + real request as two pipelined frames so the extra round trip does not add latency on warm sockets.

### Addressing and alias resolution

`TARGET` arguments accept five forms, resolved in this order by `AliasResolver`:

1. **UUID.** Any well-formed UUID string is assumed to be the canonical ID. No round trip; validated locally.
2. **`current` / `.`** — resolves via `$TOUCH_CODE_{PANE,TAB,WORKTREE,SPACE}_ID` depending on the expected kind.
3. **Index.** For Panes: `1`-based position in the current Tab's `splitTree.leaves()`. For Tabs: position in the current Worktree's `tabs[]`. For Worktrees: position in the current Project's `worktrees[]`. (One-based on the CLI side to match humans; zero-based internally.)
4. **Label.** Panes only: `@agent` resolves via `hierarchy.resolvePaneLabel`. Errors out with `.conflict` if more than one pane matches.
5. **Path glob.** Worktrees only: `'**/exp/*'` resolves via `hierarchy.resolveWorktreeGlob`. Errors on zero or multiple matches unless the verb is list-shaped.

All non-UUID resolution is one round-trip to `hierarchy.resolveAlias({kind, value})` before the actual method call. The CLI caches the resolver result for the duration of a single `tc` invocation but never across invocations.

### Data model changes (`TouchCodeCore`)

- **Project.defaultEditor** (String?) already exists per exec-plan-0002 interfaces; documented here as the anchor for `tc project set-editor` and `tc open --in` fallback.
- **Project.supportsWorktrees** (Bool, computed `gitRoot != nil`) already exists on the `Project` struct (see `apps/mac/TouchCodeCore/Project.swift`) and is exec-plan-0002-defined. The CLI reads it to gate `tc worktree create` / `tc worktree remove` on non-git Projects: the commands return `.unsupported(reason: "project does not support git worktrees")` (exit code 4) when it is false. `tc project add` against a non-git path still succeeds and creates a single synthetic Worktree whose `path == Project.rootPath` and `branch == nil`; `tc worktree list --project <id>` lists that single row.
- **Pane.labels** (Set<String>) — added alongside C3's subscription-scope matching (see [C3 D10](c3-lifecycle-hooks.md#decisions)). Persisted on the `Catalog`. Additive field; no schema bump.
- **Single canonical writer for `Pane.labels`.** All mutation paths — this doc's `tc pane label` CLI verb, C3's `HookAction.setPanelLabels`, and any future in-app UI — route through `HierarchyManager.setPanelLabels(_:labels:replace:)`. The CLI's `tc pane label` is a thin wrapper around the `hierarchy.setPaneLabels` RPC, which the app dispatches directly to that single method. Mirrors the invariant recorded on the C3 side ([C3 §Data model changes](c3-lifecycle-hooks.md#data-model-changes-touchcodecore)).
- **No new top-level types.** All CLI result types are projections over existing `Space` / `Project` / `Worktree` / `Tab` / `Pane` with optional context.

New wire-only types in `TouchCodeIPC`:

```swift
public struct BroadcastScope: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case tab, worktree, space, label }
  public let kind: Kind
  public let target: String          // UUID string or label
}

public struct PaneOpenRequest: Codable, Equatable, Sendable {
  public let tabID: TabID?
  public let workingDirectory: String?
  public let initialCommand: String?
  public let labels: [String]
  public let activate: Bool
}

public struct AliasResolveRequest: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case space, project, worktree, tab, pane }
  public let kind: Kind
  public let value: String
  public let contextPaneID: PaneID?   // for "current" / indices
}

public struct AliasResolveResult: Codable, Equatable, Sendable {
  public let kind: AliasResolveRequest.Kind
  public let id: UUID
  public let disambiguations: [UUID]?   // non-empty only when the verb is list-shaped
}
```

### Component Boundaries

```
apps/mac/tc/                          (the CLI binary)
├── main.swift                        ArgumentParser root + global flags
├── Commands/
│   ├── SpaceCommands.swift           tc space *
│   ├── ProjectCommands.swift         tc project *
│   ├── WorktreeCommands.swift        tc worktree *
│   ├── TabCommands.swift             tc tab *
│   ├── PaneCommands.swift           tc pane *
│   ├── SendBroadcastCommands.swift   tc send / tc broadcast
│   ├── SkillCommands.swift           tc skill *
│   ├── OpenCommand.swift             tc open
│   ├── HookCommands.swift            tc hook *
│   └── SystemCommands.swift          tc system *
├── Transport/
│   ├── RPCClient.swift               envelope build/parse, streaming read
│   ├── SocketDiscovery.swift         $TOUCH_CODE_SOCKET_PATH → build-channel default socket → launch
│   ├── AliasResolver.swift           UUID/./current/index/label/glob → UUID
│   └── Framing.swift                 re-exports TouchCodeIPC framing
└── Render/
    ├── TextRenderer.swift
    └── JSONRenderer.swift

Dependencies:
  tc → TouchCodeCore, TouchCodeIPC, ArgumentParser
  tc ⇍ Runtime, Hooks, Git, App                   (hard rule)
```

- **Allowed imports in `tc`:** `TouchCodeCore`, `TouchCodeIPC`, `ArgumentParser`, `Foundation`.
- **Forbidden in `tc`:** `AppKit`, `SwiftUI`, `GhosttyKit`, `TCA`, `@Observable`, anything under `touch-code/Runtime|Hooks|Git|App/`. The [architecture dependency rules](../architecture.md#dependency-direction) already state this; reviewer enforces.
- **CLI never talks to disk** except to read/write completion scripts on demand and the bundled Skill copy in `tc skill install`. No ambient config file.
- **`Render/*` has no side effects.** Pure function `(Result, Mode) -> String`.

### Error handling model

- **Exit codes** are stable across versions:
  - `0` — success.
  - `1` — user error (missing arg, unknown subcommand, bad alias).
  - `2` — not-found (hierarchy lookup miss, unknown EDITOR).
  - `3` — conflict (directory exists, duplicate label).
  - `4` — unsupported (worktree op on non-git project).
  - `5` — backpressure / overloaded.
  - `6` — version mismatch.
  - `10` — socket unavailable (app not running).
  - `11` — request timeout (server did not respond within `--timeout` seconds).
  - `12` — launch timeout (`tc system launch` or an auto-launched `tc open` waited longer than the launch budget for the socket to appear).
  - `20` — internal error (bug).
- **Stderr formatting** in text mode:
  - First line: `error: <human message>`.
  - Subsequent lines: `  hint: <suggestion>` if applicable.
  - No backtraces or "please file a bug" boilerplate (matches `git` and Ghostty style).
- **JSON mode** (`--json`) writes `{"ok": false, "error": {"code": "notFound", "message": "...", "path": ["params", "id"]}}` to stderr *and* stdout; stdout JSON preserves machine-readability, stderr duplicate helps log-scraping humans.
- **Cancellation.** SIGINT (Ctrl-C) aborts an in-flight request by closing the socket; partial effects are the app's problem to undo (all mutations are atomic at the `HierarchyManager` level).

### Rollout plan

| Phase              | What ships                                                                                           | Gate                                       |
|--------------------|------------------------------------------------------------------------------------------------------|--------------------------------------------|
| **R1 — scaffold** | `tc`, `tc --version`, `tc system {status,ping,version}`, `--json` plumbing, socket discovery          | `tc` binary first — nothing else          |
| **R2 — reads**     | All read-only commands (`list`, `show`) across every namespace                                       | No app-side mutations required             |
| **R3 — writes**    | `space/project/worktree/tab/pane create|remove|rename|activate` + `pane split|close|focus|label`     | Depends on exec-plan-0002 M5/M6            |
| **R4 — I/O**       | `send`, `broadcast`, `pane retry`, `pane zoom|unzoom|resize`                                      | Depends on `TerminalEngine.sendInput` (M4) |
| **R5 — skill**     | `skill list/install/uninstall/check/path`                                                             | Requires `touch-code-skill/` peer directory|
| **R6 — open**      | `open [--in …]`, editor allowlist, user templates                                                     | Depends on C8 editor integration           |
| **R7 — hooks**     | `hook list/install/remove/enable/reload/test/fire/recent/tail`, `hook events` streaming              | Depends on C3                              |
| **R8 — shell**     | `--generate-completion-script`, `--man`                                                              | Polish pass                                |

Back-compat: the method enum is `Codable(unknownCases: .allow)` on the server — older servers seeing a newer-client method return `IPCError.unknownMethod(methodString)` which the CLI maps to exit 6 with the message "`tc` v<x> requires touch-code ≥ v<y>".

### Testing strategy

- **Parser (`tcTests`):** every subcommand's argument parsing is round-tripped via `ParsableCommand.parseAsRoot`; all flag combinations that yield valid commands are table-driven. Invalid combinations assert the expected `ValidationError`.
- **Renderer (`tcTests`):** for each command result type (`SpaceList`, `PaneShow`, …), golden-file tests for text-mode output; JSON-mode tests compare against the same schema the Swift decoder accepts (proves the renderer is symmetric with the server).
- **AliasResolver (`tcTests`):** table-driven — UUID/`.`/`@label`/index/path-glob all map to canonical IDs; failure modes (ambiguous label, bad index) throw the expected error.
- **RPC client (`tcTests`):** against an `InMemoryIPCServer` harness that mirrors the real server's method table; end-to-end round-trip for one command per namespace.
- **Integration (`tcIntegrationTests`):** runs against a real app built under `xcodebuild`. Launches the app headlessly (`--skip-onboarding`), runs a script of CLI invocations, asserts catalog state and side effects. One end-to-end scenario per [Validation and Acceptance](#validation-and-acceptance).
- **Snapshot tests on help text.** `tc --help` and `tc <verb> --help` are captured as golden files; regressions caught in CI.
- **Completion script smoke tests.** Generated zsh/bash/fish completions are lint-checked with `shellcheck` (bash) and `zsh -n` (zsh parser).

### Validation and acceptance

After R1–R7 land, a fresh shell in a new Pane can execute this script and see the exact effects:

```bash
# Every call should exit 0.
tc system ping
tc space create "validate" --activate
tc project add .
tc worktree create exp/validate
tc tab create agent --activate
tc pane open --label agent --cwd .
tc send @agent 'echo hello from tc\n'
tc broadcast --tab current 'date\n'
tc hook install hooks/notify-agent-done.json
tc hook test $(jq -r .id hooks/notify-agent-done.json)
tc open --in vscode
tc skill install --claude-code
```

Each invocation produces deterministic stdout (asserted in integration tests). A machine-readable driver passes `--json` and asserts structured results.

## Alternatives Considered

### A1 — Rename binary to `touch` or `tch`

Avoids the Linux `tc` collision problem entirely.

**Trade-offs:** `touch` collides with POSIX `touch` (file timestamp); `tch` is unmemorable. Neither is used by either reference project (supacode → `supacode` / `sp`; supaterm → `sp`). Coding agents typing into a chat window will type `tc` faster than `tcode`; ergonomic penalty compounds across an agent's output length budget and a user's muscle memory.

**Verdict:** reject. Keep `tc` as primary; install `tcode` as universal fallback so scripts in the Skill can use either.

### A2 — Build one monolithic `tc command subcommand-path JSON` verb

Instead of typed subcommands, ship a single `tc call METHOD [PARAMS_JSON]` verb that maps 1:1 to RPC methods. Let users script everything around that.

**Trade-offs:** tiny binary; no ArgumentParser. But: no completion, no validation, no discoverability — every user becomes responsible for learning the raw method names. Agents writing CLI calls would produce brittle shell strings. Matches nothing the reference projects did.

**Verdict:** reject. The CLI exposes typed commands only; raw RPC access stays internal to keep the supported surface discoverable and bounded. See [Decisions](#decisions) §D9.

### A3 — gRPC / Cap'n Proto instead of JSON-RPC

Strong schema, code generation, streaming built in.

**Trade-offs:** external codegen toolchain; harder to debug (binary wire); agent-readable JSON is lost; adding a dependency footgun to the whole CLI → app boundary. Every comparable native-Mac app (supacode, supaterm, Ghostty CLI, even Docker CLI's original incarnation) went with JSON-RPC or plain HTTP+JSON for the same reason: the boundary is low-bandwidth and observability outweighs the parse cost.

**Verdict:** reject. Keep JSON-RPC.

### A4 — Let `tc` do partial work without the app running

If the app is down, allow `tc worktree list` by reading `catalog.json` directly; `tc pane open` would launch the app and queue the command.

**Trade-offs:** users can keep querying state offline. But: breaks the "`tc` is stateless" invariant; introduces two code paths for every read; risks divergent "last-known" vs "live" state; prevents hooks from firing on mutations the offline CLI would perform.

**Verdict:** reject. `tc` errors cleanly with "start touch-code first" for every verb except `tc system launch` and `tc skill install` (skill install is a pure file-copy that doesn't need the app running). See [Decisions](#decisions) §D4.

### A5 — Interactive TUI on `tc`

`tc` with no arguments drops into a fuzzy-find interface over Spaces/Projects/Worktrees/Tabs/Panes.

**Trade-offs:** ergonomic for humans. But: hostile to agents (they can't read a TUI); duplicates functionality the GUI already provides; adds a dependency on a TUI library; conflicts with the "scriptable surface" framing.

**Verdict:** reject. If demand emerges, we add a separate `tc-tui` binary that shells out to `tc`; it stays outside the scriptable surface.

### A6 — Embed the alias resolver app-side only (client sends raw string, server resolves)

Simpler client; no `AliasResolver` module.

**Trade-offs:** the client loses the ability to fail fast on malformed UUIDs; every command is a round-trip; error messages about ambiguity come from the server instead of with local-context hints.

**Verdict:** reject. Client-side UUID validation is effectively free; non-UUID aliases go through `hierarchy.resolveAlias` (server side anyway). The CLI doesn't duplicate logic — the *UUID-fast-path* lives in `tc`; the *real resolver* lives in the app.

### A7 — Separate binaries per namespace (`tc-pane`, `tc-hook`, …)

Each namespace ships as its own binary; `tc` is a dispatcher.

**Trade-offs:** small binaries; parallel install. But: violates user expectation from both reference projects; multiplies completion scripts; no clear win on any axis that we actually have.

**Verdict:** reject. Single binary; ArgumentParser subcommands.

## Cross-Cutting Concerns

### Security

- **Socket auth.** The Unix socket is mode `0600` with the user's uid; peer is verified via `SO_PEERCRED` / `LOCAL_PEERCRED` on accept (macOS). Any other uid is closed immediately. This gives us process-level isolation matching other-user accounts without requiring an explicit auth token.
- **Token-based auth (deferred).** Post-v1, connections from another process on the same user could carry a per-app-session token (`$TOUCH_CODE_SESSION_TOKEN` injected alongside the socket path) to support machine-per-user multi-tenancy. Not v1.
- **`tc send` and `tc broadcast`** inject text into Panes — including `\n` — so they can execute shell commands if they target a Pane running a shell. This is *intentional* (agents do exactly this), but it means `tc send` must never be reachable by a foreign process. Same socket auth protects it.
- **`tc open`** shells out via `Process` with an argv array; editor names are validated against the allowlist + user templates; paths are never passed through a shell interpreter.
- **`tc skill install`** only writes into the agent's own configured directory (`~/.claude/skills`, `~/.codex/skills`, `~/.pi/skills`) and refuses to traverse symlinks.

### Observability

- **stderr at `--verbose` / `-v`** prints the request envelope about to be sent and the response received, both pretty-printed JSON, with timing. Mirrors `curl -v` style.
- **`tc system sockets`** prints the discovery path order and which one was chosen; useful when users have multiple sessions or leftover `/tmp` entries.
- **App-side logging.** Every method served under `com.touch-code.ipc` with category equal to the method namespace. Request ids are included so stderr traces from `tc` and app logs can be correlated.
- **Metrics.** `system.status` returns a rolling 1-minute histogram of request counts per method, available to monitoring; `tc system status --json` exposes it.

### Versioning and compatibility

- **Semver on the app.** Major bumps signal wire-protocol-breaking changes. `tc` pinned to the app it shipped with — but `tc --version` shows both, so users know.
- **Rolling compatibility window.** Within one major version, the CLI gracefully degrades: unknown methods return a friendly error; new optional params are ignored by older servers; the server-side `clientVersion` header enables best-effort support.
- **Deprecation.** Method deprecations ship as `deprecatedMethods: ["hierarchy.oldName"]` in `system.version`; the CLI prints a stderr warning once per session when invoking one.

### Performance

- **Round-trip budget.** Every non-streaming command should complete in < 50ms p95 on a warm app (socket already open elsewhere? no — `tc` opens a fresh connection per invocation to keep auth model simple). Socket accept + JSON decode + in-process method dispatch + JSON encode = low milliseconds.
- **Cold app launch.** `tc system launch` may take up to 10s waiting for the socket to appear; exit code 12 (launch timeout) on timeout.
- **Completion script generation** must be < 100ms (it's a one-shot at install and rare rerun).
- **Streaming throughput.** `tc hook tail` must sustain the app's hook event volume (< 1000 events/sec under stress); NDJSON newline-framing keeps parser cost low.

### Cross-Cutting with C3 Hooks

- Every mutation issued by `tc` may trigger C3 hooks (a `pane.created` fires when `tc pane open` runs). Hooks see the CLI-driven mutation the same way they see GUI-driven mutations — good, and intentional.
- `tc hook test` / `tc hook fire` are the canonical way to synthesize a hook event without actually producing one — essential for handler development.
- The recursion-guard rule (C3 D4) ensures a hook handler that runs `tc pane send …` does not feed back into a hook listening for its own output within the `HookConfig.recursionWindowMs` window (default 250ms).

### Migration & rollback

- Release builds install `tc` to `/usr/local/bin` via Settings → Developer (one admin auth dialog). Debug builds install `tc-dev` / `tcode-dev` instead, so local development never takes over the production command. Uninstalling the app does not remove the symlinks; the Developer pane's Uninstall button (or `sudo rm /usr/local/bin/{tc,tcode}` manually) clears them.
- Schema-breaking change rollouts: ship the new server method under a new name (e.g., `hierarchy.createWorktree2`) while the old continues to work; deprecate the old on the next minor release; remove on the next major.
- A broken `tc` release can be rolled back by the user running `tcode install-cli --reinstall --version <prev>` (sugar; actually a no-op because `tcode` is app-bundled — user rolls back the app itself, and `tc` follows).

## Decisions

- **D1 — Primary binary name is `tc`; `tcode` ships as a peer fallback. (Resolves Open Q #1.)** *Partially supaterm-parallel (`sp`), supacode-parallel (`supacode`).* The ergonomic win is too large to cede; the collision-check installer handles the edge case (see [Collision check](#collision-check-plan-for-tc--tcode)).
- **D2 — Single binary, ArgumentParser-rooted.** *Supacode- and supaterm-parallel.* ArgumentParser handles completion, help, subcommand dispatch, version — no reason to diverge.
- **D3 — Install Release to `/usr/local/bin/{tc,tcode}` via single admin auth dialog. (Resolves architecture Open Q #3.)** *Aligned with most macOS tools.* `/usr/local/bin` is on the default macOS `PATH`, so `tc` works in every shell, GUI launcher, and cron context without rc-file edits. Debug builds install `/usr/local/bin/{tc-dev,tcode-dev}` to keep development and production commands separate. The privileged write is one in-process `NSAppleScript` "do shell script with administrator privileges" call per install / uninstall — the auth dialog renders with the touch-code app icon and bundle name. Symlinks point at the bundled binary inside `Contents/Resources/bin/tc`, so app upgrades preserve the install. Full design and migration plan in [`cli-install-system-bin.md`](cli-install-system-bin.md). *(Amended 2026-04-29; original decision was `~/.local/bin` with a PATH advisory — superseded because the advisory was structurally noisy and the directory is not on the default `PATH`.)*
- **D4 — `tc` errors when the app isn't running, except for `tc system launch` and `tc skill install`.** *Divergent from supaterm (which attempts best-effort).* The "`tc` is stateless" invariant is the most valuable property of this CLI; relaxing it means two code paths forever. `tc skill install` is explicitly a file-copy-only verb because the Skill exists independent of the app runtime.
- **D5 — Convenience aliases (`current`, `.`, `@label`, index, path glob) resolve through `hierarchy.resolveAlias` on the server, not in the CLI.** *New.* Keeps name-resolution logic as the single source of truth; the client only validates UUID format locally.
- **D6 — `tc send` / `tc broadcast` share one IPC method (`terminal.sendInput`) with a `scope` discriminator.** *New.* Reduces server surface and lets a single hook handler observe both the unicast and fan-out paths identically.
- **D7 — `--json` is universal and per-verb; every result type has a JSON schema 1:1 with the RPC.** *New; supacode has partial JSON output.* This is how agents stay reliable; the text renderer is the human convenience, not the primary contract.
- **D8 — Exit codes are stable and enumerable (`1` user error, `2` not found, `3` conflict, `4` unsupported, `5` overloaded, `6` versionMismatch, `10` no-socket, `11` request timeout, `12` launch timeout, `20` internal).** *New.* Agents and shell scripts must be able to branch on codes; picking a fixed set up front avoids the "exit 1 for everything" trap. Request vs. launch timeout split avoids the earlier collision where `tc system launch` and a slow mutation both returned 11 — a script checking `[[ $? -eq 12 ]]` now unambiguously means "app did not come up".
- **D9 — Raw RPC access is not exposed as a CLI command.** *Divergent from supaterm (`sp rpc`).* Earlier drafts included `tc rpc METHOD [JSON]` as a debugging escape hatch, but the command made the public surface larger and encouraged unsupported workflows. Debugging should use typed commands, app logs, or internal test harnesses.
- **D10 — Streaming RPCs use `stream: true` on request + bidirectional-EOF termination (either side closes write half → other flushes then closes); no multiplexing.** *New.* One streaming call per socket connection after its `system.hello`; keeps wire framing simple. If a client needs two streams, it opens two connections. The handshake lives in a dedicated `system.hello` first-frame RPC (not a per-request header), which is why the "fresh connection per invocation" property survives cleanly — every new connection pays exactly one `system.hello` round trip, pipelined with the real request.
- **D11 — Per-connection bounded in-flight queue of 64; new requests wait up to 2s then return `IPCError.overloaded`. (Resolves architecture Open Q #5.)** *New.* Prevents an agent stuck in a loop from OOM'ing the app.
- **D12 — The CLI does UUID-fast-path locally; everything else is one server round-trip before the mutation.** *New.* Latency tradeoff in favour of consistency; the round-trip cost (sub-millisecond on a local socket) is negligible.
- **D13 — `tc skill install` defaults to symlink, not copy, so skill updates during an app upgrade propagate immediately.** *Supacode-parallel (symlinks settings).* `--copy` is available for users whose agents refuse to follow symlinks.
- **D14 — `tc open` uses the ExternalEditor allowlist + user templates in `settings.json`. (Resolves product-spec Open Q #7.)** *New.* The 6-editor allowlist + template escape hatch is simpler than Launch Services discovery and covers every editor the user segment cares about.
- **D15 — Completion scripts ship pre-generated in the app bundle and are copied next to the binary on install; regeneration is `tc --generate-completion-script`.** *Divergent from supaterm (runtime generation).* Pre-gen keeps install snappy and versioned.
- **D16 — `Pane.labels` is added to `TouchCodeCore` by this doc.** *Shared with C3 ([D10](c3-lifecycle-hooks.md#decisions)).* `tc pane label` is the only way a user-facing mutation writes to it; no in-app UI yet.
- **D17 — No shell-integration layer (`eval "$(tc init zsh)"`).** *Divergent from supacode (which injects functions).* Every side-effect we'd want from a shell function is better done by the app injecting env vars into Panes directly; adding another indirection means versioning and debugging two surfaces.
- **D18 — The `send`/`broadcast` verb names live at the top-level namespace, not under `tc pane` or `tc terminal`.** *Supaterm-parallel.* They are the most-used commands; top-level placement reduces typing for agents and humans.
- **D19 — Default `--newline` is off.** *Divergent from supacode (which appends \n).* `printf`-style lets users control line termination; agents scripting multi-line payloads don't have to work around implicit newlines.

## Risks

- **R1 — `tc` named collision on Linuxbrew or heavy-TCP-configurator users.** *Probability low on macOS, non-zero on dual-boot Mac/Linux users.*
  - *Mitigation:* [Collision check plan](#collision-check-plan-for-tc--tcode) installs `tcode` unconditionally; documentation prefers `tc` but every example is tested with both. We publish a one-liner detection snippet users can paste into `.zshrc`.
- **R2 — Version skew between a user's `~/.local/bin/tc` and the running app.** Possible after a dev build swap or a manual copy.
  - *Mitigation:* handshake on first request reports both versions; skew triggers a clear-language stderr warning with exact versions. `tc system status` is the canonical diagnostic.
- **R3 — Agents issue wedge workflows (`tc send … \n tc send …`) that fill the in-flight queue.** *Realistic under high-frequency agent output.*
  - *Mitigation:* 64-deep per-connection queue + `IPCError.overloaded` with exit 5; the hook `hook.recent` ring surfaces the back-pressure episode for tuning.
- **R4 — A malicious or buggy local process discovers the socket and drives the app.** `SO_PEERCRED` limits this to same-user; a compromised user-level process can already do worse (read `~/.ssh`).
  - *Mitigation:* documented as an accepted threat model. Post-v1 per-session token considered.
- **R5 — Path-glob Worktree resolver is ambiguous.** A user runs `tc worktree activate 'exp/*'` and touch-code has three matching Worktrees.
  - *Mitigation:* list-shaped verbs return all matches; mutation-shaped verbs error `.conflict` and print the candidates; user rerun with a UUID.
- **R6 — `tc broadcast` fans out to more panes than expected.** A user broadcasts to `--space current` when the current Space has 20 Panes.
  - *Mitigation:* confirmation prompt when fan-out exceeds a threshold (default 5), bypassable with `--yes`. `TOUCH_CODE_BROADCAST_CONFIRM=0` disables globally for scripts.
- **R7 — `tc skill install` writes into the wrong directory (future agent changes its skill path).** We hard-code `~/.claude/skills`, `~/.codex/skills`, `~/.pi/skills`.
  - *Mitigation:* agent definitions live in `SkillInstaller.agents: [AgentDef]`, updatable in a point release; `tc skill install --claude-code --path <override>` for one-off overrides; `skill.check` reports the target path before installing.
- **R8 — Completion script gets stale after app upgrade.** Users don't rerun `--generate-completion-script`.
  - *Mitigation:* install step always refreshes the completion files; users who manually bypass the installer are a supportable minority.
- **R9 — Streaming client (`tc hook tail`) hangs on a dead socket.** The app quit while the stream was open.
  - *Mitigation:* read-side EOF → exit 0 with a stderr note "server closed stream"; `--timeout` is respected as max idle time on streams.
- **R10 — The CLI's UUID-fast-path accepts a UUID that doesn't match any known entity.** A typo produces a not-found at mutation time instead of a clear "bad input".
  - *Mitigation:* all server methods emit `notFound` with exit 2 and a suggestion ("`tc pane list` shows IDs"); no attempt to fuzzy-match (silent corrections would be worse).
- **R11 — Two `tc` invocations race on the same mutation (`tc worktree create` from two panes).** The app serialises `HierarchyManager` mutations on `@MainActor`, but a user could still observe out-of-order effects.
  - *Mitigation:* `@MainActor` serialisation is the guarantee; `HierarchyManager` methods are atomic from the client's perspective. Documentation flags "mutations are serialised per app instance; CLI calls land in arrival order".
- **R12 — Raw RPC access becomes a support burden.** Users invent workflows on top of undocumented methods.
  - *Mitigation:* no public `tc rpc` command. Raw method calls remain an internal implementation detail and can change without CLI compatibility commitments.
- **R13 — `tc hook edit` launches `$EDITOR` and the user's editor is misconfigured.** The command appears to hang.
  - *Mitigation:* pre-flight `$EDITOR`-exists check; fall back to `open -t` (macOS text handler); print the file path if both fail so the user can edit manually.
