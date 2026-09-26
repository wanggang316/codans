---
name: codans
description: Drive the codans Mac app from a terminal with the `codans` CLI — inspect the Project / Worktree / Tab / Pane hierarchy, create and switch worktrees, spawn tabs and panes, run a command in a pane and capture its output, send keystrokes or text, read back rendered output, broadcast input across panes, see which panes run agents and wait for their state, launch agent profiles, hand a task off to another agent, create a multi-repository workspace or add a repository to one, install this skill for agents, and check app health. Use this skill whenever the user is operating inside a codans Pane, references the `codans` command, asks how to script codans, or wants to coordinate panes / worktrees / agents from the shell. Prefer `codans tree` to discover state before issuing any other command.
---

# codans CLI (`codans`)

## What is codans?

**codans** is a macOS desktop app built for the next generation of
agent-based parallel development. At its core it is a parallel-development
tool on top of **git worktree + terminals**, organised as
**Project → Worktree → Tab → Pane**. Terminals are rendered natively via
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
  | `wrong-channel` | This pane belongs to a development build of Codans, whose CLI is `codans-dev` | Use `codans-dev` for the rest of the session; see [Development builds](#development-builds) |

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

- The user is inside a codans Pane and wants to script some action.
- The user mentions "codans ..." or asks how to do something in codans from
  the terminal.
- An agent (Claude Code, Codex, custom) wants to read a sibling pane's
  output, send input to it, or spawn new panes / tabs / worktrees.
- The user wants to inspect the codans app's state without opening the
  GUI.

## Hierarchy in 60 seconds

```
Project       a tracked git repo (one Project per repo) — or a workspace
 └── Worktree a git worktree of that repo (own dir + branch + tab layout)
      └── Tab one named grouping of panes in a worktree (one Tab visible)
           └── Pane a single libghostty terminal session
```

A **workspace** Project (`"kind": "workspace"` in `codans tree --json`) is a
plain folder holding checkouts of *several* repositories for one task, listed
in `<root>/.codans/workspace.json`. Its first Worktree row is the folder
itself; every other row is one member checkout, whose repository is reported
as `sourceGitRoot`. Treat those rows as independent repos: `git -C <path>`
per row, never `git worktree` commands against the workspace root.

`codans` is on `PATH` automatically inside every codans Pane, and the app
auto-detects which Project / Worktree / Tab / Pane that Pane belongs to —
so most commands default to the surrounding context and you rarely need
to pass IDs.

## Targeting model

One grammar everywhere. A verb that acts on one thing takes that thing as
its **single positional target**; the containers above it are
`--project` / `--worktree` / `--tab` options that default to `current`.
Text, commands, and names of new things never share the positional slot
with a target: `pane send` is the one exception (one argument is text for
the current pane, two are `<pane> <text>`), and `pane split` takes its
command as `--command`.

Every target accepts the same forms, whichever level it is:

| Form | Applies to | Example |
|---|---|---|
| `current` / `.` | project, worktree, tab, pane | the containers of the pane you run from |
| UUID | all | `codans tab close 5CBC66C9-…` |
| `t<n>` / `p<n>` handle | tab, pane | the numbers `codans tree` prints as `Tab t3:` / `Pane p7:` |
| `@label` | pane | labels set with `codans pane label` |
| name | project (name), worktree (name **or branch**), tab (title) | `--worktree bugfix/menu`, `tab switch "dev server"` |
| path | worktree (`/abs`, `~/x`, `./x`, `../x`; a directory inside the worktree also matches) | `worktree switch ~/code/api-hotfix`, `--worktree "$PWD"` |

Handles stay stable for as long as the tab / pane lives, are released
when it closes, and are never reused within one app session, so a stale
handle fails with not-found instead of hitting the wrong target. Names
are case-insensitive and scoped to the calling pane's containers when
there is one (`--worktree main` means "this project's main"); an
ambiguous name is a conflict (exit 3, `CONFLICT`) — pass the id. Panes
have no name: a bare word where a pane is expected is a usage error,
which is usually unquoted text (`codans pane send echo hi` — quote it).

`current` for a project / worktree / tab is derived from the pane the
command runs in, so it works from any subshell or wrapper inside a pane.
Outside a codans Pane there is no current pane: the command fails with
`no current <kind>: this shell is not inside a Codans pane` (exit 2,
`NO_CURRENT_CONTEXT`) — pass an explicit id, name, or path, or run
`codans tree` to discover one. Verbs whose target already determines its
containers (`tab close t3`, `pane new --tab t3`, `worktree rm <id>`) never
need `--project` / `--worktree` at all.

## Development builds

A development build of Codans is a separate app: its own socket, its own
config, and its CLI is named `codans-dev`. Inside a pane spawned by a
development build, type `codans-dev` wherever this skill says `codans`.
`$CODANS_CLI` always holds the absolute path of the CLI that belongs to
the pane you are in, so `basename "$CODANS_CLI"` is the command to use.

The release `codans` refuses to run inside a development pane (exit code
15, `codans doctor` reports `socketStatus wrong-channel`) and its hint
names the command to switch to. `codans-dev` run from a release pane
still drives the development app.

## Detecting codans from a script

Every codans Pane's environment carries a product marker plus
pane-context variables, so a script or agent can branch on "am I inside
codans" without probing the socket:

- `TERM_PROGRAM=codans` — set for every pane; `TERM_PROGRAM_VERSION`
  carries the app version.
- `CODANS_WORKTREE_PATH` / `CODANS_ROOT_PATH` — absolute paths of the
  pane's worktree and its Project root.

```bash
if [ "$TERM_PROGRAM" = "codans" ]; then
  # running inside a codans Pane; `current` targeting works
  codans pane read
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
{ "schemaVersion": "codans.cli.pane.send.v1", "data": { "paneID": "…", "bytes": 12 } }
{ "schemaVersion": "codans.cli.pane.focus.v1",
  "error": { "code": "NOT_FOUND", "message": "pane not found: p9",
             "hint": "…", "details": { "kind": "pane", "id": "p9" } } }
```

- `schemaVersion` is `codans.cli.<command path>.v1` and identical for
  `codans` and `codans-dev`; read fields under `.data`.
- On failure the exit code is still set and `error.code` is a stable
  string: `INVALID_ARGUMENT`, `NOT_FOUND`, `CONFLICT`, `UNSUPPORTED`,
  `APP_NOT_RUNNING`, `REQUEST_TIMEOUT`, `WRONG_CHANNEL`, `INTERNAL`, plus
  the specific `NO_CURRENT_CONTEXT` (`current` outside a pane),
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
codans tree                                # see every Project / Worktree / Tab / Pane
codans agent status                        # which panes run an agent, and what it is doing
codans pane send 'pwd' --capture           # run a command in the current pane, get its output
codans pane capture                        # read back what's on screen
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
form marks the selected worktree/tab with `*`, prints pane labels as
`@label`, and prints each tab/pane's short handle (`Tab t3:` / `Pane p7:`)
— pass those handles anywhere a tab/pane id is accepted. JSON output
carries full UUIDs plus the same handles as `handle` (`"t3"` / `"p7"`).

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
codans worktree show <worktree>                        # path, branch, project, selection, tab count
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
codans workspace create "Checkout Flow" --project app --project api   # ≥ 2 members
codans workspace create "Checkout Flow" --project app --repo ~/dev/shared-lib \
  --branch feat/checkout --base origin/main --path ~/tmp/checkout-flow
codans workspace create "Release" --project app --remote git@github.com:org/lib.git \
  --branch release/1.2 --track                          # remote-tracking origin/release/1.2
codans workspace add <workspace> --repo ~/dev/other --existing --branch main
codans workspace add <workspace> --repo ~/dev/tool --ref origin/main   # remote-tracking ref
codans workspace add <workspace> --remote https://host/team/svc --clone-into ~/src
codans workspace drop <workspace> <member> [--keep-branch]   # unregister one checkout
codans workspace remove <workspace> [--delete-files [--delete-branches]]
codans workspace show [<workspace>]                    # manifest + live rows
```

`create` makes `<root>/<name>` for every member with `git worktree add`
(new branch `--branch`, default: a slug of the title, from `--base`, default:
the repository's default remote branch; `--existing` checks out an existing
local branch instead; `--track` checks out the remote-tracking
`origin/<branch>`), writes `<root>/.codans/workspace.json`, and registers the
folder as a workspace Project. Members come from registered projects
(`--project`), any local repository that is not bare (`--repo`), or a
remote URL (`--remote`) — all repeatable. A remote is cloned once into
`--clone-into` (default `~/.codans/sources/<name>`; an existing clone of the
same remote there is reused) and then behaves like a local repository. With
`--track` or `add --ref <remote>/<branch>`, a local branch of the same name is
checked out as is; `--reset-local` points it at the remote tip instead and is
never implied. The root defaults to `~/.codans/workspaces/<slug>` and must
not sit inside a git repository. Both verbs really write to disk — a failure
midway removes everything the call created, including a clone it made. `drop` moves one member's checkout out of the
workspace and deletes its branch (unless `--keep-branch`); `remove` alone
only de-registers, while `--delete-files` unregisters every member and
deletes the folder — but keeps the folder if any member could not be
unregistered, so a repository is never left pointing at a missing worktree.

### `codans tab` — manage tabs inside a worktree

```bash
codans tab list                              # tabs in current worktree
codans tab new                               # untitled tab
codans tab new "dev server"                  # named tab
codans tab show <tab>                        # title, handle, focused pane, pane ids
codans tab switch <tab>                      # activate
codans tab rename <tab> "dev server"         # set the title
codans tab rename <tab>                      # clear it: follow the shell's title again
codans tab close <tab>                       # close
```

`codans tab new` creates the tab but does not spawn a pane inside it — use
`codans pane new` for that, or rely on the GUI's auto-pane behavior.

### `codans pane` — manage and drive panes

Creation / lifecycle:

```bash
codans pane list                                     # panes in current tab
codans pane new                                      # default shell
codans pane new --label agent --label claude -- claude   # initial command + labels
codans pane new --cwd /tmp -- htop                   # explicit cwd
codans pane split <pane> --direction down --command htop   # new pane beside <pane>; cwd = the anchor's
codans pane show <pane>                              # catalog view: containers, labels, agent, focus
codans pane focus <pane>                             # bring to front
codans pane resize <pane> right --amount 80          # move the divider next to it (pixels)
codans pane close <pane>
codans pane reset <pane>                             # clear scrollback + reinit terminal
codans pane label <pane> agent debug                 # add labels
codans pane label <pane> agent --replace             # replace existing label set
```

Terminal I/O (also accessible as `codans pane send`, `codans pane send-key`,
`codans pane read`, `codans pane capture`):

```bash
# Send text (Enter appended by default — use --no-enter to suppress)
codans pane send 'echo hi'
codans pane send <pane> 'echo hi'         # explicit target
codans pane send -p @agent 'status'        # target by label
codans pane send --stdin <<<'long blob'    # read text from stdin
codans pane send --no-enter 'partial '     # type without submitting
codans pane send --focus <pane> 'cmd'      # focus the pane after sending

# Run a command and wait for it: --wait returns when the shell is idle again
# and the screen has held still; --capture (implies --wait) also returns the
# lines it printed. --wait-timeout (default 30 s) → exit 11 / WAIT_TIMEOUT.
codans pane send <pane> 'npm test' --wait --wait-timeout 300
codans pane send <pane> 'git status --short' --capture
codans pane send <pane> 'git status --short' --capture --json | jq -r .data.output

# Send a named key (no text channel)
codans pane send-key escape
codans pane send-key <pane> ctrl_c
# Supported: escape, up, down, left, right, tab, enter, backspace,
# delete, home, end, pgup, pgdn, f1..f12, ctrl_c, ctrl_d, ctrl_l, ctrl_z

# Send raw bytes (e.g. CSI sequences) — exclusive of text/--stdin/--no-enter
codans pane send --raw 1b5b41        # ESC [ A (cursor up)

# Capture what's rendered (libghostty text; the usual choice)
codans pane capture                  # visible viewport (default)
codans pane capture <pane> --lines 50   # keep only the last 50 non-empty lines
codans pane capture --scope screen   # the whole active screen buffer
codans pane capture --wait-stable    # poll until the output stops changing

# Read the terminal's serialized state from its zmx daemon (scrollback too)
codans pane read                     # plain-text dump
codans pane read --tail 40           # last 40 lines
codans pane read --raw               # vt format: ANSI escapes, cursor, modes kept
```

`read`, `capture`, `info`, and `reset` take the pane as a positional
argument (`codans pane capture @worker`); only `send` / `send-key` have a
`-p/--pane` flag.

Notes:

- `codans pane send` appends Enter by default. Use `--no-enter` to leave
  the shell prompt waiting for more input.
- `--raw` ships hex bytes directly (`1b5b41`, or `0x1b 0x5b 0x41`);
  control bytes ride a key-event path, printable bytes ride the text
  channel.
- `capture` is rendered text only; `read --raw` is the daemon's vt dump
  with escapes preserved. Track app-level state via `codans tree`.

### `codans broadcast` — fan out input

```bash
codans broadcast --tab current 'pwd'
codans broadcast --worktree <wt> 'git status'
codans broadcast --label agent 'reload'
codans broadcast --tab current --no-enter '#!comment'
codans broadcast --label deploy --stdin <<<'rolling restart'
```

Exactly one of `--tab`, `--worktree`, or `--label` must be given. The
returned `delivered` count tells you how many panes received the input.

### `codans agent` — see, wait on, and launch agents

`agent status` is the Agents View from the shell: every pane the app
recognises as running an agent, with the derived state it shows there.

```bash
codans agent status                                  # p7  claude-code  working  3m12s  api/main  "dev server"
codans agent status --json | jq '.data.agents[] | select(.state=="blocked") | .paneID'
codans agent wait p7 --until idle --wait-timeout 300      # block until the agent is waiting for input
codans agent wait p7 --until error                   # wait for a recognized terminal failure
codans agent wait p7 --until changed                 # …or until anything about it changes
codans agent wait p7 --until exit --wait-timeout 600      # …or until no agent is bound to the pane
```

States: `working` (producing output), `blocked` (asking the user
something), `error` (a recognized Codex/Claude terminal failure), `idle` (at its prompt), `finished` (went idle while in the
background). The state is derived from the pane's screen and foreground
process, so it can lag a moment behind the agent; `wait` resolves
server-side, so no polling loop is needed. Past `--wait-timeout` (1–600 s,
default 60) it fails with exit 11 and `WAIT_TIMEOUT`; the JSON error's
`details.state` is the last state seen. `pane show` reports the bound
agent without the state.

Error detection is conservative terminal-text matching, not a structured provider
event. Settings > Agents > Error Recovery optionally sends a delayed prompt or
runs a bounded local script. It is off by default; avoid adding a second retry
loop when it is enabled. The error row context menu can cancel automatic recovery.

Profiles are the launch presets from Settings > Agents (agent, model, effort,
execution mode, placement, extra args, env). Launching one opens a fresh tab
(or split) in the target worktree and types the profile's command into it.

```bash
codans agent list                                    # id, name, agent, command per profile
codans agent launch "Claude Code"                     # by name (or id)
codans agent launch --agent codex                     # first enabled Codex profile
codans agent launch --agent claude --split right      # override placement
codans agent launch --agent codex --background        # don't steal focus
codans agent launch --agent claude --prompt - <<'EOF' # seed the session with a task
Review the diff on this branch and list risks.
EOF
```

Notes:

- `--prompt` works only for agents that can start interactively with an
  initial prompt (Claude Code, Codex, Gemini CLI); others reject it.
- A disabled profile is refused — enable it in Settings > Agents.
- `--json` returns `profileID`, `profileName`, `agent`, `command`, `tabID`,
  `paneID`.

### `codans handoff` — hand a task to another agent

Agents are separate processes with separate context; the filesystem is the
only durable channel between them. `handoff` makes that channel structured:
it archives the previous round under the worktree's `.codans/handoff/`,
installs **your** briefing as `current.md`, regenerates `context.md`
(branch, changed files, a screen excerpt of your pane, and a resume command
for your session), then starts the receiving agent in a background tab with
a kickoff prompt pointing at those files.

**You are the source.** Run it inside your own pane and codans hands off the
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
codans handoff to codex --split right --brief -       # receiver in a split beside this pane
codans handoff to amp --no-launch --brief - # archive + brief only; don't start the receiver
codans handoff to codex --profile "Build" --brief -   # launch a specific profile
codans handoff to codex --pane p3 --brief -           # another pane is the source
```

Rules:

- `--brief -` or `--no-brief` is required. Missing → error with a
  copy-pasteable heredoc, nothing written. A briefing must contain at least
  `## Objective`, `## Current State`, and `## Next Steps` (outside code
  fences); otherwise the command errors with zero side effects.
- Any agent token is a receiver. `claude`/`claude-code`, `codex`, `gemini`,
  `cursor-agent`, `grok`, `pi` and `omp` take the kickoff prompt on their
  command line; for the others codans types it into the new pane once the
  agent is up and presses Enter once the input box shows the text (a TUI
  that opens on a dialog gets no Enter; the miss is logged).
  `--no-launch` archives and briefs without starting anyone.
- The receiver starts in the background in the same worktree: a **new tab**
  by default, or beside the source pane with `--split right|left|up|down`.
  The handoff never types into your pane and never focuses anything.
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

### Read a sibling pane (agent A inspecting agent B)

```bash
codans agent status                                      # which panes run an agent, and their state
codans pane list --json | jq -r '.data.panes[].id'      # find a pane uuid
codans pane capture <uuid> --lines 200 > /tmp/log.txt    # snapshot trailing rendered output
codans pane read <uuid>                                  # the daemon's dump (scrollback too)
```

If both panes share a tab, label the target once (`codans pane label <uuid> agent`)
and refer to it as `@agent` thereafter.

### Drive a REPL from a script

```bash
codans pane new --label repl -- python3
codans pane send -p @repl 'import math' --wait
codans pane send -p @repl 'print(math.pi)' --capture
```

### Spin up a worktree and a tab for it

```bash
WT=$(codans worktree new exp/feature-x --json | jq -r '.data.id')   # git worktree add + register
TAB=$(codans tab new "dev" --worktree "$WT" --json | jq -r '.data.id')
codans pane new --tab "$TAB" --cwd "$(codans worktree show "$WT" --json | jq -r '.data.path')" -- npm run dev
```

### Start a cross-repository task in a workspace

```bash
codans workspace create "Checkout Flow" --project app --project api --branch feat/checkout
# The workspace root is the new project's first worktree; each member is a row.
WS=$(codans tree --json | jq -r '.projects[] | select(.kind == "workspace") | .id')
codans workspace show "$WS"
codans tab new --worktree "$(codans tree --json | jq -r --arg ws "$WS" '.projects[] | select(.id == $ws) | .worktrees[0].id')" "agent"
codans pane new -- claude    # runs at the workspace root; `git -C app`, `git -C api` per member
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
PANE=$(codans pane list --json | jq -r '.data.panes[0].id')
out=$(codans pane send "$PANE" 'make test' --capture --wait-timeout 600 --json)
if jq -e '.error' <<<"$out" >/dev/null; then
  echo "failed: $(jq -r '.error.code + ": " + .error.message' <<<"$out")" >&2
else
  jq -r '.data.output' <<<"$out"
fi
```

### Verify before you act

Without `--wait`, `codans pane send` is fire-and-forget — the RPC reports
bytes shipped, not the receiving program's reaction. For a shell command
use `--wait` / `--capture`; for an agent pane, wait on its state and then
read the screen:

```bash
codans pane send -p @worker 'run the tests and fix what fails'
codans agent wait @worker --until idle --wait-timeout 600
codans pane capture @worker --wait-stable --lines 40
```

## Troubleshooting

| Symptom                                             | Likely cause / fix                                                        |
|-----------------------------------------------------|---------------------------------------------------------------------------|
| `socket /tmp/codans-*.sock did not become reachable` | App isn't running. Run `codans launch` or open codans from the GUI.       |
| `no current pane: this shell is not inside a Codans pane` (or project/worktree/tab) | You used `current` / `.` outside a codans Pane. Pass an explicit ID or name. |
| `pane <uuid> not found`                             | The pane was closed, or the UUID came from a different app instance.     |
| `unknown key "..."`                                 | `codans pane send-key` only knows the keys listed above. Use `--raw` for the rest. |
| `--raw is exclusive of ...`                         | `codans pane send --raw` cannot combine with positional text, `--stdin`, or `--no-enter`. |
| `unknown pane "echo"; pass a pane id, ...`           | The first word of an unquoted `pane send` was taken as the target. Quote the text. |
| `pane p7 did not reach idle within 60s`             | `agent wait` hit its deadline (exit 11, `WAIT_TIMEOUT`). Raise `--wait-timeout`, or check `codans agent status` for what the agent is doing. |
| `command in pane … still running after 30s`        | `pane send --wait` hit its deadline. Raise `--wait-timeout`, or read the pane later with `codans pane capture`. |
| Help shows fewer commands than expected             | Trust `codans --help` over external docs; `codans help-json` prints the whole tree. |

## What this CLI does *not* do (yet)

To prevent suggesting commands that don't exist:

- No `codans send` / `codans read` / `codans send-key` / `codans capture` at top level —
  they live under `codans pane`.
- No `codans tag ...` yet (tags are managed in the sidebar).
- No pane zoom / unzoom: the app has no zoomed-pane rendering to drive.
- No `codans space ...` — codans does not expose a Space concept via `codans`
  today; the hierarchy is rooted at Project.

If a user asks for any of these, surface the gap rather than fabricating a
command.
