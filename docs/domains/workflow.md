# Workflow

A workflow is a multi-agent sequence that a YAML file declares and codans runs. A typical one launches a reviewer beside the author, gives it the diff, reads its verdict, asks the author to fix, and repeats until the review is clean. Without workflows, such a loop exists only as typed CLI commands or a bash loop that an agent improvises: it cannot be shared, shows no progress, and has no place to stop and ask the user. A workflow adds three things to the existing primitives: a declaration that can be shared, visible progress, and a point where the user can step in.

Availability: Beta. A run starts from the Command Palette (`Run Workflow: <name>`), the "Run Workflow" submenu of an Agents View row, the Run button of a workflow in Settings → Workflows, and `codans workflow run`. Hidden: the toolbar workflow group and the Workflow Runs panel that it opens. A master switch in Settings → Workflows (on by default) turns the feature off: every `workflow.*` IPC method then answers `unsupported` and the GUI entry points disappear.

## Scope and ownership

This page owns the definition model, discovery and trust, admission, the run state machine, delivery, and the run directory. Neighbor topics:

- `codans workflow` verbs, flags, and error envelopes: [CLI](cli.md) and the `codans-workflow` Agent Skill.
- The Agents View panel, its rows, and agent runtime state: [Agent state](agent-state.md).
- Agent Profiles, the launch pipeline, and `codans handoff`: [Agent profiles and handoff](agent-profiles-and-handoff.md). The built-in `handoff` workflow is part of this page.
- The Settings window: [Settings](settings.md). The inbox: [Notifications](notifications.md).

## Concepts

- **Definition**: one file `<id>.workflow.yaml`. The file name is the id; `name` is the display name. It declares `inputs`, `roles`, mutable `state`, and `steps`.
- **Role**: an abstract participant ("an agent that can review code"). The file never names a machine, a pane, or a profile that must exist. The binding of a role to a pane happens at start.
- **Step**: a mapping with exactly one verb, an optional `id`, `name`, and `if:` guard. A step whose guard is false is `skipped`.
- **Run**: one execution of a definition in one Worktree. It holds the frozen definition, the role bindings, the inputs, the state, the step outcomes, and the deliveries.
- **Activation**: one wait for a delivery, opened when a step with `expect` starts. It has an ordinal that is unique in the run, a role, a pane, and a random token.
- **Delivery**: the body that a participant hands back with `codans workflow deliver`, with an optional verdict.

The document follows GitHub Actions spelling, because users and agents already know it: `${{ }}` expressions in string values, `if:` guards, `run:` with `working-directory`, `timeout-minutes`, and `continue-on-error`, the shape of `inputs`, and kebab-case keys. It adds only roles, explicit delivery (`expect`), and loops with state (`while:` with `max-iterations`, `set:`, `break`, `continue`). When a new key or shape is in doubt, follow the GitHub Actions form.

### Roles and binding

| `source` | Binds to | Rule |
|---|---|---|
| `current` | The pane that starts the run | At most one per definition. It must hold a recognized agent only if a step that is not skipped sends it a `message`. |
| `pick` | A recognized agent pane in the same Worktree | Chosen at start, in the start panel or with `--role`. |
| `launch` | A new agent that codans starts from a profile | Launched at most once per run, and never inside a loop body. |

A `launch` role resolves its profile in this order: an explicit choice, the binding remembered on this machine, the `profile:` name in the definition, the only enabled profile that qualifies. If none decides, the CLI fails with `PROFILE_REQUIRED` and the start panel leaves the picker empty. The profile is frozen into the run at admission; a later edit of the profile does not change a live run. Remembered bindings live in `settings.json` under `workflows.bindings`, keyed by a digest of the role's requirement block (`source`, `agents`, `profile`): a change to the requirement drops the memory, a change to a prompt keeps it.

**A pane belongs to at most one run.** Admission refuses a `current` or `pick` pane that another run holds (`PANE_BUSY`).

### Verbs

`message` types a line into a role's pane. `launch` starts a `launch` role with a prompt. `run` executes a shell command headless through `CommandRunner` in the Worktree root, and records `exit-code`, `stdout`, and `stdout-path` as step outputs. `wait` waits until a role is `idle`, `blocked`, or exited. `notify` posts to the inbox. `close` closes a launched role's pane. `set` assigns state; all its expressions read the same old state. `while` loops over a body.

A `message` or `launch` without `expect` completes as soon as the line is typed or the agent starts. A workflow is deterministic up to the prompt boundary and no further.

A long `instruction` is written to a file in the run directory, and the pane receives one line that points to it. Agents exchange file paths, not contents: `${{ deliveries.<name>.path }}` is an absolute path inside the Worktree, so an agent reads it from its own working directory.

### Expressions

The expression language is small on purpose: literals, field access, comparison, `&&`, `||`, `!`, `??`, integer `+` and `-`, and `exists`, `length`, `contains`, `startsWith`, `endsWith`. A reference to a missing value is an error; `exists()` and `??` are the only fallbacks. There is no implicit type conversion, and `if` and `while` must give a boolean. A value that is one whole `${{ }}` keeps its type. Every new operator is a long-term cost in the parser, the validator, and the docs.

## Definitions: discovery, validation, trust

Three scopes, each later scope shadowing an earlier one by id:

```
app bundle  Resources/workflows/   built-in: review-loop, handoff, advisor
user        ~/.codans/workflows/   (CODANS_WORKFLOWS_DIR overrides it)
repository  <worktree>/.codans/workflows/
```

The built-in files live in the top-level `workflows/` directory of this repository and are copied into the bundle at build time. The repository scope is read from each Worktree root, so each Worktree sees the definitions of its own branch. The app watches the user directory and the `.codans/workflows` of each local Worktree, so a file that an agent writes or an editor saves appears and revalidates without a refresh.

Validation has two stages: the parser reports structure errors (unknown key, wrong type, missing field, more than one verb), and the validator checks cross-references (undefined role, duplicate step id, a `launch` twice or in a loop, a reference with no producer). Each diagnostic has a stable code and a path such as `steps[2].expect.verdicts`. A file with errors is listed but cannot start. `codans workflow validate` runs without the app.

**Trust.** A repository-scope file that contains a `run:` step must be trusted before it starts; otherwise admission fails with `WORKFLOW_TRUST_REQUIRED`. Cloning a repository must not mean consent to run its shell commands. A grant binds the file path and the SHA-256 of its bytes and is stored in `settings.json` under `workflows.trusted`; any edit to the file needs a new grant. Only the app grants trust, in the start panel or in Settings → Workflows; the CLI cannot. Bundle and user files, and repository files without `run:`, need no trust. No workflow ever starts by itself.

**`.codans/.gitignore`.** In a repository without definitions, `.codans/` stays invisible to git (`*`). When a repository-scope workflow is created, or a run starts while `.codans/workflows/` exists, the app writes the anchored permitting form `/*`, `!/.gitignore`, `!/workflows/`, so definitions can be committed while run artifacts stay ignored. The patterns must stay anchored: an unanchored `*` also matches every file inside `workflows/`. The app replaces only content that it wrote itself.

## Admission

Every start goes through one `WorkflowAdmission`, for the CLI and for the GUI start panel alike. It touches no pane. It resolves, in order, and fails with a stable code at the first gap: the source Worktree (from the caller pane, or a named pane or Worktree; `SOURCE_REQUIRED`), the definition (`WORKFLOW_NOT_FOUND`, `WORKFLOW_INVALID`, `WORKFLOW_DISABLED`), the trust, the typed inputs, the steps to skip, and the role bindings. A Worktree of a Remote Project is refused, because the run directory must be on the local disk.

The start panel (`WorkflowStartOverlayView`) collects role choices, inputs, and skips, then calls the same admission. It holds only the draft, never run state. A step can be skipped at start only if every step that needs its delivery is skipped too.

**Self-initiated run.** If the caller pane is the `current` role and the first step sends that role a `message`, the response returns the rendered instruction and completion command, and the engine does not type them into the caller pane. An agent can hand itself off in two commands: `codans workflow run handoff`, then the returned `deliver` command.

## Run state

```
              ┌──────────────── user action resolves ───────────┐
              ▼                                                  │
 admit ──► running ──── needs input from the user ────► needs_attention
              │                                                  │
              │ steps end, or a terminal outcome                 │ cancel, or a skip
              ▼                                                  ▼     with a dependent
   completed | cancelled | skipped(step, dependent) | iteration_limit_reached
             | failed(step) | interrupted
```

`needs_attention` is not a failure. The run stops and waits for the user, and keeps all its state. Each attention carries a reason and the exact list of actions it allows; the GUI and `codans workflow resolve` render that list as it is and derive no policy. The machine accepts only an action that the current attention offers, plus `cancel` at any time.

| Reason | Typical actions |
|---|---|
| Provisional delivery (missing section or verdict) | Accept, Accept with verdict, Ask again, Skip, Cancel |
| Role `blocked` on a prompt | Focus pane, Keep waiting, Skip, Cancel |
| Role pane or agent gone | Relaunch (`launch` roles only), Skip, Cancel |
| Idle without delivery, after one nudge | Keep waiting, Ask again, Skip, Cancel |
| Delivery or wait timeout | Keep waiting, Skip, Cancel |
| Launch failed | Relaunch, Cancel |
| Typing into the pane or a `run:` command failed | Retry, Skip, Cancel |

**Skip** computes its result at once: if a later step needs the skipped delivery without `exists()` or `??`, the run ends as `skipped(step, dependent)` instead of failing later on a missing reference. **Cancel** revokes the activation and ends the run. It closes no pane, stops no agent work, and undoes no side effect.

### Waiting on agents

The engine reads each role's agent runtime state from `AgentStateStore`. Rules:

- **Never type into a `working` pane.** A `message` waits until the role holds `idle` for a short stable period, so that a line does not land between two tool calls.
- `blocked` that holds for a while becomes an attention. codans never answers a permission prompt and never sends Ctrl-C.
- While a delivery is open, the watchdog uses role state, not wall time. When the role goes from `working` to `idle` and stays idle for the idle grace period without a delivery, codans types the completion command once more (a nudge, same token), then raises an attention after a second grace period. A role that stays `working` is never interrupted; only `expect.timeout-minutes` does that, and it has no default.
- If the agent of a role exits while the pane stays open, or a launched role never gets an agent within its startup grace, the role counts as gone.
- `wait: until: idle` measures a turn, not a task: an agent that moved work to the background looks idle. Use `expect` when the result matters.

## Delivery

Explicit delivery is how a participant says "done, the result is here". Guessing completion from the screen fails for agents that work in the background.

A step with `expect` opens an activation. codans appends the completion command, `CODANS_WORKFLOW_TOKEN=<token> codans workflow deliver [--verdict a|b] -`, to the typed line or the launch prompt; a launched agent also gets the token in its environment. Authors never write this command in the definition, and the validator warns if they do.

`deliver` finds the activation by token, else by the caller pane. **The token correlates; it does not authenticate.** Its job is to reject a delivery that arrives late, twice, or for the wrong step: Ask again keeps the token, but Skip, Cancel, and Relaunch revoke it, and a late delivery with an old token gets `TOKEN_INVALID` instead of landing on a newer step. A delivery from a pane other than the waiting one fails with `ROLE_MISMATCH` unless `--force`. Without a caller pane, `--run` and `--step` name the step (a manual delivery).

The body is checked against `expect`: an empty body or one larger than the IPC frame cap is rejected. Missing `sections` or a missing verdict makes the delivery **provisional** by default, and the run goes to `needs_attention` for the user to decide. One badly formatted answer must not discard a long review. `strict: true` rejects instead. The body is written to `deliveries/<name>.<ordinal>.md`, and then `deliveries/<name>.md` is replaced atomically; the activation completes only after the write succeeds. Several steps can deliver under one name; the latest wins.

## The run directory

```
<worktree>/.codans/workflow-runs/
  index.json                      runs of this Worktree: id, workflow, state, times
  <run-id>/
    run.json                      status, bindings, inputs, state, steps, deliveries
    log.md                        append-only timeline
    definition.workflow.yaml      the definition as it was at start
    instructions/  deliveries/  steps/
```

Runs live in the Worktree, not in `~/.codans/`, so a participant reads a delivery path from its own working directory with no scoped read command. The cost is accepted: removing the Worktree removes its run history. Each Worktree keeps the 20 most recent terminal runs; an index entry marked `keep` is never pruned.

- `run.json` follows the persistence invariants of [Architecture](../architecture.md): top-level `version`, atomic rename, snake_case keys, ISO-8601 dates.
- **Tokens, environment values, rendered launch commands, and credentials are never written to disk.**
- Every write checks that the path stays inside the run directory, and a run directory that is a symlink is refused, so a hostile Worktree cannot redirect writes.
- A run uses the definition frozen at start; later edits to the source file do not affect it.
- Runs do not survive an app restart. A record on disk that is not terminal and has no live engine reads as `interrupted`. It is for inspection only and does not resume.

## Where runs show

- The Agents View lists active runs as a "Workflows" group. A click opens a popover with the steps, the role panes, the attention actions, and links to the log and the run directory.
- The inbox receives a notification when a run needs attention, when it ends, and for each `notify` step, titled `Workflow · <name>`.
- The Command Palette offers `Cancel Workflow: <name>` for each active run.
- Settings → Workflows lists every scope, with enable switches, diagnostics, remembered bindings, trust, and a detail page with Run.

## Traps

- **A `message` never lands.** The role does not stay idle long enough, often because the agent state classifier misreads a new agent UI. The run waits for the role with no attention; check the agent runtime state of the pane.
- **An early nudge.** An agent that works in the background looks idle and gets the completion command. The nudge text says "when your work is complete", never "now".
- **A loop with no effects.** A `while` body that only sets state and has no `max-iterations` fails the run, because nothing outside could ever end it.
- **A shadowed file.** A repository file with the same id hides the user or built-in file for that Worktree only, so the same id can run different definitions in two Worktrees.

## Shape of the implementation

```
 CLI / Command Palette / start panel ──► WorkflowHandlers ──► WorkflowAdmission
                                                                 │ configuration
 deliver ──► WorkflowHandlers ──► WorkflowActivationRegistry     ▼
                                   (token / pane ──► run)   WorkflowEngine (@Observable)
                                                                 │ events ▲ effects
                                                           WorkflowMachine (CodansCore, pure)
 effects ──► AgentStateStore, terminal input, profile launch, CommandRunner, inbox, WorkflowRunStore
```

`CodansCore/Workflow/` holds the pure parts: definitions, parser, validator, expressions, discovery, the run store layout, and `WorkflowMachine`. The machine takes events and returns effects; it has no I/O, no clock, and no randomness, so the whole execution semantics is tested as "events in, effects out". The app's `WorkflowEngine` owns the live runs, gives each run one serial effect queue, interprets effects against the app, and reports results back as events. Run state lives in the observable engine, not in a TCA reducer, because long-lived effect queues do not fit a reducer's effect lifetime; TCA holds only the start panel draft. `Runtime/` imports no workflow type.

## Related decisions

- [ADR 0015](../adrs/0015-workflow-completion-is-an-explicit-delivery.md): a step completes by an explicit delivery, not by idle detection.
- [ADR 0016](../adrs/0016-repository-workflows-with-commands-need-trust-from-the-app.md): trust for repository workflows that run commands.
