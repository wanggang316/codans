# Workflows

Status: Initial implementation. The GUI can create and run fixed serial workflows. The broader dynamic workflow design remains in progress.

## Create and inspect a workflow

Open **Workflows → New Workflow…**, or choose **New Workflow** in the workflow window. **Workflows → Show Workflows…** opens existing runs. The running app must include this implementation; an older installed app does not provide these controls.

1. Choose Advisor, Committee, Handoff, or Save Handoff.
2. Enter a title and a question or handoff briefing.
3. Select the workspace where the agents should work.
4. For Advisor, choose one enabled profile. For Committee, choose the first and second reviewer profiles. Both selections may use the same profile; each assignment opens a separate tab.
5. For Handoff, choose a source pane in the selected workspace and a receiving profile. Save Handoff requires a source pane and briefing but no receiving profile.
6. Select **Start Workflow**. The form retains its content and creation identity on failure. After creation, the window selects the run.

A bound assignment that is not claimed within ten minutes is marked as needing attention, without launching another Agent. Its original pane may still claim it later. The detail view shows the report or advice, dispatch status, steps, and event history. **Open Agent** locates the assigned pane. Storage and dispatch errors remain visible. A started agent, an idle terminal, and an accepted result are different facts.

## Templates and results

| Template | Steps | Result means |
|---|---|---|
| `handoff-save` | packet → export | Materials and compatibility files were saved |
| `handoff` | packet → export → receive | The receiver acknowledged the immutable packet |
| `advisor` | advice → disposition | Advice was delivered and a decision was recorded |
| `committee` | analysis-a / analysis-b → review-a / review-b → synthesis | Independent analyses, one cross-review per member, and synthesis were delivered |

### Advisor

The GUI starts the advisor in a new background tab with the question and claim/delivery instructions. Its accepted advice appears directly in the detail view. Select **Adopt**, **Need more evidence**, or **Reject**, enter a reason, and choose **Record Decision**. This records the user's disposition without launching another agent. “Need more evidence” records that decision; it does not automatically create a follow-up investigation.

### Committee

The runner executes the five steps serially, opening a new background tab for each assignment. Both initial analyses receive the same question without the other member's report. Cross-reviews receive both accepted analyses; synthesis receives the accepted reports and reviews. The second profile handles analysis-b and review-b; the primary profile handles the other steps.

Separate tabs and prompts provide separate launched contexts. Read-only instructions remain an agent/runtime contract, not a filesystem sandbox. Nonempty accepted reports do not prove correctness or agreement; the synthesis is instructed to preserve unresolved disagreements.

### Record an agent result manually

If an agent answers in its pane but does not use the delivery protocol, open the eligible step and expand **Record Result Manually**. Review and paste the result, then choose **Record Result**. The app records a manual submission and can advance the workflow; this does not stop the external agent.

This recovery is available only for Advisor's advice and eligible Committee steps. It cannot bypass handoff export, receiver acknowledgement, or Advisor's separate decision control. Errors preserve the entered text.

## Handoff entry points

The GUI uses the same Handoff handlers as `handoff save` and `handoff to`. Existing CLI entry points also create tracked runs and return `workflowRunID`; `--no-launch` uses `handoff-save`. They retain `.codans/handoff/` compatibility files while storing an immutable packet in the run. Later changes to shared `current.md` do not change that accepted packet.

The briefing should preserve the objective, current state, completed work, constraints, failed attempts, evidence, and next steps. The receiver prompt contains the run ID, packet digest, and claim/delivery instructions. Its JSON receipt must contain the matching `packetDigest` and a nonempty `nextAction`. Only the bound receiver pane can claim this receipt in a handler-created handoff. Launch and kickoff submission alone do not complete the run.

Acknowledging a packet does not authorize new worktree writes or complete the underlying task. The old writer must be handled and continuation authorized separately; writer reservations and ownership transfer are not implemented.

## CLI and explicit assignments

Use `codans-dev` for Debug and `codans` for Release. The CLI remains available for inspection and explicit claim/delivery. A plain CLI `workflow create` registers a template; unlike GUI creation with profiles, it does not configure automatic launching.

```bash
codans workflow create --template advisor --title 'Review cancellation' \
  --input 'Review cancellation without modifying files. Return evidence, risks and unknowns.' --json
codans workflow list --json
```

```text
codans workflow status RUN_ID --json
codans workflow claim RUN_ID --step advice --pane current --json
codans workflow deliver RUN_ID --attempt ATTEMPT_ID --delivery-id DELIVERY_UUID --pane current --content -
codans workflow cancel RUN_ID
```

`--content -` reads stdin. Retry a lost delivery acknowledgement using the same delivery UUID and identical content; changed content under the same UUID is rejected. Claiming a CLI-created step records its assignment; it does not itself launch an agent.

## Cancellation, persistence, and limits

**Cancel Workflow** stops subsequent dispatch and acceptance. It does not kill agent processes, close their tabs, or undo edits. Inspect any still-running agents before assigning replacement work.

Runs are atomic JSON snapshots under the channel-specific settings directory's `workflows/runs/`. They embed bounded input, deliveries, execution configuration, and events.

- Title: 512 UTF-8 bytes; initial input: 64 KiB; each delivery/packet: 32 KiB; encoded snapshot: 256 KiB.
- CLI list returns the newest 50 snapshots; status reads a known run.
- Acceptance is acknowledged after persistence. Write failure fences further execution and surfaces a storage issue.
- Restart marks unfinished runs `interrupted`; it does not replay assignments. External agent processes may remain active.
- Accepted material survives cancellation/interruption. There is no automatic retry or restart-resume.
- Unreadable records remain visible as storage issues rather than becoming empty runs; CLI list also reports storage issues.

## Remaining scope and verification

Dynamic plan transactions, structured semantic report validation, follow-up stages, scoped worker credentials, writer admission, general Human decision nodes, partial-result completion, parallel scheduling, separate immutable artifact storage, and independent WorkItem acceptance remain future work. The existing Advisor decision form is a concrete supported operation, not a general Human-node engine.

GUI creation, automatic dispatch, manual result recovery, and the updated Handoff path still require this iteration's build, targeted tests, and interactive acceptance. See [implementation plan](workflow-implementation-plan.md) and [scenario contracts](design-docs/workflow-use-cases.md).
