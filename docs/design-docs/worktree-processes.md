# Worktree Processes

## Scope

Track the selected worktree's live foreground tasks, with one entry per
terminal pane. The tab hover card shows the entry of its tab.

The header no longer shows a process badge or a process list popover (removed
in HAN-210). The registry and its query API stay in place for other surfaces.

This includes manually typed commands such as `npm run tauri dev`, as well as
Agent and Run launches in internal terminal panes. Detached
background daemons and external GUI applications launched by arbitrary script
contents are outside this foreground-task model.

## State and lifetime

`WorktreeProcessRegistry` keeps one entry per Pane, keyed by `PaneID`. Each
entry carries its Project, Worktree and Tab IDs, PID, process start time,
observed name, optional agent kind, and working directory. Entries are scoped
to existing panes in non-archived worktrees.

A live foreground sample is required for every visible row. Agent/Run launch
attribution supplies a friendly name and task kind; it cannot create a visible
entry on its own. Manual shell commands use the same sampling path. Agents
waiting for input remain foreground tasks, while a shell prompt retires an
observed task. PID and process start time identify continuity; a replacement
process loses the prior launch attribution.

Hierarchy removal and delayed samples both check current catalog membership.
The registry and launch attribution are session-only: application startup
rebuilds the list from fresh samples.

## Verification contracts

The source tests cover lifecycle retirement, PID replacement, stale samples,
worktree isolation, and process icons.
Runtime checks should cover ordinary typed commands, Agent and Run launches,
external termination, hierarchy deletion, and restart. A source test or
documented command is not a recorded runtime result.

To rerun the focused native tests:

```bash
cd apps/mac
xcodebuild test -workspace codans.xcworkspace -scheme Codans \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -only-testing:CodansTests/HierarchyManagerProcessTests \
  -only-testing:CodansTests/ForegroundJobReaderTests
```

Use `TEST_RUNNER_CODANS_CONFIG_DIR` to isolate app-hosted tests.

## Evidence and recovery boundaries

Local samples include the kernel process start time. Missing foreground samples
are retired after the existing three-sample hysteresis; observing a shell prompt
retires the entry directly. No extra process polling loop is added.

Remote probe failure hides entries immediately. An already-observed task's
attribution may be retained for up to 30 seconds to recover the same process,
but is never displayed without a successful new sample. Remote samples without
a start time show an unknown duration. Failed/unobserved launch intentions expire
after 15 seconds.

Launch attribution is not persisted. After restarting Codans, all foreground
commands are rediscovered only from fresh live samples. Run display names fall
back to the observed process name; an old pane label alone is not evidence of
liveness. Launch provenance enriches names but never gates process visibility.

## Process icons

The tab hover card shows a 14-point template icon before the process name.
Observed agent identities reuse the bundled agent marks. Other executable names
resolve through `CommandIconCatalog`, the same tool-mark table command icons use
(Node.js, npm, pnpm, Python, Go, Rust, Docker, Git and the rest of the `tool-*`
marks — see [Command Suggest](command-suggest.md)); unknown commands use the
terminal symbol. Matching uses live process identity, never a
user-defined Run task name. Icon selection does not alter process detection.


## Implementation references

- [WorktreeProcessRegistry.swift](../../apps/mac/codans/Runtime/WorktreeProcessRegistry.swift): entries, launch attribution and recovery bounds.
- [ForegroundJobReader.swift](../../apps/mac/codans/Runtime/ForegroundJobReader.swift): local foreground evidence and process start times.
- [WorktreeProcessIconView.swift](../../apps/mac/codans/App/Features/StatusBar/Views/WorktreeProcessIconView.swift): process identity icons.
