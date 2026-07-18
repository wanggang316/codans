---
name: notifications-v1-1
description: User-test set for the v1.1 Notifications work — policy chokepoint, five settings controls, command-finished suppression, per-pane mute, worktree auto-promote, and the inbox JSON envelope migration. Authored by /hs-test-spec. Read docs/user-test-patterns.md for project-wide testing conventions before editing.
---

# User Tests: Notifications v1.1

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-05-20
**Spec:** [notifications.md](../design-docs/notifications.md)
**Design:** [docs/design-docs/notifications.md](../design-docs/notifications.md)

## Personas Used

- `dev_running_long_task` — drives the chokepoint, the command-finished paths, the worktree promote path, and the inbox envelope cases. Defaults align with v1.1 out-of-the-box settings.
- `settings_tweaker` — drives the Settings → Notifications pane (toggles, disabled-Sound row, permission alert, Reveal in Finder, threshold input validation).
- `quiet_user` — drives the per-pane mute affordance and the toggle-off paths.

All three personas were added to `docs/user-tests/_shared/personas.yaml` as part of this document's authoring; see [Personas / Fixtures Added](#personas--fixtures-added-during-authoring) below.

## Journeys

### Journey CP: Settings toggles take effect at decision time

**Persona:** `dev_running_long_task`
**Outcome:** Flipping a notification toggle changes the next notification's behaviour without an app relaunch, and notifications dropped while a toggle is off do not retroactively appear.

#### Case `UT-V11-CP-001`: Live setting flip controls the next decision

**Covers AC:** AC-V11-CP1, AC-V11-CP2

**Preconditions:**
- App started; ready signal "App launched" per patterns doc
- A pane exists in worktree W1 of project P1 that is **not** the user's current focus (focus is on a different worktree's pane)
- `notifications.inAppEnabled = true`, `notifications.systemEnabled = true`, `authStatus = authorized`
- The inbox file `~/.config/codans/notifications.json` exists with `entries: []`
- A way to drive a single OSC 9 desktop-notification event on the unfocused pane (e.g., a script the persona can paste into that pane via the `codans` CLI's pane-input verb, or a shell command on the pane that runs `printf '\033]9;hello\007'`)

**Steps:**
1. Trigger one OSC 9 event on the unfocused pane.
2. Wait for the ready signal "Notification emitted" — Dock badge changes from blank to `1`.
3. Open Settings → Notifications.
4. Toggle "In-app notifications" off.
5. Wait for the toggle's switch role to read "off".
6. Trigger a second OSC 9 event on the same unfocused pane.
7. Wait either ≤ 3 seconds OR until the next log line under subsystem `com.gumpw.codans.notifications` category `coordinator` is emitted, whichever comes first.

**Assertions:**
1. (UI) After step 2: Dock badge label is `1`.
2. (UI) After step 2: status-bar bell badge label is `1`.
3. (File) After step 2: `notifications.json`'s `entries` array has length 1.
4. (UI) After step 7: Dock badge label is still `1` (the second event was dropped because the live `inAppEnabled` value at decision time was `false`).
5. (File) After step 7: `notifications.json`'s `entries` array has length 1 (unchanged).
6. (Log) After step 7: a debug line appears with text matching `drop inAppDisabled` for an entry whose source pane matches the unfocused pane's ID.

**Artifacts on FAIL:**
- `screenshot.png` of the worktree status bar and Dock at the time of the failed assertion
- `notifications.json.snapshot.json`
- `console.log` filtered to subsystem `com.gumpw.codans.notifications`

#### Case `UT-V11-CP-002`: A dropped event never resurfaces after the toggle flips back on

**Covers AC:** AC-V11-CP3

**Preconditions:**
- App in the state at the end of `UT-V11-CP-001` (one entry in inbox; second OSC 9 dropped while In-app off)

**Steps:**
1. Toggle "In-app notifications" back on.
2. Wait ≤ 3 seconds for the toggle switch role to read "on".
3. Open the status-bar bell popover.

**Assertions:**
1. (UI) Dock badge label is `1` (unchanged from before the flip).
2. (File) `notifications.json`'s `entries` array has length 1 (no retroactive surfacing).
3. (UI) The bell popover lists exactly 1 row.

**Artifacts on FAIL:**
- `screenshot.png` of the bell popover
- `notifications.json.snapshot.json`

### Journey S: Five Settings controls behave per their captions

**Persona:** `settings_tweaker`
**Outcome:** Each of the five Notifications-pane controls produces the documented observable effect on the next emitted notification, and the static UI state of each control follows the spec.

For every case below, "trigger one notification-worthy event" means: drive one OSC 9 desktop-notification event on a pane that is **not** the user's current focus, then wait on the ready signal "Notification emitted".

#### Case `UT-V11-S-001`: In-app off — banner posts, inbox stays empty, Dock stays cleared

**Covers AC:** AC-V11-S1

**Preconditions:**
- App started; an unfocused pane exists in W1/P1
- `inAppEnabled = false`, `systemEnabled = true`, `authStatus = authorized`
- `notifications.json`'s `entries` is empty
- Dock badge cleared

**Steps:**
1. Trigger one notification-worthy event on the unfocused pane.
2. Wait ≤ 5 seconds for either a macOS banner to appear OR the next coordinator log line.

**Assertions:**
1. (UI) A macOS banner with the originating worktree label appears in Notification Center.
2. (UI) Dock badge remains cleared (no label).
3. (UI) Status-bar bell badge remains hidden.
4. (File) `notifications.json`'s `entries` array has length 0.

**Artifacts on FAIL:** screenshot of Notification Center, Dock, status bar.

#### Case `UT-V11-S-002`: System off — inbox/Dock update, no banner

**Covers AC:** AC-V11-S2

**Preconditions:**
- `inAppEnabled = true`, `systemEnabled = false`, `authStatus = authorized`
- `notifications.json`'s `entries` is empty; Dock badge cleared

**Steps:**
1. Trigger one notification-worthy event on the unfocused pane.
2. Wait ≤ 5 seconds.

**Assertions:**
1. (UI) **No** macOS banner appears within the wait window.
2. (UI) Dock badge label becomes `1`.
3. (UI) Status-bar bell badge shows `1`.
4. (File) `notifications.json`'s `entries` array has length 1.

**Artifacts on FAIL:** screenshot of Notification Center (proving no banner), Dock, status bar.

#### Case `UT-V11-S-003`: Sound off — banner posts without sound

**Covers AC:** AC-V11-S3

**Preconditions:**
- `inAppEnabled = true`, `systemEnabled = true`, `soundEnabled = false`, `authStatus = authorized`
- macOS system volume audible (so a sound, if played, would be heard)
- A way to capture audio output OR observe the banner request's `sound` property via the macOS Notification Center inspection tool

**Steps:**
1. Trigger one notification-worthy event on the unfocused pane.
2. Wait ≤ 5 seconds for the banner to appear.

**Assertions:**
1. (UI) A macOS banner appears.
2. (Audio / Inspector) The banner is delivered silently — no system default notification sound plays, OR the notification's `sound` field inspected through macOS Notification Center is `nil` / absent.

**Artifacts on FAIL:** audio capture of the wait window if available; screenshot of the banner.

#### Case `UT-V11-S-004`: Sound row is disabled while System is off

**Covers AC:** AC-V11-S4

**Preconditions:**
- Settings → Notifications open
- `systemEnabled = false`

**Steps:**
1. Inspect the "Sound" row in the Notifications section.
2. Hover the cursor over the "Sound" row and wait for a tooltip.

**Assertions:**
1. (UI) The "Sound" toggle's interactive state is "disabled" (does not respond to clicks; rendered with the standard SwiftUI disabled appearance).
2. (UI / Accessibility) Hovering the row surfaces a tooltip whose text indicates that Sound requires System notifications to be on.
3. (UI) Toggling "System notifications" back to on causes the "Sound" row to become interactive on the same pane render, with the persisted value preserved (its switch state is not reset).

**Artifacts on FAIL:** screenshot of the Notifications pane with the cursor hovering the Sound row.

#### Case `UT-V11-S-005`: Dock badge off — badge stays cleared even with unread inbox

**Covers AC:** AC-V11-S5

**Preconditions:**
- `inAppEnabled = true`, `dockBadgeEnabled = false`, `authStatus = authorized`
- `notifications.json` seeded with one entry, `readAt: null` (unread)
- App started; Dock badge cleared at launch

**Steps:**
1. Wait for the app's ready signal.
2. Open the status-bar bell popover and confirm the unread row is visible.
3. Trigger one additional notification-worthy event on an unfocused pane.

**Assertions:**
1. (UI) Dock badge remains cleared throughout — at launch, after the popover open, and after the new event.
2. (UI) Status-bar bell badge shows `2` after step 3 (the two unread entries).
3. (File) `notifications.json`'s `entries` array has length 2 after step 3.

**Artifacts on FAIL:** screenshot of the Dock and the status-bar bell at each step.

#### Case `UT-V11-S-006`: Mute summary reports rule and pane counts

**Covers AC:** AC-V11-S6

**Preconditions:**
- `settings.json`'s `notifications.mute.mutedRuleIDs` seeded with exactly 3 string values
- `settings.json`'s `notifications.mute.mutedPaneIDs` seeded with exactly 2 UUID values
- Settings → Notifications opened after seed

**Steps:**
1. Locate the "Mute rules" section in the Notifications pane.

**Assertions:**
1. (UI) The summary row text reads "3 rule(s), 2 pane(s) muted" — exact pluralization preserved.

**Artifacts on FAIL:** screenshot of the Mute rules section.

#### Case `UT-V11-S-007`: Mute summary collapses to "No mute rules" when both counts are zero

**Covers AC:** AC-V11-S7

**Preconditions:**
- `settings.json`'s `notifications.mute.mutedRuleIDs` is empty
- `settings.json`'s `notifications.mute.mutedPaneIDs` is empty
- Settings → Notifications opened

**Steps:**
1. Locate the "Mute rules" section.

**Assertions:**
1. (UI) The summary row text reads exactly "No mute rules".

**Artifacts on FAIL:** screenshot of the Mute rules section.

#### Case `UT-V11-S-008`: Reveal rules.json button selects the file in Finder

**Covers AC:** AC-V11-S8

**Preconditions:**
- Settings → Notifications open
- `~/.config/codans/detection-rules.json` may or may not exist beforehand

**Steps:**
1. Click "Reveal rules.json in Finder…" in the Mute rules section.
2. Wait for Finder to activate.

**Assertions:**
1. (UI) Finder is the frontmost application.
2. (UI) Finder's active window shows `detection-rules.json` selected (highlighted).
3. (File) `~/.config/codans/detection-rules.json` exists on disk after the click (was created with defaults if previously absent).

**Artifacts on FAIL:** screenshot of Finder; output of `ls -la ~/.config/codans/detection-rules.json`.

### Journey P: Denied permission surfaces an actionable alert

**Persona:** `settings_tweaker`
**Outcome:** A user with macOS notifications denied can still capture their preference (system toggle "on" persists) and gets a one-click route to the macOS Notifications pane, regardless of macOS version.

#### Case `UT-V11-P-001`: Toggling System on while denied shows the recovery alert

**Covers AC:** AC-V11-P1

**Preconditions:**
- macOS notification authorization for codans is currently **denied** (set via System Settings before app launch)
- App started; Settings → Notifications open
- `systemEnabled = false`

**Steps:**
1. Toggle "System notifications" on.
2. Wait ≤ 2 seconds for an alert to appear.

**Assertions:**
1. (UI) A modal alert appears with a body that names macOS as the source of the block.
2. (UI) The alert has two buttons: a default-styled "Open System Settings…" and a cancel "Cancel".
3. (UI / File) After dismissing the alert with either button, the "System notifications" toggle remains in the "on" position; `settings.json`'s `notifications.systemEnabled` reads `true`.

**Artifacts on FAIL:** screenshot of the alert; `settings.json.snapshot.json`.

#### Case `UT-V11-P-002`: Open System Settings deep-link lands on the macOS Notifications pane

**Covers AC:** AC-V11-P2

**Preconditions:**
- The alert from `UT-V11-P-001` is visible

**Steps:**
1. Click "Open System Settings…".
2. Wait for System Settings to activate.

**Assertions:**
1. (UI) System Settings is the frontmost application.
2. (UI) The active pane in System Settings is "Notifications" — verified by the pane title or breadcrumb visible at the top of the System Settings window.
3. (UI) The pane shows either the codans app's row (newer macOS) **or** the top-level Notifications listing (older macOS) — either is an acceptable landing per the spec's fallback clause; the case PASSES on either.

**Artifacts on FAIL:** screenshot of System Settings.

### Journey M: Per-pane mute via right-click menu

**Persona:** `quiet_user`
**Outcome:** A noisy pane can be silenced with one menu click without editing JSON files, and the silencing is fully observable in the menu state and the notification behaviour.

#### Case `UT-V11-M-001`: Unmuted pane shows "Mute notifications" without a checkmark

**Covers AC:** AC-V11-M1

**Preconditions:**
- App started; an open pane P exists whose `labels` array does not contain `notifications:muted`
- The pane is visible in the main window

**Steps:**
1. Right-click anywhere on the pane chrome (the area surrounding the terminal surface; not on the terminal output itself if the terminal would capture the right-click).
2. Wait for the macOS context menu to appear.

**Assertions:**
1. (UI) The context menu contains a row labelled "Mute notifications".
2. (UI) The row does **not** display a checkmark.

**Artifacts on FAIL:** screenshot of the context menu.

#### Case `UT-V11-M-002`: Selecting "Mute notifications" adds the checkmark on next open

**Covers AC:** AC-V11-M2

**Preconditions:**
- State from `UT-V11-M-001`

**Steps:**
1. Click "Mute notifications" in the context menu (the menu closes).
2. Right-click the pane chrome again.

**Assertions:**
1. (UI) The context menu's "Mute notifications" row now displays a checkmark.
2. (File) `~/.config/codans/catalog.json` — within a 1-second observation window after the menu close — the pane P's `labels` array contains the string `notifications:muted`. (Catalog persistence is debounced; the in-memory state changes immediately but disk write follows within the project's standard catalog debounce window.)

**Artifacts on FAIL:** screenshot of the context menu re-opened; `catalog.json.snapshot.json` captured shortly after the click.

#### Case `UT-V11-M-003`: Muted pane's events do not produce any inbox, banner, or badge change

**Covers AC:** AC-V11-M3

**Preconditions:**
- Pane P is muted (labels contain `notifications:muted`)
- The user's current focus is on a different pane
- Dock badge cleared; `notifications.json`'s `entries` array is empty

**Steps:**
1. Trigger one notification-worthy OSC 9 event on muted pane P.
2. Wait ≤ 5 seconds.

**Assertions:**
1. (UI) Dock badge remains cleared.
2. (UI) Status-bar bell badge remains hidden.
3. (UI) No macOS banner appears.
4. (File) `notifications.json`'s `entries` array has length 0.

**Artifacts on FAIL:** screenshot of Dock and status bar; `notifications.json.snapshot.json`.

#### Case `UT-V11-M-004`: Muting a pane does not erase its existing inbox rows

**Covers AC:** AC-V11-M4

**Preconditions:**
- `notifications.json` seeded with 2 unread entries whose `source.paneID` equals pane P's ID
- Pane P's labels do **not** contain `notifications:muted` yet
- App started

**Steps:**
1. Right-click pane P; select "Mute notifications".
2. Wait for the menu to close.
3. Open the status-bar bell popover.

**Assertions:**
1. (UI) Status-bar bell badge shows `2` after the mute toggle (unchanged).
2. (UI) The popover lists exactly 2 rows whose source matches pane P.
3. (File) `notifications.json`'s `entries` array has length 2; both entries' `readAt` is still `null`.

**Artifacts on FAIL:** screenshot of the bell popover; `notifications.json.snapshot.json`.

### Journey CF: Command-finished suppression rules

**Persona:** `dev_running_long_task` (with the threshold path also driven by `settings_tweaker`)
**Outcome:** Command-finished events surface only when they cross the configured threshold AND are not user-initiated cancellations AND are not during active keyboard interaction. Non-zero exit produces a visibly distinct title.

For every CF case, the pane running the command must be **not** the user's current focus, so the source-is-focused gate does not pre-empt the rule under test.

#### Case `UT-V11-CF-001`: Feature toggle off suppresses all command-finished notifications

**Covers AC:** AC-V11-CF1

**Preconditions:**
- `commandFinishedEnabled = false`
- All other settings at defaults; `authStatus = authorized`
- An unfocused pane P attached to a shell with OSC 133 shell integration active

**Steps:**
1. In pane P, run `sleep 30` and let it complete naturally (exit code 0, duration ≥ threshold).
2. Wait for the shell prompt to return (signals the command-finished event was published).

**Assertions:**
1. (UI) Dock badge remains cleared.
2. (UI) No macOS banner appears.
3. (File) `notifications.json`'s `entries` array does not gain a `Command finished` entry.

**Artifacts on FAIL:** screenshot of Dock; `notifications.json.snapshot.json`.

#### Case `UT-V11-CF-002`: Short-duration command is silent

**Covers AC:** AC-V11-CF2

**Preconditions:**
- `commandFinishedEnabled = true`, `commandFinishedThresholdSec = 10`
- Unfocused pane P with shell integration active
- No keystrokes into P in the 1 second before the test starts

**Steps:**
1. Run `sleep 5` in pane P; let it complete.
2. Wait for the shell prompt to return.

**Assertions:**
1. (File) `notifications.json` does not gain a new entry for pane P.
2. (UI) No Dock badge change, no banner.

**Artifacts on FAIL:** as above.

#### Case `UT-V11-CF-003`: Long-duration command surfaces with success-toned title

**Covers AC:** AC-V11-CF3

**Preconditions:**
- Same as CF-002

**Steps:**
1. Run `sleep 30` in pane P; let it complete (exit code 0, duration ≥ threshold).
2. Wait for the shell prompt and for the next coordinator log line.

**Assertions:**
1. (UI) Dock badge label is `1` (or one greater than its prior value).
2. (UI) A macOS banner appears whose title makes the success visible at a glance — e.g., "Command finished" (no "failed" word, no exit-code in the title text).
3. (File) `notifications.json` gains one entry whose `kind` is `taskFinished` and whose title does not contain the word `failed` (case-insensitive).

**Artifacts on FAIL:** screenshot of the banner; `notifications.json.snapshot.json`.

#### Case `UT-V11-CF-004`: User-cancelled command (Ctrl-C) is silent regardless of duration

**Covers AC:** AC-V11-CF4

**Preconditions:**
- Same as CF-002

**Steps:**
1. Run `sleep 60` in pane P.
2. After 15 seconds, press Ctrl-C in pane P to interrupt (the persona must focus the pane briefly to deliver the keystroke, then re-focus elsewhere before the case's "not focused" precondition is re-evaluated).
3. Wait for the shell prompt to return.

**Assertions:**
1. (File) `notifications.json` does not gain a new entry for pane P.
2. (UI) No Dock badge change, no banner.
3. (Log) A debug line appears with text matching `drop commandCancelled` for the event.

Note: this case explicitly involves focusing the pane to deliver Ctrl-C. The "not focused" gate is irrelevant here because the suppression under test (`commandCancelled`) fires earlier in the decision chain than the focused-source gate. The case PASSES if the event produces no surface regardless of which suppression reason logged.

**Artifacts on FAIL:** as above; plus `console.log` filtered to coordinator drops.

#### Case `UT-V11-CF-005`: Recent keystroke into the pane suppresses the notification

**Covers AC:** AC-V11-CF5

**Preconditions:**
- `commandFinishedEnabled = true`, `commandFinishedThresholdSec = 1` (set low to keep the wait short)
- Unfocused pane P with shell integration active

**Steps:**
1. Focus pane P.
2. Run `(sleep 2; echo done)` in pane P (a 2-second command that will cross the 1-second threshold).
3. Within 0.5 seconds of pressing Return for step 2, press one harmless key in pane P (e.g., the spacebar before the command starts producing the prompt-bound output, or any key the shell will buffer — exact key does not matter; the requirement is "a keystroke into pane P within 1 second before the commandFinished event fires").
4. Switch focus to a different pane so the "not focused" precondition is restored before the command finishes.
5. Wait for the command to complete and for the next coordinator log line.

**Assertions:**
1. (File) `notifications.json` does not gain a new entry for pane P.
2. (Log) A debug line appears with text matching `drop userTypingRecently` for the event.

**Artifacts on FAIL:** as above.

#### Case `UT-V11-CF-006`: Non-zero exit produces a visibly distinct title

**Covers AC:** AC-V11-CF6

**Preconditions:**
- Same as CF-002 (no recent keystrokes)

**Steps:**
1. Run `false` in pane P, which exits immediately with code 1 — but this is too short for the threshold. To meet the threshold with non-zero exit, run instead: `sleep 30 && false` (waits 30 seconds, then exits non-zero). Confirm exit code is 1, not 130 / 143.
2. Wait for the shell prompt and the next coordinator log line.

**Assertions:**
1. (UI) Dock badge label is `1` (or one greater than its prior value).
2. (UI) A macOS banner appears whose title contains the word `failed` OR the literal phrase `exit 1` — the assertion: the title is **not** identical to the success-toned title from CF-003.
3. (File) `notifications.json`'s new entry's title contains either `failed` or `exit 1`.

**Artifacts on FAIL:** screenshot of the banner; `notifications.json.snapshot.json`.

#### Case `UT-V11-CF-007`: Threshold input validation rejects out-of-range values

**Covers AC:** AC-V11-CF7

**Preconditions:**
- Settings → Notifications open
- `commandFinishedThresholdSec` currently `10` (default)

**Steps:**
1. Click the threshold input field.
2. Clear the field and type `0`. Press Tab (or click outside the field).
3. Observe the input field's effective value.
4. Click the field again, clear it, type `10000`. Press Tab.
5. Observe the input field's effective value.

**Assertions:**
1. (UI) After step 3, the field's displayed value is **not** `0` — either the input is reverted to a value within `[1, 3600]` (e.g., the prior value `10`), OR the field shows a validation message and refuses the change.
2. (UI) After step 5, the field's displayed value is **not** `10000` — same behaviour: reverted or refused.
3. (File) `settings.json`'s `notifications.commandFinishedThresholdSec` reads a value within `[1, 3600]` throughout — never `0`, never `10000`.

**Artifacts on FAIL:** screenshot of the threshold input after each entry attempt; `settings.json.snapshot.json`.

### Journey WT: Worktree promotion on first unread

**Persona:** `dev_running_long_task`
**Outcome:** A worktree that gains its first unread notification moves to the top of its project's worktree list (within the unpinned section) and stays there until the user reorders it manually — once-per-edge, persistent across relaunch, respects pinned worktrees.

#### Case `UT-V11-WT-001`: First unread promotes the worktree to the top of its project

**Covers AC:** AC-V11-WT1

**Preconditions:**
- `moveNotifiedWorktreeToTop = true`
- Project P1 has at least 3 worktrees, none pinned. Worktree W3 sits at position 2 (third) in the worktree list as shown in the sidebar.
- `notifications.json` is empty; all worktrees in P1 have 0 unread.
- App started; the sidebar is visible.

**Steps:**
1. Trigger one notification-worthy event on a pane belonging to W3 (the pane must not be the user's current focus).
2. Wait for the ready signal "Notification emitted".

**Assertions:**
1. (UI) After the wait, the sidebar shows W3 as the first row under P1's worktree group.
2. (File) `~/.config/codans/catalog.json` — within the catalog's standard debounce window — shows W3 as the first element of P1's `worktrees` array.

**Artifacts on FAIL:** screenshot of the sidebar before and after; `catalog.json.snapshot.json`.

#### Case `UT-V11-WT-002`: A second unread on the already-promoted worktree does not retrigger reorder

**Covers AC:** AC-V11-WT2

**Preconditions:**
- State from the end of `UT-V11-WT-001`: W3 is at position 0 of P1's worktrees with 1 unread

**Steps:**
1. Trigger a second notification-worthy event on a different pane in W3 (still unfocused) — use a different source pane or wait > 30 s to escape the inbox dedup window.
2. Wait for the ready signal "Notification emitted".

**Assertions:**
1. (UI) W3 remains at position 0 of P1's worktrees in the sidebar (unchanged).
2. (UI) Status-bar bell badge reflects the increased unread count (e.g., from `1` to `2`).
3. (File) `catalog.json` — the order of P1's `worktrees` array is unchanged from the snapshot taken at the end of WT-001.

**Artifacts on FAIL:** screenshots before/after; `catalog.json.snapshot.json` and the WT-001 snapshot for diff.

#### Case `UT-V11-WT-003`: Marking the unread read does not auto-demote the worktree

**Covers AC:** AC-V11-WT3

**Preconditions:**
- State from the end of `UT-V11-WT-002`: W3 promoted, has 2 unread

**Steps:**
1. Open the status-bar bell popover.
2. Click "Mark all read".
3. Wait for the popover to update.

**Assertions:**
1. (UI) Status-bar bell badge clears (becomes hidden / count 0).
2. (UI) W3 remains at position 0 of P1's worktrees in the sidebar.
3. (File) `catalog.json`'s P1.worktrees order is unchanged.

**Artifacts on FAIL:** as above.

#### Case `UT-V11-WT-004`: Disabled toggle prevents promotion

**Covers AC:** AC-V11-WT4

**Preconditions:**
- `moveNotifiedWorktreeToTop = false`
- P1 has 3 unpinned worktrees; W3 sits at position 2. All worktrees have 0 unread.

**Steps:**
1. Trigger one notification-worthy event on an unfocused pane in W3.
2. Wait for the ready signal "Notification emitted".

**Assertions:**
1. (UI) W3 remains at position 2 of P1's worktrees (unchanged).
2. (UI) The status-bar bell shows `1` unread (notification still surfaced; only the reorder was suppressed).
3. (File) `catalog.json`'s P1.worktrees order is unchanged.

**Artifacts on FAIL:** as above.

#### Case `UT-V11-WT-005`: Promoted order persists across app restart

**Covers AC:** AC-V11-WT5

**Preconditions:**
- State after `UT-V11-WT-001` ran and completed; W3 is at position 0 of P1.worktrees on disk.

**Steps:**
1. Quit the app (Cmd-Q; confirm the app process terminates).
2. Wait for the app process to exit.
3. Launch the app fresh.
4. Wait for the ready signal "App launched".
5. Inspect the sidebar.

**Assertions:**
1. (UI) Under P1's worktree group, W3 is the first row.
2. (File) `catalog.json` reads the same on-disk order it had before the quit.

**Artifacts on FAIL:** screenshot of the sidebar after relaunch; `catalog.json.snapshot.json` taken before quit and after relaunch.

#### Case `UT-V11-WT-006`: Pinned worktree is never auto-promoted

**Covers AC:** AC-V11-WT1 (negative — pinned exclusion clause from the design)

**Preconditions:**
- `moveNotifiedWorktreeToTop = true`
- Project P1 has 3 worktrees: W1 (pinned, sitting in the pinned section at the top), W2 (unpinned at position 0 of the unpinned section), W3 (pinned, sitting second in the pinned section). All worktrees have 0 unread.
- `notifications.json` is empty

**Steps:**
1. Trigger one notification-worthy event on an unfocused pane belonging to **pinned** worktree W3.
2. Wait for the ready signal "Notification emitted".

**Assertions:**
1. (UI) The pinned-worktree section order is unchanged (W1 still first pinned, W3 still second pinned).
2. (UI) The unpinned-section order is unchanged.
3. (UI) Status-bar bell shows `1` unread (notification still surfaced; only the reorder was skipped).
4. (File) `catalog.json`'s P1.worktrees array order is unchanged.

**Artifacts on FAIL:** sidebar screenshot; `catalog.json.snapshot.json`.

### Journey J: Inbox JSON envelope and migration

**Persona:** `dev_running_long_task`
**Outcome:** The inbox file is forward-compatible (legacy bare-array reads cleanly and upgrades on next save), backward-safe (a forward-version file is quarantined, not destroyed), and self-announces a quarantine via a single user-visible row.

#### Case `UT-V11-J-001`: Fresh install writes the envelope shape on first save

**Covers AC:** AC-V11-J1

**Preconditions:**
- No `~/.config/codans/notifications.json` file on disk
- App launched fresh

**Steps:**
1. Wait for the ready signal "App launched".
2. Trigger one notification-worthy event on an unfocused pane so the inbox has something to persist.
3. Wait ≥ 1 second beyond the inbox debounce window so the file has been written.

**Assertions:**
1. (File) `~/.config/codans/notifications.json` exists.
2. (File) `jq 'has("version") and has("entries")' notifications.json` returns `true`.
3. (File) `jq '.version' notifications.json` returns `1`.
4. (File) `jq '.entries | type' notifications.json` returns `"array"` and `.entries | length` returns `1`.

**Artifacts on FAIL:** `notifications.json.snapshot.json`.

#### Case `UT-V11-J-002`: Legacy bare-array file decodes and upgrades to envelope on next save

**Covers AC:** AC-V11-J2

**Preconditions:**
- `~/.config/codans/notifications.json` seeded with a top-level JSON array containing exactly 3 inbox entries in the v1.0 shape (no `version` key wrapping the array). Two entries are unread, one is read.
- App not running

**Steps:**
1. Launch the app fresh.
2. Wait for the ready signal "App launched".
3. Open the status-bar bell popover and observe the row count.
4. Trigger one new notification-worthy event so a save will be scheduled.
5. Wait ≥ 1 second beyond the inbox debounce window.

**Assertions:**
1. (UI) After step 3: the bell popover shows exactly 3 rows.
2. (UI) After step 3: the status-bar bell badge shows `2` (the two seeded unread entries).
3. (File) After step 5: `notifications.json` is now in envelope shape — `jq 'has("version") and has("entries")'` returns `true`.
4. (File) After step 5: `jq '.entries | length' notifications.json` returns `4` (3 seeded + 1 new).

**Artifacts on FAIL:** bell popover screenshot; `notifications.json.snapshot.json` before launch and after step 5.

#### Case `UT-V11-J-003`: Forward-version file is quarantined and the Inbox-reset row appears

**Covers AC:** AC-V11-J3, D-OQ1 (Inbox reset toast)

**Preconditions:**
- `~/.config/codans/notifications.json` seeded with envelope `{ "version": 99, "entries": [ /* 2 entries */ ] }` — a version greater than any the current build understands
- App not running
- No file matching `notifications.json.bak-*` exists in `~/.config/codans/`

**Steps:**
1. Launch the app fresh.
2. Wait for the ready signal "App launched".
3. Open the status-bar bell popover.

**Assertions:**
1. (File) A new file matching `~/.config/codans/notifications.json.bak-*` exists, with content equal to the seeded forward-version JSON.
2. (File) `~/.config/codans/notifications.json` either does not exist yet (no save fired) **or** exists in envelope shape with `.version == 1`.
3. (UI) The bell popover lists exactly 1 row: the "Inbox reset" entry. Its title reads "Inbox reset" (or equivalent wording established by the implementation, observable in the popover row's title text); its body references the backup file's basename.
4. (UI) Clicking the "Inbox reset" row marks it read and lands the user somewhere safe (the inbox popover stays open, or the focus does not jump to a missing pane). The case PASSES as long as no crash occurs.
5. (Negative) Relaunching the app a second time (without seeding a new forward-version file) does **not** add a second "Inbox reset" row.

**Artifacts on FAIL:** `ls -la ~/.config/codans/notifications.json*`; bell popover screenshot.

### Journey L: Coordinator drop logging is unobtrusive at default

**Persona:** `dev_running_long_task`
**Outcome:** Drop reasons are recorded at `.debug` level only — the default Console view stays uncluttered, but a user troubleshooting silence with the documented filter can see every drop.

#### Case `UT-V11-L-001`: Default Console view does not surface coordinator drops

**Covers AC:** D-OQ2 (logging severity)

**Preconditions:**
- `inAppEnabled = false` (so subsequent events drop on the in-app gate, generating drop lines)
- An unfocused pane available

**Steps:**
1. Start `log stream` with the default level filter (`level: default`) and subsystem `com.gumpw.codans.notifications`. Do **not** add `--debug`.
2. Trigger 3 notification-worthy events on the unfocused pane.
3. Wait 5 seconds.
4. Stop `log stream` and inspect captured lines.
5. Re-run `log stream` with `--debug` and the same subsystem.
6. Trigger 3 more events.
7. Wait 5 seconds; stop and inspect.

**Assertions:**
1. (Log) After step 4: zero lines containing `drop inAppDisabled` appear in the captured output.
2. (Log) After step 7: at least 3 lines containing `drop inAppDisabled` appear in the `--debug` captured output.

**Artifacts on FAIL:** the two captured log files.

### Journey D: Per-pane mute label write follows catalog debounce

**Persona:** `quiet_user`
**Outcome:** Toggling Mute notifications updates the in-memory state instantly (next menu open reflects the change) and writes to disk inside the project-standard catalog debounce window, not faster (no thrash on rapid toggles).

#### Case `UT-V11-D-001`: Rapid mute toggling coalesces to a single catalog save

**Covers AC:** D-OQ3 (setPaneLabel debounce)

**Preconditions:**
- Pane P exists, unmuted
- `catalog.json`'s mtime captured as `T0`
- App started

**Steps:**
1. Right-click pane P; select "Mute notifications" (toggle on).
2. Within 200 ms, right-click P; select "Mute notifications" again (toggle off).
3. Within 200 ms, right-click P; select "Mute notifications" again (toggle on, final state).
4. Right-click P; observe the checkmark state.
5. Wait ≥ the project-standard catalog debounce window plus 200 ms (per the patterns doc / project conventions; on the order of 500 ms).
6. Observe `catalog.json`'s mtime.

**Assertions:**
1. (UI) After step 4: the context menu shows "Mute notifications" with a checkmark (in-memory state reflects the latest toggle immediately, before any disk write).
2. (File) After step 6: `catalog.json`'s mtime is **later** than `T0` (a write did occur), and pane P's `labels` array contains `notifications:muted`.
3. (File) The number of catalog writes between step 1 and step 6 is small (a single trailing write after the rapid burst is the expected outcome; the case PASSES if the file's mtime moves at most twice in the entire window — a guard against per-toggle writes).

**Artifacts on FAIL:** `catalog.json` content after step 6; mtime history of `catalog.json` during steps 1–6 if observable.

## Coverage Matrix

Every spec Acceptance Criterion appears here with ≥ 1 covering case. The three design-resolution decisions (D-OQ1, D-OQ2, D-OQ3) are also covered because they introduce new user-observable behaviour beyond the spec's ACs.

| Spec AC / Resolution | Covered by |
|---|---|
| AC-V11-CP1 | UT-V11-CP-001 |
| AC-V11-CP2 | UT-V11-CP-001 |
| AC-V11-CP3 | UT-V11-CP-002 |
| AC-V11-S1 | UT-V11-S-001 |
| AC-V11-S2 | UT-V11-S-002 |
| AC-V11-S3 | UT-V11-S-003 |
| AC-V11-S4 | UT-V11-S-004 |
| AC-V11-S5 | UT-V11-S-005 |
| AC-V11-S6 | UT-V11-S-006 |
| AC-V11-S7 | UT-V11-S-007 |
| AC-V11-S8 | UT-V11-S-008 |
| AC-V11-P1 | UT-V11-P-001 |
| AC-V11-P2 | UT-V11-P-002 |
| AC-V11-M1 | UT-V11-M-001 |
| AC-V11-M2 | UT-V11-M-002 |
| AC-V11-M3 | UT-V11-M-003 |
| AC-V11-M4 | UT-V11-M-004 |
| AC-V11-CF1 | UT-V11-CF-001 |
| AC-V11-CF2 | UT-V11-CF-002 |
| AC-V11-CF3 | UT-V11-CF-003 |
| AC-V11-CF4 | UT-V11-CF-004 |
| AC-V11-CF5 | UT-V11-CF-005 |
| AC-V11-CF6 | UT-V11-CF-006 |
| AC-V11-CF7 | UT-V11-CF-007 |
| AC-V11-WT1 | UT-V11-WT-001, UT-V11-WT-006 (pinned-exclusion clause) |
| AC-V11-WT2 | UT-V11-WT-002 |
| AC-V11-WT3 | UT-V11-WT-003 |
| AC-V11-WT4 | UT-V11-WT-004 |
| AC-V11-WT5 | UT-V11-WT-005 |
| AC-V11-J1 | UT-V11-J-001 |
| AC-V11-J2 | UT-V11-J-002 |
| AC-V11-J3 | UT-V11-J-003 |
| D-OQ1 (Inbox-reset toast on quarantine) | UT-V11-J-003 |
| D-OQ2 (drop logs are .debug only) | UT-V11-L-001 |
| D-OQ3 (setPaneLabel debounce) | UT-V11-D-001 |
| AC-V11-S-OBS1 (Should-have: observable drop reasons) | UT-V11-CP-001 (step 6 asserts `drop inAppDisabled` log), UT-V11-CF-004 (`drop commandCancelled`), UT-V11-CF-005 (`drop userTypingRecently`) |

## Personas / Fixtures Added During Authoring

- Added persona `dev_running_long_task` to `docs/user-tests/_shared/personas.yaml`
- Added persona `settings_tweaker` to `docs/user-tests/_shared/personas.yaml`
- Added persona `quiet_user` to `docs/user-tests/_shared/personas.yaml`
- Bootstrapped `docs/user-test-patterns.md` (no prior project-wide testing-conventions doc existed; the file documents surfaces, allowed selectors, ready signals, fixture seeding, time / clock conventions, and artifacts-on-FAIL defaults).

No feature-local fixtures were introduced; every case seeds its own state from inline file paths under `~/.config/codans/`. If the cases prove burdensome to replay, a future revision can extract `_shared/fixtures/notifications/`.

## Open Questions

1. Several cases assume a documented way to deliver a single OSC 9 event into an unfocused pane (e.g., via the `codans` CLI's pane-input verb, or by scripting via shell). The exact mechanism is left to the runner — the patterns doc names file inspection and `log stream` as the universal fallback. **Default:** the runner picks; no case will be rejected for using a different OSC 9 delivery mechanism as long as the assertions remain observable.
2. `UT-V11-CF-005` requires asserting a keystroke into pane P landed within a 1-second window before a known time-anchored event. On a manual run this is best-effort; on an automated run the runner needs to inject the keystroke at a deterministic moment. **Default:** manual runs accept a generous re-take policy (3 attempts before FAIL); automated runs use a fake clock if available.
3. `UT-V11-S-003`'s "no system sound played" assertion depends on the runner's ability to either capture audio or inspect the macOS notification request. **Default:** if neither is available in the runner, the case FAILS soft (marked Inconclusive rather than PASS/FAIL) and the runner must record the limitation.

