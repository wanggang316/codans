# Agent integration contracts implementation

## Objective and status

The revised [design](../design-docs/agent-integration-protocols.md) is implemented
in the HAN-167 isolated worktree. App/CLI integration validation is complete;
this is not a release or a claim of real provider recovery. The primary checkout
is outside the implementation scope and remains untouched.

The first protocol extraction preserved the original behavior. Subsequent review
showed that final-error ordering, instance ownership and coordinated input were
required for correct recovery. This plan records the replacement implementation;
the first extraction's differential results are not acceptance evidence for the
new state semantics.

## Implemented sequence

1. Replace split current-error fields with `AgentState.error(AgentFailure)` and
   add explicit unknown and input-availability values. Keep terminal signatures
   in controlled parser results and a per-instance observation tracker.
2. Order Codex/Claude failure and retry cues within the current interaction.
   Preserve pure Agent-specific parser ownership and conservatively report unknown
   without a recognized current cue.
3. Bind observations to actual Agent PID/birth time/PGID, surface generation and
   session identity. Reject stale instances/sequences and exclude error banners
   in the replacement's first frame.
4. Introduce input revisions, per-pane submission leases and residual-draft
   handling across native, CLI, Send Now, queued and recovery input.
5. Schedule recovery with occurrence tickets and scope-level attempt budgets.
   Policy edits cancel tickets without replenishing attempts; explicit cancellation
   persists for the scope. Gate prompt recovery on an empty verified composer.
6. Consolidate identity, launch data, terminal parser and optional resume behavior
   in AgentRegistry with compatibility facades. Add unknown to UI/IPC/CLI state
   handling and retain existing settings/display-value compatibility.
7. Integrate, validate, review, commit and update PR #211 after the final checks.

## Acceptance coverage

- Error is one state carrying failure detail; no parser recovery-support flag or
  duplicate Agent-name allowlist remains.
- Parser candidate, accepted observation and presentation are separate. Finished
  attention and hysteresis cannot authorize recovery.
- Historical retry text cannot hide a later terminal failure. Unknown and unreadable
  composers cannot authorize automatic input.
- Same-kind PID/birth/surface/session replacement cannot inherit an old ticket or
  an old terminal banner, including output missed by the predecessor's last sample.
- Static captures refresh liveness; identical frames do not invent state occurrences.
- Input invalidates pending operations before writes. An interrupted paste retains
  a marker; programmatic appends are rejected until explicit resolution or an
  observed occupied-to-empty composer transition.
- Native editing remains available. CLI rejection distinguishes a draft conflict
  from an absent pane. Teardown and membership reconciliation clear coordinator
  state without allowing late completions to recreate it.
- Autonomous state changes, policy edits and identity uncertainty do not replenish
  attempts. New external input or a verified instance starts a new scope.
- Existing launch/resume commands, quoting, profile behavior and stored display
  values remain compatible; clients must accept the added unknown state.

## Verification

- App build and **248 tests across 20 suites passed**. Coverage includes recovery
  timing and budgets, accepted observation versus presentation, identity/binding,
  capture ownership, all submission stages, CLI conflicts, command queues,
  Handoff routing, Root integration, notifications and process cancellation.
- **149 tests across 11 suites passed** in the independent SwiftPM Core/Store
  harness, including all parser fixtures, registry/launch/resume compatibility,
  policy/settings decoding and replacement-instance first-frame baselines.
- A separate temporary App test using a real GhosttyRuntime, PaneSurface and
  `/bin/cat` passed. Input reached the terminal; interrupted paste blocked later
  programmatic appends; explicit draft resolution restored delivery. The fixture
  was removed afterward and did not use a provider session or the production app.
- The CLI builds; built `agent wait --help` exposes unknown/error. All three
  bundled Agent wait completion state lists match the built generator after
  normalizing the Debug command name. The output schema parses as JSON.
- All **75 changed/new Swift files pass scoped SwiftLint**; `git diff --check`
  passes. Full `make mac-check` reported existing lint diagnostics; its 205
  unrelated formatting changes were restored. This is not a clean full-tree audit.
- The earlier complete Core run had baseline failures recorded in the
  [original recovery plan](agent-error-recovery.md); the current focused run does
  not claim those unrelated failures are resolved.

Logs: `/private/tmp/han167-contract-app-tests-final.log`,
`/private/tmp/han167-unified-core-tests/final-run.log`,
`/private/tmp/han167-native-transport-validation.log`,
`/private/tmp/han167-contract-cli-build.log`,
`/private/tmp/han167-contract-scoped-lint.log`,
`/private/tmp/han167-contract-mac-check.log`.

## Known boundaries

No live provider outage, end-to-end automatic retry against a real Agent,
terminal-version matrix or visual GUI verification was performed. The real PTY
check verifies the input transport boundary; fixture tests verify parsing and
recovery decisions. PTY writes cannot be atomic with kernel process replacement.

## Deferred architecture work

Session-history format/layout decoding remains in its current local and SSH
readers. Extract it only when all existing Agent formats and both transport paths
can share tested IO, budgets, cancellation and effective-profile HOME handling.
Structured provider events and session-addressed submission require separate
transport/session integration; no unused source protocol or plugin loader is added.
