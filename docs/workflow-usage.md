# Workflow execution preview

Status: Initial implementation. Fixed serial templates and explicit delivery are available; the broader design remains in progress.

Open **Workflows → Show Workflows** to inspect runs, steps, accepted results, storage errors, and the event history. CLI and UI use the same app-owned store. The running app must include this implementation; an older installed app does not expose these methods.

## Templates

| Template | Steps | Result means |
|---|---|---|
| `handoff-save` | packet → export | Materials and compatibility files were saved |
| `handoff` | packet → export → receive | The receiver acknowledged the immutable packet |
| `advisor` | advice → disposition | Advice and the coordinator's decision were delivered |
| `committee` | analysis-a / analysis-b → review-a / review-b → synthesis | Both reports, cross-reviews and synthesis were delivered |

All templates run serially. Committee analysis order is flexible, but neither review is eligible until both analyses are accepted. There is exactly one cross-review per member. This version does not enforce semantic report schemas for Advisor/Committee; accepting a nonempty report records a delivery, not its correctness or consensus. Independent contexts and read-only execution must be arranged by the coordinator and underlying Agent runtime.

## Advisor example

Use `codans-dev` for a Debug build and `codans` for Release. The examples use the Release name. Run the commands from a Codans pane, or supply an explicit pane address.

```bash
codans workflow create --template advisor --title 'Review cancellation' \
  --input 'Review the cancellation path. Do not modify source files. Return evidence, risks and unknowns.' --json
codans workflow list --json
```

Use the returned run ID with `workflow status`. An advisor claims `advice` from its own pane, does the work, and submits a result. Claiming records ownership; it does not launch an Agent or send instructions to another pane.

```text
codans workflow status RUN_ID --json
codans workflow claim RUN_ID --step advice --pane current --json
codans workflow deliver RUN_ID --attempt ATTEMPT_ID --delivery-id DELIVERY_UUID --pane current --content -
```

The final command reads the report from stdin. Keep the delivery UUID and exact content if retrying a lost acknowledgement. Reusing a delivery UUID with changed content is rejected. The coordinator then claims `disposition` and delivers what it adopted, rejected, or still needs to verify. `workflow cancel RUN_ID` prevents new work from being accepted; it does not kill an external Agent or roll back edits.

## Existing Handoff entry points

`handoff save` and `handoff to` now create tracked runs in the live app. They preserve the existing `.codans/handoff/` compatibility files and return `workflowRunID`. `--no-launch` uses `handoff-save`. The workflow stores an immutable packet so later changes to `current.md` cannot change its accepted input.

The receiver prompt contains the run ID, packet digest, and claim/delivery instructions. A receiver receipt is JSON containing `packetDigest` and a nonempty `nextAction`. The app only allows the bound receiver pane to claim the receipt step. Receiver creation and kickoff submission do not complete the run.

A receipt does not grant permission to modify the worktree. The old writer must be handled and continuation authorized separately. This preview does not implement writer reservations or ownership transfer. Starting a receiver whose runtime cannot preserve the no-write instruction is outside this guarantee.

## Persistence and limits

Each run is an atomic JSON snapshot under the channel-specific settings directory's `workflows/runs/`. The snapshot currently embeds bounded input, delivery text and events. Separate artifact storage, WorkItem records and dynamic plan revisions are not implemented in this slice.

- Title: at most 512 UTF-8 bytes; initial input: 64 KiB; individual delivery/packet: 32 KiB.
- Encoded run snapshot: 256 KiB. `workflow list` returns the newest 50 complete snapshots; `status` reads a known run.
- A delivery is acknowledged only after the updated snapshot is saved. A failed write fences further execution in the current process and displays a storage issue.
- Restart changes running records to `interrupted`; no work is automatically replayed. Existing external processes may still be active.
- Cancel and interruption preserve accepted material. There is no retry/resume command in this preview.
- UI exposes unreadable records as storage issues; it does not replace them with empty runs. CLI list reports storage issues instead of silently presenting a complete-looking list.

## Remaining design work

Dynamic plan transactions, structured Advisor/Committee report contracts, follow-up stages, automatic Agent dispatch, capabilities and attempt credentials, independent-context enforcement, writer admission, Human decisions, partial-result completion, parallelism, separate immutable artifacts, and WorkItem acceptance remain unimplemented. See [implementation plan](workflow-implementation-plan.md) and [scenario contracts](design-docs/workflow-use-cases.md).
