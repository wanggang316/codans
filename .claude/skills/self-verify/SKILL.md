---
name: self-verify
description: Explicitly verify a codans change end to end in an isolated Debug instance (private config, cache, and socket) through the bundled codans-dev CLI, PID-scoped Accessibility, and window screenshots. Use only when the user asks for self-verify, end-to-end verification against a running Debug build, or to drive and check codans UI behavior (Settings, popovers, menus, toolbar, sidebar). Do not invoke after ordinary implementation work, and do not use it in place of unit tests, make mac-check, or make mac-build.
---

# Self Verify

## Invocation Contract

Run this skill only after an explicit user request. A request to implement, fix, test, or build does not authorize it.
It is an opt-in layer on top of focused tests and `make mac-build`: it launches a real GUI app, so it is slower and
less deterministic than those checks.

Every scenario ends with one outcome:

- `PASS`: each assertion has direct evidence.
- `FAIL`: the observed result contradicts an assertion.
- `SKIPPED`: a precondition (build, permission) is missing, so no action ran.
- `INCONCLUSIVE`: the action ran, but the evidence cannot prove or disprove the assertion.

Never turn missing evidence into `PASS`. An action that returns `ok` is delivery telemetry, not evidence.

## Define the Scenario First

Before you build or launch, write a short contract per scenario:

1. Setup: fixture repo, project, worktree, tab, pane, and settings.
2. Action: the exact CLI command, AX command, or guarded physical input.
3. Assertions: terminal text, CLI JSON fields, AX labels or values, window titles, or pixels.
4. Evidence source: `codans_debug`, `sv-tool`, a window screenshot, or a log marker.
5. Cleanup: what the scenario changed and how it goes back.

Keep scenarios narrow. "The app launched" or "the UI looks right" is not an assertion.

## Safety Rules

Gump works in the release app and in dev builds while you test. These rules protect them:

- Address the instance by PID only. Release, dev, and test instances are all named `Codans`, and System Events
  specifiers (including `whose unix id is`) resolve by name and land on the release app. Never use `osascript`,
  `pkill`, `killall`, `open -a Codans`, or title-based targeting.
- Keep config, cache, and socket private (the helpers do). The default dev cache holds Gump's zmx sessions, and a
  test instance on it kills them at launch. The default dev socket is Gump's dev app.
- Do not take focus. Semantic commands never activate the app. Use physical input only when no semantic action
  exists, and only through `sv_click` / `sv_hover`.
- Never send bare keystrokes or key codes: they go to the frontmost app, which can be Gump's terminal.
  A modifier gesture (hold ⌘) can go to the instance only: post a `flagsChanged` `CGEvent` with
  `postToPid(<instance pid>)`. The inactive instance drops some of these events, so log what the app receives
  and compare each screenshot with the received state, not with what you posted.
- Do not launch a real agent, clone, or touch `~/.codans` unless the scenario requires it and restores it.
- Preserve unrelated working-tree changes. Do not run `xcodebuild test` while an instance runs: it rewrites the
  Debug bundle under it.

## Launch

From the repository root, after `make mac-build`:

```bash
. .claude/skills/self-verify/scripts/helpers.sh
sv_seed_settings                 # scratch settings: worktrees in scratch, no fetch, no update checks
fixture="$(sv_fixture_repo)"     # fixtures/repo-multi-branch.bundle: main, feat/header-redesign (HEAD),
                                 # bugfix/menu, origin/* refs without a URL
sv_launch                        # private paths; refuses a busy socket; checks uptime and socket owner
```

Source the helpers again in every new shell. In a scenario script, add `trap sv_cleanup EXIT` right after
`sv_launch`, and do not pipe the script into `head`: SIGPIPE ends it before cleanup and leaves the instance
running.

Default paths are private to the session, so parallel sessions in the same or different worktrees each run their
own instance, and one session's `sv_cleanup` never touches another session's files or processes:
`SELF_VERIFY_DIR` is `$TMPDIR/codans-self-verify-<uid>-<token>`, the socket is `/tmp/cdv-sv-<uid>-<token>.sock`,
and the cache is `/tmp/cdv-sv-cache-<uid>-<token>`. The token is a hash of the worktree root and the session id:
`SELF_VERIFY_SESSION` if set, else `CLAUDE_CODE_SESSION_ID`, else the session's anchor process. The anchor is the
nearest ancestor that is not a shell or a command wrapper (`env`, `nohup`, `make`, ...), taken as PID plus start
time: the agent process for an agent (each Bash call is a child shell of it), the terminal's `login` for a person.
So every shell and script of one session sources the helpers to the same paths, and two sessions never do, with no
setup. Terminal and pane ids (`TERM_SESSION_ID`, `CODANS_PANE_ID`) are not used: every agent that an engine starts
from one pane inherits them. Set `SELF_VERIFY_SESSION` when steps of one session run under different anchors, for
example a step detached to launchd. Socket and cache paths stay short: zmx puts one socket per pane in the cache
dir and AF_UNIX paths are capped at 104 bytes. Explicit `SELF_VERIFY_DIR`, `SELF_VERIFY_SOCKET`, and
`SELF_VERIFY_CACHE` override the defaults; set them before sourcing.

The helpers launch the Debug `Codans.app` of the worktree you source them in. `sv_app` asks
`xcodebuild -showBuildSettings` (Debug, scheme `Codans`) for the app path from `git rev-parse --show-toplevel`, and
caches the worktree root and the app path in `$SELF_VERIFY_DIR/app-path`. It reuses the cache only for the same
worktree root and only while the app exists, so worktrees that share an explicit `SELF_VERIFY_DIR` each launch their
own build. Set `SELF_VERIFY_APP` to launch a different bundle; it skips resolution and the cache.

`sv_launch` records the front app and gives focus back if the instance took it. It snapshots the shared
`com.gumpw.codans` defaults domain; `sv_cleanup` restores only the keys that changed.

## Choose the Control Surface

Use the smallest surface that can prove the assertion:

1. `codans_debug`: projects, worktrees, tabs, panes, terminal input and output, agent state. It is the Debug
   bundle's `codans-dev` on the private socket, with the calling pane's context removed. Read
   `skills/codans-cli/SKILL.md` before you write commands; it owns flags, JSON fields, and exit codes.
2. Semantic AX (`sv_tree`, `sv_find`, `sv_press`, `sv_action`, ...): native UI labels, values, selection, popovers, menus,
   Settings. Read [references/ui.md](references/ui.md) before a UI scenario.
3. Guarded physical input (`sv_click`, `sv_hover`): only for tap gestures and hover-revealed controls.
4. Window screenshot (`sv_screenshot`): only for geometry, clipping, or visual hierarchy.
5. Log marker: only when neither CLI nor AX exposes the behavior.

A screenshot does not prove that a control is enabled, selected, or wired.

## Drive the Terminal with the CLI

```bash
project="$(codans_debug project add "$fixture" --json | jq -r '.data.id')"
worktree="$(codans_debug tree --json | jq -r '.data.projects[0].worktrees[0].id')"
tab="$(codans_debug tab new sv --project "$project" --worktree "$worktree" --json | jq -r '.data.id')"
pane="$(codans_debug pane new --project "$project" --worktree "$worktree" --tab "$tab" --cwd "$fixture" --json |
  jq -r '.data.id')"
codans_debug pane send "$pane" 'printf "SV:%s\n" "$PWD"' --capture --json | jq -r '.data.output'
codans_debug pane focus "$pane"  # brings the worktree and tab into view for AX and screenshots
```

- `pane new` uses the caller's `$PWD` without `--cwd`, so always pass `--cwd`.
- `tab new` creates no pane. Take ids only from the JSON your scenario created.
- Assert a unique marker, cwd, or env value for command routing. For hierarchy changes, compare `tree --json`
  before and after.
- Parse JSON with pipes or `printf '%s\n' "$json" | jq`, not `echo` (zsh rewrites escapes).
- A pane dies at spawn when the cache path is too long: `tree` shows it, then `pane read` says not found.

## Full CLI Regression

`cli-regression/harness.sh <Debug Codans.app> all` drives every `codans-dev` verb on its own isolated instance
and checks exit codes, output, and the JSON schema. Run it when the CLI, the RPC protocol, or the published
`codans-cli` skill changes; see `cli-regression/README.md`. Do not run it while another instance from this
skill uses the same build.

## Screenshots and Logs

```bash
sv_screenshot "$SELF_VERIFY_DIR/main.png"                # first instance window, by window id
sv_screenshot "$SELF_VERIFY_DIR/settings.png" General    # window whose title contains "General"
```

The capture uses `screencapture -l <window id>` from a PID-filtered CGWindowList: it does not raise the window,
and other apps cannot leak into it. Review the image only for the declared visual assertion.

The app log is `$SELF_VERIFY_DIR/app.log` (stdout and stderr only). For unified logs use `/usr/bin/log` (the shell
`log` is a function) with a predicate on a marker specific to the change. Default-level messages are not
persisted, so use `log stream` during the action, not `log show` after it.

## Crash Check

A UI step that returns, or an AX walk that prints a complete tree, does not prove that the instance did not crash:
the app can crash a moment later. Bracket any step that can crash (an AX walk, a new pane, a Settings screen):

```bash
sv_crash_mark                    # records the instance PID and the existing Codans-*.ips reports
sv_tree --window Settings >"$SELF_VERIFY_DIR/tree.txt"
sv_crash_check                   # waits 3 s, then exits 1 when the instance is gone or a new report names its PID
```

On failure, `sv_crash_check` prints the new report path from `~/Library/Logs/DiagnosticReports`, the exception,
and the top crashed-thread frames to stderr. When the instance is gone, it waits for ReportCrash up to 15 s more;
"no new Codans-*.ips report" then means it died without a report (for example SIGKILL). Release, dev, and test
instances all write `Codans-*.ips`, so reports from before the mark and reports of other PIDs do not count.
Settings: `SELF_VERIFY_CRASH_SETTLE` (seconds before the check, default 3), `SELF_VERIFY_CRASH_WAIT` (default 15),
`SELF_VERIFY_CRASH_FRAMES` (default 15), `SELF_VERIFY_CRASH_DIR` (report dir). Call `sv_crash_mark` again before
the next step: a check compares with the last mark.

## Cleanup

```bash
sv_cleanup
```

It closes every pane of the instance, stops it, stops processes that hold files in the private cache (zmx daemons),
restores changed defaults keys, and removes the socket, cache, and scratch dir (`SELF_VERIFY_KEEP_DIR=1` keeps the
scratch dir). Report any line it prints about a process still alive.

## Report

For each scenario: outcome, assertions with their direct evidence (CLI JSON, AX line, window title, screenshot
path), the control surfaces used, any physical input or retry, and cleanup status. For UI scenarios add the
`UI Evolution` section from [references/ui.md](references/ui.md). Keep build, lint, and unit-test results separate
from end-to-end outcomes.

## Maintain This Skill

When you change the scripts, run their tests:

```bash
bash .claude/skills/self-verify/tests/helpers_test.sh    # lifecycle, fake app and CLI, ~5 s
bash .claude/skills/self-verify/tests/sv_tool_test.sh    # every sv-tool command on a SwiftUI fixture
SV_TEST_PHYSICAL=1 bash .claude/skills/self-verify/tests/sv_tool_test.sh   # adds click and hover
bash .claude/skills/self-verify/tests/smoke_test.sh      # real Debug build, end to end, ~25 s
```

Edit the relevant rule in place when a run teaches something durable; do not append a dated field note.
