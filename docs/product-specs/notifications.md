# Product Spec: Notifications

**Status:** Approved
**Author:** Gump (with Claude)
**Date:** 2026-04-30

## Summary

codans is a multi-pane workbench for running coding agents and other long-running terminal processes in parallel across many Worktrees. Users routinely leave a Pane unattended — switch to another Worktree, another tab, or another app entirely — while a build, test run, or AI agent works in the background. Notifications exist to **pull the user's attention back to the exact Pane that needs them**, and only that Pane.

This spec defines the v1 of the notification system: which events qualify as notifications, how the user is alerted, and where unread state surfaces in the UI. It deliberately replaces and shrinks the in-flight C6 design (`docs/design-docs/c6-agent-notifications.md` / `c6-agent-notifications-v2.md`), which over-built around hooks and rule editors before the actual user need was tested.

## Context

- The hierarchy is `Catalog → Project → Worktree → Tab → Pane`. A Pane is a single Ghostty terminal surface; multiple Panes split-arrange inside a Tab.
- A reference implementation in [supacode](https://github.com/anysphere/supacode) sits at the simple end of the design space: stdout-driven, no persistence, hover popover only. The C6 worktree (`design+c6-agent-notifications`) sits at the complex end: 24 files, persisted JSON, FSM, rule DSL, permission delegate. v1 of codans lands closer to supacode in mechanism, with the addition of persistence and hierarchical roll-up badges.

## Goals and Non-Goals

**Goals**

- Reliably surface two events: a Pane is **waiting for user input**, or a Pane has **finished a long task / exited unexpectedly**.
- Deliver alerts through four channels: in-app unread count, in-app inbox list, macOS system banner, Dock badge.
- Roll unread counts up the hierarchy so the count appears at the highest ancestor the user cannot currently see.
- Survive app restarts so a notification missed overnight is still visible the next morning.

**Non-Goals (v1)**

- Sound (in-app or system).
- Pane-internal toast / inline banner.
- Hover popover entry point (supacode-style).
- User-editable detection rules or template DSL.
- Snooze / re-mark-as-unread.
- Hook-based detection (deferred until c3-hooks lands and proves a user need).
- Cross-window / multi-window aggregation.
- Severity levels beyond "needs response" vs. "informational".

## User Stories

- As a developer running an AI agent in one Pane, I want to be alerted when the agent stops to ask me a permission question, so I do not leave it idling unanswered while I work elsewhere.
- As a developer running a long build in another Worktree, I want to be alerted when the build finishes (success or failure), so I can immediately review and move on.
- As a developer with the app in the background, I want a macOS banner so I notice the alert without having to keep the app foreground.
- As a developer with the app in the foreground but on a different Pane, I want a quiet visual count, not a banner — I am already at the keyboard.
- As a developer with the app closed overnight, I want yesterday's unread notifications to still be there when I reopen, so I can audit what happened.
- As a developer scanning the sidebar, I want a single number on a collapsed Project to tell me "something inside needs attention", and to drill in to find which Worktree / Tab / Pane it is.
- As a developer who clicked a notification, I want the app to focus the exact Pane that produced it, even if it is in a different Worktree.
- As a developer for whom one specific Pane is too noisy (e.g. a watcher with frequent rebuilds), I want to silence notifications from that Pane without affecting others.

## Requirements

### Must Have

#### Detection (what produces a notification)

- [ ] **N1 — Waiting for input.** Detect when a Pane is blocked on a user prompt by scanning the terminal output for a known set of prompt patterns (Claude Code permission line, generic `(y/n)` style prompts, shell `read -p` prompts, etc.). The pattern set is hard-coded in v1.
- [ ] **N2 — Long task finished.** Detect when a Pane has been actively producing output and then either (a) the foreground process exits, or (b) the Pane has produced no output for `T_idle` seconds while no interactive shell prompt is detected. `T_idle` defaults to 30 s.
- [ ] **N3 — Process exited non-zero is rolled into N2.** Both clean exit and crash funnel through the same "task finished" notification; the body text reflects the exit status.
- [ ] **N4 — Monitored panes.** All Panes are monitored by default. Each Pane has a per-Pane "notifications enabled" toggle (default on); turning it off suppresses N1 and N2 for that Pane only.
- [ ] **N5 — Dedup window.** If the same Pane produces the same notification kind within 30 s of a prior one, the system updates the existing entry rather than creating a new one. Unread count is not double-counted.

#### Channels (how the user is alerted)

- [ ] **C1 — Unread indicators.** A boolean unread indicator at each hierarchy level (Project / Worktree / Tab / Pane), plus a numeric unread count on the single status-bar bell entry. Per-level shape is defined in the Display section.
- [ ] **C2 — Inbox popover.** A bell button in the worktree status bar opens a popover listing all notifications newest-first, with read/unread state and the originating `(projectID, worktreeID, tabID, paneID)` tuple. There is no sidebar route or dedicated inbox page.
- [ ] **C3 — macOS system banner.** Sent through `UNUserNotificationCenter` only when **either** the app is not the frontmost app **or** the originating Pane is not the focused Pane in the focused Tab. When the user is already looking at the Pane, no banner fires (the in-pane output is the alert).
- [ ] **C5 — Dock badge.** The Dock tile badge mirrors the global unread count. When the count is 0, the badge clears.

#### Display (where unread state surfaces)

- [ ] **L1–L4 — Hierarchical roll-up indicators.** Unread state rolls up `Pane → Tab → Worktree → Project`. Each level emits its indicator **only if that level is currently collapsed or not focused** — if the user can already see deeper, the indicator is suppressed at the higher level and shown only at the deepest still-hidden ancestor. Per-level visual:
  - **L1 Pane** — a 2–4 px high coloured line across the top edge of the Pane's chrome. **Green** = task finished (N2). **Amber** = waiting for input (N1). When both kinds are unread on the same Pane, amber wins.
  - **L2 Tab** — a small unread dot rendered immediately before the Tab title text. Boolean only (no count, no kind distinction).
  - **L3 Worktree** — the row's leading icon is replaced by a bell glyph for the duration of the unread state. Boolean only.
  - **L4 Project** — a small unread dot rendered immediately to the right of the Project name. Boolean only.
- [ ] **L5 — Status-bar bell.** The single popover entry. The bell carries a numeric unread count (≥ 100 displays as `99+`). Hidden / unbadged when unread total is 0.
- [ ] **Visual distinction (kind).** Kind distinction (N1 vs N2) is preserved only at L1 (Pane line colour) and inside the popover (kind icon per row). L2–L4 indicators are kind-agnostic — the user opens the popover or descends the hierarchy to learn which kind is waiting.

#### Read / unread semantics

- [ ] **R1 — Focusing a Pane marks all unread notifications for that Pane as read.**
- [ ] **R2 — Clicking a row in the inbox marks that single row as read.**
- [ ] **R3 — A "Mark all as read" action is available in the inbox.**
- [ ] **R4 — No re-mark-as-unread or snooze in v1.**

#### Click-to-navigate

- [ ] **G1 — From inbox row.** Clicking an inbox row focuses the originating `(projectID, worktreeID, tabID, paneID)` exactly; all four levels are revealed and selected.
- [ ] **G2 — From macOS banner.** Clicking a system banner brings the app to the front and performs the same focus action as G1.
- [ ] **G3 — Dead targets.** If the originating Pane / Tab no longer exists at click time, navigation falls back to the deepest still-existing ancestor (Worktree, then Project, then the inbox view itself). The notification row is not deleted.

#### Persistence

- [ ] **P1 — Survive restart.** Inbox content persists across app launches.
- [ ] **P2 — Cap.** At most 500 entries retained globally. When full, the oldest read entry is evicted; if all 500 are unread, the oldest unread is evicted.
- [ ] **P3 — Age out.** Entries older than 7 days are removed on app launch and once per day thereafter, regardless of read state.
- [ ] **P4 — Dead-target retention.** Notifications whose originating Pane / Tab / Worktree has been deleted are retained until P2 / P3 evict them; only navigation behavior changes (G3).

#### Permission

- [ ] **PM1 — On-demand prompt.** The `UNUserNotificationCenter` authorization prompt is triggered the first time a notification would be delivered through C3, not at app launch.
- [ ] **PM2 — Settings re-request.** A Notifications section in the Settings window shows the current authorization status and offers a "Request permission" button when the status is `notDetermined`, plus a "Open System Settings" deep-link when the status is `denied`. This is the recovery path if the user dismissed the on-demand prompt.

### Nice to Have

- [ ] **NH1 — Per-Worktree mute toggle** in the Worktree row context menu (silences all Panes within).
- [ ] **NH2 — Auto-promote** a Worktree to the top of the sidebar list on the first unread arrival within it. (Trade-off: nice for visibility, can feel jumpy.)
- [ ] **NH3 — Inbox grouping toggle** to group consecutive entries from the same Pane.

### Won't Have (v1)

- Sound.
- Pane-internal toast.
- Hover popover.
- User-editable detection rules / templates / DSL.
- Severity beyond N1 vs. N2.
- Snooze / re-mark-as-unread.
- Hook-based detection.
- Cross-window aggregation.

## Acceptance Criteria

### Detection

- **AC-D1.** Given a Pane running `read -p "continue? "`, when the prompt appears, then within 1 s an N1 notification is created with `kind = waitingForInput`.
- **AC-D2.** Given a Pane running `make build`, when the foreground process exits, then within 1 s an N2 notification is created whose body includes the exit status.
- **AC-D3.** Given a Pane producing output every 5 s for 2 minutes, when output stops for 30 s and no interactive prompt is detected, then exactly one N2 notification is created.
- **AC-D4.** Given a Pane with notifications disabled, when an N1 trigger fires, then no notification is created and no badge changes.
- **AC-D5.** Given an N1 notification was just created for Pane P, when a second matching trigger fires within 30 s on the same Pane, then no second notification is created and the unread count is unchanged.

### Channels

- **AC-C1.** Given the app is frontmost and Pane P is the focused Pane, when an N1 fires for P, then no system banner is shown; only in-app indicators and the inbox row update.
- **AC-C2.** Given the app is in the background, when an N1 fires, then a macOS banner is delivered.
- **AC-C3.** Given the app is frontmost on Pane Q (different from N1's source Pane P), when N1 fires for P, then a macOS banner is delivered.
- **AC-C4.** Given the global unread count is N, when the count changes, then the Dock tile badge reflects the new value within 1 s; at N = 0 the badge clears.

### Display roll-up

- **AC-L1.** Given Project A is collapsed in the sidebar with any unread notification inside, then the Project A row shows the unread dot to the right of its name and no descendant indicator is rendered.
- **AC-L2.** Given Project A is expanded but Worktree W1 holds the unread, then no dot on Project A; W1's leading icon is the bell glyph.
- **AC-L3.** Given W1 is the active Worktree and Tab T1 (inactive) holds the unread, then W1's leading icon is the normal git/PR icon; T1's title shows the unread dot prefix.
- **AC-L4.** Given T1 is the active Tab and Pane P (not focused) holds the unread, then T1's title shows no dot; Pane P's chrome shows the coloured top line — green for an N2-only Pane, amber for a Pane with any N1.
- **AC-L5.** Given a Pane is focused and has unread notifications, when the user focuses it (R1), then all those unread are marked read and indicators at every level update accordingly.
- **AC-L6.** Given the global unread total is 100, then the status-bar bell badge text is `99+`. Per-level indicators (Project / Worktree / Tab / Pane) never render numeric counts.
- **AC-L7.** Given a Pane has both an unread N1 and an unread N2, then its top line is amber.

### Navigation

- **AC-G1.** Given the user clicks an inbox row whose source `(P, W, T, Pn)` all still exist, then the app navigates to Project P, Worktree W, Tab T, Pane Pn, expanding any collapsed ancestors.
- **AC-G2.** Given a macOS banner click, then the app activates and performs the same navigation as AC-G1.
- **AC-G3.** Given an inbox row whose source Pane has been deleted but whose Worktree still exists, when clicked, then navigation lands on the Worktree, the inbox row remains, and the user sees a subtle "source no longer exists" indicator.

### Persistence

- **AC-P1.** Given 5 unread notifications, when the app is quit and relaunched, then those 5 notifications are present and still unread.
- **AC-P2.** Given the inbox already holds 500 entries (mix of read/unread) and a new one arrives, then the oldest read entry is evicted; if no read entry exists, the oldest unread is evicted; total count remains 500.
- **AC-P3.** Given an inbox entry timestamped 8 days ago, when the app launches, then that entry is removed before the inbox renders.

### Permission

- **AC-PM1.** Given a fresh install where the user has never been prompted, when the first notification would be delivered through C3, then macOS shows the standard authorization prompt; meanwhile the in-app inbox / badges update unconditionally.
- **AC-PM2.** Given the user denied permission, when they open Settings → Notifications, then the panel shows "Denied" and exposes an "Open System Settings" link to grant permission manually.
- **AC-PM3.** Given the user dismissed the prompt without choosing, when they open Settings → Notifications and click "Request permission", then the macOS prompt is presented again.

## Design

To be specified in a follow-up design doc that supersedes `docs/design-docs/c6-agent-notifications.md` and `c6-agent-notifications-v2.md`. Scope of the design doc:

- Detection mechanism (stdout scanner, idle timer, prompt patterns).
- Notification model and inbox storage format / location.
- Roll-up badge computation given the live `Catalog` / focus state.
- Navigation request handling against the existing hierarchy router.
- macOS authorization integration and Settings panel.

The design doc must explicitly justify any retained pieces from the C6 worktree; the default disposition is to delete and re-derive.

## Open Questions

- **OQ1.** What exact set of prompt patterns ships in v1's hard-coded scanner? (Proposal: Claude Code permission line, `[y/N]` and `(y/n)` shell prompts, `read -p`. To be expanded as users hit gaps.)
- **OQ2.** Where in the sidebar does the L5 inbox view live — a dedicated top-level entry (alongside Worktree list), or a tab within an existing pane? (Proposal: top-level entry, demoted in v1 to a single "Inbox" row with badge.)
- **OQ3.** When a Pane is split-visible (two Panes side-by-side, both visible), does focusing the Tab clear unread on both Panes (R1) or only the focused one? (Proposal: only the focused Pane; visible-but-not-focused still counts as unread.)
- **OQ4.** Does N2's idle-timer scanner pause while the user is typing in that Pane? (Proposal: yes — keystrokes in the Pane reset the idle timer, since the user is plainly already attending to it.)

---

## References

- Reference implementation (mechanism baseline): `supacode/Clients/Notifications/` and `supacode/Features/Repositories/Views/*Notification*View*.swift`.
- Prior design (to be replaced): `docs/design-docs/c6-agent-notifications.md`, `docs/design-docs/c6-agent-notifications-v2.md`.
- Hierarchy model: `apps/mac/CodansCore/{Catalog,Project,Worktree,Tab,Pane}.swift`.
