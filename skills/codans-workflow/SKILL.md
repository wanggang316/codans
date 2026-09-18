---
name: codans-workflow
description: Author, validate, run, and take part in codans Agent Workflows — the `<id>.workflow.yaml` files that orchestrate several live coding agents (launch an agent from a profile, message one, wait for an explicit delivery, loop on a verdict, run shell commands) inside the running codans app. Use it when the user wants a workflow written or edited ("write a codans workflow where two agents review each other"), wants one run ("run the review-loop workflow", "跑一下 advisor"), asks about a run's progress or its result files, or when a `[codans] …` line ending in `codans workflow deliver …` appears in this pane — that means this agent is a participant in a run and must deliver through the workflow protocol. Not for driving single panes by hand (use the `codans` skill).
---

# codans Agent Workflows

A workflow is one YAML file, `<id>.workflow.yaml`, in GitHub-Actions-flavoured syntax. It
declares **roles** (which agent plays whom), **steps** (launch / message / run / wait /
notify / close / set / while), typed **inputs** and mutable **state**, and codans executes it
against one worktree using real terminal panes. The file name is the workflow id.

Where files live (later scopes shadow earlier ones by id):

| Scope | Path | Notes |
|---|---|---|
| bundle | inside the app | built-ins: `review-loop`, `handoff`, `advisor` |
| user | `~/.codans/workflows/<id>.workflow.yaml` | yours |
| repo | `<repo root>/.codans/workflows/<id>.workflow.yaml` | committed with the branch; a file with `run:` steps must be trusted once in the app before it can start |

## Running

```bash
codans workflow list [--json]                      # what this worktree can see, with validation status
codans workflow run <id> [source] [--role r=<profile|auto|pN>]… [--input k=v]… [--skip <step>]… [--json]
codans workflow status [run-id] [--json]           # no argument inside a run: who am I, what is awaited
codans workflow resolve <run-id> <action> [--verdict v]   # accept | accept-with-verdict | ask-again | keep-waiting | skip | cancel | relaunch | retry
codans workflow cancel <run-id>
codans workflow runs [--json]                      # history for this worktree
codans workflow validate <file>                    # offline, no app needed
```

- `[source]` is a pane / tab / worktree reference. Omitted inside a pane: that pane plays the
  `current` role and its worktree is the run's. A workflow with a `current` role cannot start
  outside a pane (`SOURCE_REQUIRED`).
- `launch` roles resolve to an Agent Profile: `--role reviewer=<profile name|uuid>` overrides;
  otherwise the remembered binding, then the file's `profile:` hint, then the only enabled
  profile that qualifies; the CLI never asks — an unresolved role is `PROFILE_REQUIRED`.
  `pick` roles need `--role r=p<n>` (an existing agent pane in the same worktree).
- Required inputs without defaults need `--input name=value` (`INPUT_REQUIRED`).
- The run is asynchronous: `run` returns the run id and frozen bindings. Poll
  `codans workflow status <run-id> --json` (`.data.run.state` is `running`, `needs_attention`,
  or terminal: `completed` / `cancelled` / `skipped` / `iteration_limit_reached` / `failed` /
  `interrupted`). Artifacts are under `<worktree>/.codans/workflow-runs/<run-id>/` — `log.md`
  is the timeline, `deliveries/<name>.md` the latest delivery of each name.
- **Self-initiated runs.** When you start a workflow from the pane that becomes its `current`
  role and the first step messages that role, the `run` response carries `selfInitiated`
  (`.data.selfInitiated` with `--json`): the task text (or an instruction file) and the exact
  completion command. Do that task yourself and deliver — codans does not type it back into
  your own pane, and waiting for a message would leave your own step unfinished.
- Finishing never closes launched panes; only a `close:` step does. Cancelling stops the
  orchestration, not the agents' work.

## Participating

A message typed into this pane by codans looks like:

```
[codans] <instruction…> — finish with: CODANS_WORKFLOW_TOKEN=<token> codans workflow deliver [--verdict a|b] -
```

or points at an instruction file (`[codans] Read and follow <path> — finish with: …`). A
launched participant finds the same protocol at the end of its kickoff prompt, with the
token already in its environment.

1. Do the work the instruction asks for, completely, before delivering.
2. Deliver by running the **exact command you were given**, body on stdin as markdown:
   ```bash
   CODANS_WORKFLOW_TOKEN=… codans workflow deliver --verdict issues - <<'EOF'
   ## Findings
   - src/foo.swift:42 — …
   EOF
   ```
   When verdict variants are offered, pick exactly one.
3. Include the declared sections and verdict. An empty body is rejected; other contract
   mismatches make the delivery **provisional** — the command still succeeds, but the run waits
   for the user to accept, ask you again, or skip. Do not resubmit on your own.
4. Lost? `codans workflow status` (no arguments) answers "who am I": this pane's run, role,
   awaited step, and completion command.
5. Never report a step as done through `codans pane send` or plain chat; only `deliver`
   completes it.

## Authoring

Minimal file:

```yaml
name: Summarize
description: Ask the current agent for a summary of its changes.
roles:
  author: {source: current}
steps:
  - message: author
    instruction: Inspect the uncommitted changes and write a concise summary under "## Summary".
    expect: {delivery: summary, sections: ["## Summary"]}
  - notify: Summary saved to ${{ deliveries.summary.path }}
```

### Roles

```yaml
roles:
  author:   {source: current}                  # the pane the run starts from; at most one
  reviewer:                                    # codans launches it from an Agent Profile
    source: launch
    agents: [claude-code, codex]               # optional allow-list; omit unless the task truly needs it
    profile: Reviewer                          # optional preferred profile name (a remembered binding wins)
    placement: split                           # split | tab
    direction: right                           # right | left | up | down
    background: true                           # do not steal focus
  partner:  {source: pick}                     # an existing agent pane, chosen at start
```

### Steps

Each step has an optional `name`, optional `id` (needed to reference `steps.<id>`), optional
`if:` guard, and exactly one verb:

| Verb | Keys |
|---|---|
| `message: <role>` | `text` (one line) **or** `instruction` (multi-line, delivered as a file); optional `expect`. Waits until the role is idle before typing. |
| `launch: <role>` | `prompt`; optional `expect`. Once per launch role, never inside a loop. |
| `run: <command>` | `working-directory`, `env`, `timeout-minutes` (10), `continue-on-error`, `in: <role>` (type into that pane instead of running headless). Outputs: `steps.<id>.outputs.exit-code` / `stdout` / `stdout-path`. |
| `wait: <role>` | `until: idle \| blocked \| exit`, `timeout-minutes`. Cheap "wait until idle" — it measures the agent's turn, not its task. |
| `notify: <text>` | Notification in the app inbox. |
| `close: <role>` | Closes a launched role's pane. Only when the task needs cleanup. |
| `set: {name: value}` | Assign declared `state` (all values evaluated against the old state). |
| `while: <expr>` + `steps:` + `max-iterations` | Loop; `break: true` / `continue: true` inside. Hitting the cap ends the run as `iteration_limit_reached`. |

Without `expect`, `message` / `launch` are fire-and-forget: the run advances as soon as the
text is typed or the agent is launched. Use `expect` whenever a later step depends on the
agent's work.

### `expect`

```yaml
expect:
  delivery: review            # name; default = step id; the latest delivery of a name wins
  format: markdown            # markdown | text | json
  sections: ["## Findings"]   # required headings (case / level forgiving; fenced code ignored)
  verdicts: [clean, issues]   # 2–4 slugs; makes --verdict mandatory
  timeout-minutes: 30         # hard cap; no default — omit to wait as long as the agent works
  on-timeout: attention       # attention | skip | cancel
  strict: false               # true rejects a delivery missing sections / verdict instead of holding it
```

codans appends the completion command itself. **Never write `codans workflow deliver` into your
own `text` / `instruction` / `prompt`** (the validator warns).

### Expressions

`${{ … }}` anywhere in a string; `if:` / `while:` take a bare expression. Names may contain `-`
(`inputs.max-rounds`), so binary minus needs spaces: `a - b`. Operators: `! == != < <= > >= && ||
?? + -`; functions `exists(x)`, `length(x)`, `contains(s, t)`, `startsWith(s, p)`, `endsWith(s,
p)`. A missing name is an error — use `exists()` or `??` for optional data. Namespaces:

| Namespace | Members |
|---|---|
| `inputs.<name>` | typed start-time inputs |
| `state.<name>` | declared mutable state (type fixed by its initial literal) |
| `deliveries.<name>` | `path`, `verdict` |
| `steps.<id>` | `outcome` (`success` / `failure` / `skipped`), `outputs.*` |
| `roles.<role>` | `pane-id`, `agent`, `name`, `state` |
| `workflow` / `run` / `worktree` | `id`, `name` / `id`, `path` / `id`, `path`, `name`, `branch` |
| `loop.iteration` | current iteration inside `while` (null outside) |
| `codans.cli` | how to spell this build's CLI inside `run:` |

Inputs: `type: string | number | boolean | choice` (`options`), `default`, `required`,
`description`, `min` / `max` for numbers.

Validate with `codans workflow validate <file>` and fix every error; read the warnings. Passing
validation does not guarantee admission: profiles, panes, inputs and trust are checked at start.

### Patterns

- **Review loop**: launch the reviewer once with `expect` + `verdicts`; `while state.verdict ==
  'issues' && state.round < inputs.max-rounds`; inside, `message` the author with the review
  path, `message` the reviewer for a fresh delivery, `set` the verdict from
  `deliveries.review.verdict`. Do not rely on an implicit "last delivery" — copy what the loop
  needs into `state`.
- **Second opinion**: `launch` an advisor with `expect`, then `message` the `current` role with
  the delivery path (fire-and-forget) so the asking agent continues on its own.
- Keep prompts about *what* to deliver ("finish with a `## Findings` section"), never about the
  mechanics — the completion command is appended for you.
