# Product Spec: Notifications v1.1 — Settings, Coordinator, Command-Finished Threshold

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-05-20
**Supersedes (scoped):** specific Non-Goals in [notifications.md](notifications.md) — see §Relationship to v1.
**Depends on:** v1 of the Notifications system (shipped in [exec-plans/notifications.md](../exec-plans/notifications.md)) and the Settings v2 persistence layer (shipped in [exec-plans/settings-base.md](../exec-plans/settings-base.md)).

## Summary

v1 of the Notifications system shipped the detection translator, persistent inbox, four-level hierarchical roll-up indicators, status-bar bell with popover, and a placeholder Settings → Notifications pane that only reports macOS authorization status. The four user-controlled toggles (in-app / system / sound / dock badge) and the per-pane mute affordance were specced but never wired through to the runtime; the detector still posts banners unconditionally, and every command-finished event becomes a notification regardless of duration or whether the user is at the keyboard.

v1.1 closes that gap. It introduces a **single policy chokepoint** through which every emitted notification must pass — currently the detector calls the OS banner and the inbox directly — and wires the four settings toggles, a fifth per-pane mute switch, a command-finished duration threshold with intent-aware suppression, and a "promote noisy worktree to the top of its project" affordance into that chokepoint. Two structural concerns ride along: the inbox JSON gets a version envelope so future schema changes can migrate cleanly, and the OS banner's sound channel is folded into the banner-post API rather than implicit.

## Relationship to v1

| v1 status | v1.1 disposition |
|---|---|
| Goals — detection, persistence, roll-up, navigation, on-demand permission | **Retained unchanged.** v1.1 sits downstream of detection. |
| Non-Goal — **sound** | **Re-scoped IN.** v1.1 introduces a `soundEnabled` switch that controls whether OS banners carry the system default sound. No in-app sound channel is introduced. |
| Non-Goal — **Per-Pane mute** (specced as NH1 in v1 Nice-to-Have, partially wired) | **Promoted to Must-Have UI affordance.** The detector already honours `Pane.labels` containing `notifications:muted`; v1.1 adds the user-facing toggle. |
| Non-Goal — **User-editable detection rules / DSL** | **Still out.** v1.1 surfaces a read-only summary of existing mute state and a Reveal-in-Finder button; it does NOT add a rules editor. |
| Non-Goal — **Auto-promote worktree on unread arrival** (specced as NH2) | **Promoted to Must-Have, default ON.** Scope is per-Project worktree list reorder on the 0 → N unread transition only. |
| Non-Goal — **Per-event threshold / configurable suppression** | **Re-scoped IN for command-finished events only.** Other event sources keep their v1 behaviour. |
| Non-Goal — **Snooze, severity, hook-based detection, cross-window aggregation** | **Still out.** Same boundary as v1. |

## Context

Three classes of evidence forced the v1.1 scope.

1. **Inert toggles are worse than missing toggles.** The Settings v2 work landed four notification-related fields on `NotificationsSettings` and a placeholder pane that does not reflect them. A user who flips "Sound" off today sees the value persist but still hears the system sound on the next banner. This regression must close before the Settings window goes to dogfood.

2. **Command-finished noise is the dominant complaint vector during agent sessions.** v1 emits one `taskFinished` notification per `commandFinished` event regardless of duration, so a fast loop of small commands (`git status`, `ls`, shell-integration prompts) buries genuine "long task done" signals. The same is true for commands the user actively cancelled with Ctrl-C — the user knows the command ended; the banner is noise.

3. **Worktree triage stalls on scroll.** When a worktree at the bottom of a long Project list emits a notification, the user has to expand the project, scroll to find which worktree is lit, and click. Promoting that worktree to the top of its project removes one of those steps without changing global navigation.

## User Stories

- As a developer who flipped "Sound" off in Settings, I want the next macOS banner to be silent without restarting the app.
- As a developer who flipped "System notifications" off, I want the in-app bell badge and Dock badge to continue updating, but no banner to appear.
- As a developer who flipped "In-app notifications" off, I want the inbox to stop accumulating rows and the Dock badge to stay at zero, while OS banners are unaffected (the system surface and the in-app surface are independent switches).
- As a developer running a tight loop of fast commands, I want commands that complete in under 10 seconds to not produce a notification, so the inbox only carries long-running work.
- As a developer who pressed Ctrl-C to abort a command, I do not want a banner about it — I know it ended, and I aborted it.
- As a developer who started a long command and immediately started typing in that pane, I want no banner for the next short period — I am clearly attending to the pane.
- As a developer whose command exited non-zero, I want a banner whose title makes the failure obvious before I read the body.
- As a developer who finds one pane noisy, I want a one-click "Mute notifications" on that pane's context menu, so I don't have to edit a JSON file.
- As a developer who has a noisy worktree at the bottom of a long Project list, I want it bumped to the top of that project the moment it gets its first unread notification, so I can find it without scrolling.
- As a developer reviewing the Notifications settings pane, I want a one-line summary of how many mute rules / muted panes are active, plus a button that reveals the underlying rules file in Finder if I want to inspect or edit it manually.

## Requirements

### Must Have

#### Policy chokepoint

- [ ] **N1.1-CP1.** Every notification emitted by the detection layer passes through a single in-process policy chokepoint before any side effect (inbox append, OS banner post, Dock badge update). The chokepoint reads the live `NotificationsSettings` plus the macOS authorization status and is the only place those gates are evaluated.
- [ ] **N1.1-CP2.** The chokepoint reacts to settings mutations within one event tick — flipping `inAppEnabled` while a notification is en route either lets it through or drops it according to the value at decision time, not the value cached at detector startup.
- [ ] **N1.1-CP3.** The chokepoint does not buffer notifications across settings flips. If `inAppEnabled` is off when a notification arrives, the notification is dropped; flipping it back on later does not surface the missed entry.

#### Settings — five controls

- [ ] **N1.1-S1 — In-app notifications.** A boolean toggle on the Notifications settings pane controlling whether the inbox accumulates new rows. When `false`, new notifications are dropped before reaching the inbox, the Dock badge does not increment, and the bell popover shows no new entries (existing read/unread entries are preserved). OS banner posting is unaffected by this switch.
- [ ] **N1.1-S2 — System notifications.** A boolean toggle controlling whether `UNUserNotificationCenter` banners are posted. When `false`, no banner is posted, but the inbox + bell badge + Dock badge continue to update according to N1.1-S1. The toggle write persists regardless of authorization state.
- [ ] **N1.1-S3 — Sound.** A boolean toggle controlling whether the system default sound accompanies the OS banner. When `systemEnabled == false`, the Sound row is disabled in the UI with a tooltip explaining that sound requires the system banner; the persisted value is preserved across the disabled state. When `systemEnabled == true`, the toggle gates `UNNotificationContent.sound = .default`.
- [ ] **N1.1-S4 — Dock badge.** A boolean toggle controlling whether `NSApp.dockTile.badgeLabel` reflects the unread count. When `false`, the badge is cleared and stays cleared regardless of inbox state.
- [ ] **N1.1-S5 — Mute rules summary.** A read-only row on the Notifications pane showing `N rule(s), M pane(s) muted` based on the current `NotificationsSettings.mute` content, plus a "Reveal rules.json in Finder" button that selects `~/.config/codans/detection-rules.json` in Finder. When both counts are zero the summary text collapses to `No mute rules`.

#### Permission alert on system toggle (PM2 follow-up)

- [ ] **N1.1-P1.** When the user flips System notifications from `false` to `true` while `authStatus == .denied`, the pane surfaces a modal alert with body text indicating that macOS is blocking banners and offering an "Open System Settings" button that opens `x-apple.systempreferences:com.apple.preference.notifications?id=<bundle-id>` and a "Cancel" button. The toggle value remains `true` regardless of the user's alert response — the setting captures intent, the alert reports the OS-level block.
- [ ] **N1.1-P2.** When the deep-link variant with `?id=<bundle-id>` is not supported by the running macOS version, the pane falls back to opening `x-apple.systempreferences:com.apple.preference.notifications` (the top-level Notifications pane) and treats that as success.

#### Sound channel collapsed into banner-post

- [ ] **N1.1-SND1.** The banner-post API takes an explicit `playSound` parameter. The chokepoint passes the live `soundEnabled` value at the moment of post. The banner adapter is otherwise stateless w.r.t. settings — it does not subscribe to settings changes itself.

#### Per-pane mute UI

- [ ] **N1.1-M1.** A "Mute notifications" item appears in the pane's right-click context menu. Selecting it toggles the presence of `notifications:muted` in that pane's `Pane.labels`. The menu item shows a checkmark when the label is present.
- [ ] **N1.1-M2.** Muting a pane has the same effect the detector already implements: notifications originating from that pane are dropped before they reach the chokepoint.
- [ ] **N1.1-M3.** Existing inbox rows from a pane that is later muted are preserved. Muting affects future notifications only.

#### Command-finished threshold and suppression

- [ ] **N1.1-CF1 — Threshold toggle.** A boolean `commandFinishedEnabled` (default `true`) on `NotificationsSettings`. When `false`, command-finished events never produce a notification; all other event sources (OSC 9, bell, pane exit/crash, idle) are unaffected.
- [ ] **N1.1-CF2 — Threshold value.** An integer `commandFinishedThresholdSec` (default `10`, range `[1, 3600]`) on `NotificationsSettings`. When a command-finished event arrives with a duration shorter than this threshold, no notification is produced. The value is editable via a numeric input on the Notifications pane.
- [ ] **N1.1-CF3 — User-cancel suppression.** A command-finished event with exit status `130` (SIGINT) or `143` (SIGTERM) is suppressed regardless of duration or threshold — the user-initiated cancellation already conveys completion.
- [ ] **N1.1-CF4 — Recent-keystroke suppression.** When any user keystroke is delivered to the source pane within the 1 second preceding the command-finished event, the notification is suppressed. The 1 second window is a hardcoded constant in v1.1 — it does not surface in Settings.
- [ ] **N1.1-CF5 — Non-zero exit titling.** A command-finished event with a non-zero, non-cancellation exit status produces a notification whose title makes the failure obvious before the body is read. The exact phrasing is a design-doc concern; the requirement is that the title differs from the success/cancel cases in a glance-readable way.

#### Worktree auto-promote

- [ ] **N1.1-WT1.** A boolean `moveNotifiedWorktreeToTop` (default `true`) on `NotificationsSettings`. When `true`, the first unread notification arriving for a worktree (the 0 → N edge transition) reorders that worktree to the top of its parent Project's worktree list. When the worktree returns to zero unread, its position is **not** restored — the promoted order persists until the user reorders manually.
- [ ] **N1.1-WT2.** Promotion fires only on the 0 → N edge — subsequent notifications to the same already-promoted worktree do not retrigger the reorder.
- [ ] **N1.1-WT3.** Promotion is per-Project; no global reordering across projects, no cross-project priority.
- [ ] **N1.1-WT4.** When `moveNotifiedWorktreeToTop == false`, no reorder happens; the worktree list keeps the user's manual order.
- [ ] **N1.1-WT5.** The promotion mutates the persisted Catalog ordering — relaunching the app shows the worktree in its promoted position, not its original one.

#### Inbox JSON envelope

- [ ] **N1.1-J1.** The inbox JSON file gains a version envelope: `{ "version": 1, "entries": [InboxEntry, ...] }`. New writes always emit this shape.
- [ ] **N1.1-J2.** The loader transparently reads the legacy bare-array shape as version `1` and rewrites it in envelope shape on the next persistence flush. No user-visible state is lost.
- [ ] **N1.1-J3.** A file whose `version` is greater than the version the current build understands is treated as unreadable: the loader returns an empty inbox and the existing file is renamed to `notifications.json.bak-<ISO date>` once on next save, so a downgrade does not silently destroy a newer file's contents.

### Should Have

- [ ] **N1.1-OBS1 — Observable drop reasons.** When the chokepoint drops a notification, the reason (one of: `inAppDisabled`, `systemDisabled`, `paneMuted`, `commandFinishedDisabled`, `commandFinishedShort`, `commandCancelled`, `userTypingRecently`, `authorizationDenied`) is logged at debug level under the existing notifications log category. No persistent storage; structured log lines are sufficient.

- [ ] **N1.1-CF6 — Threshold input validation.** The numeric input for `commandFinishedThresholdSec` rejects values outside `[1, 3600]` at the UI layer; persistence layer clamps any out-of-range loaded value into the same range and logs the correction once.

### Won't Have (v1.1)

- Sound source other than `UNNotificationSound.default` (no per-event custom sounds, no in-app sound channel).
- Configurable "recent keystroke" window — the 1 second value is fixed.
- Per-rule notification threshold (only command-finished gets a threshold).
- Worktree auto-demote when unread returns to zero.
- Cross-project worktree promotion (a noisy worktree never beats a quiet one in another project).
- Snooze / re-mark-as-unread.
- Rules editor in the Settings pane (Reveal-in-Finder is the entire editing affordance).
- Mute-rules detail (rule IDs and pane IDs are summarized as counts only).

## Acceptance Criteria

AC IDs continue the v1 numbering line where natural (no clashes with `AC-D*`, `AC-C*`, `AC-L*`, `AC-G*`, `AC-P*`, `AC-PM*`). New IDs use the `AC-V11-*` prefix for v1.1-introduced behaviour.

The runnable form of these criteria will be expressed as user-test cases in `docs/user-tests/notifications-v1-1.md` once `/hs-test-spec` runs against this spec; the criteria below capture **intent** only.

### Policy chokepoint

- **AC-V11-CP1.** Given the detector translates a `TerminalEvent` into a candidate notification, when the chokepoint evaluates it, then any side effect (inbox append, OS banner post, Dock badge update) takes its enable decision from the live settings at evaluation time.
- **AC-V11-CP2.** Given a candidate notification is en route to the chokepoint, when the user flips `inAppEnabled` to `false` before the chokepoint executes, then the notification is dropped without an inbox row.
- **AC-V11-CP3.** Given `inAppEnabled` is `false`, when one notification is dropped and the user later flips it back to `true`, then no retroactive inbox row appears for the dropped event.

### Settings — five controls

- **AC-V11-S1.** Given `inAppEnabled == false` and `systemEnabled == true` and `authStatus == .authorized`, when the detector translates a notification-worthy event, then a banner is posted but no inbox row is added and the Dock badge does not increment.
- **AC-V11-S2.** Given `systemEnabled == false` and `inAppEnabled == true`, when the detector translates a notification-worthy event, then an inbox row is added and the Dock badge increments but no banner is posted.
- **AC-V11-S3.** Given `systemEnabled == true` and `soundEnabled == false`, when a banner is posted, then the banner's `UNNotificationContent.sound` is `nil`.
- **AC-V11-S4.** Given `systemEnabled == false`, when the Notifications pane renders, then the Sound row is disabled and a tooltip explains the dependency.
- **AC-V11-S5.** Given `dockBadgeEnabled == false` and one unread notification in the inbox, when the Dock badge would normally show `1`, then the badge stays cleared.
- **AC-V11-S6.** Given `NotificationsSettings.mute.mutedRuleIDs.count == 3` and `mute.mutedPaneIDs.count == 2`, when the Notifications pane renders, then the summary row reads `3 rule(s), 2 pane(s) muted`.
- **AC-V11-S7.** Given both mute counts are zero, when the Notifications pane renders, then the summary row reads `No mute rules`.
- **AC-V11-S8.** Given the user clicks "Reveal rules.json in Finder", then Finder activates with `~/.config/codans/detection-rules.json` selected. When that file does not exist, it is created from defaults first.

### Permission alert

- **AC-V11-P1.** Given `authStatus == .denied`, when the user flips System notifications from `false` to `true`, then a modal alert appears with an "Open System Settings" button and a "Cancel" button, and the toggle value is `true` regardless of alert outcome.
- **AC-V11-P2.** Given the user clicks "Open System Settings" in the alert, then System Settings opens at the Notifications pane (either at the app's row if the macOS version supports the `?id=` deep-link, or at the top of the Notifications pane as a fallback).

### Per-pane mute

- **AC-V11-M1.** Given a pane has no `notifications:muted` label, when the user opens the pane context menu, then "Mute notifications" is present without a checkmark.
- **AC-V11-M2.** Given the user selects "Mute notifications" on an unmuted pane, when the menu closes, then `notifications:muted` is added to that pane's labels and the next reopening of the menu shows a checkmark next to the item.
- **AC-V11-M3.** Given a muted pane, when an event that would otherwise produce a notification fires on that pane, then no chokepoint evaluation happens (the detector drops the event before chokepoint).
- **AC-V11-M4.** Given a pane has existing unread inbox rows, when the user mutes that pane, then existing rows are unchanged; only future events are dropped.

### Command-finished

- **AC-V11-CF1.** Given `commandFinishedEnabled == false`, when a `commandFinished` event arrives, then no notification is emitted regardless of duration or exit code.
- **AC-V11-CF2.** Given `commandFinishedEnabled == true` and `commandFinishedThresholdSec == 10`, when a `commandFinished` event arrives with `duration == 5s` and `exitCode == 0`, then no notification is emitted.
- **AC-V11-CF3.** Given the same configuration, when a `commandFinished` event arrives with `duration == 30s` and `exitCode == 0`, then a notification is emitted with success-toned title.
- **AC-V11-CF4.** Given any threshold value, when a `commandFinished` event arrives with `exitCode ∈ {130, 143}`, then no notification is emitted.
- **AC-V11-CF5.** Given a `commandFinished` event with `duration > threshold` and `exitCode == 1` arrives, when the user typed into the source pane in the 1 second preceding the event, then no notification is emitted.
- **AC-V11-CF6.** Given the same configuration but no keystroke in the prior 1 second, when the event arrives, then a notification is emitted whose title makes the non-zero exit visibly different from the success-toned title (e.g., explicit "failed" / `exit N` wording).
- **AC-V11-CF7.** Given the user attempts to enter `commandFinishedThresholdSec == 0` or `commandFinishedThresholdSec == 10000` in the Notifications pane, then the input is rejected at the UI layer and the persisted value remains unchanged.

### Worktree promotion

- **AC-V11-WT1.** Given `moveNotifiedWorktreeToTop == true` and worktree W3 sits third in its Project's worktree list with zero unread, when the first chokepoint-passing notification for W3 arrives, then W3 moves to position 0 of that Project's worktree list and the change is persisted to the catalog file.
- **AC-V11-WT2.** Given W3 is already at position 0 with one unread, when a second notification for W3 arrives, then no reorder happens (the order is already correct, and the 0 → N edge has already fired).
- **AC-V11-WT3.** Given W3 is at position 0 from a prior promotion, when the user marks all W3 notifications read, then W3 stays at position 0 (no auto-demote).
- **AC-V11-WT4.** Given `moveNotifiedWorktreeToTop == false`, when a notification fires for a worktree at any position, then no reorder happens.
- **AC-V11-WT5.** Given W3 was promoted and the app is then quit and relaunched, when the project loads, then W3 is at position 0 (the catalog has the promoted order).

### Inbox JSON envelope

- **AC-V11-J1.** Given a fresh install, when the inbox is first persisted, then `notifications.json` decodes as `{ "version": 1, "entries": [ ... ] }`.
- **AC-V11-J2.** Given a `notifications.json` file containing a bare top-level JSON array (legacy format), when the app launches, then the inbox loads its entries unchanged, and on the next persistence flush the file is rewritten in envelope form.
- **AC-V11-J3.** Given a `notifications.json` file with `version` greater than the current build understands, when the app launches, then the inbox loads as empty and the file is renamed to `notifications.json.bak-<ISO date>` exactly once before the next save.

## Open Questions

- **OQ-V11-1.** Should the non-zero-exit notification title include the exit code numerically (`Command failed (exit 1)`) or be qualitative (`Command failed`)? Proposal: include the numeric exit code in the body, keep the title compact for banner real estate. Confirm during design.
- **OQ-V11-2.** Should the recent-keystroke suppression window be measured from "any key into the pane" or "any key after the command actually started executing"? Proposal: any key into the pane — simpler to implement, and a user typing while a command is running is still attending the pane. Confirm during design.
- **OQ-V11-3.** When `moveNotifiedWorktreeToTop` flips from `true` to `false`, do prior promotions get rolled back? Proposal: no. The promotion was a discrete past event and the user's current manual order (whatever it is now) is the authority. Confirm during design.

## Out of Scope (deferred to v1.2 or later)

- An undo affordance for worktree promotion ("show original order").
- A "test notification" button in the Settings pane that fires a fake event through the full chokepoint, for verifying settings without driving an actual long command.
- Per-event-kind sound choice (only the system default sound is wired in v1.1).
- A snooze-this-pane verb distinct from mute (mute is permanent until toggled off; v1.2 might introduce a time-bounded version).
- CLI access to the chokepoint (no `codans notifications` subcommand in v1.1).

---

## References

- v1 product spec: [notifications.md](notifications.md) — defines the underlying event sources, the inbox model, the roll-up indicators, and the navigation flow that v1.1 inherits.
- Settings v2 base: [exec-plans/settings-base.md](../exec-plans/settings-base.md) — defines `SettingsStore`, `NotificationsSettings`, and the disk-debounced persistence pipeline that v1.1's new fields ride on.
- Settings pane design (T2): [design-docs/settings-notifications.md](../design-docs/settings-notifications.md) — the prior design pass for the UI; v1.1 supersedes its coordinator-wiring section with the broader chokepoint design in [notifications-v1-1.md](../design-docs/notifications-v1-1.md) (forthcoming).
- Inbox storage primitive: `apps/mac/CodansCore/Notifications/InboxStorage.swift` — pure dedup/age/cap functions; v1.1's envelope work touches only the file I/O wrapper, not these primitives.
