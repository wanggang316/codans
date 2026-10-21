---
name: codans
description: Drive the codans Mac app from a terminal with the `codans` CLI — inspect the Project / Worktree / Pane / Tab hierarchy, create and switch worktrees, open tabs and split panes, run a command in a tab and capture its output, send keystrokes or text, read back rendered output, broadcast input across tabs, see which tabs run agents and wait for their state, launch agent profiles, hand a task off to another agent, create a multi-repository workspace, add a project to one, or create and delete its branch groups, install this skill for agents, and check app health. Use this skill whenever the user is operating inside a codans Tab, references the `codans` command, asks how to script codans, or wants to coordinate tabs / panes / worktrees / agents from the shell. Prefer `codans tree` to discover state before issuing any other command.
---

# codans CLI (`codans`)

## What is codans?

**codans** is a macOS desktop app built for the next generation of
agent-based parallel development. At its core it is a parallel-development
tool on top of **git worktree + terminals**, organised as
**Project → Worktree → Pane → Tab**. Terminals are rendered natively via
**libghostty**.

`codans` is the command-line client that drives the app over a local Unix
domain socket — the same things the GUI does, scriptable from any shell.
The binary is installed as `codans`.

## Before you run anything: check it's installed

Before suggesting any `codans` command, verify the app is installed and
reachable:

```bash
codans doctor
```

Three outcomes:

- **Prints `socketStatus      ok`** — app is installed and running.
  Proceed.
- **Prints any other `socketStatus`** — the app is installed but not
  usable yet. The value says why, so branch on it instead of guessing:

  | `socketStatus` | What happened | What to do |
  |---|---|---|
  | `socket-missing` / `app-not-running` | No socket, or a stale one left by a crash | `codans launch`, then retry |
  | `permission-denied` | The socket belongs to another user | Stop; ask the user — launching will not help |
  | `not-a-socket` / `path-too-long` | `CODANS_SOCKET_PATH` points somewhere wrong | Stop; fix the env var |
  | `server-busy` / `timed-out` | App is up but not accepting right now | Wait a moment and retry |
  | `wrong-channel` | This tab belongs to a development build of Codans, whose CLI is `codans-dev` | Use `codans-dev` for the rest of the session; see [Development builds](#development-builds) |

  `codans doctor --json` emits the same value plus a `socketHint` string.
- **`codans: command not found`** — Codans is not installed. Stop and tell
  the user to install it from the releases page:

  > Codans is not installed. Download the latest `.dmg` from
  > <https://github.com/wanggang316/codans/releases/>, drag
  > **Codans.app** into `/Applications`, launch it once so `codans` lands
  > on `PATH`, then retry.

  Do not invent fallback commands or try to install it via Homebrew / npm
  / pip — there is no such package today; the GitHub releases page is the
  only distribution channel.

## When to use

- The user is inside a codans Tab and wants to script some action.
- The user mentions "codans ..." or asks how to do something in codans from
  the terminal.
- An agent (Claude Code, Codex, custom) wants to read a sibling tab's
  output, send input to it, or open new tabs / panes / worktrees.
- The user wants to inspect the codans app's state without opening the
  GUI.

## Hierarchy in 60 seconds

```
Project       a tracked git repo (one Project per repo) — or a workspace
 └── Worktree a git worktree of that repo (own dir + branch + a layout of panes)
      └── Pane one slot of the worktree's split layout; carries its own tab strip
           └── Tab one terminal session in that strip (one Tab shown per Pane)
```

A **Pane** is a leaf of the worktree's split tree: panes sit side by side
and nested, exactly one pane has keyboard focus, and a pane can be zoomed
to fill the layout. Each pane carries a strip of **Tabs** and shows the
selected one; a pane is never empty (closing its last tab closes the pane).
A **Tab** is one terminal session — its title, color, and icon belong to
the tab, and its session identity (the *content id*) survives relaunches
and layout changes. So: `codans tab …` drives a session, `codans pane …`
shapes the layout.

A **workspace** Project (`"kind": "workspace"` in `codans tree --json`) is a
plain folder that groups *several* repositories (its source projects) for one
task. Its rows come in groups, reported as `workspaceGroup {id, name, role}`
in `codans tree --json`:

- the `default` group links to each source project's main checkout
  (`role: "reference"`);
- each named group has one branch, checked out once per project under
  `<root>/<group>/<project>` (`role: "member"`);
- every group also has its own row for the group folder
  (`role: "groupTerminal"`).

A row's repository is reported as `sourceGitRoot`. Treat member rows as
independent repos: `git -C <path>` per row, never `git worktree` commands
against the workspace root. Create and delete groups with `codans workspace
group …`, never with `codans worktree new` / `rm`, which refuse workspace rows.

`codans` is on `PATH` automatically inside every codans Tab, and the app
auto-detects which Project / Worktree / Pane / Tab that shell belongs to —
so most commands default to the surrounding context and you rarely need
to pass IDs.

## Targeting model

One grammar everywhere. A verb that acts on one thing takes that thing as
its **single positional target**; the containers above it are
`--project` / `--worktree` / `--pane` options that default to `current`.
Text, commands, and names of new things never share the positional slot
with a target: `tab send` is the one exception (one argument is text for
the current tab, two are `<tab> <text>`), and `pane split` takes its
command as `--command`.

Every target accepts the same forms, whichever level it is:

| Form | Applies to | Example |
|---|---|---|
| `current` / `.` | project, worktree, pane, tab | the containers of the tab you run from |
| UUID | all | `codans tab close 5CBC66C9-…` |
| `p<n>` / `t<n>` handle | pane, tab | the numbers `codans tree` prints as `Pane p2:` / `Tab t7:` |
| `@label` | tab | labels set with `codans tab label` |
| name | project (name), worktree (name **or branch**), tab (title) | `--worktree bugfix/menu`, `tab focus "dev server"` |
| path | worktree (`/abs`, `~/x`, `./x`, `../x`; a directory inside the worktree also matches) | `worktree switch ~/code/api-hotfix`, `--worktree "$PWD"` |

**Any id works in any id slot.** A pane id, a tab id, or a content id is
accepted wherever an id is expected and resolves to the level the verb
needs: give `tab send` a pane id and it targets that pane's selected tab;
give `pane focus` a tab or content id and it focuses the pane holding it.
The single exception is `pane close`, which refuses a tab or content id
and tells you to use `tab close` — so you never close more than you meant.
`--pane <id>` on `send` / `capture` / `broadcast` likewise means "that
pane's selected tab".

Handles stay stable for as long as the pane / tab lives, are released
when it closes, and are never reused within one app session, so a stale
handle fails with not-found instead of hitting the wrong target. Names
are case-insensitive and scoped to the calling tab's containers when
there is one (`--worktree main` means "this project's main"); an
ambiguous name is a conflict (exit 3, `CONFLICT`) — pass the id. Panes
have no name: a bare word where a target is expected is a usage error,
which is usually unquoted text (`codans tab send echo hi` — quote it).

`current` for a project / worktree / pane / tab is derived from the tab the
command runs in, so it works from any subshell or wrapper inside a tab.
Outside a codans Tab there is no current tab: the command fails with
`no current <kind>: this shell is not inside a Codans tab` (exit 2,
`NO_CURRENT_CONTEXT`) — pass an explicit id, name, or path, or run
`codans tree` to discover one. Verbs whose target already determines its
containers (`tab close t3`, `tab new --pane p2`, `worktree rm <id>`) never
need `--project` / `--worktree` at all.

## Development builds

A development build of Codans is a separate app: its own socket, its own
config, and its CLI is named `codans-dev`. Inside a tab spawned by a
development build, type `codans-dev` wherever this skill says `codans`.
`$CODANS_CLI` always holds the absolute path of the CLI that belongs to
the tab you are in, so `basename "$CODANS_CLI"` is the command to use.

The release `codans` refuses to run inside a development tab (exit code
15, `codans doctor` reports `socketStatus wrong-channel`) and its hint
names the command to switch to. `codans-dev` run from a release tab
still drives the development app.

## Detecting codans from a script

Every codans Tab's environment carries a product marker plus
context variables, so a script or agent can branch on "am I inside
codans" without probing the socket:

- `TERM_PROGRAM=codans` — set for every tab; `TERM_PROGRAM_VERSION`
  carries the app version.
- `CODANS_CONTENT_ID` — the id of *this* session. Use it to address
  yourself (`codans tab capture "$CODANS_CONTENT_ID"`); it stays the same
  if the tab is moved to another pane or the app relaunches.
- `CODANS_TAB_ID` — the id of the tab this session sits in (its chip:
  title, color, icon, position in the strip).
- `CODANS_PANE_ID` — the id of the pane around it (the layout slot and
  its strip), for `pane split`, `pane zoom`, or `broadcast --pane`.
- `CODANS_WORKTREE_PATH` / `CODANS_ROOT_PATH` — absolute paths of the
  tab's worktree and its Project root.

Each variable has exactly one meaning; none of them is an alias for
another. Worktree and project ids are not exported — `current` resolves
them server-side.

```bash
if [ "$TERM_PROGRAM" = "codans" ]; then
  # running inside a codans Tab; `current` targeting works
  codans tab read
fi
```

## Global flags

These work on every subcommand (mounted via `@OptionGroup`):

- `--json` — machine-readable output instead of text.
- `--socket <path>` — talk to a non-default socket (rarely needed; the
  default points at the running app automatically).
- `--timeout <seconds>` — RPC client timeout (default 10s), applied to every
  call the command makes.

Use `codans <subcommand> --help` for the exact flag list of any command.
`codans help-json` prints the whole subcommand tree as JSON.

### JSON output contract

`--json` prints exactly one object per command, always on stdout:

```json
{ "schemaVersion": "codans.cli.tab.send.v1", "data": { "tabID": "…", "bytes": 12 } }
{ "schemaVersion": "codans.cli.pane.focus.v1",
  "error": { "code": "NOT_FOUND", "message": "pane not found: p9",
             "hint": "…", "details": { "kind": "pane", "id": "p9" } } }
```

- `schemaVersion` is `codans.cli.<command path>.v1` and identical for
  `codans` and `codans-dev`; read fields under `.data`.
- On failure the exit code is still set and `error.code` is a stable
  string: `INVALID_ARGUMENT`, `NOT_FOUND`, `CONFLICT`, `UNSUPPORTED`,
  `APP_NOT_RUNNING`, `REQUEST_TIMEOUT`, `WRONG_CHANNEL`, `INTERNAL`, plus
  the specific `NO_CURRENT_CONTEXT` (`current` outside a tab),
  `EMPTY_INPUT`, and `WAIT_TIMEOUT` (`agent wait` / `send --wait` deadline).
  `details` carries structured context such as `kind` / `id`.
- The shapes are described by the JSON Schema shipped in the repository
  (`apps/mac/codans-cli/Resources/schema/cli-output.schema.json`).
- Only `codans help-json` prints its tree bare, and command lines the
  argument parser rejects (exit 64) print the parser's own text.

Exit codes: `0` ok · `1` usage / user error · `2` not found · `3` conflict
· `4` unsupported · `5` overloaded · `6` version mismatch · `10` app not
running · `11` request timeout · `12` launch timeout · `13` socket
permission denied · `14` socket unusable · `15` wrong build channel ·
`20` internal · `64` the argument parser rejected the command line (unknown
subcommand or option, missing argument, bad enum value).

## Quick start

```bash
codans doctor                              # confirm the app is reachable
codans tree                                # see every Project / Worktree / Pane / Tab
codans agent status                        # which tabs run an agent, and what it is doing
codans tab send 'pwd' --capture            # run a command in the current tab, get its output
codans tab capture                         # read back what's on screen
codans pane split --command htop           # a new pane (with a fresh tab) beside this one
```

## Command reference

### App & diagnostics

```bash
codans status                # server, uptime, connected clients
codans launch [--wait 10]    # start codans and block until the socket is up
codans doctor                # print socket path, reachability, client version
```

`codans launch` is idempotent — if the app is already up it just prints the
existing socket path.

### `codans tree` — discover state

```bash
codans tree                          # full hierarchy as text
codans tree --json                   # same, machine-readable
codans tree --project current        # restrict to one project
```

Always run `codans tree` first when you don't know what's around. The text
form marks the selected worktree, the focused pane, and each pane's
selected tab with `*`, prints tab labels as `@label`, prints each pane's
and tab's short handle (`Pane p2:` / `Tab t7:`), and prints every tab's
content id — pass any of those wherever an id is accepted. JSON output
carries full UUIDs (`id`, plus `contentID` on tabs, `selectedTabID` /
`isFocused` on panes, `focusedPaneID` on worktrees) and the same handles
as `handle` (`"p2"` / `"t7"`).

### `codans project` — manage projects

```bash
codans project list                          # all projects
codans project add ~/code/api                # register an existing directory
codans project add --name "API" ~/code/api   # custom display name
codans project show <project>                # paths, git root, selection, worktree counts
codans project rename <project> "API v2"     # sidebar name ('' clears the override)
codans project rm <project>                  # remove (id, name, or 'current')
```

Adding a project registers an existing directory (it must exist and not
be registered already); its git root is detected so a repository gets its
worktrees listed, a plain folder becomes a folder project. Removing only
de-registers — no files are deleted.

### `codans worktree` — manage git worktrees

```bash
codans worktree list                                   # for current project
codans worktree list --project <project>
codans worktree new <branch>                           # git worktree add + register
codans worktree new <branch> --base origin/main        # new branch starts from --base
codans worktree new --path /abs/path --name "Hotfix" <branch>
codans worktree new <branch> --profile "Build"         # start an agent profile once setup finishes
codans worktree new <branch> --agent codex             # …or that agent's first enabled profile
codans worktree show <worktree>                        # path, branch, project, selection, pane count
codans worktree switch <worktree>                      # activate it in the GUI
codans worktree rename <worktree> "Hotfix"             # sidebar label only (path/branch stay)
codans worktree prune                                  # git worktree prune + reconcile (current project)
codans worktree rm <worktree>                          # forget the entry (files stay)
codans worktree rm <worktree> --delete                 # git worktree remove + branch cleanup
```

`new` runs the same pipeline as the New Worktree sheet: the branch is
created from `--base` (default: the repo's default remote branch, else
`HEAD`) or checked out if it already exists, and the project's copy /
fetch / setup settings apply. The directory defaults to the project's
worktrees directory (Settings ▸ Worktree; `~/.codans/repos/<project>/<branch>`
out of the box), not `$PWD`. `--path` accepts a relative path (resolved
against `$PWD`) or an absolute one; a path that already exists on disk is
registered as-is. `--name` overrides the display label (defaults to the
branch). `--json` reports `path` and whether the worktree was `created`
or merely registered. `rm` only forgets the entry, and a real git worktree
is re-adopted on the next reconcile; pass `--delete` to run the sidebar's
Remove Worktree (directory removed, branch deleted per Settings).

### `codans workspace` — one task, several repositories

```bash
codans workspace create "Checkout Flow" --project app --project api   # sources only, no branch
codans workspace create "Release" --project app --remote git@github.com:org/lib.git --path ~/tmp/release
codans workspace add <workspace> ~/dev/other                 # or --project P / --remote URL
codans workspace drop <workspace> <project>                  # name or path; disk unchanged
codans workspace show [<workspace>] [--json]                 # projects + groups + rows
codans workspace group create <workspace> feat --branch feat/checkout \
  [--base app=origin/release] [--no-fetch] [--copy-ignored] [--copy-untracked] [--agent "Claude Code"]
codans workspace group delete <workspace> feat --dry-run     # what would be lost
codans workspace group delete <workspace> feat [--delete-branches] [--discard]
codans workspace remove <workspace> [--delete-files [--discard] [--delete-branches]]
```

`create` registers the folder (default `~/.codans/workspaces/<slug>`, never
inside a git repository) with its source projects: registered projects
(`--project`), local repositories that are not bare (`--repo`), or remotes
(`--remote`, cloned once into `--clone-into`, default `~/.codans/sources/<name>`).
It creates no branch and checks nothing out; the `default` group links to each
project's main checkout. `add` and `drop` change only the source list and the
`default` group — named groups and every folder on disk stay as they are.

`group create` checks out one branch in every project into
`<root>/<name>/<project>`, using each project's Codans settings for base ref,
fetch, and copy options unless a flag overrides them. A local branch of the
same name in any project blocks it (exit 3, the project is named); a failed
checkout removes every checkout the call made. Setup commands run after all
checkouts exist; a failed one keeps the group and is reported. `--agent`
starts that profile in each member once the group exists.

`group delete` checks each member first. Uncommitted changes, unpushed
commits, running terminals, or other files in the group folder fail it with
the list (exit 3) unless `--discard` accepts losing them; a check that cannot
run fails it too. A member that cannot be removed keeps the group with the rest
deleted — run the same command again to retry. The `default` group cannot be
deleted. `remove` alone only removes the sidebar entry; `--delete-files`
deletes every named group, the links, and the workspace folder with the same
checks. Source project folders are never deleted.

Old branch flags on `create` / `add` (`--branch`, `--existing`, `--track`, …)
and `drop --keep-branch` fail with a pointer to `group create`.

### `codans tab` — open and drive sessions

A tab is one terminal session, so everything you do *to a session* lives
here. Creation / lifecycle:

```bash
codans tab list                                      # tabs in the current worktree (all panes)
codans tab list --pane p2                            # only that pane's strip
codans tab new                                       # default shell, in the focused pane
codans tab new --label agent --label claude -- claude   # initial command + labels
codans tab new --cwd /tmp --name "monitor" -- htop   # explicit cwd and a title
codans tab new --pane p2 -- npm run dev              # into a specific pane's strip
codans tab show <tab>                                # catalog view: pane, content id, labels, agent, selection
codans tab focus <tab>                               # select it and focus its pane
codans tab rename <tab> "dev server"                 # set the title
codans tab rename <tab>                              # clear it: follow the shell's title again
codans tab close <tab>                               # close the tab and end its session
codans tab reset <tab>                               # clear scrollback + reinit terminal
codans tab label <tab> agent debug                   # add labels
codans tab label <tab> agent --replace               # replace existing label set
```

`tab new` always opens a terminal: it lands at the end of the target
pane's strip (the focused pane by default) and is selected there. If the
worktree has no pane yet, one is created. `--json` returns the new tab's
`id`, `handle`, `paneID`, and `contentID`. Closing a pane's last tab
closes the pane.

Terminal I/O (`send`, `send-key`, and `capture` are also available at the
top level as `codans send` / `codans send-key` / `codans capture`, with
the target given as `--tab` or `--pane`):

```bash
# Send text (Enter appended by default — use --no-enter to suppress)
codans tab send 'echo hi'
codans tab send <tab> 'echo hi'           # explicit target
codans tab send @agent 'status'           # target by label
codans tab send p2 'status'               # a pane id targets that pane's selected tab
codans tab send --stdin <<<'long blob'    # read text from stdin
codans tab send --no-enter 'partial '     # type without submitting
codans tab send --focus <tab> 'cmd'       # select the tab (and focus its pane) after sending
codans send --pane p2 'echo hi'           # top-level form, same flags

# Run a command and wait for it: --wait returns when the shell is idle again
# and the screen has held still; --capture (implies --wait) also returns the
# lines it printed. --wait-timeout (default 30 s) → exit 11 / WAIT_TIMEOUT.
codans tab send <tab> 'npm test' --wait --wait-timeout 300
codans tab send <tab> 'git status --short' --capture
codans tab send <tab> 'git status --short' --capture --json | jq -r .data.output

# Send a named key (no text channel)
codans tab send-key escape
codans tab send-key <tab> ctrl_c
# Supported: escape, up, down, left, right, tab, enter, backspace,
# delete, home, end, pgup, pgdn, f1..f12, ctrl_c, ctrl_d, ctrl_l, ctrl_z

# Send raw bytes (e.g. CSI sequences) — exclusive of text/--stdin/--no-enter
codans tab send --raw 1b5b41        # ESC [ A (cursor up)

# Capture what's rendered (libghostty text; the usual choice)
codans tab capture                  # visible viewport (default)
codans tab capture <tab> --lines 50   # keep only the last 50 non-empty lines
codans tab capture --scope screen   # the whole active screen buffer
codans tab capture --wait-stable    # poll until the output stops changing

# Read the terminal's serialized state from its zmx daemon (scrollback too)
codans tab read                     # plain-text dump
codans tab read --tail 40           # last 40 lines
codans tab read --raw               # vt format: ANSI escapes, cursor, modes kept

# Ask the daemon what it is running
codans tab info <tab>               # shell pid + cwd, from the live daemon
```

`read`, `capture`, `info`, and `reset` take the tab as a positional
argument (`codans tab capture @worker`); `send` / `send-key` take it as the
first of two positionals (`codans tab send @worker 'ls'`). The top-level
forms take `--tab` or `--pane` instead.

Notes:

- `codans tab send` appends Enter by default. Use `--no-enter` to leave
  the shell prompt waiting for more input.
- `--raw` ships hex bytes directly (`1b5b41`, or `0x1b 0x5b 0x41`);
  control bytes ride a key-event path, printable bytes ride the text
  channel.
- `capture` is rendered text only; `read --raw` is the daemon's vt dump
  with escapes preserved. Track app-level state via `codans tree`.
- The CLI never asks for close confirmation; the in-app setting only
  governs closing from the GUI.

### `codans pane` — shape the layout

A pane is a slot of the worktree's split layout that carries a strip of
tabs; the verbs here move, split, and size those slots. They never send
text — that is `codans tab`.

```bash
codans pane list                                     # panes in the current worktree: handle, selected tab, focus
codans pane focus <pane>                             # give it keyboard focus (⌘T / ⌘W now act on its strip)
codans pane split                                    # new pane with a fresh tab to the right of the focused one
codans pane split <pane> --direction down --command htop   # beside <pane>; cwd = its selected tab's
codans pane split --json | jq -r .data.tabID         # prints the NEW TAB's id — drive it right away
codans pane resize <pane> right --amount 80          # move the divider next to it (pixels)
codans pane equalize                                 # make every split in the worktree equal
codans pane zoom                                     # focused pane fills the layout; run again to leave
codans pane zoom <pane>
codans pane close <pane>                             # close the pane AND every tab in it
```

- `pane split` creates a pane *and* its first tab; the text output is the
  new tab's id, so `TAB=$(codans pane split --json | jq -r .data.tabID)`
  followed by `codans tab send "$TAB" …` is the idiom.
- `pane close` takes a pane id (or `p<n>`). Given a tab or content id it
  fails and points you at `codans tab close` — it will not guess which
  pane you meant.
- Every pane verb accepts a tab or content id as a convenience and acts on
  the pane holding it (except `close`, above).
- There is no `pane new`: new sessions are `tab new` (into a pane's strip)
  or `pane split` (a new pane).

### `codans broadcast` — fan out input

```bash
codans broadcast --pane current 'pwd'                # every tab in this pane's strip
codans broadcast --worktree <wt> 'git status'        # every tab in every pane of the worktree
codans broadcast --label agent 'reload'              # every tab carrying the label
codans broadcast --pane p2 --no-enter '#!comment'
codans broadcast --label deploy --stdin <<<'rolling restart'
```

Exactly one of `--pane`, `--worktree`, or `--label` must be given. The
returned `delivered` count tells you how many tabs received the input.

### `codans agent` — see, wait on, and launch agents

`agent status` is the Agents View from the shell: every tab the app
recognises as running an agent, with the derived state it shows there.

```bash
codans agent status                                  # t7  claude-code  working  3m12s  api/main  "dev server"
codans agent status --json | jq '.data.agents[] | select(.state=="blocked") | .contentID'
codans agent wait t7 --until idle --wait-timeout 300      # block until the agent is waiting for input
codans agent wait t7 --until changed                 # …or until anything about it changes
codans agent wait t7 --until exit --wait-timeout 600      # …or until no agent is bound to the tab
```

States: `working` (producing output), `blocked` (asking the user
something; `blockedKind` says permission, question, or auth when known),
`idle` (at its prompt), `done` (finished a turn you have not looked at),
`error` (the agent reported a failure). An agent that reports OSC 7501
program status (Claude Code, Pi, omp) sets its own state (`source:
programStatus`, often with a `message`); for other agents the state is
derived from the tab's screen (`source: screen`), so it can lag a moment
behind the agent. `--until finished` still works as the old name of
`done`. `wait` resolves
server-side, so no polling loop is needed. Past `--wait-timeout` (1–600 s,
default 60) it fails with exit 11 and `WAIT_TIMEOUT`; the JSON error's
`details.state` is the last state seen. Each row carries the tab's
`contentID`, `tabID`, and `paneID`, so you can send to it, select it, or
split beside it without a second lookup. `tab show` reports the bound
agent without the state.

Profiles are the launch presets from Settings > Agents (agent, model, effort,
execution mode, placement, extra args, env). Launching one opens a fresh tab
in the focused pane (or a new pane with `--split`) in the target worktree
and types the profile's command into it.

```bash
codans agent list                                    # id, name, agent, command per profile
codans agent launch "Claude Code"                     # by name (or id)
codans agent launch --agent codex                     # first enabled Codex profile
codans agent launch --agent claude --split right      # a new pane instead of a tab
codans agent launch --agent codex --background        # don't steal focus
codans agent launch --agent claude --prompt - <<'EOF' # seed the session with a task
Review the diff on this branch and list risks.
EOF
```

Notes:

- `--prompt` works only for agents that can start interactively with an
  initial prompt (Claude Code, Codex, Gemini CLI); others reject it.
- A disabled profile is refused — enable it in Settings > Agents.
- `--json` returns `profileID`, `profileName`, `agent`, `command`, `paneID`,
  `tabID`, `contentID`.

### `codans handoff` — hand a task to another agent

Agents are separate processes with separate context; the filesystem is the
only durable channel between them. `handoff` makes that channel structured:
it archives the previous round under the worktree's `.codans/handoff/`,
installs **your** briefing as `current.md`, regenerates `context.md`
(branch, changed files, a screen excerpt of your tab, and a resume command
for your session), then starts the receiving agent in a background tab with
a kickoff prompt pointing at those files.

**You are the source.** Run it inside your own tab and codans hands off the
task you are working on. Write the briefing yourself, from your working
knowledge, as a heredoc on stdin:

```bash
codans handoff to codex --brief - <<'EOF'
# Handoff
## Objective
…
## Current State
…
## What Has Been Done
…
## Open Questions
…
## Risks / Watch Out
…
## Next Steps
1. …
## Suggested Prompt For Next Agent
…
EOF
```

```bash
codans handoff save --brief - <<'EOF'      # checkpoint: briefing + context, no receiver
…
EOF
codans handoff to claude --no-brief         # context-only (explicit) — no briefing written
codans handoff to codex --split right --brief -       # receiver in a new pane beside this one
codans handoff to amp --no-launch --brief - # archive + brief only; don't start the receiver
codans handoff to codex --profile "Build" --brief -   # launch a specific profile
codans handoff to codex --pane t3 --brief -           # another tab is the source
```

Rules:

- `--brief -` or `--no-brief` is required. Missing → error with a
  copy-pasteable heredoc, nothing written. A briefing must contain at least
  `## Objective`, `## Current State`, and `## Next Steps` (outside code
  fences); otherwise the command errors with zero side effects.
- Any agent token is a receiver. `claude`/`claude-code`, `codex`, `gemini`,
  `cursor-agent`, `grok`, `pi` and `omp` take the kickoff prompt on their
  command line; for the others codans types it into the new tab once the
  agent is up and presses Enter once the input box shows the text (a TUI
  that opens on a dialog gets no Enter; the miss is logged).
  `--no-launch` archives and briefs without starting anyone.
- The receiver starts in the background in the same worktree: a **new tab**
  in the focused pane by default, or a new pane beside the source tab's
  pane with `--split right|left|up|down`. The handoff never types into
  your tab and never focuses anything.
- `--pane` names the source session; it accepts a tab, content, or pane id
  (a pane means its selected tab).
- If the app's Hand Off panel asked you to run this, keep the
  `CODANS_HANDOFF_REQUEST_ID=…` prefix it gave you — that is how the panel
  knows the transition it is waiting on completed.
- Handoff only reads git (`status`, branch, shortstat); it never commits or
  pushes. `.codans/handoff/` ignores itself.

### `codans open` — open a directory in an editor

```bash
codans open                          # $PWD in the project's / global default editor
codans open ~/code/api --in cursor   # a specific editor id: cursor, zed, vscode, xcode, finder, ghostty, …
```

`--in` is strict (an uninstalled editor is an error); without it codans
walks the per-project default, the global default, then the installed
editors in priority order, ending at Finder.

### `codans skill` — install this skill for your agents

The app bundles its agent skills; these commands link them into the
folders agents read skills from, so each agent learns the CLI from the
version that matches the installed app. Local file-system work — the app
need not be running. The same switches live in Settings ▸ Developer ▸
Agent skills; installing is always the user's choice per agent.

```bash
codans skill list                            # bundled skills × targets, with install status
codans skill install                         # link every skill into every detected target
codans skill install codans-cli --target claude --target codex
codans skill install --scope project         # into <git root>/.claude/skills (etc.)
codans skill uninstall                       # remove the links (only ones that point at a bundle)
codans skill path codans-cli                 # where the bundled copy lives
```

Targets: `claude` (`~/.claude/skills`), `codex` (`~/.codex/skills`),
`agents` (`~/.agents/skills`); a target is detected when its agent folder
exists. A link to another install's copy is replaced; a directory or
foreign link under the skill's name is a conflict unless `--force`.

## Common patterns

### Read a sibling tab (agent A inspecting agent B)

```bash
codans agent status                                      # which tabs run an agent, and their state
codans tab list --json | jq -r '.data.tabs[].id'        # find a tab uuid
codans tab capture <uuid> --lines 200 > /tmp/log.txt     # snapshot trailing rendered output
codans tab read <uuid>                                   # the daemon's dump (scrollback too)
```

Label the target once (`codans tab label <uuid> agent`) and refer to it
as `@agent` thereafter.

### Drive a REPL from a script

```bash
codans tab new --label repl -- python3
codans tab send @repl 'import math' --wait
codans tab send @repl 'print(math.pi)' --capture
```

### Put a watcher beside you

```bash
TAB=$(codans pane split --direction down --command 'npm test -- --watch' --json | jq -r .data.tabID)
codans tab capture "$TAB" --wait-stable --lines 20       # read the new pane's tab
codans pane focus "$CODANS_PANE_ID"                      # come back to your own pane
```

### Spin up a worktree and a tab for it

```bash
WT=$(codans worktree new exp/feature-x --json | jq -r '.data.id')   # git worktree add + register
codans tab new --worktree "$WT" --name "dev" --cwd "$(codans worktree show "$WT" --json | jq -r '.data.path')" -- npm run dev
```

### Start a cross-repository task in a workspace

```bash
WS=$(codans workspace create "Checkout Flow" --project app --project api --json | jq -r '.data.id')
codans workspace group create "$WS" checkout --branch feat/checkout
# The group's own row is the group folder; each member is a row under it.
GROUP_ROW=$(codans workspace show "$WS" --json | jq -r '.data.groups[] | select(.name == "checkout") | .worktreeID')
codans tab new --worktree "$GROUP_ROW" --name "agent" -- claude
# runs in <root>/checkout; `git -C app`, `git -C api` per member
```

### Take over a task from the previous agent

If you were started by a handoff, your kickoff prompt names the files. Read
them before touching code:

```bash
cat .codans/handoff/current.md    # the previous agent's briefing (may be absent)
cat .codans/handoff/context.md    # generated state: branch, changed files, session excerpt
ls .codans/handoff/archive/       # earlier rounds, newest last
```

Continue from **Next Steps**; do not redo what is listed under **What Has
Been Done**. When you are done or blocked, hand off again with
`codans handoff to <agent> --brief -` or checkpoint with `codans handoff save`.

### JSON-driven scripting

Every command supports `--json` and prints the envelope described under
[JSON output contract](#json-output-contract). Read fields under `.data`
and branch on `.error.code`:

```bash
TAB=$(codans tab list --json | jq -r '.data.tabs[0].id')
out=$(codans tab send "$TAB" 'make test' --capture --wait-timeout 600 --json)
if jq -e '.error' <<<"$out" >/dev/null; then
  echo "failed: $(jq -r '.error.code + ": " + .error.message' <<<"$out")" >&2
else
  jq -r '.data.output' <<<"$out"
fi
```

### Verify before you act

Without `--wait`, `codans tab send` is fire-and-forget — the RPC reports
bytes shipped, not the receiving program's reaction. For a shell command
use `--wait` / `--capture`; for an agent tab, wait on its state and then
read the screen:

```bash
codans tab send @worker 'run the tests and fix what fails'
codans agent wait @worker --until idle --wait-timeout 600
codans tab capture @worker --wait-stable --lines 40
```

## Troubleshooting

| Symptom                                             | Likely cause / fix                                                        |
|-----------------------------------------------------|---------------------------------------------------------------------------|
| `socket /tmp/codans-*.sock did not become reachable` | App isn't running. Run `codans launch` or open codans from the GUI.       |
| `no current tab: this shell is not inside a Codans tab` (or project/worktree/pane) | You used `current` / `.` outside a codans Tab. Pass an explicit ID or name. |
| `tab <uuid> not found`                              | The tab was closed, or the UUID came from a different app instance.      |
| `use "codans tab send"` (or another new location)   | The verb moved: session verbs live under `codans tab`, layout verbs under `codans pane`. Re-run at the location the hint names. |
| `pane close: <id> is a tab; use "codans tab close"` | You gave `pane close` a tab or content id. Use `tab close` for one session, or the pane's own id (`p<n>`) to close the whole pane. |
| `unknown key "..."`                                 | `codans tab send-key` only knows the keys listed above. Use `--raw` for the rest. |
| `--raw is exclusive of ...`                         | `codans tab send --raw` cannot combine with positional text, `--stdin`, or `--no-enter`. |
| `unknown tab "echo"; pass a tab id, ...`            | The first word of an unquoted `tab send` was taken as the target. Quote the text. |
| `tab t7 did not reach idle within 60s`              | `agent wait` hit its deadline (exit 11, `WAIT_TIMEOUT`). Raise `--wait-timeout`, or check `codans agent status` for what the agent is doing. |
| `command in tab … still running after 30s`         | `tab send --wait` hit its deadline. Raise `--wait-timeout`, or read the tab later with `codans tab capture`. |
| Help shows fewer commands than expected             | Trust `codans --help` over external docs; `codans help-json` prints the whole tree. |

## What this CLI does *not* do (yet)

To prevent suggesting commands that don't exist:

- No `codans pane new` / `pane send` / `pane send-key` / `pane read` /
  `pane capture` / `pane info` / `pane label` / `pane reset` / `pane show`,
  and no `codans tab switch` — those verbs exit non-zero and name their
  home under `codans tab` (`tab new`, `tab send`, `tab focus`, …).
- No `codans read` at the top level; only `send`, `send-key`, `capture`,
  and `broadcast` have top-level forms.
- No moving a tab between panes or worktrees from the CLI; no drag-style
  reordering.
- No `codans tag ...` yet (tags are managed in the sidebar).
- No `codans space ...` — codans does not expose a Space concept via `codans`
  today; the hierarchy is rooted at Project.

If a user asks for any of these, surface the gap rather than fabricating a
command.
