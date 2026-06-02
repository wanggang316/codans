---
name: pane-resume
description: User-test set for Pane Resume. Authored by /hs-test-spec. Read `docs/user-test-patterns.md` for project-wide testing conventions before editing.
---

# User Tests: Pane Resume

**Status:** Approved
**Author:** Gump
**Date:** 2026-05-24
**Spec:** [docs/product-specs/pane-resume.md](../product-specs/pane-resume.md)
**Design:** [docs/design-docs/pane-resume.md](../design-docs/pane-resume.md)

## Personas Used

- `dev_running_long_task` — primary persona; covers live tier, force-quit recovery, reaper, VT-state fidelity, and explicit close
- `settings_tweaker` — drives the snapshot-tier path by flipping the "Resume panes on launch" toggle off

No new personas added.

## Journeys

### Journey 1: A long-running shell survives cmd-Q

**Persona:** `dev_running_long_task`
**Outcome:** After quitting touch-code while a `tail -f` is running and then relaunching, the same shell process is still attached to the same pane and is still streaming output that was produced while the app was closed.

#### Case `UT-PANE-RESUME-001`: Live tier — running shell + output stream survive cmd-Q

**Covers AC:** AC1

**Preconditions:**
- App started; ready signal per `docs/user-test-patterns.md` ("App launched")
- `~/.config/touch-code/settings.json` seeded so `general.resumePanesOnLaunch` is `true` (default)
- Catalog seeded with `docs/user-tests/pane-resume/fixtures/single-pane-catalog.json` (one Project, one Worktree, one Tab, one Pane); pane is attached (ready signal "Pane attached")
- A test log file `/tmp/touch-code-test-001.log` exists, empty (mode 0644)

**Steps:**
1. In the open pane, run `tail -f /tmp/touch-code-test-001.log` followed by Enter (via `tc pane send <paneID> $'tail -f /tmp/touch-code-test-001.log\r'`)
2. Wait until `log stream --predicate 'subsystem == "com.touch-code.runtime"' --info` emits a line matching `pane=<paneID> .*foreground_command=tail` (signals the daemon recognised the foreground process)
3. Capture the pane's shell PID: `PID_PRE=$(tc pane info <paneID> --json | jq -r '.shellPid')`
4. Capture the daemon's socket path: `SOCK=$(jq -r '.sessions["<paneID>"].socketPath' ~/.config/touch-code/sessions.json)`
5. Quit the app via the Quit menu item (or AppleScript `tell application "TouchCode" to quit`)
6. Wait until `pgrep -x TouchCode` returns empty
7. From a shell outside the app: `echo "marker-after-quit" >> /tmp/touch-code-test-001.log`
8. Relaunch the app via `open -a TouchCode`, wait for ready signal
9. Wait until the pane re-attaches (ready signal "Pane attached")
10. Capture content: `tc pane read <paneID> --tail 20 --json | jq -r '.content' > /tmp/pane-content-after.txt`

**Assertions:**
1. (Process) After step 6 the app is gone but `kill -0 "$PID_PRE"` exits 0 — the daemon's shell process survived app quit
2. (File) After step 6, `"$SOCK"` exists and is a socket file (`test -S "$SOCK"`)
3. (CLI) After relaunch, `tc pane info <paneID> --json | jq -r '.shellPid'` equals `"$PID_PRE"`
4. (File) `tc pane read <paneID> --tail 20` output contains the literal string `marker-after-quit`
5. (File) `~/.config/touch-code/sessions.json` `.sessions["<paneID>"].pid` equals `"$PID_PRE"` and `.sessions["<paneID>"].lastAttachedAt` is within the last 60s

**Artifacts on FAIL:**
- `sessions.json.snapshot.json` — copy of the sessions catalog at failure time
- `pane-content-after.txt` from step 10
- `ps-zmx.txt` from `ps -eo pid,ppid,sid,command | grep -E '(zmx|TouchCode)' > ps-zmx.txt`
- `runtime.log` from `log stream --predicate 'subsystem == "com.touch-code.runtime"' --last 5m`

---

### Journey 2: Snapshot tier — visual replay when Resume disabled

**Persona:** `settings_tweaker`
**Outcome:** With "Resume panes on launch" turned off, quitting causes the daemon to serialize and exit; on relaunch the visible buffer + scrollback are restored exactly, but the shell PID has changed.

#### Case `UT-PANE-RESUME-002`: Snapshot tier — buffer faithfully replayed; PID differs

**Covers AC:** AC2

**Preconditions:**
- App started; ready signal "App launched"
- `settings.json` seeded so `general.resumePanesOnLaunch` is `false` (the persona flipped it off in this session, or seeded directly)
- Catalog seeded with `docs/user-tests/pane-resume/fixtures/single-pane-catalog.json`
- Pane attached (ready signal "Pane attached")

**Steps:**
1. In the open pane, run: `tc pane send <paneID> $'echo "first line"; echo -e "\\033[33mSECOND-LINE\\033[0m"\r'`
2. Wait until `tc pane read <paneID> --tail 4` includes both lines
3. Capture the full pane buffer: `BUFFER_PRE=$(tc pane read <paneID> --raw)` (raw VT, no normalization)
4. Capture shell PID: `PID_PRE=$(tc pane info <paneID> --json | jq -r '.shellPid')`
5. Quit the app via the Quit menu item
6. Wait until `pgrep -x TouchCode` returns empty
7. Wait until the snapshot file appears: `~/Library/Caches/touch-code/snapshots/<paneID>.snap` (poll up to 5s)
8. Confirm the daemon's PID `$PID_PRE` is gone: `kill -0 "$PID_PRE"` returns nonzero
9. Relaunch the app via `open -a TouchCode`, wait for ready signal and "Pane attached"
10. Capture the new buffer: `BUFFER_POST=$(tc pane read <paneID> --raw)`
11. Capture the new shell PID: `PID_POST=$(tc pane info <paneID> --json | jq -r '.shellPid')`

**Assertions:**
1. (File) After step 7, the snapshot file exists and is non-empty (`test -s ~/Library/Caches/touch-code/snapshots/<paneID>.snap`)
2. (Process) After step 8, `$PID_PRE` is no longer a live process
3. (String compare) `BUFFER_PRE` matches the first N rows of `BUFFER_POST` (where N = rows visible at quit) — visual content is preserved byte-for-byte. (The case runner is responsible for trimming the new shell's fresh prompt line.)
4. (CLI) `$PID_POST` is a valid PID (`kill -0 "$PID_POST"` returns 0) AND `$PID_POST` != `$PID_PRE`
5. (File) `~/.config/touch-code/sessions.json` `.sessions["<paneID>"].pid` equals `$PID_POST` (new daemon adopted the same paneID)

**Artifacts on FAIL:**
- Copy of `<paneID>.snap` to artifacts
- `BUFFER_PRE.txt` and `BUFFER_POST.txt`
- `sessions.json.snapshot.json`
- `runtime.log`

---

### Journey 3: VT-state fidelity on replay

**Persona:** `dev_running_long_task`
**Outcome:** Esoteric terminal state — custom palette, alt screen, OSC 7 pwd, scrolling region — survives a quit+relaunch under both tiers.

#### Case `UT-PANE-RESUME-003`: Scrollback content + cursor position preserved (live tier)

**Covers AC:** AC7

**Preconditions:**
- App started; `resumePanesOnLaunch=true`
- Single-pane fixture (as in UT-PANE-RESUME-001)
- Pane attached

**Steps:**
1. Produce 200 lines of distinctive output: `tc pane send <paneID> $'for i in $(seq 1 200); do printf "line-%03d\\n" "$i"; done\r'`
2. Wait until `tc pane read <paneID> --tail 1` contains `line-200`
3. Move cursor mid-line and emit a partial-line marker: `tc pane send <paneID> $'printf "PARTIAL"; printf "\\r"; printf "X"\r'`
4. Capture buffer + cursor: `tc pane info <paneID> --json > /tmp/pane-info-pre.json`; `tc pane read <paneID> --raw --full > /tmp/buffer-pre.txt`
5. cmd-Q the app, wait until process is gone
6. Relaunch, wait for "Pane attached"
7. Capture again: `tc pane info <paneID> --json > /tmp/pane-info-post.json`; `tc pane read <paneID> --raw --full > /tmp/buffer-post.txt`

**Assertions:**
1. (CLI) `jq -r '.cursor.row' /tmp/pane-info-pre.json` equals `jq -r '.cursor.row' /tmp/pane-info-post.json` (cursor row preserved)
2. (CLI) `jq -r '.cursor.col' /tmp/pane-info-pre.json` equals `jq -r '.cursor.col' /tmp/pane-info-post.json` (cursor column preserved — `PARTIAL\rX` should leave cursor after the X)
3. (CLI) `diff /tmp/buffer-pre.txt /tmp/buffer-post.txt` produces no output (byte-for-byte buffer match including scrollback)
4. (CLI) `tc pane read <paneID> --range scrollback --tail 1` contains `line-001` (the oldest line scrolled out is still in scrollback)

**Artifacts on FAIL:**
- `buffer-pre.txt`, `buffer-post.txt`, `pane-info-pre.json`, `pane-info-post.json`
- Diff output saved as `buffer.diff`

#### Case `UT-PANE-RESUME-004`: Terminal modes + OSC 7 pwd preserved across quit

**Covers AC:** AC7

**Preconditions:**
- Same as UT-PANE-RESUME-003

**Steps:**
1. Enable application keypad mode and an alt screen marker: `tc pane send <paneID> $'printf "\\033[?1049h"; printf "ALT-SCREEN-MARKER\\n"\r'` (enter alt screen, write marker)
2. Set a non-trivial cwd: `tc pane send <paneID> $'cd /tmp\r'` (shell integration emits OSC 7)
3. Wait until `tc pane info <paneID> --json | jq -r '.pwd'` equals `/tmp`
4. cmd-Q app, wait until gone
5. Relaunch, wait for "Pane attached"
6. Capture state: `tc pane info <paneID> --json > /tmp/info-post.json`; `tc pane read <paneID> --raw --range visible > /tmp/visible-post.txt`

**Assertions:**
1. (CLI) `jq -r '.pwd' /tmp/info-post.json` equals `/tmp`
2. (File) `/tmp/visible-post.txt` contains the literal `ALT-SCREEN-MARKER`
3. (CLI) `jq -r '.modes.altScreen' /tmp/info-post.json` equals `true`

**Artifacts on FAIL:**
- `info-post.json`, `visible-post.txt`
- `runtime.log`

---

### Journey 4: Explicit close cleans up daemon

**Persona:** `dev_running_long_task`
**Outcome:** When the user closes a pane intentionally (UI or CLI), the daemon, its socket, and its catalog entry are all gone within a small bounded time.

#### Case `UT-PANE-RESUME-005`: `tc pane close` removes daemon, socket, and catalog entry within 2s

**Covers AC:** AC4

**Preconditions:**
- App started; `resumePanesOnLaunch=true`
- Single-pane fixture; pane attached
- `PID=$(tc pane info <paneID> --json | jq -r '.shellPid')`
- `SOCK=$(jq -r '.sessions["<paneID>"].socketPath' ~/.config/touch-code/sessions.json)`

**Steps:**
1. `tc pane close <paneID>`
2. Wait up to 2s for `kill -0 "$PID"` to fail (use a short polling loop, not a fixed sleep)
3. Reread sessions.json

**Assertions:**
1. (Process) Within 2s of step 1, `kill -0 "$PID"` returns nonzero (daemon child + daemon process gone)
2. (File) After step 2, `test -S "$SOCK"` is false (socket file unlinked)
3. (File) `jq -e '.sessions["<paneID>"] == null' ~/.config/touch-code/sessions.json` succeeds (entry removed)
4. (File) No matching snapshot file at `~/Library/Caches/touch-code/snapshots/<paneID>.snap` (explicit close should NOT leave a snapshot)

**Artifacts on FAIL:**
- `ps-zmx.txt` from `ps -eo pid,ppid,sid,command | grep zmx`
- `sessions.json.snapshot.json`
- `runtime.log`

---

### Journey 5: Reaper removes stale sessions

**Persona:** `dev_running_long_task`
**Outcome:** A daemon that has been detached for more than the reaper threshold (7 days default) gets killed and removed on next app launch; the pane (if still in catalog) cold-starts at the last known cwd.

#### Case `UT-PANE-RESUME-006`: 7-day-stale session is reaped on launch

**Covers AC:** AC3

**Preconditions:**
- App is NOT running (`pgrep -x TouchCode` returns empty)
- A daemon for a fake pane is running with `lastAttachedAt` 8 days in the past:
  - Seed `~/.config/touch-code/catalog.json` with a single pane `STALE-PANE-ID` at cwd `/tmp`
  - Spawn a daemon manually: `ZMX_DIR=~/Library/Caches/touch-code/zmx-sessions ./TouchCode.app/Contents/Resources/bin/zmx serve STALE-PANE-ID --cwd /tmp`
  - `STALE_PID=$(jq -r '.sessions["STALE-PANE-ID"].pid' ...)` — wait, no, this is pre-launch; the case-runner constructs `sessions.json` by hand with `lastAttachedAt = now - 8d`
  - Capture `STALE_PID=$(pgrep -f 'zmx serve STALE-PANE-ID')`

**Steps:**
1. Launch the app: `open -a TouchCode`, wait for ready signal
2. Wait until `log stream --predicate 'subsystem == "com.touch-code.runtime"' --info` emits a line containing `reaper killed session=STALE-PANE-ID` (or the chosen log marker)
3. Activate the stale pane via the UI (or `tc pane focus STALE-PANE-ID`)
4. Wait for "Pane attached"
5. Capture new state: `tc pane info STALE-PANE-ID --json > /tmp/info-after-reap.json`

**Assertions:**
1. (Process) After step 2, `kill -0 "$STALE_PID"` returns nonzero (old daemon killed)
2. (File) `jq -r '.sessions["STALE-PANE-ID"]' ~/.config/touch-code/sessions.json` is `null` initially (then re-populated by the cold start in step 3 with a new pid)
3. (File) No snapshot left for STALE-PANE-ID: `test ! -f ~/Library/Caches/touch-code/snapshots/STALE-PANE-ID.snap`
4. (CLI) After step 5, `jq -r '.shellPid' /tmp/info-after-reap.json` is a valid live PID and is NOT equal to `$STALE_PID`
5. (CLI) `jq -r '.pwd' /tmp/info-after-reap.json` equals `/tmp` (last cwd from catalog preserved as cold-start cwd)

**Artifacts on FAIL:**
- `sessions.json.snapshot.json` before and after launch (named `sessions-pre.json`, `sessions-post.json`)
- `runtime.log` filtered on `category:"reaper"` if that subcategory exists

---

### Journey 6 (negative): Second app instance cannot double-attach

**Persona:** `dev_running_long_task`
**Outcome:** A second `TouchCode.app` process launched while the first is running cannot attach to the first instance's daemons; the second instance either declines its panes or cold-starts them. No daemon serves two clients in v1.

#### Case `UT-PANE-RESUME-007`: Second instance fails to attach to a held daemon

**Covers AC:** AC6

**Preconditions:**
- App is running with the single-pane fixture; pane attached
- `PID=$(tc pane info <paneID> --json | jq -r '.shellPid')`

**Steps:**
1. Launch a second instance: `open -n -a TouchCode` (the `-n` forces a new instance)
2. Wait until two `TouchCode` processes exist: `pgrep -x TouchCode | wc -l` returns `2`
3. Capture the second instance's view of the pane: in the second instance, query `tc pane info <paneID> --json --instance second > /tmp/second-info.json` (the `--instance` flag is a precondition for this case; the runner is responsible for routing to the right socket)
4. Capture the first instance's pane: `tc pane info <paneID> --json > /tmp/first-info.json`

**Assertions:**
1. (Process) After step 1, the original daemon `$PID` is still alive (`kill -0 "$PID"` succeeds)
2. (CLI) `/tmp/first-info.json` `.shellPid` still equals `$PID`
3. (CLI) Either:
   - The second instance reports the pane as `state: "rejected"` (preferred) — `jq -r '.state' /tmp/second-info.json` equals `rejected`
   - OR the second instance cold-started a separate pane with a different PID — `jq -r '.shellPid' /tmp/second-info.json` is NOT equal to `$PID`
   The runner picks whichever branch applies based on what the second instance actually does; both are acceptable per spec, but ONE must hold.
4. (File) `~/.config/touch-code/sessions.json` `.sessions["<paneID>"].pid` is still `$PID` (was not corrupted by the second instance)

**Artifacts on FAIL:**
- `first-info.json`, `second-info.json`
- `ps-touchcode.txt` from `ps -eo pid,ppid,command | grep TouchCode`
- `runtime.log` from both instances (`--last 5m`)

---

### Journey 7: Force-quit recovery

**Persona:** `dev_running_long_task`
**Outcome:** When the user `kill -9`s the app, any daemons that were already running survive (they are detached from the app's process group); on relaunch the panes re-attach.

#### Case `UT-PANE-RESUME-008`: `kill -9` followed by relaunch restores running daemons

**Covers AC:** AC8

**Preconditions:**
- App started; `resumePanesOnLaunch=true`
- Single-pane fixture; pane attached; the shell is busy: `tc pane send <paneID> $'while true; do echo tick; sleep 1; done\r'`
- Wait until `tc pane read <paneID> --tail 1` includes `tick` (signals the daemon is forwarding output)

**Steps:**
1. Capture state: `PID=$(tc pane info <paneID> --json | jq -r '.shellPid')`; `SOCK=$(jq -r '.sessions["<paneID>"].socketPath' ~/.config/touch-code/sessions.json)`
2. Force-kill the app: `kill -9 $(pgrep -x TouchCode)`
3. Wait until `pgrep -x TouchCode` is empty
4. Confirm daemon survival: `kill -0 "$PID"` returns 0 (within 2s of step 2)
5. Relaunch: `open -a TouchCode`, wait for ready signal
6. Wait for "Pane attached"
7. Capture: `tc pane info <paneID> --json | jq -r '.shellPid'` and `tc pane read <paneID> --tail 3`

**Assertions:**
1. (Process) Step 4 succeeds — daemon survived `kill -9`
2. (File) `"$SOCK"` exists after step 4 (`test -S "$SOCK"`)
3. (CLI) After relaunch, the pane's reported PID equals `$PID`
4. (CLI) `tc pane read <paneID> --tail 3` shows more `tick` lines than at step 1 (output continued accumulating while app was dead)
5. (File) `sessions.json` `.sessions["<paneID>"].lastAttachedAt` is bumped to within the last 60s

**Artifacts on FAIL:**
- `sessions.json.snapshot.json`
- `pane-content-after.txt`
- `ps-zmx.txt`
- `runtime.log`

---

## Coverage Matrix

| Spec AC | Covered by |
|---|---|
| AC1 | UT-PANE-RESUME-001 |
| AC2 | UT-PANE-RESUME-002 |
| AC3 | UT-PANE-RESUME-006 |
| AC4 | UT-PANE-RESUME-005 |
| AC5 | — verified by perf-budget gate (P99 keystroke-to-glyph < 50ms); not a user-observable case per `docs/user-test-patterns.md` |
| AC6 | UT-PANE-RESUME-007 |
| AC7 | UT-PANE-RESUME-003, UT-PANE-RESUME-004 |
| AC8 | UT-PANE-RESUME-008 |

## Personas / Fixtures Added During Authoring

- No new personas added.
- Added fixture directory `docs/user-tests/pane-resume/fixtures/` with:
  - `single-pane-catalog.json` — minimal catalog (one Project, one Worktree, one Tab, one Pane) used by UT-PANE-RESUME-001/002/003/004/005/007/008
  - Runner instructions for UT-PANE-RESUME-006 to seed `sessions.json` with a forged `lastAttachedAt` 8 days in the past

The fixture file itself is produced during implementation (planner Task: "seed fixtures") — not by this skill.

## Open Questions

1. **Does the spec require live-tier resume to also survive crash-only scenarios where the app died before the daemon was spawned?** *Default:* AC8 already covers crashes after daemon spawn; daemon-not-yet-spawned panes cold-start (no coverage gap, but worth noting to PM).
2. **For UT-PANE-RESUME-007 (second app instance), is the preferred behaviour "second instance rejects the pane" or "second instance cold-starts the pane in isolation"?** *Default:* either is acceptable per spec; case asserts the "OR" branch. The PM may want to pin one. If pinned, split this case into one positive case per branch.
3. **Should snapshot-tier replay (UT-PANE-RESUME-002) tolerate the daemon prepending a divider line ("─── new shell ───") above the fresh prompt, per OQ5 in the design doc?** *Default:* assertion 3 trims the fresh-prompt section before diffing, allowing any number of decorative lines below the historical buffer. If OQ5 lands "no divider", tighten the trim to "exactly one new prompt line".
4. **Does `tc pane read` need a `--raw` option to expose VT escape sequences un-normalized for byte-equality assertions (UT-PANE-RESUME-003 assertion 3)?** *Default:* yes — this is a precondition for the case to pass. Surface to planner as a tc CLI addition.

---

**Downstream:**
- `/hs-planner` binds tasks to these case IDs (UT-PANE-RESUME-001…008) and adds `tc pane read --raw` / `tc pane close` / `tc pane info --json` / `--instance` to the CLI surface as task dependencies.
- The runtime validator subagent (`hs-user-test`) executes these cases against a built app.
