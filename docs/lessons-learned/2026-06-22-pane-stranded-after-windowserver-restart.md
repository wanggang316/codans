# Lessons Learned: panes stuck on `/login` after a WindowServer restart

**Status:** Resolved
**Date:** 2026-06-22
**Area:** Runtime / session lifecycle (`SessionEpoch`, `SessionReaper`, `SessionCoordinator`)
**Fix:** PR #134 — `fix(runtime): preserve daemon session epoch across reattach`

## Summary

A pane's embedded coding agent (Claude Code) kept failing with `Please run
/login` / `401 Invalid authentication credentials`, while every other terminal
on the same machine, the same account, and the same network worked fine.
Quitting and relaunching the agent **in the same pane** did not help.

Root cause was two faults stacked on top of each other:

1. **macOS (trigger):** WindowServer hit a userspace-watchdog timeout and was
   force-restarted, which rotated the GUI login (audit) session **without a
   reboot**. The login keychain is unlocked per audit session; processes left
   behind in the dead session lose keychain access.
2. **codans (latent defect):** the machinery that was *supposed* to detect and
   recycle daemons stranded in a dead session was silently defeated — the
   daemon's birth-session stamp was overwritten with the live session on every
   reattach, so the reaper compared the live session against itself and never
   saw the strand.

The agent stores its OAuth token in the **login keychain**, so a pane whose
`zmx` daemon was stranded in the dead session could no longer read it →
`/login`. Network and the credential itself were fine the whole time.

## Impact

- Any pane whose `zmx` daemon was spawned **before** a login-session change and
  then reattached **after** it: the agent (and `ssh`, `gh`, anything that needs
  the login keychain or `getpwuid`) breaks inside that pane.
- Recurs on every session rotation (WindowServer crash, logout/login,
  fast-user-switch) while daemons survive — i.e. intermittently, and only for a
  subset of panes, which made it look like a flaky account/network problem.

## Why it was hard (the investigation, including the wrong turns)

The symptom pointed everywhere except the real cause. What was **ruled out**,
with evidence:

| Hypothesis | Probe | Verdict |
|---|---|---|
| codans terminal/pane layer | `pane info` / `--raw` render clean; input reaches the agent | not it |
| Network / proxy | `curl` to `api.anthropic.com` → clean `401`, 5x no RESET, no system proxy | not it |
| OAuth credential expired/revoked | hit the API with the keychain token directly → **`404` model-not-found, not `401`** (token authenticates) | not it |
| Env / project config override | broken pane's env identical to a healthy peer's; no `ANTHROPIC_BASE_URL`, no `apiKeyHelper` | not it |

Two **wrong hypotheses** were entertained and discarded before the real one —
worth recording so the next person skips them:

- *"Per-process stale in-memory OAuth token."* Predicted that restarting the
  agent in place would fix it. It did not — the new process inherited the same
  broken environment. (The shell stays a child of the stranded daemon, so a new
  agent process changes nothing.)
- *"The shared credential was revoked server-side."* Disproved by hitting the
  API with the keychain token directly and getting `404` (authenticated), not
  `401`.

The pivot: **headless `claude -p` worked from a normal shell but failed inside
the pane's shell** — same account, same binary. The only difference was the
*terminal environment*. That reframed the question from "what's wrong with the
agent/account" to "what's wrong with this shell's environment".

The decisive probes:

```
# inside a healthy shell            # inside the broken pane
launchctl managername  -> Aqua      launchctl managername  -> (Could not get manager name)
security find-generic-password -s "Claude Code-credentials" -w
                       -> OK (rc=0)                         -> FAIL (rc=44, errSecInteractionNotAllowed)
audit session id (getaudit_addr)
                       -> 107395                            -> 100022
```

Same directory, same account, same instant: one shell could read the keychain
and one could not. A **freshly created** pane came up in asid `107395` with
`KEYCHAIN_OK` and `claude -p` returned cleanly — proving the app and account
were healthy and only *pre-existing* panes were stranded.

The forensic timeline (no reboot in 7 days, per `kern.boottime` + `uptime`):

```
Jun 15 11:13   boot. GUI login session A = asid 100022
Jun 15–17      codans running; zmx daemons spawned in session A (ppid=1, setsid-detached)
Jun 17 23:08   the affected pane's daemon is born in session A (100022)
Jun 18 08:04   WindowServer userspace_watchdog_timeout (HIDEvents queue hung 40s) →
               WindowServer + loginwindow force-restart → GUI session B = asid 107395
               (machine NOT rebooted; detached zmx daemons survive in dead session A)
Jun 22 11:57   codans relaunched in session B; reattached to the surviving daemons
```

Evidence for the trigger: `/Library/Logs/DiagnosticReports/WindowServer_2026-06-18-080410_*.userspace_watchdog_timeout.spin`
(`Reason: ... unresponsive dispatch queue(s): com.apple.WindowServer.HIDEvents`),
and `last` showing the console session ending at `Jun 18 08:03`, with
`loginwindow`/`WindowServer` process start times at `Jun 18 08:03`.

## Root cause (the codans defect)

`SessionEpoch` + `SessionReaper` already implement exactly the right idea: stamp
each persisted `Session` row with the audit session id (asid) at spawn, and on
the next launch recycle any daemon whose stamp differs from the live session
(`SessionReaper.sweep` → `SessionEpoch.isStranded`). A recycled daemon is
killed and its row pruned, so bring-up respawns it clean in the live session.

That machinery never fired, because of one line in `SessionCoordinator.recordLive`:

```swift
// before
snapshot.sessions[session.paneID.raw.uuidString] = session   // stamps SessionEpoch.current() every write
```

`TerminalEngine.ensureSurface` cannot tell a fresh spawn from a reattach — zmx
`attach` is an opaque upsert ("reattach to a surviving daemon or create a fresh
one", no branch). So it always wrote the row with `sessionEpoch:
SessionEpoch.current()`. When the app reattached (in the *new* session) to a
daemon stranded in the *old* session, it **overwrote the daemon's birth epoch
with the live one**. The reaper then compared `current == current` and saw no
strand.

Confirmed on disk: all 28 rows in `~/.config/codans/sessions.json` carried the
current asid (`107395`) while the affected pane's daemon was actually in
`100022`.

## The fix

Treat `sessionEpoch` as **write-once birth identity**: `recordLive` carries the
existing stamp forward instead of overwriting it. Every other field
(`lastAttachedAt`, `pid`, …) still refreshes on reattach.

```swift
// after
var session = session
let key = session.paneID.raw.uuidString
if let bornEpoch = snapshot.sessions[key]?.sessionEpoch {
  session.sessionEpoch = bornEpoch          // preserve birth identity
}
snapshot.sessions[key] = session
```

Why this is sufficient and safe:

- When the reaper recycles a stranded daemon it **removes the row**, so the
  subsequent bring-up is a genuine fresh spawn that finds no prior row and
  stamps `current()` correctly.
- A dead daemon's row is always pruned at launch (liveness probe fails),
  independent of epoch — so a stale epoch can never pin a healthy fresh daemon
  to the wrong session.
- A `nil` legacy stamp stays adoptable (rows written before the field existed),
  matching `SessionEpoch`'s existing "unknown → skip, don't mass-recycle" rule.

## Verification

- `SessionCoordinatorEpochTests` — epoch preserved across reattach (a true
  regression test: fails on the pre-fix one-liner), fresh-stamp when no prior
  row, nil-is-adoptable.
- `SessionReaperStrandedTests` — end-to-end via a real listening Unix socket:
  alive + stale-epoch daemon is recycled (`.dead`, row pruned); alive +
  matching-epoch daemon is kept (`.alive`).
- Manual smoke (optional): poison a row's `sessionEpoch` in
  `~/.config/codans/sessions.json`, relaunch → Console logs
  `Recycling stranded daemon for pane …` and the daemon respawns clean.

## Limitations / follow-ups

- **Existing strands do not self-heal retroactively.** Rows already clobbered to
  the current asid stay until the *next* session rotation; a stranded pane that
  predates the fix still needs a one-time **close + reopen** (which spawns a
  fresh daemon in the live session).
- **The fix takes effect only once the app is rebuilt** from this branch and
  shipped.
- **Hardening (not in this PR):** have the `zmx` daemon report its own asid
  (ground truth) in its Info/handshake payload, so the app never relies on a
  persisted stamp that bring-up can clobber. Removes the entire class of
  "stamp got out of sync with the daemon" bugs. Requires a change to the `zmx`
  submodule.
- **Trigger frequency:** the WindowServer watchdog timeout correlated with
  heavy load (≈37 concurrent agent sessions on 16 GB). Reducing concurrent
  sessions / adding RAM lowers how often a session rotation happens, but the
  durable fix is resilience to the rotation, not preventing it.

## How to recognize a recurrence

Inside the suspect pane:

```bash
launchctl managername          # healthy: "Aqua";  stranded: "Could not get manager name."
security find-generic-password -s "Claude Code-credentials" -w >/dev/null \
  && echo OK || echo "STALE rc=$?"   # stranded: rc=44
```

A `STALE` result means the pane's daemon is in a dead audit session. With this
fix shipped, the launch-time reaper recycles it automatically; until then,
close + reopen the pane.
