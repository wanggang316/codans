# Agent Profiles and Handoff

A user of codans runs several coding agents (Claude Code, Codex, Gemini CLI, and others) side by side. Each agent is a separate process, and no agent can see the session of another. This domain gives the user two tools. An **Agent Profile** is a named launch preset, so that one choice starts an agent with the correct model, mode, and environment. A **Handoff** passes a task from one agent to another through files in the Worktree, because those files are the only context that both agents can read.

codans never starts a hidden model call. It does not write a briefing for an agent and it does not continue or fork the session of an agent.

## Scope and ownership

This page owns the profile model and its storage, the launch pipeline, the New Agent dialog, the command line of a profile, the handoff artifacts in the Worktree, the transition sequence, the kickoff text, and the Hand Off panel.

Neighbor topics:

- How a Pane is identified as an agent, and the runtime state of an agent: [Agent state](agent-state.md).
- The built-in `handoff` workflow and `launch` roles: [Workflow](workflow.md).
- The syntax of `codans agent` and `codans handoff`, addressing, and exit codes: [CLI](cli.md).
- Skill completion in the prompt of the New Agent dialog: [Agent skill completion](agent-skill-completion.md).
- The window toolbar that holds the New Agent button: [Main window](main-window.md).
- The single-writer `settings.json`: [Settings](settings.md).

## Agent Profiles

### Model and storage

A profile has an agent kind, a name, an enabled flag, an optional SF Symbol, optional model, reasoning effort, and execution mode, a placement (new Tab, split with a direction, or the focused Pane), extra arguments, environment variables, and a dedicated-home flag.

The static facts of each agent come from `AgentCatalog`: the executable name, the models, efforts, and modes the CLI accepts, and its **prompt style**, the argument form that gives the CLI an initial prompt in interactive mode. Some agents have no prompt style.

Rules:

- **An empty override means "Runtime default".** codans then writes no flag, and the agent CLI decides. An override that the agent does not offer (the agent kind changed, or a hand edit) is ignored at render time, so codans never writes a flag that the CLI rejects.
- **The editor shows only the options the catalog can spell.** Anything else goes in Extra Arguments.
- **Profiles live in `settings.json` under `agents.profiles`**, not in the catalog, because a profile is a user preference. If the `agents` key is absent, codans seeds one profile for each built-in agent with a fixed id derived from the agent kind, so a re-seed keeps the same ids. An empty `profiles` list is a real choice and stays empty.
- **A profile of an agent kind that this build does not know is skipped when the file is read.** Builds of different versions share `settings.json`, and one unknown entry must not make the whole file unreadable.
- **Disabled profiles stay configured but are not offered.** `codans agent launch` refuses a disabled profile with `conflict`.

### From profile to command line

`AgentLaunchCommand` renders a profile into the exact line that codans types into the Pane. The Launch Preview in Settings → Agents uses the same renderer, so the preview is the command, character for character:

```
[env KEY='value' … HOME='…'] <executable> [model] [effort] [mode] [extra arguments] [prompt]
```

- **Variables use an `env` prefix, not the Pane environment.** They reach only the agent process. When the agent exits, the shell in the Pane has the user's normal environment again, and an agent the user starts by hand in that Pane does not get the profile's account.
- **A dedicated home** sets `HOME` to `agent-homes/<profile id>/` under the state root (see [Environment](environment.md)). `HOME` comes last, so it wins over a `HOME` in the profile variables. The first launch is where the user logs in. codans does not read or copy credentials.
- **Extra arguments are a raw shell fragment.** codans appends them without quoting and does not interpret them.
- **The prompt is last and uses the prompt style.** For an agent with no prompt style, the renderer drops the prompt.

Security: profile variables are plain text in `settings.json`, and the Launch Preview shows their values. Do not put secrets in a profile.

### One launch pipeline

Every entry point resolves a profile **value** and gives it to one launch function in the hierarchy client:

```
New Agent dialog ───────────────┐
command palette ────────────────┤
codans agent launch ────────────┤
codans worktree create --agent ─┼─► AgentLaunchSpec ─► render ─► synthetic ScriptDefinition
workflow launch role ───────────┤   (profile value)               ─► script dispatcher
handoff receiver ───────────────┘                                    (new Tab / split / focused Pane)
```

- The spec carries the profile itself, not an id. This lets a handoff or a workflow launch a profile that is not saved: a bare preset for an agent with no enabled profile, or a profile with workflow variables merged in.
- The launch reuses the script dispatcher, with one difference: it does not track a run Pane. An agent is a session, not a job, so a second launch of the same profile opens a second session. It never types into the first one.
- The spec can override the placement of the profile, and can name an anchor Pane for a split.
- The tab-bar Agents menu has a launch action, but no view sends it: Hidden.

Selection by name or agent (`codans agent launch`, `handoff to --profile`): an id or a display name selects that profile, and an ambiguous name is an error. An agent token alone selects the first enabled profile of that agent, else a transient bare preset. With nothing, the first enabled profile is used.

### The New Agent dialog

The New Agent dialog starts a Worktree and an agent in one step. It opens from File ▸ New Agent… (⌘⇧N, enabled also without a Project), the New Agent button in the window toolbar, and the command palette. It collects four things:

- **A Project.** It starts on the selected Project. With no Project, it offers the Add Project flows instead.
- **A target** in a git Project: a new Worktree, or a branch. A branch that a Worktree holds sends the agent to that Worktree. Any other local branch, or a remote-tracking ref, is checked out into a new Worktree first. A branch of an archived Worktree is not offered, because the sidebar hides that Worktree. A folder or Workspace Project has one Worktree and no target choice.
- **A profile** from the offered profiles (see below). Manage Agents opens Settings → Agents.
- **A prompt**, optional, with attached file paths. A blank prompt means none.

The new-Worktree part is the Create Worktree form itself, embedded, so the dialog has the same defaults, validation, and branch-collision rules as the Create Worktree sheet (see [Worktree](worktree.md)). The dialog does no work itself. On send it closes and the root feature either launches the profile in the existing Worktree, or starts a pending Worktree creation that launches the agent when the Worktree exists. Both use the launch pipeline above, with the placement of the profile, and park the Worktree so that its first Tab goes to the agent.

The **draft** keeps what the user set in a dialog closed without sending: Project, target, branch name and Worktree options, profile, and prompt. The next open restores it. It is in memory only, for the app session, and a send clears it.

### When the agent CLI is not installed

`AgentInstallationStore` asks the user's interactive login shell `command -v` for every known agent, in one spawn. The result is advisory. The shell of the probe and the shell of a Pane can differ, so a false "missing" must never block a launch:

- Settings → Agents shows a warning on the profile and dims its row.
- The New Agent dialog and the Hand Off panel hide profiles whose CLI is missing. Before the first scan, and when the filter would hide every profile, they show all enabled profiles.
- The command palette and the CLI do not filter. A launch of a missing CLI types the command, and the Pane shell reports `command not found`.

## Handoff

### Artifacts in the Worktree

The Worktree is the only channel. The receiver must read the files from its own working directory, and the files have the life of the Worktree:

```
<worktree>/.codans/
  .gitignore                          "*": the directory ignores itself
  handoff/
    current.md                        briefing by the source agent (absent if none)
    context.md                        generated by codans; rewritten on each save
    log.md                            append-only history, one line per event
    archive/<ts>-<from>-to-<to>.md    previous round, briefing + context, per transition
    archive/<ts>-replaced-current.md  briefing replaced by a checkpoint
    sessions/<ts>-<pane>.md           screen excerpt, session id, reattach command
```

Who writes what:

- **The source agent writes the briefing.** It sends a Markdown document with the sections `## Objective`, `## Current State`, and `## Next Steps` (the skeleton recommends more). codans removes only chat wrapping (fences, lead-in, closing talk) and keeps the body byte for byte.
- **codans writes everything else.** `context.md` holds the branch, the changed files, the diff size, and a pointer to the session excerpt. The app collects the git facts and passes them in as values; the handoff store runs no subprocess.

Invariants:

- **Archive first.** Before any rewrite of `current.md`, its content is in `archive/`.
- **`current.md` exists only if a validated briefing made it.** A transition without a briefing deletes the old `current.md` and points the receiver at `context.md` and `archive/`. A briefing from an earlier round must never pose as the current one.
- **A checkpoint (`handoff save`) never deletes a briefing.** With no receiver, the last valid briefing stays valid.
- **Briefing is explicit.** The caller gives a briefing (`--brief -`, from stdin) or declines it (`--no-brief`). A missing choice or an invalid briefing is refused before any file changes, and the error carries a heredoc command to copy.
- **Handoff only reads git.** It never commits or pushes.

### The transition

All entry points run one sequence. `HandoffHandlers` drives it, and `HandoffCoordinator` owns every file write and the log format, so the CLI and the panel cannot drift:

```
validate briefing → resolve receiver profile → claim request id (panel requests only)
  → archive current round → write or remove current.md → write session excerpt
  → rewrite context.md → launch receiver (unless --no-launch) → append log line
```

The receiver starts in the same Worktree in the background, without focus. The placement is a new Tab (default) or a split of the **source** Pane, never the focused Pane, because the receiver must not type over the agent it replaces. The saved placement of the profile does not apply. If the launch fails, the files are already written; the log line records `launch=failed` with the archive path.

The source is the calling Pane (see [CLI](cli.md) for how the server finds it), or the Pane given with `--pane`. The source agent is the live entry in the agent state store, else the agent bound to the Pane in the catalog, so a restored Pane still names its agent. A receiver token can be the raw value, the executable name, or the display name (`claude` = `claude-code`).

### The kickoff line

The receiver starts with one of two fixed prompts. With a fresh briefing, it reads `current.md` and `context.md` and continues from Next Steps. Without one, it orients from `context.md` and the archive. Both ask the receiver to ask before any commit, push, or destructive git operation.

An agent with a prompt style gets the kickoff on its command line. For other agents, the app waits until the agent state store identifies the agent in the new Pane, waits for the screen to settle, types the prompt, and sends Return only if the end of the text (or a "Pasted" chip) is on screen. These are screen heuristics: if the agent opens on a dialog, nothing is submitted and the miss is only logged.

### Two ways to hand off from the app

The Hand Off panel opens from the Pane actions menu, the context menu of a row in the Agents View, and the command palette ("Hand Off…", for the focused Pane of the selected Worktree). It refuses with a status message when the Pane has no detected agent, and for a Worktree of a [Remote Project](remote-projects.md); the server also refuses a remote source with `unsupported`, because the artifacts would be on the remote host.

The panel lists the offered profiles and an "Only save progress" row, and a New Tab / Split choice that it remembers. It does no work. On confirm it closes, and the root feature runs the order in the background:

- **Hand Off with Brief** (Save Progress on the checkpoint row). The app registers a one-shot request id for the source Pane and types one line into the source agent's input: `[codans] Please hand this task off to <Agent>: run \`CODANS_HANDOFF_REQUEST_ID=<id> <cli> handoff to <agent> --pane <id> [--split <dir>] --brief -\` with your briefing on stdin …`. The agent writes the briefing and runs the command. When the completion with that id arrives, the app shows a toast and goes to the receiver. The line names the source Pane explicitly and carries the placement as flags, so the CLI needs no second channel.
- **Hand Off with Context**. The app runs a context-only transition in process, through the same handler as the CLI, without asking the agent.

The request id may run once, and only from its source Pane. A wrong Pane or a used or superseded id is refused before any change. If the source Pane cannot take the typed line, the app supersedes the request and tells the user to use Hand Off with Context. It does not fall back to context-only by itself.

The line spells the CLI with `CLIInvocation.command`, so a Debug app asks for `codans-dev` and is not answered by the installed Release app. See [Environment](environment.md) and [CLI](cli.md).

## Traps

- **The typed request depends on the agent.** The agent must treat the line as an instruction. A busy agent queues it, and its permission prompt can stop it; the user approves in the agent's Pane. Nothing in the app waits visibly. If the user does not want to wait, Hand Off with Context is the choice.
- **A sandboxed caller cannot reach the socket.** The CLI then reports a permission error and the request did not reach the app.
- **Prompt styles follow the CLI versions.** When an agent CLI changes its flags, update `AgentCatalog`.
- **A prompt for an agent without a prompt style.** `codans agent launch --prompt` refuses it with `unsupported`. The New Agent dialog and the palette launch it, but the renderer drops the prompt. Only a handoff types it.
- **Every `log.md` line from the handler says `source=cli`**, also for Hand Off with Context from the panel.

## Implementation shape

`CodansCore/Agents/` holds the profile, the agent catalog, and the command renderer; `CodansCore/Handoff/` holds the artifact layout, briefing validation, the store, the coordinator, the kickoff text, and the placement. Both are pure: no subprocess, no Pane. `CodansIPC` defines `agent.*` and `handoff.*`. In the app, `AgentHandlers` and `HandoffHandlers` connect the IPC calls to the runtime: settings, the agent state store, screen reads, git, and `HierarchyClient.launchAgent`. The Hand Off panel (`App/Features/Handoff/`) and the root feature use the same `HandoffHandlers` instance as the CLI, and `HandoffRequestRegistry` carries the one-shot ids and the completions.
