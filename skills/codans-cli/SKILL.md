---
name: codans
description: Drive the codans Mac app from a terminal with the `codans` CLI — inspect the Project / Worktree / Tab / Pane hierarchy, create and switch worktrees, spawn tabs and panes, send keystrokes or text to a pane, read back its rendered output, broadcast input across panes, launch agent profiles, hand a task off to another agent, and check app health. Use this skill whenever the user is operating inside a codans Pane, references the `codans` command, asks how to script codans, or wants to coordinate panes / worktrees / agents from the shell. Prefer `codans tree` to discover state before issuing any other command.
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
Project       a tracked git repo (one Project per repo)
 └── Worktree a git worktree of that repo (own dir + branch + tab layout)
      └── Tab one named grouping of panes in a worktree (one Tab visible)
           └── Pane a single libghostty terminal session
```

`codans` is on `PATH` automatically inside every codans Pane, and the app
auto-detects which Project / Worktree / Tab / Pane that Pane belongs to —
so most commands default to the surrounding context and you rarely need
to pass IDs.

## Targeting model

Most subcommands accept identifiers in any of these forms:

- **`current` or `.`** — the ambient Project / Worktree / Tab / Pane of
  the shell you're running `codans` from. This is the default for nearly every
  `--project`, `--worktree`, `--tab`, and `--pane` flag, so you usually
  don't have to type anything.
- **Literal UUID** — passed through unchanged; fast path for scripts.
- **`t<n>` / `p<n>` short handles** (tabs / panes) — the stable integers
  `codans tree` prints as `Tab t3:` / `Pane p7:`. A handle keeps pointing
  at the same tab/pane across CLI calls for as long as it lives (unlike
  positional indices, which shift), is released when the target closes,
  and is never reused within one app session — a stale handle fails with
  not-found instead of hitting the wrong target.
- **`@label`** (panes only) — server-side lookup against pane labels
  applied with `codans pane label`.
- **Anything else** — sent to the server's alias resolver (e.g. a project
  name or a worktree alias the app knows about).

If you run `codans` from a shell that is *not* inside a codans Pane,
`current` has no meaning and you'll get a `noContext` error — pass an
explicit UUID, or use `codans tree` to discover one.

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
- `--timeout <seconds>` — RPC client timeout (default 10s).

Use `codans <subcommand> --help` for the exact flag list of any command.

## Quick start

```bash
codans doctor                # confirm the app is reachable
codans tree                  # see every Project / Worktree / Tab / Pane
codans pane send 'pwd'       # type 'pwd\n' into the current pane
codans pane read             # read back what's on screen
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
carries full UUIDs.

### `codans project` — manage projects

```bash
codans project list                          # all projects
codans project add ~/code/api                # register an existing directory
codans project add --name "API" ~/code/api   # custom display name
codans project rm <project>                  # remove (id, name, or 'current')
```

Adding a project just registers it with codans; it does not move
files. Removing only de-registers — no files are deleted.

### `codans worktree` — manage git worktrees

```bash
codans worktree list                                   # for current project
codans worktree list --project <project>
codans worktree new <branch>                           # path defaults to ./<branch>
codans worktree new --path /abs/path --name "Hotfix" <branch>
codans worktree switch <worktree>                      # activate it in the GUI
codans worktree rm <worktree>                          # de-register
```

`<branch>` is required for `new`. `--path` accepts a relative path
(resolved against `$PWD`) or an absolute one. `--name` overrides the
display label (defaults to the branch).

### `codans tab` — manage tabs inside a worktree

```bash
codans tab list                              # tabs in current worktree
codans tab new                               # untitled tab
codans tab new "dev server"                  # named tab
codans tab switch <tab>                      # activate
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
codans pane focus <pane>                             # bring to front
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

# Send a named key (no text channel)
codans pane send-key escape
codans pane send-key <pane> ctrl_c
# Supported: escape, up, down, left, right, tab, enter, backspace,
# delete, home, end, pgup, pgdn, f1..f12, ctrl_c, ctrl_d, ctrl_l, ctrl_z

# Send raw bytes (e.g. CSI sequences) — exclusive of text/--stdin/--no-enter
codans pane send --raw 1b5b41        # ESC [ A (cursor up)

# Read what's on the pane
codans pane read                     # visible viewport (default)
codans pane read --screen            # whole active screen buffer
codans pane read --selection         # current text selection

# Capture rendered text (same data as read, plus trimming)
codans pane capture --lines 50       # keep only the last 50 non-empty lines
codans pane capture --scope screen   # capture the full screen, not just viewport
```

Notes:

- `codans pane send` appends `\n` by default. Use `--no-enter` to leave the
  shell prompt waiting for more input.
- `--raw` ships hex bytes directly (e.g. `1b` = ESC); control bytes ride a
  key-event path, printable bytes ride the text channel.
- Pane I/O is rendered-text only — codans does not expose the raw PTY
  byte stream, so OSC / CSI / APC sequences are not visible via `read` or
  `capture`. Track app-level state via `codans tree` instead.

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

### `codans agent` — launch agent profiles

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
codans handoff to amp --no-launch --brief - # archive + brief for an agent codans can't launch
codans handoff to codex --profile "Build" --brief -   # launch a specific profile
codans handoff to codex --pane p3 --brief -           # another pane is the source
```

Rules:

- `--brief -` or `--no-brief` is required. Missing → error with a
  copy-pasteable heredoc, nothing written. A briefing must contain at least
  `## Objective`, `## Current State`, and `## Next Steps` (outside code
  fences); otherwise the command errors with zero side effects.
- Launchable receivers: `claude`/`claude-code`, `codex`, `gemini`. Any other
  agent token works with `--no-launch`.
- The receiver starts in a **new background tab** of the same worktree; the
  handoff never types into your pane and never focuses anything.
- If the app's Hand Off panel asked you to run this, keep the
  `CODANS_HANDOFF_REQUEST_ID=…` prefix it gave you — that is how the panel
  knows the transition it is waiting on completed.
- Handoff only reads git (`status`, branch, shortstat); it never commits or
  pushes. `.codans/handoff/` ignores itself.

## Common patterns

### Read a sibling pane (agent A inspecting agent B)

```bash
codans pane list --json | jq -r '.panes[].id'           # find the pane uuid
codans pane read <uuid>                                  # read its viewport
codans pane capture <uuid> --lines 200 > /tmp/log.txt    # snapshot trailing output
```

If both panes share a tab, label the target once (`codans pane label <uuid> agent`)
and refer to it as `@agent` thereafter.

### Drive a REPL from a script

```bash
codans pane new --label repl -- python3
codans pane send -p @repl 'import math'
codans pane send -p @repl 'print(math.pi)'
codans pane capture -p @repl --lines 3
```

### Spin up a worktree and a tab for it

```bash
codans worktree new exp/feature-x
# Switch to the new worktree (its UUID is in the create output, or use jq):
codans worktree switch "$(codans tree --json | jq -r '.projects[0].worktrees[-1].id')"
codans tab new "dev"
codans pane new -- npm run dev
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

Every command supports `--json`. Pipe through `jq` to extract IDs without
parsing the human format:

```bash
PANE=$(codans pane list --json | jq -r '.panes[0].id')
codans pane send "$PANE" 'echo hello from script'
```

### Verify before you act

`codans pane send` is fire-and-forget — the RPC reports bytes shipped, not the
receiving program's reaction. When coordinating agents across panes, read
back after sending:

```bash
codans pane send -p @worker 'run-task'
sleep 1
codans pane read -p @worker | tail -20
```

(This mirrors the project memory note "prowl send 后 read-back 验证" — the
same idea applies to `codans`.)

## Troubleshooting

| Symptom                                             | Likely cause / fix                                                        |
|-----------------------------------------------------|---------------------------------------------------------------------------|
| `socket /tmp/codans-*.sock did not become reachable` | App isn't running. Run `codans launch` or open codans from the GUI.       |
| `noContext(kind: .pane)` (or project/worktree/tab)  | You used `current` / `.` outside a codans Pane. Pass an explicit ID.  |
| `pane <uuid> not found`                             | The pane was closed, or the UUID came from a different app instance.     |
| `unknown key "..."`                                 | `codans pane send-key` only knows the keys listed above. Use `--raw` for the rest. |
| `--raw is exclusive of ...`                         | `codans pane send --raw` cannot combine with positional text, `--stdin`, or `--no-enter`. |
| Help shows fewer commands than expected             | Some legacy docs reference unimplemented commands (e.g. `codans open`, `codans skill`, `codans agent`). Trust `codans --help` over external docs. |

## What this CLI does *not* do (yet)

To prevent suggesting commands that don't exist:

- No `codans send` / `codans read` / `codans send-key` / `codans capture` at top level —
  they live under `codans pane`.
- No `codans open` (external editor handoff).
- No `codans skill ...` (skill installation lives outside the CLI).
- No `codans agent ...` (agent hook installation lives outside the CLI).
- No `codans space ...` — codans does not expose a Space concept via `codans`
  today; the hierarchy is rooted at Project.

If a user asks for any of these, surface the gap rather than fabricating a
command.
