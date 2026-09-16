# Workflows

## Definitions and execution

Settings → Workflows manages reusable DSL definitions independently of Agents.
Create or import a definition, inspect its roles and inputs, and edit its YAML
Source. Definitions do not own sessions or workspaces; role bindings are chosen
when starting a run.

The main window places Run Workflow and Workflow History together before Agents
on the right toolbar. Choose a definition, fill its inputs and role bindings, and
start. The parameter form closes and leaves the terminal visible; it does not
open history or execution details automatically. Open Workflow History to inspect
progress or act on a human decision. Open Agent focuses the associated terminal.
Human decision nodes display the
proposal and require an explicit decision and reason.

Workflow History is a two-column popover: the run list stays on the left while
the selected run details stay on the right. Status text is accompanied by a
spinner for running work and colored indicators for other states.
Details include steps, inputs and results, events, and the frozen YAML used by
that run. Settings contains no run history. There is no separate Workflow window
or menu-bar menu.

## Built-in cases

- Decision Only records a human decision without an Agent.
- Advisor requests advice from an existing Agent and then records a decision.
- Committee collects independent analyses and reviews before synthesis.
- Handoff obtains a briefing from an existing Agent, stores an immutable packet,
  starts a receiver, and verifies its acknowledgement against the packet digest.
- Handoff from Briefing starts from supplied text and verifies a receiver's receipt.

Handoff completion means the receiver acknowledged the packet. The handed-off
implementation task is not executed by the acknowledgement node.

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

The standalone `handoff save` and `handoff to` commands retain their briefing,
archive and receiver-launch behavior; they do not create Workflow runs. Use the
Handoff DSL definition for observable multi-node execution and verified receipts.

Only the current DSL run store is read and written. Old template runs, their
compatibility routing and the template-based `workflow create` command are not
supported.
