# CLI

The `codans` CLI is the programmable surface of the running app. An agent or a script in any shell, usually inside a Pane, uses it to read the Project → Worktree → Tab → Pane hierarchy, to make Worktrees, Tabs, and Panes, to send input to a Pane and read its screen, and to start and coordinate agents. The GUI and the CLI drive the same app state. The published Agent Skill teaches agents to control codans only through this CLI.

The CLI holds no state. Each command is a short-lived RPC client of the app that is running: it resolves its targets, sends one request over the app's Unix socket, renders the reply, and exits with a stable code. If the app does not run, a command that needs it fails. It does not use a cached copy.

## Scope and ownership

This page owns the transport and the request/response model, target addressing and the `current` pronoun, the verb families, the output and exit-code contract, and the installation of the CLI and of the bundled skills.

Neighbor topics:

| Topic | Owner |
|---|---|
| Socket path resolution, the CLI name per build, the wrong-channel refusal (exit 15), the Pane environment | [Environment](environment.md) |
| Semantics of the `workflow` verbs | [Workflow](workflow.md) |
| Semantics of the `workspace` verbs | [Workspace](workspace.md) |
| Agent profiles, `agent launch`, and `handoff` | [Agent profiles and handoff](agent-profiles-and-handoff.md) |
| Agent runtime state behind `agent status` and `agent wait` | [Agent state](agent-state.md) |
| Worktree lifecycle behind the `worktree` verbs | [Worktree](worktree.md) |
| zmx daemons behind `pane read`, `pane info`, and `pane close` | [Terminal runtime](terminal-runtime.md) |
| Saved commands behind `project commands` | [Project commands](project-commands.md) |

This page is not a manual. `codans help` (and `--help` on each verb) and the published skill in `skills/codans-cli/` describe each verb and flag.

## Request path

```
 shell in a Pane                       Codans app
 ---------------                       ----------
 codans pane send p3 'make'            SocketServer (0600, same-uid peers only)
   |  parse args (ArgumentParser)        |
   |  resolve targets -----------------> hierarchy.resolveAlias  (uses peer PID)
   |  <------------------------------ UUIDs
   |  system.hello + request ----------> SocketConnection (one frame at a time)
   |                                       |
   |                                     MethodRouter -> <namespace>Handlers
   |                                       |   (MainActor; HierarchyManager,
   |                                       |    terminal engine, clients)
   |  <------------------------------ result | IPCError
   |  render text or JSON, exit code
```

Transport rules:

- **Framing.** A frame is a `UInt32` big-endian length followed by exactly that many bytes of UTF-8 JSON, with no trailing newline. The limit is 16 MiB per frame. An oversize frame closes the connection.
- **Methods.** `IPC.Method` in `CodansIPC` is the one method table. Both sides switch on the enum, never on the raw string. The names are dotted and namespaced (`hierarchy.createWorktree`, `terminal.sendInput`). A method that the enum declares but the router does not handle returns `unsupported` ("not wired in this build").
- **Handshake.** The first frame on a connection must be `system.hello`. The client writes the hello and the real request in one write, so the handshake adds no round trip, and matches the two replies by id. The server refuses a client whose major version differs (`versionMismatch`, exit 6). A successful handshake does not promise that every method exists.
- **One connection per invocation.** The server handles the frames of a connection one at a time. A streaming call ends with a final frame `{id, stream: false}`. To run two streams, open two connections.
- **Errors.** Handlers convert domain errors to `IPCError` at this boundary: `invalidParams`, `notFound`, `conflict`, `unsupported`, `overloaded`, `versionMismatch`, `internal`, and `domain` (a stable string code with a message and a hint).
- **Security.** The socket file has mode 0600, and the server checks the peer uid on accept. Any process of the same user can drive the app, also `pane send` into a shell. That is the accepted threat model.
- **Concurrency.** All mutations go through the MainActor owners (`HierarchyManager` and the clients), so two CLI calls that change the same thing apply in arrival order.

## Addressing targets

A command names its target with an alias. The CLI turns each alias into a UUID before the real call. Internal code sees only UUIDs. Aliases, in the order they are tried:

1. **UUID**: used as is, without a round trip.
2. **`current` or `.`**: the container of the caller (see below).
3. **`@label`** (Pane only): the Pane with this label. More than one match is a `conflict`.
4. **Handle** `t<n>` or `p<n>`: the short, stable handle that `codans tree` prints for Tabs and Panes.
5. **Name**: Project name, Worktree name or branch, Tab title, case-insensitive. Inside a Pane, a Worktree name is looked up in the caller's Project and a Tab title in the caller's Worktree. One match resolves. More than one is a `conflict` that asks for an id. Panes have no names: a bare word for a Pane is `invalidParams`, with a hint to quote the text (the usual cause is `pane send echo hi` without quotes).
6. **Path** (Worktree only): a value that starts with `/`, `~/`, `./`, or `../` is a path. The CLI makes it absolute against `$PWD`, and the server picks the deepest Worktree whose root contains it, in any Project. A branch such as `bugfix/menu` stays a name.

The server is the only resolver of names. The CLI checks UUID syntax locally and sends every other alias to `hierarchy.resolveAlias`. The result is cached for one invocation only.

### The `current` pronoun

The app writes only `CODANS_PANE_ID` into a Pane environment, because a Pane can move to another Tab, Worktree, or Project, and an exported container id would become wrong. The server finds the caller's Pane from the kernel: it takes the peer PID of the connection and walks its parent chain to the shell PID of a live Pane. This works when a subshell or an agent removed the variable. If the walk finds nothing, the server uses the `CODANS_PANE_ID` that the client sends. The Tab, Worktree, and Project of `current` come from the catalog row that holds that Pane.

Outside a Pane, `current` fails with `NO_CURRENT_CONTEXT` ("this shell is not inside a Codans pane"). In a Pane, `--project`, `--worktree`, `--tab`, and `--pane` default to `current`. If a command names a Tab or Worktree explicitly and leaves the containers at `current`, the CLI finds the containers from the tree, so `codans tab close t3` works from any shell.

Project aliases also take `--host` (`0` for This Mac, or a Host id). With `--host`, also a UUID or `current` goes to the server, which checks that the Project is on that Host. See [ADR 0006](../adrs/0006-project-identity-is-host-and-path.md).

### Arguments

Each verb has at most one positional target. Containers use `--project`, `--worktree`, `--tab`. Text, commands, and new names do not compete with the target for a position. `pane send` is the one exception: one argument is text for the current Pane, two arguments are a target and text. `pane split` takes its command through `--command`.

## Verb families

| Family | Purpose |
|---|---|
| `status`, `doctor`, `launch` | App health. `doctor` and `launch` work without the app (see below). |
| `tree` | The whole hierarchy in one call, with handles. The first command an agent runs to discover state. |
| `project`, `worktree`, `tab`, `pane` | Lifecycle of each level: `list`, `show`, create, rename, switch or focus, close or remove. `pane` also has `split`, `resize`, `label`, `reset`. `project commands` manages saved commands. |
| `pane send`, `send-key`, `capture`, `read`, `info`; `broadcast` | Terminal input and output. `broadcast` sends one text to every Pane of a Tab, a Worktree, or a label, with the fan-out on the server. |
| `agent` | Agent profiles (`list`, `launch`) and runtime state (`status`, `wait --until`). |
| `handoff` | Pass the task of the calling agent to another agent (`to`), or save the handoff artifacts only (`save`). |
| `workspace` | Multi-repository Workspaces and their groups. |
| `workflow` | List, validate, run, and drive workflow runs. |
| `open` | Open a directory in an editor through the `editor.*` methods. |
| `skill` | Link the bundled Agent Skills for agents. Local only. |

Rules that apply across families:

- **Same path as the GUI.** A CLI mutation calls the same owner as the matching GUI action. For example, `worktree new` uses the pipeline of the New Worktree sheet and `pane split` the keyboard split. Do not add a CLI-only variant of an action.
- **Terminal verbs need a live Pane.** A Pane in the catalog without a running daemon gives `PANE_NOT_LIVE` (exit 3). A Pane whose daemon runs but has no surface (for example a Tab not yet opened) is live: the verb attaches a surface first, without a new process and without focus.
- **`pane send --wait`** returns when the foreground job of the Pane has ended, the screen has stopped changing, and the screen shows that the sent command ran. A settled screen alone is not completion. It reads the daemon's screen when the Pane has one, never surface text that is still being replayed. `--capture` implies `--wait` and returns the new screen lines. This is best effort, because the terminal exposes rendered text, not command boundaries. A timeout gives `WAIT_TIMEOUT` (exit 11).
- **`pane close` ends the session.** It kills the Pane's zmx daemon, waits until the daemon is gone, and then removes the Pane.

## Output and exit codes

The CLI renders each result once, in text or in JSON. A command cannot work in only one mode, because both modes render the same result value.

- **Text** goes to stdout. Errors go to stderr as `error: <message>` and an optional `  hint: <next step>`.
- **`--json`** prints exactly one object on stdout, also for errors:

```json
{ "schemaVersion": "codans.cli.pane.send.v1", "data": { ... } }
{ "schemaVersion": "codans.cli.pane.focus.v1",
  "error": { "code": "NOT_FOUND", "message": "...", "hint": "...", "details": { ... } } }
```

`schemaVersion` comes from the command path, without the binary name, so `codans` and `codans-dev` print the same value. `error.code` is a `CLIErrorCode`: each exit code has a default code, and cases that one exit code cannot separate have their own (`NO_CURRENT_CONTEXT`, `WAIT_TIMEOUT`, `PANE_NOT_LIVE`, the workflow codes). `codans-cli/Resources/schema/cli-output.schema.json` describes every output. The two exceptions are `help-json`, which prints the bare command tree, and lines that ArgumentParser rejects (exit 64).

Exit codes are stable within a major version, because agents and scripts branch on them:

| Code | Meaning | What a script does |
|---|---|---|
| 0 | Success | |
| 1 / 2 / 3 / 4 | User error / not found / conflict / unsupported | Fix the call |
| 5 / 11 | Overloaded / request timeout | Retry as is |
| 6 | Version mismatch between CLI and app | Use the CLI of the running app |
| 10 / 12 | App not reachable / `launch` timed out | Start the app, then retry |
| 13 / 14 | Socket permission denied / socket path not usable | Stop and get a person |
| 15 | Wrong channel, see [Environment](environment.md#socket-resolution) | Use the other CLI name |
| 20 | Internal error | Report it |
| 64 | Command line rejected by the parser | Fix the call |

Rules:

- A connect failure maps to the action the caller must take, not to the errno. An errno without a mapping stays `unknown` and does not join a near category: a wrong category is worse for a script than an honest unknown.
- A new verb needs a schema entry with a `schemaVersion` binding. A new failure that a script must branch on needs a `CLIErrorCode` case, not only a message.
- `--timeout` is the deadline of each RPC in the command, alias resolution included. Verbs that wait (`pane send --wait`, `agent wait`) have their own `--wait-timeout`.

## Commands without the app

- **`doctor`** does not call the app. It prints the client name, version, channel, the resolved socket, and `socketStatus` (`ok`, a failure kind such as `socket-missing` or `permission-denied`, or `wrong-channel`), so a script can branch without parsing stderr. It reports the channel refusal instead of exiting on it.
- **`launch`** starts the app that contains this CLI binary and waits for its socket (`--wait`, default 10 seconds, then exit 12). It forwards its own socket, config, and state overrides to the app with `open --env`, so the app binds the socket that `launch` waits for. It fails at once on a failure that a start cannot fix (permission, unusable path). Only the release CLI can fall back to the installed app by name. A development CLI never starts the release app.
- **`skill`** works on the file system only (below).

## Installation and discovery

The CLI binary is inside the app bundle at `Contents/Resources/bin/<name>`, signed with the app: `codans` in Release, `codans-dev` in Debug. Each Pane gets this directory on `PATH` and its absolute path in `CODANS_CLI`. [Environment](environment.md) explains why the name, not the `PATH` order, selects the app.

For shells outside codans, Settings › Integrations installs a symlink `/usr/local/bin/<name>` to the bundled binary, with one administrator prompt per install or uninstall. The symlink follows app moves and updates. Rules of the installer:

- It replaces only its own symlinks, also stale ones that point to another build. A foreign file at the destination is a collision: the installer stops and shows no administrator prompt.
- The privileged script checks each symlink again before it removes it, because the file can change between the probe and the run.

### Agent Skills

The app bundle contains the Agent Skills of the repository's `skills/` directory (`codans-cli`, `codans-workflow`). `codans skill install` links them into the skills folders of the detected agents: `~/.claude/skills`, `~/.codex/skills`, and `~/.agents/skills`, or the same folders in a repository with `--scope project`. A link to an older bundle is replaced. Any other file is a conflict unless `--force`. `uninstall` removes only links to a codans bundle. The skill sections in Settings › Integrations use the same installer. The app does not link skills by itself. The CLI finds the bundled skills next to its own resolved binary, or in `CODANS_SKILLS_DIR`.

## Traps

- **The CLI answers to the wrong app.** Check `type codans` and `codans doctor` first. See [Environment](environment.md) and [Dev pane commands answered by release app](../lessons-learned/2026-09-05-dev-pane-commands-answered-by-release-app.md).
- **Exported container ids.** Do not add `CODANS_TAB_ID` or similar to the Pane environment. They become wrong when a Pane moves. The CLI reads them only if a caller exports them by hand.
- **Logic in the CLI.** The CLI must not import the app modules (`Runtime`, `Git`, `App`) or keep app state. Put the behavior in a handler or in the owner it calls, so that the GUI and the CLI cannot disagree.
- **Unquoted text.** `pane send echo hi` reads `echo` as a Pane target and fails. Quote the text.
- **Retired wire keys.** A request with a field that the protocol no longer accepts fails with `invalidParams` and points to the new verb. It is not silently ignored, so the caller does not think the work was done.
- **A missing `bin/zmx` looks like a CLI failure.** Every `pane new` then fails with exit 20. Check the bundle before the CLI. See [CLI agent orchestration gaps](../lessons-learned/2026-09-14-cli-agent-orchestration-gaps.md).

## Implementation shape

`codans-cli` is one ArgumentParser command tree. It depends only on `CodansKit`, `CodansIPC`, and `CodansCore`. `CodansKit` holds the client side: socket discovery and dialing, `RPCClient`, `AliasResolver`, the renderer and envelope, the exit and error codes, and the skill installer. `CodansIPC` holds the wire types, the framing, and `IPC.Method`, shared by both sides. In the app, `App/Features/Socket/` holds the server, the per-connection loop, `MethodRouter`, and one handler group per namespace. The handlers convert wire types and errors, and call the MainActor owners of app state. The CLI installer is an app client behind the Settings card.
