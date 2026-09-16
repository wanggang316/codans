# Workflow implementation plan

Status: First executable slice implemented and tested; broader design in progress. Authorized on 2026-09-16. No commits or publication requested.

## First executable slice

Build the common serial execution protocol against Handoff, Advisor, and Committee. Use fixed, versioned built-in plans before exposing dynamic plan mutation. Keep the existing Handoff CLI/UI entry points. A receiver launch is not an accepted delivery.

1. Core: typed runs, dependencies, attempts, idempotent deliveries, cancellation, interruption, and deterministic scenario tests. Use `AgentWorkflowRun` to avoid the existing GitHub Actions `WorkflowRun` name.
2. Persistence: single app-owned store, atomic per-run snapshots, bounded content, durable acceptance before response, restart interruption, visible load/write errors.
3. IPC/CLI: create/list/status/claim/deliver/cancel, shared wire types, validated identifiers and standard output conventions.
4. Handoff: persist an execution intent before material writes/launch, retain immutable packet content, expose run identity, require explicit receiver receipt. Preserve existing exports as compatibility outputs.
5. UI: run list, steps, accepted outputs and event timeline, visible errors and cancellation, shared with CLI state.
6. Verification: Core scenario tests, store fault/restart tests, IPC integration checks, existing Handoff regressions, app/CLI build and changed-file lint.

## Deliberate boundaries

This slice uses pull/claim for generic Agent steps and fixed serial plans. Dynamic revisions, automated heterogeneous terminal dispatch, coordinator transfer, retries, parallel scheduling, separate WorkItem acceptance, and writer ownership transfer remain follow-up work. No terminal-idle completion inference or automatic replay. Handoff receipt confirms materials only, and does not authorize new writes.

Do not label the full architecture or all WF/HC/AC/CC acceptance criteria complete on the strength of this slice. Record actual commands, results, and remaining integration limits before delivery.

## Verification on 2026-09-16

First executable slice implemented; the full architecture remains in progress. Production Handoff entry points use the shared store; Advisor/Committee currently use explicit CLI claim/delivery. Snapshot text is bounded and embedded rather than stored in a separate ArtifactStore.

Executed from `apps/mac` with Xcode 26.0.1:

```bash
xcodebuild -workspace codans.xcworkspace -scheme Codans -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild -workspace codans.xcworkspace -scheme codans-cli -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild -workspace codans.xcworkspace -scheme codans-cli -configuration Release CODE_SIGNING_ALLOWED=NO build
xcodebuild test -workspace codans.xcworkspace -scheme CodansCore -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:CodansCoreTests/AgentWorkflowRunTests
xcodebuild test -workspace codans.xcworkspace -scheme Codans -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:CodansTests/AgentWorkflowStoreTests \
  -only-testing:CodansTests/WorkflowRouterTests \
  -only-testing:CodansTests/HandoffHandlersTests \
  -only-testing:CodansTests/HandoffFeatureTests
```

- App and both CLI builds passed.
- Workflow Core: 7 tests passed; App targeted tests: 33 tests in 4 suites passed.
- CLI help for the root, workflow group and six subcommands passed. Release shell completions regenerated.
- Changed-file lint reports two findings in unchanged functions: RootFeature shortcut grouping complexity and MethodRouter's existing async project router without await. No new-file findings remain.
- Full Core run: 622 tests, 4 issues in ShortcutSchemaAuditTests and TabIconTests. Those files were not changed by this work; the full suite is not green.
- Documentation links and `git diff --check` passed.
- Logs are under `/tmp/codans-workflow-build` on the development machine. No live external Agent handoff or interactive UI acceptance was performed; fake launchers and the actual app test host exercised the integration.

Next slice: formal report schemas and read contracts, dynamic plan revision/attempt credentials, writer admission and continuation authorization. Parallel scheduling remains after the serial contracts are complete. Do not mark all design acceptance criteria complete based on the checks above.
