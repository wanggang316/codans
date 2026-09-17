# Workflow execution records

Status: Implemented; focused tests and real GUI Handoff verified on 2026-09-17.

## Scope and decisions

Separate node definitions from actual executions. Keep the existing CLI receipt
identifier while exposing execution records in the model and UI. Each execution
owns resolved inputs, outputs, timing, status, and action identity. Agent requests
add their exact instruction, target identity, dispatch state, and submission
history. Local actions and human decisions keep their existing typed inputs and
outputs; they do not acquire artificial agent lifecycle objects.

Preserve the current SQLite transaction as the authoritative snapshot in this
change. Maintain a readable, rebuildable run directory with frozen YAML, events,
execution snapshots, instructions and submission records. This is not a storage
migration or a cross-file transaction. Do not replay uncertain external effects.

## Implementation

1. Add execution/request/submission records and synchronize node projections.
2. Persist requests before sending; distinguish prepared, sending, sent and
   failed. Correlate asynchronous completion with the execution identity.
3. Preserve rejected content and validation issues; deduplicate identical retries
   while retaining corrected content under the same delivery identifier.
4. Persist readable process files continuously and show requests/submissions in
   compact expandable history sections.
5. Test correction, deduplication, cancellation, restart, storage and asynchronous
   completion; build, lint, inspect the actual GUI, and commit owned changes.

## Boundaries

No new retry command, automatic replay, loop scheduler or generic script runner.
The execution collection can retain future explicitly restarted executions, but
current definitions still schedule each node once. Existing CLI --attempt is an
execution correlation identifier, not a new invocation on every claim.

## Current data and lifecycle

`WorkflowNodeRunV2` is the scheduler's current-node projection. Its `executions`
collection owns the actual records; persistence synchronizes the current record
from the projection. An execution stores the node ID and action, resolved inputs,
outputs, error and timestamps. A fresh scheduled execution allocates its ID once.
`claim` returns that identifier without creating an execution. Agent tool calls,
waiting and corrected submissions do not allocate another execution.

Agent execution details contain a request and zero or more submissions. The
request freezes the exact dispatched prompt, suggested delivery ID, pane, session
and endpoint generation before transport begins. Dispatch transitions are
`prepared -> sending -> sent | failed`. `sent` means terminal submission completed,
not model acknowledgement. A completed submission is the acceptance evidence.
Cancellation/restart invalidates the node execution; already-sent requests retain
their sent timestamp and dispatch fact. Unfinished transport becomes cancelled or
interrupted. A late send callback cannot resurrect cancelled work or overwrite an
accepted result. A transport error after an accepted result does not fail the run.

Each submission has its own record UUID, delivery ID, raw content, acceptance,
validation issues and receipt time. Corrected content with the same delivery ID
creates another record. Identical rejected retries do not duplicate records;
identical accepted retries remain idempotent. Accepted delivery IDs cannot be
reused with changed content. Invalid endpoints and oversized payloads are rejected
at the boundary, rather than archived as authenticated submissions.

Human decisions record their question/options/evidence as inputs and their choice
and reason as outputs. Native packet creation and acknowledgement verification
record their inputs and outputs without artificial request/submission objects.
There is no generic process/script action in this implementation, so it does not
invent stdout/stderr or exit-code files for actions that never ran a subprocess.

## Readable run directory

```text
artifacts/<run-id>/
  workflow.yaml
  run.json
  events.jsonl
  <packet-id>.md
  nodes/<execution-id>/
    execution.json
    inputs.json
    outputs.json
    request.json
    instruction.md
    submissions/<submission-record-id>.json
```

Request and submission files exist only for Agent requests. UUID directory names
avoid allowing definition node IDs to become filesystem paths. Every persisted
transition refreshes these files; Reveal in Finder opens this same directory.
SQLite remains authoritative. Mirrors are written after committing the snapshot
and before dispatch; archive failure stops subsequent dispatch. A crash can leave
a mirror behind the committed state, never ahead of it. Each file is replaced
atomically, but the directory and SQLite do not form one atomic transaction.
Startup reconstructs mirrors from committed snapshots. Files are intended for
inspection, not an independent replay log. The complete run snapshot retains the
existing 16 MiB limit and individual deliveries retain the 256 KiB limit.

History shows request dispatch and submission acceptance independently, with
expandable exact content and validation issues. Execution identifiers live under
Details. Multiple execution headers appear only when multiple records exist.
Older stored nodes without execution records remain inspectable; missing request
or submission evidence is never fabricated retroactively.

## Verification

- Debug app build succeeded. The final test build passed 23 tests across
  WorkflowServiceV2Tests, WorkflowRouterV2Tests and WorkflowEndpointIdentityV2Tests.
  New coverage includes exact pre-dispatch persistence, corrected and duplicate
  submissions, asynchronous send completion, cancellation, restart, archive repair,
  archive failure and prevention of repeated scheduling after storage failure.
- Changed Swift files pass focused SwiftLint and swift-format; `git diff --check`
  passes. Repository-wide `make mac-check` is blocked by pre-existing lint findings
  in other modules. Its unrelated formatter changes were reverted.
- GUI run `9B1D65D3-3620-40E0-8DB3-0F50999DD9D0`, titled
  `GUI Execution Records Handoff`, completed all five nodes using real Pi Agents.
  The author deliberately submitted a missing-heading result, then corrected it
  under the same execution/delivery IDs. The independent receiver acknowledged the
  packet and digest. No test-driver delivery or manual Return was used.
- GUI history showed Request / Sent to terminal, both Rejected and Accepted
  submissions, their exact content, and the validation error. The complete request
  expanded correctly with Copy Request. Launch kept the terminal visible.
- Reveal in Finder opened the run directory. Its 26 files include all five node
  execution snapshots, two exact requests, three submissions, frozen YAML and
  events. The run and execution JSON files matched the authoritative database;
  archived instruction text matched the recorded dispatched prompts.
- Logs: `/tmp/codans-execution-verified.log`,
  `/tmp/codans-execution-build.log`, `/tmp/codans-execution-check.log`.
