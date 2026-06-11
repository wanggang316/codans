# Design Doc: Agent Notifications v2 — Hardening & Cross-Source Robustness (C6.2)

**Status:** Deprecated (2026-04-30 — superseded by [notifications.md](notifications.md))
**Author:** Gump (with Claude)
**Date:** 2026-04-25

> **Superseded by [docs/design-docs/notifications.md](notifications.md).**
> Hardening of an abandoned design line. Retained here for historical
> context.

## Context

v1 of C6 (see [c6-agent-notifications.md](c6-agent-notifications.md)) shipped the FSM tracker, detection-rule DSL, persisted inbox, OS notifier, dock badger, and inbox sidebar. A post-v1 audit identified two classes of gap:

1. **Missing UX affordances.** No status-bar entry point (the inbox is reachable only via the sidebar); no cross-source deduplication when the same agent event arrives both as a hook envelope and as a terminal OSC 9 sequence; no suppression while the user is actively typing in a Pane; in-app sound and OS notification sound can both fire on the same event; a worktree gaining unread notifications is not promoted in the list.
2. **Runtime-correctness defects.** C3 integration is exercised only against a mocked dispatcher; macOS notification authorization is read once at boot and never refreshed; rule-file reload does not invalidate active trackers; the dock badge can lag by one tick when `inAppEnabled` toggles; the OS notification "Dismiss" action does not propagate to the inbox.

v2 closes both classes. This doc enumerates **deltas only**. v1 remains the base reference for FSM transition table, file paths, persistence semantics, and dependency direction (`C6 → C3 → C2`).

## Goals and Non-Goals

**Goals**

- Add a status-bar / worktree-header bell entry as a fourth UI surface alongside sidebar inbox, OS notification, and dock badge.
- Extend the detection-rule DSL with a per-rule `surfaceIdle` override, with a grammar version bump and migration of bundled defaults.
- Add a `dedupKey: String?` field to `AgentNotification` and a 2 s cross-source dedup window (hook ↔ OSC 9 ↔ template-rendered) keyed on `(paneID, dedupKey ?? hash(title|body))`.
- Suppress notifications to a Pane within 3 s of any user key input on that Pane (a "user is at the keyboard" gate).
- Add a top-level "Notifications enabled" master switch separate from `mute.enabled`.
- Wire `applicationDidBecomeActive` to refresh `UNUserNotificationCenter` authorization status.
- On rule-file reload, invalidate active trackers so re-evaluation picks up the new rule set.
- Re-evaluate dock badge synchronously when `inAppEnabled` toggles.
- Wire OS notification "Dismiss" action to `InboxClient.dismiss([id])`.
- Mutex sound vs. system notifications (when system enabled, in-app sound is silenced).
- Auto-promote a worktree to top-of-list on first unread notification arrival (gated by `moveNotifiedWorktreeToTop`).
- Replace `C6EndToEndTests`'s mocked `HookDispatcher` with a real one for at least one happy-path scenario.
- Cover all "focus → mark read" paths, not just `InboxSidebarFeature.rowTapped`.
- Emit structured counters for rule matches, render failures, and OS post failures.

**Non-Goals**

- Restructuring the FSM. `AgentState` and the v1 transition table stay.
- Changing the persistence format or storage path. `~/.config/codans/inbox.json` keeps its v1 schema; only `AgentNotification` gains an optional field (forward-compatible).
- Cross-device sync, push, snooze, rich notifications.
- Replacing C3's `internalEventStream()` with a separate IPC channel (socket, named pipe, etc.). C3 already provides an in-process event bus that suffices for v2's needs; introducing a parallel transport would duplicate routing and dedup logic.
- Per-agent hook installer state machine UX. C3 owns hook installation in codans; C6 only consumes.

## Design

The deltas are grouped by concern. Each carries a short rationale, a concrete contract, and the testable outcome.

### D1. Status-bar bell entry (UI surface #4)

**Where it lives.** `apps/mac/codans/App/Features/WorktreeHeader/` (alongside the existing status-bar pieces touched by recent commits `98305e8`, `93ace64`, `9447120`, `6911a65`).

**What it shows.** A bell icon button bound to the same `unreadPublisher` that drives the dock badge.

- Hidden state (zero unread): outline bell, no badge, button still clickable to open the inbox sidebar.
- Has-unread state: filled bell, capsule badge with **count of worktrees with unread** (not raw notification count) — see rationale below.
- Master-disabled state (`settings.enabled == false`): bell-slash icon, no badge, click still opens the inbox sidebar so the user can re-enable notifications from settings (per DEC-V11).
- Hover/click: opens (or focuses) the inbox sidebar with filter `.unread`.

**Why worktree-count not notification-count.** Users care which worktrees demand attention; once they enter one, all its notifications are visible together. A "37" badge tells you nothing actionable; "3 worktrees" does.

**Contract.**

```swift
// apps/mac/codans/App/Features/WorktreeHeader/StatusBarBellView.swift
struct StatusBarBellView: View {
    @ObservedObject var viewModel: StatusBarBellViewModel
    var body: some View { /* … */ }
}

@MainActor final class StatusBarBellViewModel: ObservableObject {
    @Published private(set) var unseenWorktreeCount: Int = 0
    init(inbox: InboxClient, focus: @escaping () -> Void)
}
```

Subscribes to `inbox.observeUnreadByWorktree()` (new method, see D11). Tap action calls `focus()` — wired in `AppFeature` to dispatch `.inboxSidebar(.toggle(.open(filter: .unread)))`.

**Tests.** `StatusBarBellViewModelTests` — empty state, unread on one worktree, unread on three worktrees, transition through zero. SwiftUI snapshot for both states.

### D2. Per-rule `surfaceIdle` override + DSL v2

**Why.** Today `settings.notifications.mute.surfaceIdle` is a single global toggle — users can't keep idle notifications for `claude` while suppressing them for `aider`. The rule grammar already encodes per-agent intent, so the override belongs there.

**Schema bump.** `detection-rules.json` gains a top-level `version` field (v1 was implicit; treat as `1`). v2 adds:

```json
{
  "version": 2,
  "rules": [
    {
      "id": "claude.idle",
      "agent": "claude",
      "match": { "kind": "paneIdle", "afterSeconds": 30 },
      "transition_to": "idle",
      "title": "{agent} is idle",
      "body": "{since}",
      "surfaceIdle": true   // NEW: opt-in per-rule; default false
    }
  ]
}
```

**Resolution order at coordinator.**

1. If global `mute.enabled` → drop.
2. If `mutedRuleIDs.contains(rule.id)` → drop.
3. If `mutedPaneIDs.contains(transition.paneID)` → drop.
4. If transition is to `.idle`:
   - If rule has `surfaceIdle == true` → surface (override the global mute).
   - Else if `settings.mute.surfaceIdle == true` → drop.
5. Otherwise → surface.

This makes the global setting a default, and per-rule a granular escape hatch. The reverse (global on + per-rule off) is intentionally not supported: suppress at the rule edit-site instead — keeps the truth table small.

**Migration.** `RuleStore.load()` detects `version == nil || version == 1` files and writes them back as `version: 2` with all rules defaulting `surfaceIdle: false`. Bundled `DefaultRules` ship `version: 2` directly. No data is lost; users who have customised their file see their rules untouched aside from the version stamp.

**Tests.** `AgentDetectionRulesTests` round-trip with v1 input → v2 normalised output. `NotificationCoordinatorTests` cover all four cells (global × per-rule).

### D3. `dedupKey` on `AgentNotification` + cross-source dedup window

**Model delta.**

```swift
public struct AgentNotification: Codable, Equatable, Identifiable {
    // … existing fields …
    public var dedupKey: String?  // NEW; nil = derive from (title, body) hash
}
```

**Why optional.** Most notifications already have a natural identity from `(paneID, kind, transitionTimestamp)`. The field exists for cases where two different signal sources describe the same event — e.g., agent emits a Stop hook and the terminal emits OSC 9 within milliseconds of each other.

**Coordinator-level window.**

```swift
// apps/mac/codans/Notifications/NotificationCoordinator.swift
private struct DedupRecord {
    let key: String         // dedupKey or hash(paneID|title|body)
    let postedAt: Date
}
private var recentByPane: [PaneID: DedupRecord] = [:]
private let dedupWindow: TimeInterval = 2.0
```

When a transition arrives:

1. Compute `key = notification.dedupKey ?? hash(paneID + title + body)`.
2. If `recentByPane[paneID]?.key == key` and `now - postedAt < dedupWindow` → drop entirely (do not append to inbox, do not OS-post, do not increment unread).
3. Otherwise insert/replace `recentByPane[paneID]` and continue.

When a Pane closes, `TrackerRegistry.teardown(paneID)` calls `coordinator.clearDedupCache(paneID)` so stale keys don't leak.

**Why 2 s** — long enough to span the typical race between an agent's structured hook event and the terminal OSC 9 sequence (observed at well under 500 ms in practice, but with headroom for a stalled hook handler), short enough that a user re-running the same command intentionally still gets a fresh notification. The window is a private constant in v2; if reports surface that 2 s is wrong for some workflow, it can be lifted to a setting later.

**Why drop entirely vs. coalesce** — the inbox is the source of truth (DEC-5 in v1). Mutating an existing entry (e.g., replacing body) breaks read-status semantics; dropping the duplicate keeps the model immutable-once-appended.

**Tests.** `NotificationCoordinatorTests`:
- `dedupBlocksDuplicateWithinWindow` — two arrivals within 1.5 s, same key → only first stored.
- `dedupAllowsDuplicateAfterWindow` — second arrival at 2.5 s → both stored.
- `dedupKeyOverridesContentHash` — same `dedupKey` but different body → still deduplicated.
- `paneTeardownClearsDedup` — close pane, re-open with same ID, no false positive.

### D4. User-interaction suppression (3 s typing window)

**Why.** A user actively typing in a Pane is, by definition, already attending to it; emitting a notification for that same Pane in that moment is at best redundant and at worst disruptive (notification sound on top of the user's own keystrokes, OS banner stealing focus from the very window they are using). The fix is to suppress notifications to a Pane within a short window after any key input on that Pane.

**Why 3 s.** Long enough to cover the gap between the user finishing a command and the agent's first response (typical sub-second to two-second latency for short prompts), short enough that a user who walks away mid-keystroke still receives subsequent notifications.

**Wire-up.**

```swift
// apps/mac/codans/Notifications/AgentStateTracker.swift
private var lastUserInputAt: Date?
private let userInteractionWindow: TimeInterval = 3.0

func recordUserInput(at: Date = .now) { lastUserInputAt = at }

private func shouldSuppress(_ transition: AgentStateTransition) -> Bool {
    guard let t = lastUserInputAt else { return false }
    if .now.timeIntervalSince(t) >= userInteractionWindow { return false }
    // Only suppress completion / idle. blockedOnInput is the one signal
    // a typing user actually wants — they're explicitly being asked.
    return transition.to == .completed || transition.to == .idle
}
```

**Hook into pane input.** `GhosttySurfaceBridge` (or its codans equivalent) already routes key input; we add a `paneKeyInput(paneID:)` callback the `TrackerRegistry` forwards to the matching tracker's `recordUserInput`.

**Why selective (only `.completed` / `.idle`).** `.blockedOnInput` is exactly when a typing user has stopped because the agent is asking; suppressing that transition would defeat the purpose. `.running` is not a notification-worthy transition anyway.

**Tests.** `AgentStateTrackerTests`:
- `userInputSuppressesCompletionWithinWindow`
- `userInputDoesNotSuppressBlockedOnInput`
- `userInputAfterWindowAllowsCompletion`

### D5. Top-level master "Notifications enabled" switch

**State delta.** `NotificationsSettings.enabled: Bool` (default `true`), distinct from `mute.enabled` which is the user-facing "do-not-disturb".

**Semantics.**

| Toggle | OFF effect |
|---|---|
| `enabled` (NEW master) | Coordinator early-returns; no inbox append, no OS post, no badge, no sound. Same as if C6 weren't booted. |
| `mute.enabled` | "Snooze" — inbox still appends (so users can review history), but OS post + badge + sound are gated off. |

The two are intentionally separate: master-off = "I don't want this feature right now"; mute-on = "save it for later".

**UI.** A single labelled toggle at the top of `NotificationsSettingsView`; sub-toggles dim/disable when master is off (visual hint, not just functional).

**Tests.** `NotificationCoordinatorTests.masterEnabledFalseDropsAll`.

### D6. `applicationDidBecomeActive` permission refresh

**Where.** `apps/mac/codans/App/AppDelegate.swift` (or the SwiftUI `Scene`-level equivalent already in use). Add:

```swift
NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    .sink { [weak coordinator] _ in
        Task { await coordinator?.refreshAuthorizationStatus() }
    }
```

`refreshAuthorizationStatus()` already exists on `NotificationCoordinator` (called once at boot in `C6AppBootstrap`); we just call it again on every activation.

**Tests.** Hard to fully unit-test (needs `UNUserNotificationCenter` injection); add a smoke test that asserts `refreshAuthorizationStatus` is invoked on a publisher tick. Manual QA: deny in System Settings, observe banner, grant, switch back to app, send synthetic notification — should now post.

### D7. Rule-reload → tracker invalidation

**Today.** `RuleStore.reloadAndRematerialise()` re-renders C3 subscriptions and broadcasts a `.rulesReloaded` signal, but `DetectionRouter` and `AgentStateTracker` keep their old per-rule lookup tables.

**Change.** On reload:

1. `RuleStore` rebuilds `[RuleID: AgentDetectionRule]`.
2. Broadcasts `RulesReloaded(version: Int, ruleIDs: Set<RuleID>)`.
3. `DetectionRouter` swaps in the new lookup table (atomic).
4. `TrackerRegistry.invalidateAll()` calls `tracker.refreshRuleBindings(newTable)` on each active tracker, which:
   - Drops cached match contexts keyed by stale rule IDs.
   - Resets the idle timer if the matching idle rule's `afterSeconds` changed.
   - Does **not** reset `currentState` — that's a property of the agent, not the rules.

**Tests.** `RuleStoreReloadTests.reloadInvalidatesActiveTrackers` — boot with v1 rules, create tracker, reload with v2 rules, verify tracker emits transitions matching v2 rules.

### D8. Dock badge re-evaluation on `inAppEnabled` flip

**Bug.** `NotificationCoordinator.handleUnread()` ANDs `dockBadgeEnabled && inAppEnabled`; toggling `inAppEnabled` off while there are unread notifications leaves the badge stale until the next unread-count event.

**Fix.** `NotificationCoordinator` observes `settings` for changes to `inAppEnabled` and `dockBadgeEnabled` and synchronously re-evaluates `dockBadger.set(label:)`:

```swift
settings.publisher(for: \.inAppEnabled)
    .combineLatest(settings.publisher(for: \.dockBadgeEnabled))
    .sink { [weak self] _, _ in self?.recomputeDockBadge() }
```

**Tests.** `NotificationCoordinatorTests.inAppDisabledClearsBadgeImmediately`.

### D9. OS Dismiss action → `InboxClient.dismiss`

**Today.** Tapping "Dismiss" on the OS notification banner closes the banner; the inbox entry survives. This contradicts the in-app swipe behaviour.

**Fix.** `OSNotifier` registers two `UNNotificationAction`s — `focus` and `dismiss` — keyed by `notification.id`. The `UNUserNotificationCenterDelegate` dispatches:

```swift
switch response.actionIdentifier {
case "codans.focus":   inbox.markRead([id]); deeplink.open("codans://pane/\(paneID)/focus")
case "codans.dismiss": inbox.dismiss([id])
case UNNotificationDefaultActionIdentifier: /* tap on body = focus */
default: break
}
```

This makes the OS surface a peer of the in-app surface, both writing to the same source of truth.

**Tests.** `OSNotifierTests` (mocked center) — focus action calls `markRead+deeplink`, dismiss calls `dismiss`.

### D10. Sound ↔ system-notification mutex

**Why.** When both `notificationSoundEnabled` and `systemEnabled` are on, the user hears the in-app `notification.wav` *and* the OS-provided notification sound in quick succession for the same event. The two channels are not coordinated, and the user has no clean way to express "play one sound, not two" without disabling a feature whose other behaviours they want.

**Fix.** `OSNotifier` posts with `content.sound = .default` only when `systemEnabled && !muted`. Coordinator's sound path becomes:

```swift
let shouldPlayInAppSound = settings.notificationSoundEnabled && !settings.systemEnabled
```

When both are on, OS owns audio; when only in-app is on, we play `notification.wav`.

**UI.** When `systemEnabled` toggles on, `notificationSoundEnabled` UI row gets a footnote "Played by macOS" and disables the toggle (the value is preserved so flipping system off restores prior intent).

**Tests.** `NotificationCoordinatorTests.soundMutexWithSystem`.

### D11. Notified-worktree auto-promote

**Setting.** New `moveNotifiedWorktreeToTop: Bool` (default `true`) in `NotificationsSettings`.

**Behaviour.** On first unread notification arrival for a worktree (transition from "no unread" to "has unread"), publish a `.worktreePromoteRequested(worktreeID)` event. The Worktree list reducer reorders so that worktree is at the top of its repository group; existing manual ordering is preserved as the fallback.

**Why "first unread"** — promoting on every arrival would cause flapping when multiple Panes in one worktree fire in quick succession. Promoting once on the 0→N transition is the smallest user-visible nudge.

**InboxClient gains** `observeUnreadByWorktree() -> AsyncStream<[WorktreeID: Int]>` to drive both this feature and D1's status-bar bell.

**Tests.** `InboxStoreTests.observeUnreadByWorktreeEmitsPerGroup`. Worktree-list reducer test for promotion.

### D12. Real C3 integration test

**Today.** `C6EndToEndTests` mocks `HookDispatcher`. If C3's protocol shape drifts, no test catches it.

**Fix.** Add `C6C3IntegrationTests` (in `apps/mac/Tests/NotificationsTests/Integration/`):

1. Spin up a real `HookDispatcher` from C3.
2. Register `DetectionRouter` as an `InternalHookSubscriber`.
3. Inject a synthetic `HookEnvelope(.paneOutputMatch, …)` through the dispatcher.
4. Assert the tracker observes a transition and the coordinator appends to the inbox.

Use the same fake clock and in-memory `AtomicFileStore` already used by v1 tests — only the dispatcher is real.

**Tests.** Listed above. Goal: a single happy-path test that exercises the actual sentinel-prefix routing.

### D13. Focus → mark-read coverage

**Audit.** v1 marks-read on `InboxSidebarFeature.rowTapped`. Other focus paths:

- Click on OS banner body (default action) — D9 wires this.
- `codans focus <paneID>` CLI command — currently does **not** mark read.
- Status-bar bell click — D1 opens sidebar but does not mark anything read until the user clicks a row.
- Click on a worktree in the sidebar list — does not mark read.

**Decision.** "Focus implies acknowledgement of unread for that Pane only." Add `InboxClient.markReadForPane(_:)`. Wire:

- `codans focus` → `markReadForPane(paneID)`.
- Sidebar worktree row tap → `markReadForWorktree(worktreeID)` (new).
- Status-bar bell remains read-on-row-click — the bell is a nav affordance, not an acknowledgement.

**Tests.** `InboxClientTests.markReadForPane`, `markReadForWorktree`. CLI smoke test for `codans focus`.

### D14. Structured metrics

**Why.** Operators (and the user when debugging "why didn't I get a notification?") need observable counters.

**Counters.**

```swift
enum NotificationMetric: String {
    case rulesEvaluated         // every paneOutputMatch envelope
    case rulesMatched           // a rule actually fired
    case templateRenderFailures
    case dedupDropped
    case mutedDropped
    case userInputSuppressed
    case osPostFailures
    case osPostSucceeded
}
```

**Sink.** Initially write through `os.Logger` with a structured payload (`subsystem: "codans.notifications"`, `category: "metrics"`). Expose a `codans notifications stats` CLI subcommand that reads the last hour of logs and prints per-counter totals. No external metrics service in v1.

**Tests.** `MetricsTests` — assert each counter increments on the relevant code path.

## Data Model Deltas (consolidated)

```swift
// CodansCore/Notifications/AgentNotification.swift
public struct AgentNotification: Codable, Equatable, Identifiable {
    public let id: UUID
    public let paneID: PaneID
    public let agent: String
    public let kind: AgentState
    public let title: String
    public let body: String
    public var readAt: Date?
    public var dismissedAt: Date?
    public let createdAt: Date
    public var dedupKey: String?            // NEW
}

// CodansCore/Notifications/AgentDetectionRules.swift
public struct AgentDetectionRules: Codable {
    public let version: Int                 // NEW (always 2 going forward)
    public let rules: [AgentDetectionRule]
}

public struct AgentDetectionRule: Codable {
    // … existing fields …
    public var surfaceIdle: Bool = false    // NEW
}

// CodansCore/Notifications/NotificationsSettings.swift
public struct NotificationsSettings: Codable {
    public var enabled: Bool                = true   // NEW master
    public var inAppEnabled: Bool           = true
    public var systemEnabled: Bool          = false
    public var soundEnabled: Bool           = true
    public var dockBadgeEnabled: Bool       = true
    public var moveNotifiedWorktreeToTop: Bool = true  // NEW
    public var mute: MuteSettings           = .init()
}
```

## Migration

`RuleStore.load()`:

```swift
let raw = try decoder.decode(RawRules.self, from: data)
let version = raw.version ?? 1
let rules = raw.rules.map { rule in
    var r = rule
    if version < 2 { r.surfaceIdle = false }
    return r
}
let normalised = AgentDetectionRules(version: 2, rules: rules)
if version < 2 { try save(normalised) }       // write back so next load is fast
return normalised
```

`InboxStore` does not migrate — `dedupKey` is optional and defaults `nil`; old `inbox.json` files decode unchanged.

`SettingsStore` adds `enabled` and `moveNotifiedWorktreeToTop` with defaults via Codable's `decodeIfPresent` (already the v1 pattern).

## Sequencing

**Stage A — runtime hardening (P0/P1, ~1 week):**

1. D6 `applicationDidBecomeActive` refresh
2. D8 dock badge synchronous recompute
3. D9 OS Dismiss action → InboxClient
4. D7 rule-reload tracker invalidation
5. D12 real C3 integration test

**Stage B — UX gap-closing (~1 week):**

6. D3 `dedupKey` + window
7. D4 user-interaction suppression
8. D10 sound mutex
9. D11 worktree auto-promote
10. D5 master toggle
11. D13 focus → mark-read coverage

**Stage C — new surfaces & telemetry (~3–4 days):**

12. D1 status-bar bell
13. D2 per-rule `surfaceIdle` + DSL v2 migration
14. D14 structured metrics

Each stage is independently shippable; A unblocks confidence, B closes UX gaps, C adds the new affordances the user explicitly approved.

## Tests Added

Total new test files: **9**. Total new test methods: **~32**. All run against the existing fake clock + in-memory `AtomicFileStore` infra used by v1 tests.

| Stage | New file | Methods |
|---|---|---|
| A | `C6C3IntegrationTests` | 1 (happy-path real dispatcher) |
| A | `OSNotifierTests` extensions | 3 (focus / dismiss / default actions) |
| A | `RuleStoreReloadTests` | 2 (active-tracker invalidation, atomic swap) |
| A | `NotificationCoordinatorTests` extensions | 2 (badge recompute, refresh on activate) |
| B | `NotificationCoordinatorTests` extensions | 6 (dedup × 4, mutex, master) |
| B | `AgentStateTrackerTests` extensions | 3 (suppression × 3) |
| B | `InboxStoreTests` extensions | 2 (per-worktree unread, promote signal) |
| B | `InboxClientTests` extensions | 2 (markReadForPane, forWorktree) |
| C | `StatusBarBellViewModelTests` | 4 (zero / one / many / transition) |
| C | `AgentDetectionRulesMigrationTests` | 3 (v1 → v2, default surfaceIdle, round-trip) |
| C | `MetricsTests` | 4 (rulesEvaluated, dedupDropped, suppressed, osPostFailure) |

## Decisions

- **DEC-V1.** Status-bar bell is the fourth UI surface; badge displays unseen-worktree count, not raw notification count. (User-confirmed 2026-04-25.)
- **DEC-V2.** Detection-rule DSL grammar bumps to version 2; `surfaceIdle` is per-rule, defaults `false`, migration is automatic and lossless. (User-confirmed.)
- **DEC-V3.** `AgentNotification.dedupKey: String?` is optional; coordinator dedups within a 2 s window using `dedupKey` or `hash(paneID|title|body)`; teardown clears the cache. (User-confirmed.)
- **DEC-V4.** User-interaction suppression: 3 s window, applies to `.completed` / `.idle` only, never to `.blockedOnInput`.
- **DEC-V5.** Top-level master `enabled` is distinct from `mute.enabled`; master OFF skips inbox append entirely; mute ON still appends to inbox but silences surfaces.
- **DEC-V6.** Sound mutex: when system notifications enabled, in-app sound is silenced and the UI reflects that the OS owns audio.
- **DEC-V7.** Worktree promotion fires only on the 0→N unread transition per worktree.
- **DEC-V8.** `codans focus` and sidebar worktree-row tap mark read; status-bar bell click does not (it's nav, not acknowledgement).
- **DEC-V9.** Status-bar bell is the only new entry-point in v2; per-tab unread dots in the tab bar are deferred until usage data shows the status-bar bell alone is insufficient. (User-confirmed 2026-04-25.)
- **DEC-V10.** `moveNotifiedWorktreeToTop` defaults `true`. Manual ordering is preserved as the fallback when no unread; promotion is reversible by clearing unread. (User-confirmed.)
- **DEC-V11.** When the master `enabled` toggle is OFF, the status-bar bell renders as a bell-slash icon (not hidden), so the entry-point for re-enabling stays discoverable. Click still opens the inbox sidebar; the sidebar surfaces a banner reminding the user that notifications are globally disabled. (User-confirmed.)

## Risks

- **R1.** D2 grammar bump risks breaking users who have hand-edited `detection-rules.json`. Mitigation: migration is purely additive (new field defaults to `false`) and the writeback only changes the version stamp.
- **R2.** D3 cross-source dedup could mask genuine repeated events that happen to share a content hash within 2 s (e.g., a tight loop emitting the same status line). Mitigation: dedup is per-Pane and 2 s is short; if reports surface, expose the window as a setting.
- **R3.** D4 user-interaction suppression could swallow notifications the user actually wanted (they typed in Pane A, agent in Pane B finishes — wait, that's a different Pane, suppression is per-Pane so this is fine). Risk re-validated: suppression is correctly Pane-local.
- **R4.** D11 worktree promotion changes user-visible list order; some users may have manually arranged their worktrees. Mitigation: respect the manual order as the fallback when no unread; promotion is reversible by clearing unread.

## References

- v1 design: [c6-agent-notifications.md](c6-agent-notifications.md)
- v1 inbox sidebar: [c6-m5-inbox-sidebar.md](c6-m5-inbox-sidebar.md)
- v1 settings: [settings-notifications.md](settings-notifications.md) + [exec-plan](../exec-plans/settings-notifications.md)
- C3 hooks: [c3-lifecycle-hooks.md](c3-lifecycle-hooks.md)
