---
name: active-agents-view
description: User-test set for the ActiveAgents view — in-app status-bar badge + hover popover that lists every Pane running a known agent (Claude Code / Codex / pi) with derived runtime state. Authored by /hs-test-spec. Read docs/user-test-patterns.md for project-wide testing conventions before editing.
---

# User Tests: ActiveAgents View

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-05-22
**Spec:** [docs/product-specs/active-agents-view.md](../product-specs/active-agents-view.md)
**Design:** [docs/design-docs/active-agents-view.md](../design-docs/active-agents-view.md)

## Personas Used

- `dev_running_long_task` — the only persona referenced. Drives every journey below: identifying agent panes, watching headline transitions, hovering for popover, clicking rows, and verifying parallel-independence from notifications. Defaults align with v1 out-of-the-box settings; no per-case overrides required.

No new persona or fixture was introduced by this document.

## Test Surface — local conventions for this feature

Per [user-test-patterns.md](../user-test-patterns.md), this set probes three surfaces:

- **SwiftUI window UI** — the ActiveAgents badge in `WorktreeHeader`, the hover popover, and its rows. Selectors are accessibility identifiers / role+label pairs / unambiguous on-screen text. The required accessibility identifiers (declared by the implementation as a precondition for these cases to be runnable) are:
  - `activeAgents.badge` — the status-bar entry (the headline view)
  - `activeAgents.popover` — the popover container
  - `activeAgents.row.<paneID>` — one identifier per popover row
  - `activeAgents.row.<paneID>.state` — the state icon in that row, with `accessibilityLabel` ∈ {`waitingForInput`, `loading`, `finished`, `idle`}
  - `activeAgents.row.<paneID>.headline` — the `<Project> / <Worktree>` line
- **Persisted state** — `~/.config/touch-code/catalog.json` queried with `jq` to verify the `agentKind` / `agentSessionID` fields on a Pane survive a relaunch.
- **Log stream** — `log stream --predicate 'subsystem == "com.touch-code.activeagents"' …` for identification / state-transition trace lines, used as a ready signal where the UI alone is ambiguous.

A "trigger an OSC 9;4 busy report on pane P" step means: drive `printf '\e]9;4;3\a'` into pane P (via the `tc` CLI's pane-input verb or by typing it into the pane chrome); the matching "clear" step drives `printf '\e]9;4;0\a'`. These exact escape sequences are documented in [memory: OSC 9;4 emitter coverage](../../.claude/projects/-Users-wanggang-dev-00-touch-code/memory/project_osc94_emitters.md) and have a manual test recipe verified by Gump on 2026-05-03.

A "drive a `waitingForInput`-class OSC 9 event on pane P" step means: send `printf '\e]9;Approve this action\a'` into pane P. The title text `"Approve"` causes `DetectionTranslator.classify` to label the event as `waitingForInput` rather than `taskFinished`.

A "make pane P appear to be running agent A" precondition means: at pane creation time, set `initialCommand` to the bare agent name (`claude`, `codex`, or `pi`) via `tc tab new --command <name>`. The agent need not actually be installed — `AgentBinder` matches on the recorded `initialCommand` string regardless of whether the binary resolves. This keeps cases reproducible on machines without all three agents installed.

## Journeys

### Journey AA-B: Status-bar badge headline reflects current Agent activity

**Persona:** `dev_running_long_task`
**Outcome:** Without ever opening the popover, the persona can read a single line at the top of the main window that tells them which Agent (if any) demands attention.

#### Case `UT-AA-B-001`: No bound Agent → badge hidden

**Covers AC:** AC1

**Preconditions:**
- App started; ready signal "App launched" per patterns doc.
- Main window's current Worktree has at least one Tab open with one Pane, whose `initialCommand` is `bash` (or no agent name) and whose `catalog.json` entry has no `agentKind` field.
- No other Worktree contains any pane with `agentKind` set.

**Steps:**
1. Confirm the current focus is the main window (`tc focus` may be used as a no-op trigger to bring it forward).
2. Inspect the `WorktreeHeader` region for the presence of an element with accessibility identifier `activeAgents.badge`.

**Assertions:**
1. (UI) No element with identifier `activeAgents.badge` exists in the accessibility tree of the main window.
2. (UI) The Worktree header layout to the right of the worktree label is unchanged compared to the pre-feature baseline (no empty placeholder, no leading separator).

**Artifacts on FAIL:** `screenshot.png` of the full main window header.

#### Case `UT-AA-B-002`: One Agent working → headline reads "<DisplayName> is working"

**Covers AC:** AC2, AC3 (priority within mixed states is exercised separately in UT-AA-B-006), AC5 (the "is-not-yet-waiting" path)

**Preconditions:**
- App started.
- One Pane P1 in worktree W1 of project Pj1, created with `initialCommand=claude`. `catalog.json` shows `agentKind: "claude-code"` for P1 (else this is a test of the identification path, not the badge path — abort and run UT-AA-I-001 first).
- No other Pane has `agentKind` set.
- P1 is **not** currently emitting OSC 9;4 busy (idle baseline).

**Steps:**
1. Verify ready signal: `activeAgents.badge` exists and its accessibility label reads exactly `Claude Code is idle`.
2. Trigger an OSC 9;4 busy report on P1.
3. Wait until either (a) the `activeAgents.badge` accessibility label changes from "idle" to "working" OR (b) ≤ 3 seconds have elapsed.

**Assertions:**
1. (UI) After step 3: `activeAgents.badge` accessibility label reads exactly `Claude Code is working`.
2. (UI) The badge's pulse animation is running (the badge has an active `pulseAnimating=true` accessibility trait OR the accessibility identifier `activeAgents.badge.pulse` is present).
3. (Log) Within the same window, one line under `subsystem:"com.touch-code.activeagents"` `category:"registry"` matches `state-transition.*P1.*idle->loading`.

**Artifacts on FAIL:** `screenshot.png`, `catalog.json.snapshot.json`, console log filtered to subsystem `com.touch-code.activeagents`.

#### Case `UT-AA-B-003`: Working → busy cleared → headline reads "finished"

**Covers AC:** AC3

**Preconditions:**
- End-state of `UT-AA-B-002` (one bound Pane P1, badge headline reads "Claude Code is working").

**Steps:**
1. Clear the OSC 9;4 busy report on P1 (drive `printf '\e]9;4;0\a'`).
2. Wait until either (a) the `activeAgents.badge` accessibility label changes from "working" to "finished" OR (b) ≤ 5 seconds have elapsed.

**Assertions:**
1. (UI) `activeAgents.badge` accessibility label reads exactly `Claude Code is finished`.
2. (UI) The badge pulse animation is **not** running (no `pulseAnimating` trait, no `activeAgents.badge.pulse` identifier).
3. (Log) One line matches `state-transition.*P1.*loading->finished`.

**Artifacts on FAIL:** `screenshot.png`, console log.

#### Case `UT-AA-B-004`: Finished → user focuses Pane → headline drops to "idle"

**Covers AC:** AC4

**Preconditions:**
- End-state of `UT-AA-B-003` (P1's headline reads "finished").
- The user's current focus is on a Pane in a **different** Worktree than W1 — i.e., P1 is not the focused Pane.

**Steps:**
1. In the main window, click the Worktree W1 row in the sidebar.
2. Wait for ready signal "Pane attached" on P1.

**Assertions:**
1. (UI) Within ≤ 2 seconds of step 2 ready signal, `activeAgents.badge` accessibility label reads exactly `Claude Code is idle`.
2. (Log) One line matches `state-transition.*P1.*finished->idle` with `trigger=focused`.

**Artifacts on FAIL:** `screenshot.png`, console log.

#### Case `UT-AA-B-005`: Waiting-for-input wins priority over working

**Covers AC:** AC5

**Preconditions:**
- App started.
- Pane P1 in W1 of Pj1 with `agentKind=claude-code`, currently emitting OSC 9;4 busy (state `loading`).
- Pane P2 in W2 of Pj1 with `agentKind=codex`, currently idle (no busy, no events).
- Neither Pane is the user's current focus.

**Steps:**
1. Drive a `waitingForInput`-class OSC 9 event on P2 (title `"Approve this action"`).
2. Wait until either (a) the `activeAgents.badge` accessibility label contains the substring "waiting" OR (b) ≤ 3 seconds.

**Assertions:**
1. (UI) `activeAgents.badge` accessibility label reads exactly `Codex is waiting for input`.
2. (UI) The badge pulse animation is running.

**Artifacts on FAIL:** `screenshot.png`, console log.

#### Case `UT-AA-B-006`: Multiple agents same state → "N agents working" copy

**Covers AC:** AC2 (multi form), AC3 (multi form)

**Preconditions:**
- App started.
- Three bound Panes: P1=`claude-code`, P2=`codex`, P3=`pi`, each in a different Worktree.
- All three are currently emitting OSC 9;4 busy.
- The user's current focus is on a fourth Pane in a fourth Worktree, all of which have no `agentKind`.

**Steps:**
1. Read the `activeAgents.badge` accessibility label.

**Assertions:**
1. (UI) The label reads exactly `3 agents working`.
2. (UI) Pulse animation is running.

**Artifacts on FAIL:** `screenshot.png`.

#### Case `UT-AA-B-007`: Mixed states → priority-sorted two-segment copy

**Covers AC:** AC2 (mixed form), AC5 (mixed form)

**Preconditions:**
- App started.
- Two bound Panes: P1=`claude-code` in `waitingForInput`, P2=`codex` in `loading`.
- One bound Pane P3=`pi` in `finished`.
- One bound Pane P4=`claude-code` in `idle`.
- No focused agent Pane.

**Steps:**
1. Read the `activeAgents.badge` accessibility label.

**Assertions:**
1. (UI) The label reads `1 waiting · 1 working` (priority `waitingForInput > loading > finished > idle`; only the top two non-empty buckets surface; `finished` and `idle` counts are not shown in headline form).

**Artifacts on FAIL:** `screenshot.png`.

#### Case `UT-AA-B-008`: Reduce-Motion disables pulse

**Covers AC:** AC13

**Preconditions:**
- App started.
- macOS System Settings → Accessibility → Display → Reduce Motion is ON before app launch.
- One bound Pane P1=`claude-code` in `loading` state.

**Steps:**
1. Read the `activeAgents.badge` accessibility label.
2. Inspect whether the badge declares pulse animation as active.

**Assertions:**
1. (UI) Label reads `Claude Code is working`.
2. (UI) The badge has no `pulseAnimating` trait and the identifier `activeAgents.badge.pulse` is absent.

**Artifacts on FAIL:** `screenshot.png` of the full window and the macOS Accessibility settings pane.

### Journey AA-P: Hover popover surfaces every Agent with provenance

**Persona:** `dev_running_long_task`
**Outcome:** The persona hovers the badge, sees one row per Agent, and can read each row's agent / location / state without clicking.

#### Case `UT-AA-P-001`: 250ms sustained hover opens popover; sub-threshold sweep does not

**Covers AC:** AC7 (open delay)

**Preconditions:**
- App started.
- One bound Pane P1=`claude-code` in `loading`.

**Steps:**
1. Move the pointer onto the `activeAgents.badge` element and immediately move it off after ≤ 100 ms (a quick sweep).
2. Wait 500 ms.
3. Move the pointer back onto `activeAgents.badge` and hold for ≥ 400 ms.

**Assertions:**
1. (UI) Between steps 1 and 2: no element with identifier `activeAgents.popover` exists.
2. (UI) After step 3 holds ≥ 250 ms: an element with identifier `activeAgents.popover` exists and is visible.
3. (UI) The popover header text matches the regular expression `^Active Agents \(\d+\)$`.

**Artifacts on FAIL:** `screenshot.png` at the moment the popover would have appeared and at 500 ms after hover.

#### Case `UT-AA-P-002`: Hover bridge keeps popover open while pointer is over it

**Covers AC:** AC7 (hover bridge + close delay)

**Preconditions:**
- App started.
- Popover currently open (e.g., end-state of UT-AA-P-001).

**Steps:**
1. Move the pointer smoothly from over the badge into the popover content area in ≤ 100 ms.
2. Hover anywhere inside the popover for ≥ 1 s.
3. Move the pointer outside both the badge and the popover bounds.
4. Wait exactly 80 ms; check popover presence.
5. Wait another 200 ms; check popover presence.

**Assertions:**
1. (UI) After step 2: `activeAgents.popover` is still visible.
2. (UI) At the 80 ms checkpoint after step 3: `activeAgents.popover` is still visible (hover-bridge close delay is 150 ms).
3. (UI) At the 200 ms checkpoint: `activeAgents.popover` is no longer in the accessibility tree.

**Artifacts on FAIL:** `screenshot.png` at each checkpoint.

#### Case `UT-AA-P-003`: Popover lists all bound Panes including idle, sorted by state priority

**Covers AC:** AC6 (popover content), AC2/AC3 row content side

**Preconditions:**
- App started.
- Four bound Panes simultaneously:
  - P1=`claude-code` in `waitingForInput`
  - P2=`codex` in `loading`
  - P3=`pi` in `finished`
  - P4=`claude-code` in `idle`
- No other bound Panes exist.

**Steps:**
1. Hover the badge for ≥ 300 ms to open the popover.

**Assertions:**
1. (UI) `activeAgents.popover` contains exactly four rows, identified `activeAgents.row.P1`, `activeAgents.row.P2`, `activeAgents.row.P3`, `activeAgents.row.P4`.
2. (UI) The row order top-to-bottom is `P1, P3, P2, P4` (priority `waitingForInput > finished > loading > idle`; tie-break by `lastTransitionAt` desc is exercised in UT-AA-P-004).
3. (UI) The header text matches `Active Agents (4)`.
4. (UI) Each row's `<paneID>.state` accessibility label is one of the four state strings.
5. (UI) Each row's `<paneID>.headline` text contains both the Project name and the Worktree name of that Pane, separated by ` / `.

**Artifacts on FAIL:** `screenshot.png` of the popover, console log.

#### Case `UT-AA-P-004`: Tie-break within state bucket is by lastTransitionAt desc

**Covers AC:** AC6 (within-bucket order)

**Preconditions:**
- App started.
- Three bound Panes all in `loading`:
  - P1=`claude-code`, entered `loading` at T-10s
  - P2=`codex`, entered `loading` at T-5s
  - P3=`pi`, entered `loading` at T-1s
- No Pane is currently `waitingForInput` or `finished`.

**Steps:**
1. Hover the badge ≥ 300 ms.

**Assertions:**
1. (UI) Row order top-to-bottom is `P3, P2, P1` (most-recent transition first).

**Artifacts on FAIL:** `screenshot.png`, console log lines matching `lastTransitionAt`.

### Journey AA-C: Clicking a row focuses the Pane across the hierarchy

**Persona:** `dev_running_long_task`
**Outcome:** The persona finds the Agent they want to look at in the popover and reaches it with a single click, regardless of which Project / Worktree / Tab currently has selection.

#### Case `UT-AA-C-001`: Click crosses Project + Worktree + Tab boundaries

**Covers AC:** AC8

**Preconditions:**
- App started.
- Two Projects: Pj1 (current selection, with Worktree W1, Tab T1, Pane P1=`bash`) and Pj2 (not selected, with Worktree W2, Tab T2, Pane P2=`claude-code` in `loading`).
- P2 has `agentKind=claude-code` in `catalog.json`.
- Current first responder is in P1.
- Popover not yet open.

**Steps:**
1. Hover `activeAgents.badge` ≥ 300 ms.
2. Click the row identified `activeAgents.row.<P2-id>`.
3. Wait for ready signal "Pane attached" on P2.

**Assertions:**
1. (UI) Within ≤ 2 seconds: the main window's Project sidebar selection is Pj2.
2. (UI) The Worktree selection inside Pj2 is W2.
3. (UI) The Tab selection inside W2 is T2.
4. (UI) The first responder is the Ghostty surface view of P2 (verifiable by typing one printable character and observing it appear in P2's terminal output; this character must be `'#'` so it is a no-op inside any shell — pick from patterns doc's "safe characters" list).
5. (UI) `activeAgents.popover` is no longer in the accessibility tree (popover dismissed by the click).

**Artifacts on FAIL:** `screenshot.png`, console log, `catalog.json.snapshot.json` showing `selectedProjectID`/`selectedWorktreeID`/`selectedTabID`/last-focused-pane.

#### Case `UT-AA-C-002`: Click does not steal subsequent typing back to the badge

**Covers AC:** AC8 (focus stability after click)

**Preconditions:**
- End-state of `UT-AA-C-001` (P2 just focused via row click).

**Steps:**
1. Type the printable character `'#'` immediately after the click ready signal.
2. Wait ≤ 500 ms.

**Assertions:**
1. (UI) The character `'#'` appears in P2's terminal output (the click did not leave focus on the badge).

**Artifacts on FAIL:** `screenshot.png` of P2 surface contents.

### Journey AA-I: Agent identity is persisted and reflects the live process

**Persona:** `dev_running_long_task`
**Outcome:** The persona's Agent identity decisions survive relaunch; closed agents unbind cleanly; unknown commands never appear in the view.

#### Case `UT-AA-I-001`: Pane with `initialCommand=claude` is identified and persisted

**Covers AC:** AC9

**Preconditions:**
- App started.
- No bound Panes exist.

**Steps:**
1. Create a new Pane via `tc tab new --command claude` (the binary need not resolve; binder uses the recorded `initialCommand` string).
2. Wait for ready signal "Pane attached" on the new pane.
3. Wait until either (a) a row appears in `activeAgents.popover` after a hover, OR (b) `~/.config/touch-code/catalog.json`'s pane entry contains `agentKind=claude-code` — whichever first.
4. Quit the app cleanly.
5. Relaunch the app.
6. Wait for ready signal "App launched".

**Assertions:**
1. (File) After step 3: `jq '.. | objects | select(.id? and .initialCommand?) | select(.agentKind?)' ~/.config/touch-code/catalog.json` returns at least one row whose `agentKind == "claude-code"` and whose pane ID matches the new pane.
2. (UI) After step 6: hovering `activeAgents.badge` opens the popover with at least one row, and that row's content names "Claude Code".

**Artifacts on FAIL:** `catalog.json.snapshot.json` taken before quit and after relaunch; console log filtered to `com.touch-code.activeagents`.

#### Case `UT-AA-I-002`: Closing the Pane clears the binding

**Covers AC:** AC10

**Preconditions:**
- End-state of `UT-AA-I-001` after relaunch (one bound Pane visible in popover).

**Steps:**
1. Close the agent Pane via the Pane context menu's "Close" item (or `tc pane close <id>`).
2. Wait for ready signal: a coordinator log line confirming pane teardown OR the row disappearing from the popover.

**Assertions:**
1. (UI) The previously bound row no longer exists in `activeAgents.popover`. If this was the only bound Pane, `activeAgents.badge` itself is no longer in the accessibility tree.
2. (File) `jq '.. | objects | select(.id? and .initialCommand?) | .agentKind? // empty' ~/.config/touch-code/catalog.json` returns no rows naming that pane's ID with a non-null `agentKind`.

**Artifacts on FAIL:** `catalog.json.snapshot.json`, console log.

#### Case `UT-AA-I-003`: Unknown command never appears in ActiveAgents

**Covers AC:** AC11

**Preconditions:**
- App started, no bound Panes.

**Steps:**
1. Create a new Pane via `tc tab new --command "make all"`.
2. Wait for ready signal "Pane attached".
3. Wait 3 seconds, or until the next state-transition log line from `com.touch-code.activeagents` would have fired (whichever first).

**Assertions:**
1. (UI) `activeAgents.badge` is not in the accessibility tree.
2. (File) The new pane's `catalog.json` entry has no `agentKind` field (or it is null).
3. (Log) No log line under `com.touch-code.activeagents` `category:"binder"` matches this pane's ID with a non-empty kind.

**Artifacts on FAIL:** `catalog.json.snapshot.json`, console log.

#### Case `UT-AA-I-004`: Rebind on OSC 133 prompt-end + new agent title — RUNTIME-CONDITIONAL

**Covers AC:** AC15

**Preconditions:**
- App started.
- One Pane P1 bound to `claude-code`, currently `idle`.
- Shell integration is **confirmed active** for P1 (verifiable by emitting one OSC 133 D sequence manually and seeing a `subsystem:"com.touch-code.ghostty"` log line acknowledging it; if no such log line appears, the case is reported `inconclusive — shell-integration unavailable` per the spec's OQ-1 and SKIPS the assertions below).

**Steps:**
1. In P1, drive `printf '\e]133;D;0\a'` (OSC 133 D, indicating prompt returned).
2. Immediately drive `printf '\e]2;Codex CLI v1.2\a'` to change the window title to a Codex-pattern string.
3. Wait until either (a) `catalog.json`'s P1 entry shows `agentKind=codex` OR (b) ≤ 5 seconds.

**Assertions:**
1. (File) `catalog.json` P1 entry `agentKind == "codex"`.
2. (UI) The popover row for P1 now shows a Codex logo and display name.
3. (Log) One line matches `binder.*rebind.*P1.*claude-code->codex`.

**Artifacts on FAIL:** `catalog.json.snapshot.json` before and after, console log filtered to both `com.touch-code.activeagents` and `com.touch-code.ghostty`.

**Note on conditional skip:** if the precondition's OSC 133 D ack log line does not appear, the validator reports `inconclusive` with reason `shell-integration unavailable per OQ-1`. The case is **not** marked failed in that scenario — this is the spec-acknowledged limitation.

### Journey AA-N: ActiveAgents is independent of the notifications subsystem

**Persona:** `dev_running_long_task`
**Outcome:** Muting notifications, disabling notification surfaces, or unread notification state never affects what ActiveAgents shows.

#### Case `UT-AA-N-001`: Muted Pane still appears in popover

**Covers AC:** AC12

**Preconditions:**
- App started.
- One bound Pane P1=`claude-code` whose `labels` set contains `notifications:muted` (apply via the Pane context menu's "Mute notifications" item before this case).
- P1 currently in `loading`.

**Steps:**
1. Hover `activeAgents.badge` ≥ 300 ms.

**Assertions:**
1. (UI) The popover contains a row `activeAgents.row.<P1-id>` with state `loading`.
2. (UI) The badge headline contains the verb `working`.
3. (UI) No element indicating "muted" or a strikethrough on the ActiveAgents row exists (mute is a notification concern, not an ActiveAgents concern; the row presents identically to an unmuted row in the same state).

**Artifacts on FAIL:** `screenshot.png`, `catalog.json.snapshot.json` showing the labels field.

#### Case `UT-AA-N-002`: Finished cleared by focus regardless of unread inbox state

**Covers AC:** AC4 (focus clears finished), AC-AN2 isolation (cross-check no notification dependency)

**Preconditions:**
- App started.
- One bound Pane P1=`claude-code` currently in `finished` (after a recent loading→finished transition via UT-AA-B-002/003).
- `~/.config/touch-code/notifications.json` contains a corresponding `taskFinished` entry for P1 with `readAt: null` (unread).
- Current focus is on a different Pane (not P1).

**Steps:**
1. Bring P1 into focus by clicking P1's row in the popover (this reuses the AA-C path).
2. Wait for "Pane attached" on P1.

**Assertions:**
1. (UI) P1's row in the popover (if popover is reopened after) shows `idle`, not `finished`.
2. (File) `notifications.json`'s entry for that `taskFinished` event still has `readAt: null` (ActiveAgents did not touch the notification's read state).
3. (Log) State transition line matches `state-transition.*P1.*finished->idle`.

**Artifacts on FAIL:** `notifications.json.snapshot.json`, `catalog.json.snapshot.json`, console log.

#### Case `UT-AA-N-003`: All notification surfaces off does not break ActiveAgents

**Covers AC:** AC-N3-equivalent (independence from notifications subsystem) — extends AC1/AC2 in the negative

**Preconditions:**
- App started.
- `~/.config/touch-code/settings.json` has `notifications.inAppEnabled=false`, `notifications.systemEnabled=false`, `notifications.dockBadgeEnabled=false`, `notifications.soundEnabled=false`.
- One bound Pane P1=`claude-code` in `idle`.

**Steps:**
1. Trigger an OSC 9;4 busy report on P1.
2. Wait ≤ 3 seconds.
3. Drive a `waitingForInput`-class OSC 9 event on P1 (title `"Approve this action"`).
4. Wait ≤ 3 seconds.

**Assertions:**
1. (UI) After step 2: badge headline reads `Claude Code is working`, pulse running.
2. (UI) After step 4: badge headline reads `Claude Code is waiting for input`, pulse running.
3. (UI) The inbox bell badge has not changed (notifications.json still empty), and Dock badge is unchanged — confirming ActiveAgents wrote nothing through the notifications subsystem.

**Artifacts on FAIL:** `screenshot.png`, `notifications.json.snapshot.json`, console log filtered to both `com.touch-code.activeagents` and `com.touch-code.notifications`.

### Journey AA-A: Accessibility surface reads complete state

**Persona:** `dev_running_long_task`
**Outcome:** With VoiceOver enabled, the persona can navigate ActiveAgents and hear a complete description of the badge and each row.

#### Case `UT-AA-A-001`: Badge VoiceOver label and hint

**Covers AC:** AC14 (badge portion)

**Preconditions:**
- App started.
- macOS VoiceOver ON (`fn+⌘+F5`).
- One bound Pane P1=`claude-code` in `waitingForInput`.

**Steps:**
1. Move VoiceOver cursor to the `activeAgents.badge` element.
2. Record the VoiceOver speech output for that focus (capture via VoiceOver's "Copy last spoken phrase" or transcript).

**Assertions:**
1. (Speech) The spoken text contains the substring `Claude Code is waiting for input`.
2. (Speech) The spoken text additionally contains the hint substring `Open active agents popover`.

**Artifacts on FAIL:** `voiceover-transcript.txt`, `screenshot.png`.

#### Case `UT-AA-A-002`: Row VoiceOver label includes all four attributes

**Covers AC:** AC14 (row portion)

**Preconditions:**
- App started.
- VoiceOver ON.
- One bound Pane P1=`claude-code` in `loading`, in worktree `feat/login` of project `acme-web`, with `lastTransitionAt` ~12 s ago.
- Popover currently open.

**Steps:**
1. Move VoiceOver cursor onto the `activeAgents.row.<P1-id>` element.
2. Capture the spoken phrase.

**Assertions:**
1. (Speech) The phrase contains, in order: the substring `Claude Code`; the substring `acme-web`; the substring `feat/login`; the substring `loading` (or `working` — accept either, the row maps the state to the same word as the headline); a time-relative substring matching `\b(seconds?|s)\b` for the 12s case.
2. (Speech) The state icon itself is NOT separately announced (it carries `accessibilityHidden(true)` so VoiceOver does not read it twice).

**Artifacts on FAIL:** `voiceover-transcript.txt`, `screenshot.png`.

## Coverage Matrix

| Spec AC | Covered by |
|---------|------------|
| AC1 | UT-AA-B-001 |
| AC2 | UT-AA-B-002, UT-AA-B-006, UT-AA-B-007 |
| AC3 | UT-AA-B-003, UT-AA-B-006 |
| AC4 | UT-AA-B-004, UT-AA-N-002 |
| AC5 | UT-AA-B-005, UT-AA-B-007 |
| AC6 | UT-AA-P-003, UT-AA-P-004 |
| AC7 | UT-AA-P-001, UT-AA-P-002 |
| AC8 | UT-AA-C-001, UT-AA-C-002 |
| AC9 | UT-AA-I-001 |
| AC10 | UT-AA-I-002 |
| AC11 | UT-AA-I-003 |
| AC12 | UT-AA-N-001 |
| AC13 | UT-AA-B-008 |
| AC14 | UT-AA-A-001, UT-AA-A-002 |
| AC15 | UT-AA-I-004 (RUNTIME-CONDITIONAL — may report inconclusive if shell-integration unavailable per OQ-1) |

Every spec AC is covered by at least one case. No case is shared across ACs only — overlap exists where one journey naturally exercises multiple ACs (e.g., AC2 has separate cases for single-, multi-same-, and multi-mixed-state forms; AC4 is reached both directly and as a side effect of the notification-independence journey).

## Personas / Fixtures Added During Authoring

None. `dev_running_long_task` already covers this feature's only persona; no fixture files are needed beyond ad-hoc `catalog.json` / `settings.json` seeds described per-case.

## Notes on Runnability

- All cases assume the implementation has declared the accessibility identifiers listed in §"Test Surface". If the implementation has not yet wired these, the cases are still authored correctly but cannot run; the planner already lists this as a precondition for the corresponding tasks. The patterns doc forbids invented `data-test-*` ids — these identifiers are the agreed contract surface, declared by code, named here.
- `UT-AA-I-004` is the only case that depends on shell-integration emitting OSC 133 D; per the spec's OQ-1 and the design doc's Risks table, this is a documented runtime-conditional case. The validator should report `inconclusive` (not `failed`) when the precondition's ack log line is absent.
- No case asserts pixel-exact rendering or specific animation curves. The "pulse running" assertion uses an accessibility trait or identifier rather than image diff — the implementation must surface the animating state on the accessibility tree.
