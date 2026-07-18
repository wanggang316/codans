---
name: snapshot-and-exit-dogfood
description: Manual dogfood for the "Snapshot and exit" quit action (snapshot-and-exit-wireup). Confirms the 17 GUI-observable assertions the automated harness can't reach. Read docs/user-test-patterns.md first.
---

# Dogfood: "Snapshot and exit" end-to-end

**Feature:** Session lifecycle — quit snapshot + launch restore ([architecture.md](../architecture.md#session-lifecycle-quit-snapshot--launch-restore))
**Persona:** `dev_running_long_task`
**Why manual:** full-app launch → snapshot-quit → relaunch → restore is not in the automated harness. The mechanism is already proven by the real-zmx bats suite (`zig build test-integration`) and the Swift unit tests; this confirms the GUI round trip.

`<NAME>` below is `codans-dev` for a Debug build (`make mac-build`) or `codans` for a Release/installed build. Snapshots live at `~/Library/Caches/<NAME>/snapshots/<paneID>.snap`; logs subsystem is `com.gumpw.codans.runtime`.

## 0. Configure the snapshot tier (Settings UI — don't hand-edit settings.json while the app runs)

- Settings → General → **On quit → "Snapshot and exit"**.
- Settings → General → **Confirm on quit → "Never"** (so quit applies the action directly, no dialog).

## 1. Set up a pane with distinctive content + a known cwd

```bash
codans pane list                      # pick a PANE id; export it
P=<paneID>
codans pane send "$P" $'cd /tmp\r'                 # known cwd
codans pane send "$P" $'echo SMOKE-MARKER-42\r'    # distinctive visible content
codans pane send "$P" $'for i in $(seq 1 60); do printf "line-%03d\\n" $i; done\r'  # push line-001 into scrollback
sleep 1
codans pane read "$P" --raw | tail -5              # confirm SMOKE-MARKER-42 / line-060 are present
PID_PRE=$(codans pane info "$P" --json | jq -r .shellPid); echo "pre-quit shellPid=$PID_PRE"
```

## 2. Snapshot-and-exit, then inspect (producer: VAL-SNAP-001..006, 012)

```bash
SNAPDIR=~/Library/Caches/codans-dev/snapshots          # or .../codans/... for Release
# start a log capture in another shell BEFORE quitting:
#   log stream --predicate 'subsystem == "com.gumpw.codans.runtime"' --info | grep -iE 'zmx.snapshot|restore applied'
t0=$(date +%s)
osascript -e 'tell application "Codans" to quit'        # quitConfirmation=never → snapshot path
until ! pgrep -xq Codans; do sleep 0.2; done
echo "quit took $(( $(date +%s) - t0 ))s"              # VAL-SNAP-005: bounded (low single-digit s)
ls -l "$SNAPDIR"/"$P".snap                              # VAL-SNAP-001: one non-empty .snap for the pane
kill -0 "$PID_PRE" 2>/dev/null && echo "DAEMON STILL ALIVE (FAIL)" || echo "daemon gone (VAL-SNAP-002 ok)"
```

Expected: a non-empty `$P.snap`; daemon gone; quit fast; the log shows `zmx.snapshot send pane=$P` (VAL-SNAP-003).
Guard checks (optional): repeat with **"Keep session running"** → no new `.snap`, daemon alive (VAL-SNAP-011); with **"Cancel"** → app stays open, no `.snap`.
Degraded (optional): `clear` a pane before quit → that pane has no non-empty `.snap` and NO kill-fallback log, app still quits clean (VAL-SNAP-007). `chmod 0500 "$SNAPDIR"` before quit → clean quit, no stranded `*.tmp` (VAL-SNAP-008); restore the perms after.

## 3. Relaunch and verify restore (consumer: VAL-RESTORE-001/002/003/013/014, VAL-CROSS-001)

```bash
open -a Codans
# wait until the pane re-attaches (prompt cursor visible / spinner gone)
codans pane read "$P" --raw | grep -q SMOKE-MARKER-42 && echo "content restored (VAL-RESTORE-001 ok)"
codans pane read "$P" --raw | grep -q line-001       && echo "scrollback restored (VAL-RESTORE-002 ok)"
PID_POST=$(codans pane info "$P" --json | jq -r .shellPid)
[ "$PID_POST" != "$PID_PRE" ] && kill -0 "$PID_POST" && echo "fresh shell, PID differs (VAL-RESTORE-003 ok)"
codans pane info "$P" --json | jq -r .pwd            # VAL-RESTORE-004: equals /tmp (cwd preserved, no --cwd)
# log shows: zmx.restore applied pane=$P  (VAL-RESTORE-013)
```

Multi-pane (VAL-RESTORE-014 / VAL-CROSS-001): repeat with 2–3 panes in different worktrees/cwds, each with its own marker; after relaunch each pane shows ITS OWN marker (no cross-contamination) in ITS OWN cwd with a fresh PID.

Idempotency (VAL-RESTORE-009): after the restore, relaunch AGAIN (no new snapshot-quit) → the pane is clean (no stale frame re-applied), and the `.snap` is gone.

## Assertion coverage

| Step | Assertions |
|---|---|
| 2 (quit + inspect) | VAL-SNAP-001 (.snap written), -002 (daemon down), -003 (snapshot-send log), -004/-005 (all panes, bounded), -006 (wedged→fallback log, fault-inject SIGSTOP a daemon), -007/-008/-009 (degraded/double-quit), -010 (SIGTERM), -011/-012 (no-leak guards / agents persisted) |
| 3 (relaunch) | VAL-RESTORE-003 (PID differs), -013 (restore log), -014 (multi-pane), VAL-CROSS-001 (round trip); re-confirms M1 VAL-RESTORE-001/002/004 at the app layer; VAL-RESTORE-009 (no re-restore) |

A green run on steps 2–3 confirms the 17 currently-blocked assertions.
