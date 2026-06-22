# Product Spec: Notifications

**Status:** Shipped (v1 + v1.1)
**Author:** Gump (with Claude)

## Summary

codans runs coding agents and long-running terminal processes in parallel across
many Worktrees. Users routinely leave a Pane unattended while a build, test run,
or agent works in the background. Notifications **pull the user's attention back
to the exact Pane that needs them** — and only that Pane.

This spec defines which events qualify, how the user is alerted, where unread
state surfaces, and the user-controlled policy (settings, mute, thresholds,
worktree promotion). It deliberately stays small: no stdout scanner, no rule
editor, no hooks — those were the over-build of an earlier design that was
dropped before it shipped.

## Context

- Hierarchy: `Catalog → Project → Worktree → Tab → Pane`. A Pane is one Ghostty
  surface; multiple Panes split-arrange inside a Tab.
- Mechanism baseline borrowed from supacode (stdout-driven, hover popover); codans
  adds persistence, hierarchical roll-up, a policy chokepoint, and settings.

## Goals and Non-Goals

**Goals**

- Surface two event classes: a Pane is **waiting for input**, or a Pane
  **finished a long task / exited unexpectedly**.
- Alert through four channels: in-app unread indicators, in-app inbox popover,
  macOS banner, Dock badge — each independently controllable.
- Roll unread counts up the hierarchy to the highest ancestor the user can't see.
- Survive restarts. Let the user tune noise (command-finished threshold, per-pane
  mute) and triage faster (promote a notified worktree).

**Non-Goals**

- Stdout regex scanning / user-editable detection rules / template DSL.
- Hook-based detection (deferred until c3-hooks proves a need).
- In-app toast/inline banner; hover-popover entry point.
- Snooze / re-mark-as-unread; severity beyond "needs response" vs "informational".
- Cross-window aggregation; CLI access to the inbox.
- Per-event custom sound; configurable keystroke-suppression window; auto-demote.

## User Stories

- Running an agent, I'm alerted when it stops to ask a permission question.
- Running a long build in another Worktree, I'm alerted when it finishes.
- App in background → a macOS banner; app foreground on another Pane → a quiet
  count, not a banner (I'm already at the keyboard).
- App closed overnight → yesterday's unread are still there.
- A collapsed Project shows "something inside needs attention"; I drill in.
- Clicking a notification focuses the exact source Pane, across Worktrees.
- A noisy Pane → one-click "Mute notifications" on its context menu.
- Fast commands (< 10 s) and commands I cancelled (Ctrl-C) produce no banner.
- A noisy worktree at the bottom of a long list jumps to the top on first unread.

## Requirements

### Detection

- **N1 — Waiting for input.** Detected from the structured events the runtime
  emits — OSC 9 desktop notifications, the terminal bell — **not** by scanning
  stdout. Tools emitting neither are uncovered (documented limitation).
- **N2 — Long task finished.** The foreground process exits, the pane goes idle
  (`≥ 30 s`, had recent output, no prompt detected), or a shell-integration
  `commandFinished` (OSC 133) fires subject to the thresholds below.
- **N3 — Non-zero exit folds into N2**; the body/title reflect the status.
- **N4 — Per-Pane mute.** All Panes monitored by default; a per-Pane mute
  (`notifications:muted` label) suppresses N1/N2 for that Pane only.
- **N5 — Dedup window.** Same `(Pane, kind)` within 30 s updates the existing
  entry instead of adding one; unread count unchanged.

### Channels (each independently gated by Settings)

- **C1 — Unread indicators.** Boolean per hierarchy level + a numeric count on the
  status-bar bell (see Display).
- **C2 — Inbox popover.** A status-bar bell opens a newest-first popover with
  read/unread and the source `(project, worktree, tab, pane)`. No sidebar route.
- **C3 — macOS banner.** Posted only when the app is not frontmost **or** the
  source Pane is not the focused Pane. Gated by `systemEnabled` + authorization.
- **C5 — Dock badge.** Mirrors the global unread count; clears at 0. Gated by
  `dockBadgeEnabled`.

### Display — hierarchical roll-up

- **L1–L4.** Unread rolls `Pane → Tab → Worktree → Project`, shown **only at the
  deepest still-hidden ancestor**: L1 Pane = 2–4 px top line (green = finished,
  amber = waiting; amber wins if both); L2 Tab = dot before title; L3 Worktree =
  bell glyph replaces the row icon; L4 Project = dot after the name. L2–L4 are
  kind-agnostic booleans.
- **L5 — Status-bar bell.** The only popover entry; numeric count (`99+` past 100);
  hidden at 0.

### Read / navigate / persist

- **R1** focusing a Pane marks its unread read · **R2** clicking a row marks that
  row · **R3** "Mark all as read" · **R4** no snooze/re-unread.
- **G1** inbox-row click focuses the exact source · **G2** banner click activates +
  same focus · **G3** dead target → fall back to the deepest existing ancestor;
  the row stays, visibly flagged.
- **P1** survive restart · **P2** cap 500 (evict oldest read, then oldest unread)
  · **P3** age out > 7 days on launch · **P4** dead-target rows retained until
  P2/P3.

### Permission

- **PM1** on-demand prompt on first banner (not at launch) · **PM2** Settings shows
  status + Request / Open-System-Settings recovery.

### Settings — five controls (v1.1)

- **S1 In-app**, **S2 System**, **S3 Sound**, **S4 Dock badge** — four orthogonal
  toggles (in-app and system are independent, enabling "background-only").
  Sound is disabled-but-preserved when System is off. **S5** a read-only mute
  summary + Reveal-rules.json-in-Finder.
- **P-alert.** Flipping System on while denied shows an informational alert with an
  Open-System-Settings deep-link; the toggle stays on (captures intent).

### Command-finished thresholds (v1.1)

- **CF1** `commandFinishedEnabled` (default on) · **CF2** `commandFinishedThresholdSec`
  (default 10, `[1,3600]`) suppresses shorter commands · **CF3** exit 130/143
  (user cancel) always suppressed · **CF4** suppressed if a keystroke landed in
  the pane within 1 s (fixed) · **CF5** non-zero exit gets a glance-distinct title.

### Worktree promote (v1.1)

- **WT1** `moveNotifiedWorktreeToTop` (default on): first unread (`0 → N`) moves
  the worktree to the top of its Project's **unpinned** list, persisted · **WT2**
  fires only on the `0 → N` edge · **WT3** per-Project, never cross-project · **WT4**
  off → no reorder · **WT5** pinned worktrees are never auto-promoted; no
  auto-demote.

### Inbox JSON envelope (v1.1)

- **J1** `{ version: 1, entries: [...] }` on write · **J2** legacy bare-array reads
  transparently, rewritten on next flush · **J3** a greater-version file loads
  empty and is renamed `notifications.json.bak-<ISO>` once (downgrade-safe).

## Acceptance Criteria

(Behavioral assertions; the runnable form lives in
`docs/user-tests/notifications-v1-1.md`.)

**Detection** — D1 `read -p` prompt → N1 within 1 s · D2 `make build` exit → N2
with status · D3 output then 30 s idle → exactly one N2 · D4 muted pane → nothing
· D5 second trigger within 30 s → no second row.
**Channels** — C1 frontmost+focused → no banner, indicators only · C2 background
→ banner · C3 frontmost on a different Pane → banner · C4 Dock badge tracks count,
clears at 0.
**Roll-up** — L1 collapsed Project shows the dot, no descendant indicator · L2
expanded Project, worktree holds it → bell glyph · L3 active worktree, inactive
tab → tab dot · L4 active tab, unfocused pane → coloured line · L5 focus clears ·
L6 `99+` cap, no numeric per-level · L7 N1+N2 on one pane → amber.
**Navigation** — G1 full path focus · G2 banner parity · G3 deleted pane → land on
worktree, row stays flagged.
**Persistence** — P1 5 unread survive relaunch · P2 cap evicts oldest read then
unread, stays 500 · P3 8-day-old entry gone before render.
**Permission** — PM1 first banner prompts, in-app updates regardless · PM2 denied
shows Open-System-Settings · PM3 dismissed → Request re-prompts.

**v1.1 (`AC-V11-*`)** — **CP1–CP3** every notification flows one chokepoint reading
live settings; drops don't resurface on a later toggle-on. **S1–S8** the four
toggles take effect (in-app off → banner still posts, no inbox/Dock; system off →
inbox/Dock update, no banner; sound off → `content.sound == nil`; sound row
disabled when system off; dock-badge off stays cleared; mute summary text;
Reveal creates the file if absent). **P1–P2** denied + system-on → alert + deep-link.
**M1–M4** context-menu mute toggles the label / checkmark; muted pane drops before
the chokepoint; existing rows preserved. **CF1–CF7** enable/threshold/cancel/
keystroke/non-zero-title/UI-validation. **WT1–WT5** promote on the 0→N edge,
persisted; no retrigger; no demote; pinned exempt; off → no reorder. **J1–J3**
envelope write / legacy read / forward-version quarantine.

## Open Questions

Resolved during design (kept for the record): prompt-pattern set → moot (no
scanner; structured events only); inbox position → status-bar bell, no sidebar
route; split-visible focus → only the focused Pane clears unread; idle timer →
relies on the runtime's input-aware `paneIdle`; non-zero title → numeric exit in
the body, compact title; keystroke window → "any key into the pane"; promote
rollback on toggle-off → no (the manual order at that point is authority).

## References

- Design: [notifications.md](../design-docs/notifications.md)
- Hierarchy model: `apps/mac/CodansCore/{Catalog,Project,Worktree,Tab,Pane}.swift`
- Inbox storage primitive: `apps/mac/CodansCore/Notifications/InboxStorage.swift`
