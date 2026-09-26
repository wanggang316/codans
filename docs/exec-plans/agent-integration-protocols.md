# Agent integration protocol extraction

## Objective

This plan records the completed phase-1 extraction in the HAN-167 isolated
worktree. The [revised design](../design-docs/agent-integration-protocols.md)
supersedes its proposed next steps; that design is not yet implemented.

## Sequence

1. Extract pure observation contracts, per-Agent parsers and static registration.
2. Cache observations in AgentStateStore and use parser recovery capability.
3. Add contract/registration fixtures; run existing classifier and App integration tests.
4. Review the diff, run formatting/lint checks, and commit the coherent change.

## Acceptance

- Agent-specific terminal cues live with concrete parser implementations.
- State and recovery orchestration contain no AgentKind classification switches.
- A viewport is parsed once for state and error evidence and reused on idle events.
- Existing classification, attention and recovery tests retain their behavior.
- Main checkout remains untouched; only task-owned changes are committed.

## Deferred

The initial plan deferred unknown state, input readiness, instance identity,
history IO and launch/resume consolidation. Review showed that instance ownership
and input invalidation are prerequisites for correct automatic recovery; the
revised design moves them into the required correctness scope.

## Status

Phase 1 extraction and its recorded checks are complete. Subsequent review found
correctness gaps in final-error recognition, instance replacement during the
waiting period, and external input invalidation. The passing checks below do not
validate those scenarios. The revised design is proposed; no corresponding
runtime changes have been made yet.

## Verification results

- App build and 86 tests across 8 suites passed, including pre-binding observations,
  rebind invalidation, old-error suppression outside the activity window, recovery,
  IPC, command queues, cancellation, notifications and ordering.
- 70 targeted Core tests passed: observation contracts, existing classifier fixtures,
  settings compatibility and recovery policy.
- Differential harness compared the original `03e269ca` classifier with the extracted
  parsers: 101 existing fixture strings expanded to 5,793 distinct texts across all
  13 Agent kinds, totaling 75,309 observations and 225,927 field comparisons with no
  differences. Visible-error evidence used the original store's per-line algorithm
  as its oracle. The harness is temporary validation tooling, not a shipped test.
- All 23 changed/new Swift files pass SwiftLint; `git diff --check` passes.
- Full `make mac-check` still reports 60 pre-existing lint diagnostics. Its 213
  unrelated formatting changes were restored before scoped formatting and review.
- First App build was blocked by a missing worktree zmx binary. Restoring the
  previously built matching artifact allowed the complete test run to pass.
- No live provider outage, real automatic recovery or GUI visual check was performed.

Logs: `/private/tmp/han167-protocol-app-tests.log`,
`/private/tmp/han167-recovery-settings-tests/phase1-core-tests.log`,
`/private/tmp/han167-parser-differential.log`,
`/private/tmp/han167-protocol-scoped-lint.log`,
`/private/tmp/han167-protocol-mac-check.log`.
