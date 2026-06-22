# Design Doc: Notifications

**Status:** Shipped (v1 + v1.1 hardening)
**Author:** Gump (with Claude)

## Context and Scope

The notification subsystem pulls the user's attention back to the exact Pane
that needs them — a coding agent blocked on input, or a long task that finished
— and only that Pane. See the [Notifications product spec](../product-specs/notifications.md)
for capabilities and acceptance criteria.

The hierarchy is `Catalog → Project → Worktree → Tab → Pane`; a Pane is one
Ghostty surface, multiple Panes split-arrange inside a Tab via `SplitTree<PaneID>`.

This design replaced an earlier, over-built "C6" line (an FSM tracker, a
user-editable rule DSL, a stdout scanner, ~2900 LOC) that was never adopted on
`main`. The decision record below keeps the *why* of that rejection; the C6
design docs themselves were deleted (recoverable from git history).

## Goals and Non-Goals

**Goals**

- Translate the structured events the runtime already emits (OSC 9 desktop
  notification, terminal bell, OSC 133 command-finished, child-exit, idle,
  crash) into notifications — **without** a stdout scanner.
- Persist the inbox across restarts via the existing `AtomicFileStore`.
- Surface unread state as hierarchical roll-up badges (shown only at the deepest
  hidden ancestor) plus one status-bar bell with a popover inbox.
- Route every emitted notification through **one policy chokepoint** that honours
  the user's settings and macOS authorization before any side effect.
- Deliver macOS banners only when the source Pane is not the user's focus.

**Non-Goals**

- No stdout regex scanning (see Alternatives A1). Tools that emit neither OSC 9
  nor the bell nor OSC 133 are silently uncovered — documented, not patched.
- No hook-based detection (c3-hooks). Reserved for a future additive source.
- No user-editable detection rules / template DSL / severity levels / snooze /
  in-app toast surface / per-event sound choice.
- No CLI access to the inbox. The model lives in `CodansCore` so surfacing it
  later is small, but `codans` does not query it.

## Design Overview

The driving insight, in two halves:

1. **The runtime already exposes the structured events we need** — so detection
   is a small *translator* downstream of the existing event stream, not a new
   detection engine.
2. **Detection and policy must stay separate.** Mixing "translate event into a
   candidate" with "decide whether to surface it" is what made the first detector
   grow into a thicket of inline `if`s the moment settings appeared. So:
   - `DetectionTranslator` — **pure**; `(event, context) → Step`. Grows knobs as
     inputs, never as state.
   - `NotificationDetector` — orchestration: catalog walk, muted-label drop,
     `hasProducedOutput`, keystroke context; emits a `Candidate`.
   - `NotificationCoordinator` — the **policy chokepoint**: reads live settings +
     auth status, dispatches to the side-effect sinks. The only place gates live.

```
                                    ┌──────────────────────────┐
                                    │ SettingsStore (v3)       │
                                    │ .notifications: 7 fields │
                                    └─────────┬────────────────┘
                                              │ NotificationSettingsReader
                                              ▼
   ┌──────────────┐  TerminalEvent   ┌────────────────────────┐
   │ TerminalEng. │─────────────────▶│ NotificationDetector   │
   └──────────────┘                  │  • catalog walk        │
   ┌──────────────┐  key input       │  • muted-label drop    │
   │ GhosttyView  │─────────────────▶│  • DetectionTranslator │
   └──────────────┘                  └────────┬───────────────┘
                                              │ Candidate (or drop)
                                              ▼
                       ┌──────────────────────────────────────┐
                       │  NotificationCoordinator (chokepoint) │
                       │  • read settings + authStatus         │
                       │  • dispatch sinks  • unreadByWorktree  │
                       └──┬─────────┬─────────┬─────────┬──────┘
                          ▼         ▼         ▼         ▼
                    ┌────────┐ ┌────────┐ ┌──────┐ ┌──────────────────┐
                    │ Store  │ │OSNotif.│ │ Dock │ │HierarchyClient   │
                    │.append │ │.post(  │ │Badger│ │.reorderWorktrees │
                    │        │ │playSnd)│ │      │ │                  │
                    └────────┘ └────────┘ └──────┘ └──────────────────┘
```

External touchpoints: `UNUserNotificationCenter`, `NSApp.dockTile`,
`AtomicFileStore`. The only non-`TerminalEvent` input is the keystroke
side-channel (`PaneKeyboardActivityTracker`).

## Detection (`DetectionTranslator`, pure)

`translate(_ event: TerminalEvent, context: Context) -> Step` is pure; `Context`
carries `hasProducedOutput`, `lastUserKeystrokeAt: [PaneID: Date]`, an injected
`now`, and the command-finished settings. Translation table:

| Source event | Becomes | Kind |
|---|---|---|
| `desktopNotification(title, body)` (OSC 9) | that title/body | `.waitingForInput` if it matches a small heuristic ("permission"/"approval"/"input"/"?"), else `.taskFinished` |
| `bellRang` | "Pane rang the bell" | `.waitingForInput` |
| `commandFinished(exitCode, duration)` (OSC 133) | see suppression rules below | `.taskFinished` |
| `paneExited(code, signal)` | "pane exited" + status | `.taskFinished` |
| `paneCrashed(reason)` | "pane crashed: …" | `.taskFinished` |
| `paneIdle(duration)` | "task idle for …" | `.taskFinished` — only when `duration ≥ 30s` AND the pane produced output recently AND no shell prompt detected |

**Command-finished suppression** — all decisions live in the pure layer, keyed
only on the injected context (the keystroke timestamp is the one external input):

1. `commandFinishedEnabled == false` → drop (`commandFinishedDisabled`).
2. exit `130` (SIGINT) / `143` (SIGTERM) → drop (`commandCancelled`) — the user
   cancelled; they know it ended.
3. `duration < commandFinishedThresholdSec` → drop (`commandFinishedShort`).
4. a keystroke landed in the source pane within the **1 s** before the event →
   drop (`userTypingRecently`) — the user is plainly attending the pane.
5. otherwise emit, with a **glance-distinct title for non-zero exit** ("Command
   failed (exit N)" vs "Command finished").

`Step` carries an optional `drop: DropReason?` so a suppression is logged on the
same path as the coordinator's later drops. `DropReason` lives in `CodansCore`
so the pure translator and the app-layer coordinator share one string-coded enum.

**Keystroke side-channel.** `PaneKeyboardActivityTracker` (`@MainActor`, owns
`[PaneID: Date]`) records on every `GhosttySurfaceView.sendKey`, purged on pane
teardown. Why not a `TerminalEvent.paneUserInput` case: keystroke cadence is
human-scale (~10 Hz) and only the detector cares — a new event case would add
noise to every `TerminalEvent` consumer (`RootFeature`, tests, analytics). Why
not `Pane.labels` / a `@Observable` field: labels are persisted (a catalog save
per keystroke) and an `@Observable` field would force a SwiftUI re-render per
keystroke, which `GhosttySurfaceView` deliberately avoids.

## Policy chokepoint (`NotificationCoordinator`)

A `@MainActor final class` (not a reducer — it holds no UI state; not
`@Observable` — nothing binds to it), constructed once at bringup. It consumes a
`Candidate { entry: InboxEntry, sourceIsFocused: Bool }` and returns a `Decision`
(`.posted(…)` / `.dropped(reason:)`) so tests assert behaviour without inspecting
collaborators. Gate order:

1. `sourceIsFocused` → drop. (The in-pane output is itself the alert.)
2. `inAppEnabled` → append to inbox + recompute Dock badge (the Dock gate is
   inside). **In-app and system are independent switches**: "background-only"
   mode is in-app off + system on.
3. `systemEnabled && authStatus == .authorized` → `OSNotifier.post(entry, playSound: soundEnabled)`.
4. `moveNotifiedWorktreeToTop` AND the worktree's unread just went `0 → N` →
   `reorderWorktrees`.

The coordinator owns an `unreadByWorktree: [WorktreeID: Int]` cache (rebuilt from
the inbox at init, updated incrementally) so the `0 → N` edge is detected without
re-scanning the inbox. Driving promote from this cache — not by observing the
store — avoids re-promoting on every `markRead`/dedup-collapse.

`NotificationSettingsReader` is the seam onto `SettingsStore` + cached auth
status; a fake drives tests. Auth status is re-read on `applicationDidBecomeActive`
so a System-Settings change lands without restart.

**`OSNotifier.post(_ entry:, playSound:)`** takes sound per call — a stateful
`playSound` property would be racy when a batch of posts straddles a settings
flip. The adapter is otherwise ignorant of `SettingsStore`.

## Settings (`NotificationsSettings`)

A sixth top-level section on `Settings` (v3), additive — **no version bump**, all
fields optional via `decodeIfPresent` (a pre-v1.1 `settings.json` decodes to
defaults). Fields, all defaulting on/sensible: `inAppEnabled`, `systemEnabled`,
`soundEnabled`, `dockBadgeEnabled`, `moveNotifiedWorktreeToTop`,
`commandFinishedEnabled`, `commandFinishedThresholdSec` (default 10, clamped
`[1,3600]` on decode and at the UI layer), and a count-only `mute` sub-struct.

**Why four orthogonal booleans, not one `level` enum** (A5): users want the
cross-products an enum can't express (in-app off + system on = "background-only").
Sound and Dock badge are further independent axes.

The Settings → Notifications pane is **direct-view + `SettingsStore`** (no
reducer), matching `SettingsGeneralView`. Behaviours that are durable contracts
(not the exact SwiftUI layout): the Sound row is `.disabled` when `systemEnabled`
is off but its persisted value is **preserved** (flipping system back on restores
intent); flipping System on while `authStatus == .denied` shows an informational
alert with an "Open System Settings" deep-link (`?id=<bundle-id>` with a
top-level-pane fallback) and the toggle stays `true` (it captures intent, not the
OS block); the mute row is a summary + Reveal-in-Finder only (no rules editor).

## Storage (`NotificationStore` + `InboxFile`)

The inbox is `[InboxEntry]` in memory, persisted to
`~/.config/codans/notifications.json`. The record type is **`InboxEntry`**, not
`Notification` — the latter clashes with `Foundation.Notification` at any call
site importing both Foundation and CodansCore. Pure inbox mutation
(dedup/age/cap) lives in `CodansCore.InboxStorage` (a `nonisolated` enum) so it
is testable independent of the `@MainActor` store. `InboxEntry.source` stores raw
IDs (`projectID/worktreeID/tabID/paneID`), not weak refs — the catalog mutates
independently; navigation re-resolves on click.

Sweeps run on load before the inbox is exposed, and the cap is enforced on every
append: **age** (drop > 7 days), **cap** (> 500 → evict oldest read first, then
oldest unread). **Dedup window**: an incoming `(paneID, kind)` within 30 s of the
previous updates the existing row's body/timestamp instead of appending. Saves
are debounced 250 ms off the MainActor.

**Versioned envelope (`InboxFile`).** The file is `{ version: 1, entries: [...] }`.
The loader: missing → `nil`; decode `Envelope` → if `version > current`, rename to
`notifications.json.bak-<ISO>` and return `[]`, else return entries; on envelope
failure, try the **legacy bare array** (one release of back-compat); on both
failures, return `[]` without renaming (may be a partial write the next save
overwrites). Why a version key, not a filename bump (A7): renaming orphans every
existing user's inbox; the key is one decode-try with zero file ops on the happy
path. Why not fold into the settings version: the inbox is its own file with its
own write cadence — coupling would force a settings-save per inbox-save.

## Roll-up (`RollupIndex`)

Computed in a TCA reducer derivation (catalog is tens of nodes; O(N) recompute on
each input delta is fine), rebuilt when either input changes: the unread set, and
focus state (`focusedPaneID`, active tab/worktree, expanded sets). Per-level
indicators are **boolean** except the status-bar bell, which carries the numeric
global unread count (mirrored by the Dock badge).

**Invariant — each unread contributes to exactly one level: the deepest hidden
ancestor.** L4 Project (collapsed) · L3 Worktree (project expanded, worktree not
active) · L2 Tab (worktree active, tab not) · L1 Pane (tab active, pane not
focused). At L1, an unread `.waitingForInput` (amber) overrides `.taskFinished`
(green). `globalUnreadCount` is the un-rolled-up total ("every unread, regardless
of whether you can see its source"). The badge count must be a **computed read of
the live catalog**, not a cached field — a cache goes stale on catalog-only
mutations (e.g. removing a non-selected worktree that orphans an unread) because
no selection signal fires to invalidate it.

Each surface (sidebar Project dot, Worktree bell glyph, Tab dot, Pane top line)
reads `RollupIndex` via a small Equatable slice; L1–L4 are visual-only. The
status-bar bell is the **only** popover entry (A5: per-level scoped popovers
rejected — position in the hierarchy already answers "where", and a scoped
popover on a rolled-up level would show entries whose real source is several
levels deeper).

## Navigation

`RootFeature.focusHierarchyPath(SourcePath, fallback:)` walks Project → Worktree
→ Tab → Pane, setting selection at each level. **Dead-target fallback** (G3): if a
level no longer exists, land on the deepest still-existing ancestor; the inbox row
remains, flagged with a faded/struck-through source label. This is `RootFeature`'s
responsibility (it owns selection), not `PaneActionRouter`'s (intra-pane/-tab).

## Worktree promote

`HierarchyClient.reorderWorktrees(projectID, worktreeID, .moveToFrontWithinUnpinned)`
moves a worktree to the front of the **unpinned** segment on its first unread
(`0 → N` edge). **Pinned worktrees never auto-reorder** — pinned is a stronger
explicit signal than "got a notification". No auto-demote when unread returns to
0 (the promotion was a discrete past event; the user's current order is
authority). The mutation belongs to catalog ownership (one linear writer surface,
matching `setWorktreePinned`/`reorderProjects`); the coordinator only decides
*when*. Orthogonal to `bumpProjectActivity` (project-level sort) — the coordinator
does **not** duplicate that call; the detector keeps it.

## Per-pane mute

Mute is the string label `"notifications:muted"` in `Pane.labels` (Codable /
persisted — no new field). A pane right-click "Mute notifications" item toggles it
via `HierarchyClient.setPaneLabel` (debounced through `CatalogStore.scheduleSave`,
in-memory mutation immediate so a re-opened menu reads current state). The menu
reads via `hierarchy.snapshot()`, not view state, so it reflects the label each
time it opens. The detector drops muted-pane events before the chokepoint.

## Permission

`OSNotifier` requests authorization on the **first** banner-worthy notification
(not at launch). Denial silences only banners — in-app badges, inbox, and Dock
badge work unconditionally. Settings exposes Request / Open-System-Settings
recovery; status is re-read on `applicationDidBecomeActive`.

## Component Boundaries

```
CodansCore/
  Notifications/{InboxEntry, InboxStorage, DetectionTranslator(+Context),
                 InboxFile, RollupIndex, DropReason}.swift
  Settings/NotificationsSettings.swift
codans/App/Features/Notifications/
  NotificationDetector, NotificationCoordinator, NotificationSettingsReader,
  NotificationStore, OSNotifier, DockBadger, PaneKeyboardActivityTracker
codans/App/Features/Settings/Panes/NotificationsSettingsView.swift
codans/App/Clients/HierarchyClient.swift   // + reorderWorktrees, setPaneLabel
```

Dependency direction: `InboxEntry ← DetectionTranslator/Detector → Coordinator →
{Store, OSNotifier, DockBadger, HierarchyClient}`; surfaces observe `RollupIndex`.
The store is UI- and OS-ignorant by design; `Notifications/` imports no UI types
beyond the settings pane and the pane context menu.

## Alternatives Considered

- **A1 — stdout regex scanner.** Rejected: patterns drift ("(y/n)" matches chat
  transcripts), and shipping one regex set invites a rule editor (the single
  largest piece of C6). Documenting "emit OSC 9 from your tooling" is cheaper
  than maintaining the set forever; a scanner can return additively if real users
  hit the gap.
- **A2 — sidebar inbox route.** Rejected (confirmed with user): notifications are
  transient (read → click → forget); a persistent route over-promotes them. Bell
  + popover matches the flow.
- **A3 — hook-based detection.** Rejected for v1: only Claude Code writes c3
  hooks today; the runtime's structured events cover any tool respecting OSC
  9/133 — strictly broader. Additive later.
- **A4 — coordinator gating inside the detector.** Rejected: the detector is
  already orchestration; cramming policy in blurs the pure-translator /
  orchestration / policy split and lengthens the test matrix.
- **A5 — per-level scoped popovers; one toggle-enum.** Both rejected (see Roll-up
  and Settings above).
- **A6 — drive promote from the store.** Rejected: the store would need to import
  `HierarchyClient` + a settings reader — backward deps; it is the leaf type.

## Risks

| Risk | Mitigation |
|---|---|
| OSC 9 adoption gap — tools that don't emit it never trigger "waiting". | Documented limitation; bell + child-exit + idle still cover most "done" cases. |
| OSC 133 absent in the user's shell — no `commandFinished`. | `paneExited` covers foreground-process exit for any shell. |
| Catalog mutates between create and click. | Raw-ID storage + dead-target fallback (G3); the row stays, flagged. |
| Permission denial. | In-app + Dock + inbox work unconditionally; Settings has the recovery path. |
| 1 s keystroke window vs IME batching. | Tracker records every `sendKey` incl. composition; if a real IME case bites, lift the constant to a setting. |
| `reorderWorktrees` racing a manual drag. | Both `@MainActor`; last write wins — auto-promote losing to an in-progress drag is correct. |
| Forward-version inbox quarantined on downgrade. | Quarantine is a rename, not delete; restorable; one-shot "Inbox reset" entry surfaces it. |

## References

- Product spec: [notifications.md](../product-specs/notifications.md)
- Hierarchy / events: `apps/mac/CodansCore/{Catalog,Project,Worktree,Tab,Pane,SplitTree,TerminalEvent,PaneInfoDelta}.swift`
- Inbox primitives: `apps/mac/CodansCore/Notifications/`
- Settings v3 schema: `apps/mac/CodansCore/Settings/Settings.swift`
- Hierarchy mutation surface: `apps/mac/codans/App/Clients/HierarchyClient.swift`
- Status-bar host: `apps/mac/codans/App/Features/StatusBar/`
