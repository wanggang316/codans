# Worktree processes (HAN-130)

## Scope

Show the selected worktree's live foreground tasks in the header, with one
entry per terminal pane. The process badge sits beside the center status item;
the notification bell follows in a separate toolbar group. Hover or click opens
a compact list of task names, process IDs, and elapsed times. Selecting a row
closes the popover and focuses its owning tab and pane.

This includes manually typed commands such as `npm run tauri dev`, as well as
Agent and Run launches in internal terminal panes. Detached
background daemons and external GUI applications launched by arbitrary script
contents are outside this foreground-task model.

## Execution plan

1. Reuse terminal foreground sampling and add in-memory launch provenance,
   including Run commands sent to the focused pane. Keep this separate from the
   dedicated Run pane reuse index.
2. Derive observable entries from live process evidence and current catalog
   membership. Waiting-for-input agents remain processes. Shell prompts and
   persisted agent labels alone do not prove liveness.
3. Invalidate entries on external process exit, terminal exit/crash/close, tab
   close, and worktree/project archive or deletion. Reconcile membership again
   when delayed samples arrive. A new application instance starts without cached
   process entries and rebuilds only from fresh process evidence.
4. Integrate the badge and accessible hover/click popover. Freeze its dimensions
   while presented, update its rows without animated window resizing, and defer
   navigation until after dismissal. Revalidate stale selections before focus.
5. Exercise lifecycle and isolation tests, run relevant existing suites, lint,
   and build the app. Verify the header at regular and narrow window widths
   when the local app environment permits it.

## Acceptance criteria

- Manual commands and Agent/Run launches in new tabs, splits, and focused panes are represented
  once, scoped to their worktree; idle agents remain visible.
- Process exits and hierarchy removal cannot leave unbounded stale entries or
  repopulate deleted entries through delayed callbacks.
- PID reuse cannot carry an old task's name or age into a new process.
- No process list is restored from stale disk state at application startup.
- The hover card remains reachable while moving the pointer from the badge;
  keyboard activation also opens it, and Escape dismisses it.
- Row activation focuses the correct pane only while its source remains valid.
- Existing Run/Stop routing and pane reuse semantics remain intact.

## Validation

- Manual-command regression: 22 tests passed across process lifecycle,
  foreground sampling, and existing Stop behavior. The isolated app received
  `npm run tauri dev` through ordinary terminal input, using a local npm fixture
  whose script runs a long-lived Node process. The header changed from 0 to 1,
  and its popover showed the actual command name and PID. Externally terminating
  the fixture returned the count to 0 and cleared the open popover. This tests
  the manual npm entry path, not a full Handbox/Tauri application build.

- `Codans` Debug build succeeded on Xcode 26.0.1.
- Initial targeted batch: 32 tests passed across process lifecycle, duration,
  native popover sizing, foreground sampling, and existing Run/Stop suites.
- After the final dispatch-helper extraction: 44 tests passed across
  `HierarchyManagerProcessTests`, `HierarchyManagerRunScriptPaneTests`,
  `HierarchyClientStopScriptTests`, and `HierarchyClientTests`.
- The final native presentation suite passed separately in both appearance
  modes. Live entry additions/removals and long names preserve popover size.
- SwiftLint reports no violations in changed files. The repository-wide run
  still reports 61 existing violations across 34 unchanged files.
- Isolated application smoke checks verified new-tab, focused, and split Run
  launches; an actual Codex process waiting for input; external termination of
  Run and Agent processes; clicking a process from another tab; tab closure;
  restart without stale entries; and deleting a project while tasks run.
- Header and popover inspected at approximately 1405, 1054, and 825 screen
  pixels wide. The process entry remains accessible; trailing actions use the
  native toolbar overflow at the narrowest width.

To rerun the focused native tests:

```bash
cd apps/mac
xcodebuild test -workspace codans.xcworkspace -scheme Codans \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -only-testing:CodansTests/HierarchyManagerProcessTests \
  -only-testing:CodansTests/WorktreeProcessDurationTests \
  -only-testing:CodansTests/WorktreeProcessPresentationTests \
  -only-testing:CodansTests/ForegroundJobReaderTests
```

Use `TEST_RUNNER_CODANS_CONFIG_DIR` to isolate app-hosted tests and
`TEST_RUNNER_HAN130_RENDER_DIR` to export presentation PNGs through xcodebuild.

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

Rows retain their status dot and add a 14-point template icon before the name.
Observed agent identities reuse the bundled agent marks. Common executable names
map to bundled Node.js, npm, pnpm, Python, Go, Rust, Docker, and Git marks; unknown
commands use the terminal symbol. Matching uses live process identity, never a
user-defined Run task name. Icon selection does not alter process detection.

Validation: 18 tests passed across icon matching, process lifecycle, and native
presentation suites. Light and dark renders were inspected with long names and
large PIDs; icons preserve the fixed popover dimensions. Changed Swift files
pass SwiftLint.
