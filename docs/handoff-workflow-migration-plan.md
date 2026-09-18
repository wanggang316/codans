# Built-in Handoff migration

Status: Implemented and verified with isolated GUI and CLI acceptance on 2026-09-18.

## Contract

The existing Hand Off panel and handoff CLI use the workflow engine. Handoff
extracts the objective from the source conversation; users do not re-enter it.
An optional note supplements the existing task. Preserve source-anchored split
placement, background launch, supplied briefings, context-only handoff and save-only
checkpoints. Preserve worktree context and archive artifacts using existing core
file utilities as workflow actions, not a second orchestration engine.

The receiving Agent first acknowledges the immutable packet. Only a verified,
unblocked acknowledgement permits a separate recorded continuation dispatch.
Workflow completion means that continuation was submitted to the terminal, not
that the transferred development task is complete. Failures and cancellation do
not replay uncertain sends. SQLite and compatibility stores are excluded.

## Implementation and acceptance

- Update built-in definitions and add context/checkpoint and continuation actions.
- Adapt original panel and CLI entry points to create frozen workflow runs.
- Persist exact requests, submissions, generated context and immutable packets.
- Test placement, source identity, no-objective launch, acknowledgement gating,
  save-only behavior, rejected input and cancellation.
- Build and inspect the GUI. Run a real source/receiver handoff whose next step
  produces a verifiable file; inspect history and persisted evidence. Also verify
  the original CLI entry creates an inspectable run.
- Commit only owned, verified changes; do not push.

## Implementation details

The chooser is an adapter: it retains the selected Profile and placement, then
starts a specialized, frozen copy of the bundled Handoff definition. Supplied
briefings remove the author-request node. Save Progress removes receiver nodes
and uses checkpoint semantics. `handoff to --no-launch` retains transition
semantics while omitting receiver launch. No Objective is required from the user.

`codans/handoff.context.save@v1` owns the existing core archive/context utilities.
The packet includes normalized briefing text, generated repository/session
context, worktree path and supplemental note. Original worktree artifacts remain
available, while immutable packets and lifecycle records use the file-only run
store. `codans/agent.resume@v1` records a separate terminal dispatch after verified
readiness; it cannot receive claim/deliver results. A sent continuation completes
the Handoff, not the transferred task.

## Test isolation

Configuration isolation alone did not isolate zmx sockets. A test host's orphan
reaper removed terminals from the acceptance instance because both shared the
build-channel cache. `CODANS_CACHE_DIR` now relocates daemon sockets, snapshots
and logs as well. Test hosts use `/tmp/cdh-unit-cache`; GUI acceptance uses
`/tmp/cdh-gui-cache`, separate from the user's cache. Pair it with
`CODANS_CONFIG_DIR` and a unique `CODANS_SOCKET_PATH` for isolated app instances.

## Acceptance evidence

- Original pane menu → Hand Off → Pi → right split created run
  `01A66857-947D-4772-94D2-7A2D03B00A72` without an Objective form.
- All seven nodes succeeded. The receiver independently delivered the packet
  acknowledgement, received the recorded continuation, created
  `receiver-result.txt` containing exactly `HANDOFF_WORKFLOW_OK\n`, and read it
  back. The test driver did not deliver workflow results or press Return for an
  Agent. The packet SHA-256 matched the persisted file.
- GUI history showed Completed and all seven execution rows; the expanded
  continuation showed Request / Sent to terminal and its result. Starting did not
  open history. Actual app topology showed a new receiver pane beside the source
  in the same tab. During inspection, launch binding placement metadata was found
  to be discarded after resolution; the adapter now preserves it.
- This first run preceded the cache-isolation fix. Further acceptance uses the
  separate cache so test-host cleanup cannot invalidate the terminal evidence.

### Isolated user-level cases

- GUI original Hand Off, run `341B32FC-3C39-420D-A4D0-3FDE7EF6E6FA`:
  all seven nodes completed; the separate receiver wrote `gui-final-result.txt`
  containing `FINAL_GUI_HANDOFF_OK\n`. The resolved receiver binding retains
  `target: split`, `direction: right` and the source anchor pane.
- Original CLI `handoff to pi --brief - --note ...`, run
  `2D2E08DF-B759-4174-AE13-F97FB5D0B8E4`: returned a queued run ID; six nodes
  completed; the real receiver created `cli-result.txt` containing
  `CLI_HANDOFF_OK` (14 bytes, no trailing newline). The supplied note was retained in the immutable packet.
- CLI context-only `--no-launch`, run `78321CAE-AEE0-4420-AE0A-5403BD6EE4B8`:
  only context/packet nodes executed; prior briefing was archived, stale
  `current.md` removed, note preserved, and no receiver launched.
- CLI save, run `B1FFBE91-3052-4ACC-ABAE-DDCEA4B1F9EA`: creates a checkpoint
  and immutable packet without a receiver.
- GUI Save Progress initially failed closed after the source terminal was
  narrowed into a split: linear terminal extraction merged soft-wrapped rows,
  hiding the Pi composer borders. No text was submitted and the failed run
  `C0E7144B-DAA9-4DF8-BFD0-3830081D52EA` remains as evidence. Composer checks now
  read a rectangular screen selection preserving physical rows. Existing text
  readers retain their default linear behavior.
- The general run form also exposed missing current-role/location defaults when
  `catalog.selectedProjectID` was nil after initial project restoration. Workflow
  context now uses the same resolved selection as the main window.

- General toolbar Run Workflow → Handoff, run
  `998D3DAD-A24D-4704-A891-1F58843B2A88`: current Agent/location were prefilled;
  only an optional note and receiver Profile were supplied. All seven nodes
  succeeded with the source already narrowed into a split. The real receiver
  read `gui-final-result.txt`, verified the exact bytes and reported success
  without modifying files. No history opened automatically.
- Original GUI Save Progress, run `1E4C9563-C56E-476E-B266-25488EC98EF4`:
  all three nodes succeeded on that same narrowed source after the row-preserving
  fix. The source submitted its own briefing; history showed all three completed
  nodes under the default Pane scope. No receiver was launched.

## Validation

- App test selection: 107 tests across seven suites passed, including workflow
  runtime/definition, Handoff adapters, root reducer and composer echo tests.
- Core cache-directory selection: seven tests passed.
- Latest test-built app was used for the final two GUI cases above.
- `make mac-check` was run. Repository-wide lint is blocked by existing findings;
  unrelated formatter edits were restored. Focused lint reports only unchanged
  existing findings in `RootFeature` (initializer complexity) and
  `RootFeatureTests` (force-try). `git diff --check` passed.
- The original acceptance artifacts were stored in an isolated temporary directory
  and subsequently deleted at the user's request. Current execution records use
  `~/.codans/workflows/runs/`; definitions use `~/.codans/workflows/definitions/`.
  No SQLite files were created. Testing used a separate app/config/cache/socket;
  the user's installed app was not replaced.
- Real Agent end-to-end acceptance used Pi. Other Agent kinds share the adapter
  but were not individually exercised in this acceptance run.
