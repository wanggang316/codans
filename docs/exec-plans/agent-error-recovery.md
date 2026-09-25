# Agent Error Recovery (HAN-167)

## Objective

Recognize terminal-level Agent failures and offer opt-in bounded recovery without interrupting working agents or permission dialogs.

## Scope and ownership

- Error classifier, state, UI badges and CLI wait: error_detection agent.
- Backward-compatible policy settings and settings UI: recovery_settings agent.
- Recovery scheduling, lifecycle wiring, script execution and integration validation: primary agent.
- Worktree: `han-167-error-retry`; branch: `gumpwang2016/han-167-错误重试机制`.

## Implementation sequence

1. Verify current state sources and official structured-event alternatives.
2. Add conservative Codex/Claude terminal error classification with negative fixtures and stable recovery identity.
3. Add disabled-by-default recovery settings (prompt or local script, delay, bounded attempts).
4. Wire a dedicated runner that rechecks current identity, error state and live local pane before dispatch.
5. Validate classification, lifecycle invalidation, bounded attempts, settings compatibility, scripts and CLI; run lint/build/tests.

## Acceptance criteria

- A verified terminal error cue becomes `error`; focus does not clear it.
- Permission requests, internal retry activity, quoted errors and normal tool failures do not initiate recovery.
- Recovery runs only for opted-in local supported agents; an invalid policy does nothing.
- User input, a new binding, working state, pane removal or policy changes invalidate pending recovery. Spent attempts survive state oscillations until new user input or binding.
- Duplicate snapshots do not reset an attempt budget; no overlapping recovery per pane.
- Script execution uses CommandRunner with timeout/output bounds, worktree cwd and explicit session context; it never types shell code into an Agent.
- Prompt delivery checks identity before paste and before delayed Return.
- Settings lacking recovery fields decode with recovery disabled.

## Status

Implementation complete in the isolated worktree. Verified changes are committed on the feature branch; no push requested.

## Verification results

- App build and final targeted integration run: **84 tests / 8 suites passed**. Includes Agent recovery, state, IPC wait, command queue, cancellation of real subprocesses, foreground process replacement, paste/submit races, notifications and row ordering.
- Complete CodansCore run: **683 tests / 85 suites; 3 failed tests with 4 issues**. Recovery policy, settings compatibility and terminal classifier suites passed.
- Baseline verification: the original Core sources at `a584f1b447041e1611cb5ef71de05aab43231425`, extracted with `git archive` into a temporary SwiftPM package, reproduce the same four issues: two shortcut modifier mismatches, a missing `changeActiveTabColor` golden entry, and a legacy Tab identifier decode mismatch. These are outside HAN-167.
- SwiftLint: all changed/new Swift files pass. Full-repository lint reports 60 existing diagnostics outside the changed files after the new complexity issue was fixed.
- `git diff --check` passes. Built CLI help advertises `--until error`.
- Main checkout remains clean. No provider outage was induced and no real Agent session was automatically retried during validation. Visual GUI inspection and SSH recovery were not performed (SSH recovery is excluded).

### Reproduction

From `apps/mac`:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -workspace codans.xcworkspace -scheme Codans -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/codans-han-167-derived \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:CodansTests/AgentRecoveryRunnerTests \
  -only-testing:CodansTests/AgentStateStoreTests \
  -only-testing:CodansTests/AgentHandlersStateTests \
  -only-testing:CodansTests/CommandQueueRunnerTests \
  -only-testing:CodansTests/CommandRunnerCancellationTests \
  -only-testing:CodansTests/AgentNotificationConsistencyTests \
  -only-testing:CodansTests/AgentRowOrderingTests \
  -only-testing:CodansTests/AgentStateOrderCoordinatorTests
```

Local logs: `/private/tmp/han167-app-final-tests.log`, `/private/tmp/han167-core-tests.log`, `/private/tmp/han167-baseline-core-tests.log`, `/private/tmp/han167-scoped-lint.log`.
