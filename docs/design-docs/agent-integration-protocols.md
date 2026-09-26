# Agent integration protocols

## Scope and status

HAN-167 exposes Agent-specific knowledge scattered across terminal classification,
runtime adapters, launch descriptors, history scanners, and recovery eligibility.
This design separates pure Agent interpretation from shared orchestration.
Phase 1 extracts observation parsing without changing state semantics. Phases 2
and 3 below are follow-up work, not implemented behavior.

## Ownership

| Concern | Agent-owned contract | Shared responsibility |
| --- | --- | --- |
| Terminal observation | `AgentObservationParser`: activity and error evidence | Snapshot acquisition, debounce, attention, focus and keyboard handling |
| Recovery eligibility | Parser declares support for its terminal error evidence | Policy, attempt budgets, scheduling, cancellation, process identity, prompt delivery and script execution |
| Process identity and resume | Existing `AgentRuntimeAdapter` | Process probing, quoting and command execution |
| Launch configuration | Existing declarative `AgentDescriptor` | Profile overrides, environment and launch lifecycle |
| Session history (planned) | Format/layout and record interpretation | Local/SSH IO, read budgets, sorting and cancellation |

Data such as labels and process names remains data. Do not replace every field
with a protocol or introduce a single adapter responsible for all IO and policy.
Protocols belong in CodansCore when their inputs and outputs are pure domain
values. Runtime and App own side effects; all subprocess execution continues
through CommandRunner. No new Tuist target or dynamic plugin loader is needed.

## Phase 1: observation boundary

Each Agent has a concrete parser registered in `AgentObservationParsers`.
A parser accepts rendered viewport text and returns one `AgentObservation`:

- `activity`: the existing working, blocked, error or idle classification.
- `errorFingerprint`: the current trailing error evidence, independent of
  whether a stronger working/blocked cue wins activity classification.
- `visibleErrorFingerprints`: evidence still visible anywhere in the viewport,
  used to preserve keyboard suppression while an old error remains onscreen.

Parsers are deterministic, Sendable, and have no IO, clocks or mutable session
state. Shared text primitives are internal utilities; Agent-specific cue rules
remain in the corresponding implementation. The legacy interpreter entry points
remain compatibility facades so callers can migrate incrementally.

AgentStateStore caches the observation when a viewport arrives, and interprets
pre-binding text when a binding is established. It clears the cache wherever it
clears the viewport. Idle/focus events reuse this observation rather than parsing
text again. The store retains all existing user-input gating, stabilization,
attention and suppression semantics.

Recovery consults the parser's support declaration instead of maintaining a
second AgentKind allowlist. This declaration means that the parser implements
error evidence usable by the current recovery mechanism; it does not assert that
all errors are retryable or that the input composer is ready. Identity checks and
bounded, opt-in policy remain mandatory.

Compatibility constraints:

- Preserve the last-24-nonblank-lines activity region and current cue precedence.
- Preserve full-viewport old-error visibility and trailing-error exclusions.
- Preserve working stabilization and `finished` as an attention-derived state.
- Do not change persistence, IPC values, settings defaults or retry budgets.

Adding observation support requires a parser, registration, and fixtures. It
must not require AgentKind switches in the state store or recovery scheduler.
AgentRuntimeAdapters and AgentCatalog remain separate registries until their
launch/resume contracts are addressed in phase 3.

## Phase 2: explicit observation semantics

Separately review unknown versus idle, observation source and freshness,
input readiness, internal retry evidence, and instance identity. Missing evidence
must eventually be distinguishable from a confirmed idle composer. Separate
execution state from attention instead of treating `finished` as proof of success.
A same-kind process restart must invalidate old observations even without a
session ID. These change behavior and need dedicated state-transition fixtures
and process replacement tests, rather than being hidden inside extraction.

## Phase 3: remaining Agent behavior

Extract history layout/record decoding from the local and SSH scanners while
retaining shared IO limits and cancellation. Consolidate Agent registration with
launch metadata and optional resume/history capabilities only after those
contracts are concrete. Keep profile HOME overrides explicit in history lookup.
Existing launch interaction and resume command behavior must remain compatible.

## Verification

Use existing classifier fixtures as the behavior oracle, add registry and
observation contract tests, and run store/recovery integration suites. Review
moved cue bodies against their pre-refactor source. UI and IPC state values do
not change. Full Core and lint runs have known baseline failures documented in
[the recovery execution plan](../exec-plans/agent-error-recovery.md); report new
failures separately and do not claim live provider recovery from unit tests.
