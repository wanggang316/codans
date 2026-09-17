# Workflows

## Definitions and execution

Settings → Workflows manages reusable DSL definitions independently of Agents.
Create or import a definition, inspect its roles and inputs, and edit its YAML
Source. Definitions do not own sessions or workspaces; role bindings are chosen
when starting a run.

The main window places Run Workflow before Agents on the right toolbar.
Workflow History sits beside notifications in the center toolbar. Choose a definition, fill its inputs and role bindings, and
start. The parameter form closes and leaves the terminal visible; it does not
open history or execution details automatically. Open Workflow History to inspect
progress or act on a human decision. Open Agent focuses the associated terminal.
Human decision nodes display the proposal and require an explicit decision and reason.

Workflow History is a two-column popover: the run list stays on the left while
the selected run details stay on the right. The Pane / Worktree / All filter
defaults to the current pane and includes both the launch origin and participants.
Runs started before origin tracking can still match their recorded participants.
Status text is accompanied by a
spinner for running work and colored indicators for other states.
The detail pane shows compact execution rows without tabs. Expand a row for
its inputs and result; pending decisions and failures are visible immediately.
Results, run inputs, participants, activity and frozen YAML are available below
the execution list. The run actions menu provides copying, cancellation and Reveal in Finder.
Reveal opens the run's existing directory under `artifacts/<run-id>/`, containing
the frozen `workflow.yaml`, execution details, requests and submissions.
`run.json` is the sole authoritative record. Each state change atomically replaces
that complete snapshot before updating the readable derived files. Startup loads
`run.json` and repairs those derived files. Workflow runs use no database and no
database compatibility layer; SQLite run files are neither read nor migrated.
Click outside the popover or press Escape to dismiss it. Settings contains no run history. There is no separate Workflow window
or menu-bar menu.

## Role defaults

A `current` role starts with the focused Agent selected. A `launch` role starts
with the current worktree selected as its terminal location. These defaults
remain visible and can be changed before launch. If no applicable Agent or
location exists, choose one explicitly.

A launch role can also configure its Profile:

```yaml
roles:
  author:
    label: Author
    source: current
  receiver:
    label: Receiver
    source: launch
    profile: Receiver
```

`profile` accepts a saved Profile UUID or an exact, unique display name. A
configured Profile is shown directly instead of asking again. Missing, disabled
or ambiguous Profiles block launch with an error. Omit `profile` to let the user
choose an enabled Profile. Existing-session roles use their live session and do
not accept a launch Profile.

## Built-in cases

- Decision Only records a human decision without an Agent.
- Advisor requests advice from an existing Agent and then records a decision.
- Committee collects independent analyses and reviews before synthesis.
- Handoff obtains a briefing from an existing Agent, stores an immutable packet,
  archives worktree/session context, starts a receiver, verifies its acknowledgement
  against the packet digest, and submits the instruction to continue the task.
  Its optional note supplements the current conversation; Objective is not a form input.
- Handoff from Briefing starts from supplied text and verifies a receiver's receipt.

Handoff completion means the receiver acknowledged the packet and the continuation
instruction was submitted to its terminal. It does not mean the transferred task
is complete. A receiver reporting blockers does not receive continuation. The
source is instructed to stop task work after delivering the briefing.

## CLI protocol

Use `codans-dev` for Debug and `codans` for Release. Runs are started through the
DSL GUI. The CLI exposes inspection and explicit assignment delivery:

```bash
codans workflow list
codans workflow status RUN_ID
codans workflow claim RUN_ID --step NODE_ID --pane current
codans workflow deliver RUN_ID --attempt ATTEMPT_ID --delivery-id DELIVERY_ID --content -
codans workflow cancel RUN_ID
```

Agents receive the exact run, attempt and delivery identifiers in their assigned
prompt. A chat reply or idle terminal does not complete a node; an accepted
explicit delivery does. Unknown run IDs return not-found errors.

The original Hand Off panel and `handoff save` / `handoff to` CLI commands now
create runs through the same workflow engine. The panel uses the source session
to write the briefing without an Objective form. It preserves the exact selected
Profile, new-tab/source-anchored split placement, and Save Progress choice. It
closes after starting and does not automatically open history.

CLI callers still provide `--brief` or explicitly select `--no-brief`. The command
returns a queued run ID and directory, not a claim that the receiver has launched.
Inspect `workflow status RUN_ID` or Workflow History for completion/errors.
`handoff save` creates a checkpoint; `handoff to --no-launch` prepares the
transition and archives prior context without launching a receiver. Worktree `.codans/handoff/` briefing, context, session and archive files
remain available; they are written by a workflow action. The immutable packet and
execution evidence live in the workflow run directory. No separate Handoff
orchestration engine or database is used.

Only the current DSL run store is read and written. Old template runs, their
compatibility routing and the template-based `workflow create` command are not
supported.
