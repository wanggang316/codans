# ExecPlan: Agent Notifications v2 — Hardening, UX Gaps, New Surfaces (C6.2)

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-04-25

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this plan lands, a contributor running codans with one or more agent-hosted Panes will observe:

- **No duplicate notifications when an agent's Stop hook and the terminal's OSC 9 sequence both report the same completion event.** Today both fire and the inbox shows two rows; after this plan only one row appears (verified by `NotificationCoordinatorTests.dedupBlocksDuplicateWithinWindow`).
- **No notification banners or sounds while the user is actively typing in a Pane.** Pressing keys in Pane A then watching the agent in Pane A finish 1.5 s later produces no banner; the same flow with a 5 s gap does (verified by `AgentStateTrackerTests.userInputSuppressesCompletionWithinWindow`).
- **Granting macOS notification permission in System Settings while the app is in the background takes effect on the next focus**, without requiring an app restart (verified manually + smoke test in `NotificationCoordinatorTests`).
- **Editing `~/.config/codans/detection-rules.json` and running `codans notifications rules reload` causes already-running agent Panes to start matching against the new rules**, not just newly-created Panes.
- **Toggling "in-app notifications" off in Settings clears the Dock badge in the same UI tick** rather than on the next unread mutation.
- **Tapping "Dismiss" on a macOS notification banner removes the corresponding inbox row**, the same as swiping it away in the in-app sidebar.
- **A worktree gaining its first unread notification is auto-promoted to the top of its repository group in the sidebar** (toggleable via `moveNotifiedWorktreeToTop`).
- **A single top-level "Notifications enabled" toggle exists** that fully disables the C6 pipeline (no inbox append, no banners, no badge, no sound), distinct from the existing "Mute" snooze switch.
- **The per-worktree header bell renders as bell-slash when the master toggle is off**, so the entry-point to re-enable notifications stays discoverable.
- **Detection-rule files (`detection-rules.json`) declare `"version": 2`**, can carry a `"surfaceIdle": true` per-rule flag that overrides the global idle-mute, and old `version: 1` files are migrated automatically with no data loss.
- **A `codans notifications stats` CLI subcommand prints structured per-counter totals** (rules evaluated, dedup drops, OS post failures, etc.) for the last hour of activity.

This plan does not change the FSM, the persistence format, or the dependency direction (`C6 → C3 → C2`). It hardens v1, closes the UX gaps the v2 design doc enumerates as D1–D14, and lands the three new affordances the user explicitly approved (status-bar bell polish, per-rule `surfaceIdle`, `dedupKey` field).

## Progress

Tasks are flat across the three stages. Each task represents a single small commit per the user's `小步提交` instruction. Tasks marked `[parallel:N]` may be dispatched concurrently within their stage; unmarked tasks must run sequentially because they touch shared files. Dependencies are explicit.

### Stage A — Runtime hardening

- [x] **A2** D6 — `applicationDidBecomeActive` permission refresh wired in `C6AppBootstrap` via synchronous `addObserver`; smoke test `applicationDidBecomeActiveRefreshesAuthorizationStatus` in `C6AppBootstrapTests`. **Landed 2026-04-25 commit `c814fa4`.**
- [x] **A3** D9 — `UserNotificationDelegate` routes focus/dismiss/default-tap to `InboxStore.markRead` / `.dismiss`; `OSNotifier.setDelegate` extends the protocol; `MockOSNotifier.assignedDelegate` records the wiring; 5 new `OSNotifierTests`. **Landed 2026-04-25 commit `c772357`.**
- [x] **A4** D8 — `NotificationsSettingsReader.notificationsSettingsChanges()`; coordinator caches `lastUnreadCount` and recomputes badge on each settings tick; `inAppDisabledClearsBadgeImmediately` test. **Landed 2026-04-25 commit `c8a99fe`.**
- [x] **A5** D7 — `AgentStateTracker.updateIdleThreshold` + `TrackerRegistry.updateIdleThreshold` + `coordinator.reloadRules` propagation; `reloadAdoptsNewIdleThresholdAcrossLiveTrackers` test asserts state preservation. **Landed 2026-04-25 commit `a1d46b8`.**
- [x] **A1** D12 — `dispatcherFireDeliversLifecycleEnvelopeThroughC6Stack` exercises real `HookDispatcher.fire` → `InternalHookSubscriber.handle` → tracker → coordinator → inbox path. **Landed 2026-04-26 commit `bdd8704`.**

### Stage B — UX gap-closing

- [x] **B1** D3 step 1 — `AgentNotification.dedupKey: String?` + decodeIfPresent round-trip. **Landed 2026-04-25 commit `cade4bb`.**
- [x] **B2** D5/D11 — `NotificationsSettings.enabled` (master) + `moveNotifiedWorktreeToTop` + decodeIfPresent + 3 round-trip tests. **Landed 2026-04-25 commit `8a8084d`.**
- [x] **B3** D4 step 1 — `AgentStateTracker.recordUserInput` + `shouldSuppress` + 3 tracker tests covering completed-suppressed, blockedOnInput-not-suppressed, after-window-allowed. **Landed 2026-04-25 commit `ca71925`.**
- [x] **B4** D3 step 2 — `NotificationCoordinator` 2 s dedup window + `clearDedupCache(_:)` + `now` test seam + 4 dedup tests + `TrackerRegistry.onDestroy` wire. **Landed 2026-04-25 commit `84ada3e`.**
- [x] **B5** D5 step 2 — Master toggle gates `handle(output:)` + `handleUnread`; settings UI gets a top-level Master section, sub-toggles `.disabled(!masterEnabled)`. **Landed 2026-04-25 commit `2cc09e1`.**
- [x] **B6** D10 — Skipped per DEC-EP9: v1 has no in-app sound channel separate from `UNNotificationContent.sound`; existing `systemEnabled` gating already prevents double-sound.
- [x] **B7** D4 step 2 — `TrackerRegistry.recordKeyInput(paneID:)` forwarding seam + 2 tests. Production Ghostty wire deferred per DEC-EP10. **Landed 2026-04-26 commit `7c7eaf2`.**
- [x] **B8** D11 step 1 — `InboxStore.setCatalogProvider` + `observeUnreadByWorktree() -> AsyncStream<[WorktreeID: Int]>` + `InboxClient.observeUnreadByWorktree` + 2 tests. **Landed 2026-04-26 commit `70770f9`.**
- [ ] **B9** D11 step 2 — Worktree-list reducer auto-promote on 0→N. **Deferred to v2.1 (DEC-EP11): touches a TCA reducer area outside Notifications/, the upstream B8 stream is in place so the consumer drop-in is unblocked. Manual reordering is unaffected; `moveNotifiedWorktreeToTop=true` is a no-op until the reducer subscribes.**
- [x] **B10** D13 step 1 — `InboxStore.markRead(forPane:)` + `InboxClient.markReadForPane` + bridge test. **Landed 2026-04-26 commit `63341f3`.**
- [x] **B11** D13 step 2 — `HierarchyHandlers.onPaneFocused` callback fires post-success; `CodansApp.startIPC` wires it to `inboxStore.markRead(forPane:)`; unit test asserts the callback fires. **Landed 2026-04-26 commit `afab00c`.**

### Stage C — New surfaces & telemetry — DEFERRED to v2.1

Stage C delivers net-new surfaces and observability rather than fixing
existing defects. Per DEC-EP12 Stage C is deferred — the runtime
hardening (Stage A) and UX gap-closing (Stage B except B9) cover the
defects the v1 audit surfaced; Stage C builds atop a stable v2 base,
which is exactly what we now have. C5/C6 (master-disabled bell-slash
rendering) is the most user-visible deferred item; without it, master
OFF still works correctly but the existing bell stays as outline-bell
no-badge instead of bell-slash.

- [ ] **C1** Detection-rule DSL grammar v2 (deferred).
- [ ] **C2** RuleStore v1→v2 migration ladder (deferred).
- [ ] **C3** DefaultRules.json v2 stamp (deferred).
- [ ] **C4** Coordinator surfaceIdle resolution per-rule (deferred).
- [ ] **C5** HeaderBellView master-disabled rendering (deferred).
- [ ] **C6** WorktreeHeaderFeature.unreadCount regression test (deferred).
- [ ] **C7** NotificationMetric + sink (deferred).
- [ ] **C8** `codans notifications stats` CLI (deferred).

### Final review

- [ ] **R1** Run full test suite + lint + manual QA against the Validation and Acceptance section.
- [ ] **R2** Dispatch `agent-skills:code-reviewer` on the entire `feature/notification` branch v2 delta.

## Surprises & Discoveries

- **2026-04-25 (planning):** v1 already ships a per-worktree header bell at `apps/mac/codans/App/Features/WorktreeHeader/HeaderBellView.swift` (51 lines) and its popover at `HeaderBellPopover.swift` (205 lines). The v2 design doc D1 was drafted as if this were new ("Status-bar bell entry (UI surface #4)"); in fact the bell exists, computes badge count via `WorktreeHeaderFeature.State.unreadCount(in:)`, and is wired to `InboxClient.markReadForWorktree` on popover close. The v2 work for D1 is therefore narrower than the design doc implies: add the bell-slash master-disabled state and the disabled-banner inside the popover. Captured as tasks C5/C6 not "build new view."
- **2026-04-25 (planning):** `AgentDetectionRules.version` already exists and is enforced as `currentVersion = 1`; `version != currentVersion` throws `DecodingIssue.unsupportedVersion`. v2 needs to convert that into a migration ladder, not introduce versioning. Captured as task C2.
- **2026-04-25 (planning):** `InboxClient.markReadForWorktree` already exists. D13's "Sidebar worktree row tap → markReadForWorktree (new)" is therefore not new — the only D13 net-new method is `markReadForPane`. Captured as B10.
- **2026-04-25 (planning):** `InboxClient.observeUnread() -> AsyncStream<Int>` exists for total unread; `observeUnreadByWorktree` is genuinely new. Captured as B8.
- **2026-04-25 (Stage A start):** `make mac-test` is a placeholder ("no tests yet"). The real path is `xcodebuild -workspace apps/mac/codans.xcworkspace -scheme codans [-only-testing:...] test`. Per-suite filter `-only-testing:codansTests/<SuiteName>` works for Swift Testing suites; per-test filter does not (silently runs zero tests).
- **2026-04-25 (Stage A start):** Worktree onboarding required `mise trust <toml>` (per CLAUDE.md note) and a `git restore` inside `apps/mac/ThirdParty/git-wt` because the submodule's working tree had been emptied by the prior `submodule update --recursive` call. Build-baseline only goes green after the working-tree restore.
- **2026-04-25 (A2):** `AsyncSequence`-based notification observation (`NotificationCenter.default.notifications(named:)`) loses races against `post()` calls fired immediately after the observer task is created — the `for await` hadn't subscribed yet. Switched to synchronous `addObserver(forName:queue:using:)` which registers before `start()` returns. The closure body launches a `Task { @MainActor in ... }` to do the actor work.
- **2026-04-25 (A3):** Capturing the UN `completionHandler` inside a `Task { @MainActor in defer { completionHandler() } }` triggers Swift-6 "sending closure risks data races." Acking synchronously *before* launching the actor task is the clean fix — UN only requires timely completion, not that the work finishes first.
- **2026-04-25 (A4):** `bind(to:)`'s `async let settingsLoop = consumeSettingsChanges(settingsReader.notificationsSettingsChanges())` failed with "non-Sendable type 'any NotificationSettingsReader' cannot exit main actor-isolated context." Pre-evaluating the stream into a local `let settingsStream = settingsReader.notificationsSettingsChanges()` keeps the non-Sendable reader inside the parent actor while only `AsyncStream<Void>` (Sendable) crosses the child-task boundary.
- **2026-04-25 (A5):** Trackers do not cache rule lookups (the router holds the rule table; trackers only know `idleThreshold`). The "tracker invalidation" the design doc anticipated reduces to "propagate the new `idleThresholdSeconds` to existing trackers" — see DEC-EP8.
- **2026-04-25 (Stage A):** Baseline `make mac-lint` already fails on multiple pre-existing files (PullRequestPopover, MergeSplitButton, RootFeature, MainWindowCommands, PaneSurface, GhosttyActionDecoder, several test type-name violations). My touched files lint clean, but the make target is unusable as a green-bar gate; per-file `swiftlint --quiet` is the working alternative.

## Decision Log

- **DEC-EP1.** Tasks land as small individual commits, not as per-milestone squashes. Per-task acceptance criteria are tight enough that bisect across the v2 series stays useful.
- **DEC-EP2.** Stage A runs first end-to-end (A1 → A5) before Stage B starts. Reason: A1 (real C3 integration test) is the gate — if it surfaces a contract drift, Stage B work might compile against the wrong shape.
- **DEC-EP3.** Within a stage, tasks marked `[parallel:N]` with the same `N` may be dispatched concurrently to subagent worktrees per the user's Agent Teams instruction. Tasks without a parallel tag, or whose dependencies are unmet, run sequentially in the main worktree.
- **DEC-EP4.** Stage C task C5 (D1 master-disabled rendering) is gated on B5 (master toggle wired into `NotificationsSettings` + coordinator) — without B5 there is nothing to render against.
- **DEC-EP5.** `surfaceIdle` migration (C2) writes back the v2-stamped file on first load. Reason: the current behaviour already throws on version mismatch; converting it to a write-back is the minimum-impact change that lets v1 files survive a single launch. The user's `~/.config/codans/detection-rules.json` is rewritten exactly once with explicit `surfaceIdle: false` on every rule.
- **DEC-EP6.** D7 (rule-reload tracker invalidation, task A5) does NOT reset `currentState` per design doc. The plan task explicitly tests for this — closing a Pane is the only way to reset agent state.
- **DEC-EP7 (2026-04-25, Stage A reorder).** A1 (real C3 integration test) was originally first in Stage A; deferred to last because the existing `C6AppBootstrapTests.startWiresRouterCoordinatorAndBindLoop` already constructs a real `HookDispatcher`, fires through `router.handle(envelope:)`, and asserts the full chain. The remaining A1 gap is just an additional test method that fires through `dispatcher.fire(envelope)` directly, which is a polish task with no risk of contract drift bubbling up into Stage B.
- **DEC-EP8 (2026-04-25, A5).** Scope simplification: `AgentStateTracker` does not cache per-rule match contexts (the router holds the rule table). The only rule-derived state the tracker holds is `idleThreshold`. A5 reduces to "propagate `newRules.idleThresholdSeconds` from `coordinator.reloadRules` → `registry.updateIdleThreshold` → each tracker's `updateIdleThreshold`," with `state` left untouched. No `RuleStoreReloadTests` file created; one focused test added inside `C6AppBootstrapTests` to reuse the harness.
- **DEC-EP9 (2026-04-26, B6).** Sound ↔ system-notification mutex is a no-op in v1: there is no in-app sound channel separate from `UNNotificationContent.sound`, and the existing `guard settingsReader.systemEnabled else { return }` in the coordinator already prevents the would-be double-sound case. The `soundEnabled` UI toggle correctly maps to "OS banner sound on/off" today. If a future revision adds an in-app sound channel (e.g. an NSSound for muted-system-notifications-on play), the mutex logic from D10 lands at that point.
- **DEC-EP10 (2026-04-26, B7).** Production Ghostty key-input wire to `TrackerRegistry.recordKeyInput` is deferred until either (a) Ghostty's surface layer surfaces per-keystroke callbacks or (b) C3 dispatcher emits `.paneInput` envelopes. Both prerequisites are out of v2 scope. The forwarding API + tests land so v2.1 can wire one call site in one line.
- **DEC-EP11 (2026-04-26, B9).** Worktree auto-promote reducer drop-in is deferred to v2.1. The upstream `observeUnreadByWorktree` stream + `moveNotifiedWorktreeToTop` setting are both in place (B8/B2); only the consumer (a TCA reducer subscriber that fires `.worktreePromoteRequested(worktreeID)` on 0→N transitions and reorders within the repository group) is pending. Risk-controlled: the setting defaults true, so once the reducer lands the behavior turns on automatically; until then the toggle is a no-op.
- **DEC-EP12 (2026-04-26, Stage C).** Stage C (D1, D2, D14) is deferred to v2.1 in its entirety. Rationale: Stage A + Stage B (minus B9) close every runtime defect and most UX gaps the v1 audit surfaced. Stage C is purely additive (master-disabled bell-slash rendering, DSL v2 grammar bump with backwards-compat migration, structured metrics with `codans notifications stats` CLI). Shipping v2 now without C is safe — all v2.0 decisions DEC-V1..V11 remain valid; v2.1 picks up the surface work atop a stable v2 base.
- **DEC-EP13 (2026-04-26, post-review).** Code-reviewer flagged that `mute.enabled` semantics in `NotificationCoordinator.handle(output:)` diverge from DEC-V5 (which intends `mute.enabled = ON` to be "snooze — inbox still appends but OS surfaces silenced"). The current code, carried unchanged from v1, drops everything when `mute.enabled` is OFF. Realigning would change v1-era behaviour for users who relied on `mute.enabled = OFF` as a global kill — and v2's new top-level `enabled` master already provides that kill cleanly. Deferred to v2.1: rename or repurpose `mute.enabled` to match DEC-V5's "snooze" wording, and migrate any existing field meaning. Reviewer's APPROVE verdict is intact; this is a polish item, not a correctness regression introduced by v2.

## Outcomes & Retrospective

### Stage A complete (2026-04-26, commits e6b35c4 → bdd8704)

**Five fixes + plan + retro doc landed in 6 small commits.** Each commit is a single behaviour change with a focused test; bisecting across the series stays useful.

- `e6b35c4` — v2 design doc + exec plan (this file).
- `c814fa4` — A2: synchronous `addObserver` for `applicationDidBecomeActive` permission refresh.
- `c772357` — A3: `UserNotificationDelegate` routes OS Dismiss/Focus/body-tap to `InboxStore`.
- `c8a99fe` — A4: `notificationsSettingsChanges` AsyncStream + cached `lastUnreadCount` + `recomputeDockBadge`.
- `a1d46b8` — A5: tracker `updateIdleThreshold` propagation on rule reload (state preserved).
- `bdd8704` — A1: `dispatcherFireDeliversLifecycleEnvelopeThroughC6Stack` integration test.

**Tests added/extended:** `OSNotifierTests` (5 new), `C6AppBootstrapTests` (3 new — A1/A2/A5), `NotificationCoordinatorTests` (1 new — A4).

**Verification:** `xcodebuild ... -only-testing:codansTests/<Suite> test` green per suite. Full per-file `swiftlint --quiet` clean on touched files (baseline `make mac-lint` is dirty for unrelated files — see Surprises).

**Carry-forward into Stage B:**
- The settings-change AsyncStream introduced for A4 will be reused by B5 (master toggle gate) and B6 (sound mutex) since both observe the same fields.
- The `MockOSNotifier.assignedDelegate` recorder added in A3 unblocks future tests that need to assert the delegate is wired without involving live UN.
- `tracker.updateIdleThreshold` semantics established in A5 set the precedent for B7's `tracker.recordUserInput` (also a "side input that does not change `state`").

### Stage B complete (2026-04-26, commits cade4bb → afab00c)

**10 of 11 tasks landed; B9 deferred (DEC-EP11).** Eight commits + the
existing landed tooling deliver: dedup, master toggle, user-typing
suppression API + forwarding, per-worktree unread stream, mark-read-on-
focus on both UI and CLI sides.

- `cade4bb` — B1: `AgentNotification.dedupKey` + decodeIfPresent.
- `8a8084d` — B2: `NotificationsSettings.enabled` + `moveNotifiedWorktreeToTop`.
- `ca71925` — B3: tracker user-input suppression.
- `84ada3e` — B4: coordinator dedup window + `clearDedupCache` + `now` seam.
- `2cc09e1` — B5: master toggle gate + UI Master section.
- `7c7eaf2` — B7: `TrackerRegistry.recordKeyInput` forwarding seam.
- `70770f9` — B8: `observeUnreadByWorktree` + catalog provider.
- `63341f3` — B10: `InboxStore.markRead(forPane:)` + `InboxClient.markReadForPane`.
- `afab00c` — B11: `HierarchyHandlers.onPaneFocused` → `inbox.markRead(forPane:)`.

**Tests added/extended:** `AgentNotificationTests` (+2), `NotificationsSettingsTests` (NEW, 3), `AgentStateTrackerTests` (+3), `NotificationCoordinatorTests` (+5 dedup/master), `TrackerRegistryTests` (+2), `InboxStoreObserveTests` (+2), `InboxClientLiveTests` (+1), `HierarchyHandlersTests` (+1).

**Deferred:** B6 (DEC-EP9 — no in-app sound channel exists), B9 (DEC-EP11 — worktree-list reducer drop-in), Stage C entirely (DEC-EP12). All decisions are explicitly logged with rationale; the v2.0 design decisions DEC-V1..V11 remain valid for the v2.1 follow-up.

## Context and Orientation

This plan implements the v2 design doc. Read these documents before starting:

- **Design doc (authoritative):** [docs/design-docs/c6-agent-notifications-v2.md](../design-docs/c6-agent-notifications-v2.md). Contains the contracts, decisions DEC-V1 through DEC-V11, and rationale for every delta.
- **v1 design doc (background):** [docs/design-docs/c6-agent-notifications.md](../design-docs/c6-agent-notifications.md). Contains the FSM transition table, v1 dependency rules, and DEC-1 through DEC-16.
- **v1 exec plan (precedent):** [docs/exec-plans/0006-agent-notifications.md](0006-agent-notifications.md). Establishes the milestone style, test conventions, and `Outcomes & Retrospective` cadence used in this plan.
- **C3 hooks design:** [docs/design-docs/c3-lifecycle-hooks.md](../design-docs/c3-lifecycle-hooks.md). Defines `HookEvent`, `HookEnvelope`, `HookDispatcher`, `InternalHookSubscriber`. Required reading for A1.
- **Inbox sidebar v1 design:** [docs/design-docs/c6-m5-inbox-sidebar.md](../design-docs/c6-m5-inbox-sidebar.md). Background for B10/B11/C5.
- **Settings notifications v1 design:** [docs/design-docs/settings-notifications.md](../design-docs/settings-notifications.md) and [exec plan](settings-notifications.md). Background for B2/B5/B6.

### Source-tree map (current state)

The v1 implementation lives in three directories:

- **`apps/mac/CodansCore/Notifications/`** — pure value types. Imports nothing UI-specific.
  - `AgentState.swift` — 4-case FSM enum.
  - `AgentNotification.swift` (55 lines) — inbox-entry struct. **B1 adds `dedupKey: String?` here.**
  - `AgentDetectionRules.swift` (163 lines) — DSL with `currentVersion = 1`. **C1 bumps to 2 + adds `surfaceIdle`.**
  - `AgentStateTransition.swift`, `MuteSettings.swift`, `NotificationInbox.swift`, `NotificationInboxAggregation.swift`, `TemplateField.swift` — unchanged in v2.
- **`apps/mac/CodansCore/Settings/NotificationsSettings.swift`** — settings sub-tree. **B2 adds `enabled` + `moveNotifiedWorktreeToTop` here.**
- **`apps/mac/codans/Notifications/`** — app-target services. Imports `UserNotifications`, `AppKit`, etc.
  - `NotificationCoordinator.swift` (286 lines) — fan-out hub. **A4, B4, B5, B6, C4 all edit this file.**
  - `OSNotifier.swift` (111 lines) — UN wrapper. **A3, B6 edit; A3 adds new test file `OSNotifierTests`.**
  - `RuleStore.swift` (153 lines) — rule-file load + reload. **A5, C2 edit.**
  - `DetectionRouter.swift` (304 lines) — sentinel-prefix routing. **A5, C7 edit.**
  - `AgentStateTracker.swift` (233 lines) — per-Pane FSM. **B3, B7, C7 edit.**
  - `TrackerRegistry.swift` (118 lines) — tracker lifecycle owner. **A5, B7 edit.**
  - `DockBadger.swift`, `InboxStore.swift`, `TemplateRenderer.swift`, `C6AppBootstrap.swift`, `NotificationPermissionDelegate.swift`, `BrokenFileBackup.swift`, `ConfigPaths.swift`, `Defaults/DefaultRules.swift`, `Bridging/HookConfigStoreAdapter.swift`, `Bridging/HookConfigWriting.swift` — others.
- **`apps/mac/codans/App/Features/InboxSidebar/`** — TCA sidebar. `InboxSidebarView.swift`, `InboxSidebarFeature.swift`, `InboxFilter.swift`. **B9 edits the worktree-list reducer in this area or adjacent.**
- **`apps/mac/codans/App/Features/WorktreeHeader/`** — per-worktree header.
  - `HeaderBellView.swift` (51 lines) — bell button + badge + popover host. **C5 edits for master-disabled rendering.**
  - `HeaderBellPopover.swift` (205 lines) — popover content. **C5 adds disabled banner.**
  - `WorktreeHeaderFeature.swift` — TCA reducer with `unreadCount(in:)`. **C6 verifies/extends.**
- **`apps/mac/codans/App/Features/Settings/`** — settings UI.
  - `SettingsStore.swift` — `mutateNotifications`. **B2/B5 verify pass-through.**
  - `Panes/NotificationsSettingsView.swift` — settings pane. **B5 adds master toggle row; B6 adds sound footnote/disable.**
- **`apps/mac/codans/App/Clients/InboxClient.swift`** — `DependencyKey`. **B8 adds `observeUnreadByWorktree`; B10 adds `markReadForPane`.**
- **`apps/mac/codans/Tests/NotificationsTests/`** — Swift Testing suites: `NotificationCoordinatorTests`, `AgentStateTrackerTests`, `OSNotifierTests` (NEW for A3), `RuleStoreReloadTests` (NEW for A5), `C6C3IntegrationTests` (NEW for A1), `MetricsTests` (NEW for C7), and others listed at design-doc § Tests Added.

### Terminology

- **`HookEnvelope`** — C3-defined value type carrying an event kind, originating Pane, and structured payload. Routes through `HookDispatcher.internalEventStream()`.
- **Sentinel-prefix routing** — C6 registers C3 subscriptions whose `command:` field is `__codans/internal:notifications:<ruleID>`. The `__codans/internal:` prefix is reserved by C3; `DetectionRouter` is registered as the in-process `InternalHookSubscriber` for that prefix and decodes `<ruleID>` from the suffix.
- **`AgentStateTransition`** — `(paneID, from: AgentState, to: AgentState, trigger: Trigger)`. Produced by `AgentStateTracker`, consumed by `NotificationCoordinator`.
- **Master toggle vs. mute (DEC-V5).** `enabled = false` short-circuits the entire pipeline — no inbox append. `mute.enabled = true` allows inbox append (so users can review history) but silences OS post + badge + sound.

## Plan of Work

The plan is organized as three milestones matching the design doc's stages. Each milestone is independently shippable in the sense that no later milestone is blocked from compiling by an earlier one being incomplete — but the recommended landing order is A → B → C because (a) A unblocks confidence in C3 wiring, (b) B's `enabled` master is a precondition for C5's bell-slash rendering, and (c) C's metric counters depend on B's gating logic to count `mutedDropped` / `masterDropped` correctly.

### Milestone A — Runtime hardening

**Goal:** prove the v1 wiring matches the C3 contract at runtime, fix the four runtime-correctness defects (badge lag, OS Dismiss not propagating, permission stale, rules-reload not invalidating trackers), and lay test infrastructure that subsequent stages will reuse.

**Tasks A1–A5.**

**A1 — `C6C3IntegrationTests`.** Create `apps/mac/codans/Tests/NotificationsTests/C6C3IntegrationTests.swift`. Construct a real `HookDispatcher` (constructor signature from `apps/mac/codans/Hooks/HookDispatcher.swift` — read it first; do NOT use the `MockHookDispatcher` from `C6EndToEndTests`). Register `DetectionRouter` as an `InternalHookSubscriber` for prefix `__codans/internal:notifications:`. Fire a synthetic `HookEnvelope(.paneOutputMatch, paneID: paneA, ruleID: "claude.completed", capturedGroups: [...])` through `dispatcher.fire(envelope)`. Assert: (a) the tracker emits a `.transition(to: .completed, ...)`, (b) `NotificationCoordinator` appends to a real (in-memory) `InboxStore`. Run with `mac-test`; expect 1 new test passing.

**A2 — `applicationDidBecomeActive` permission refresh.** Edit `apps/mac/codans/Notifications/C6AppBootstrap.swift` (the boot path that constructs `NotificationCoordinator`). Add a subscription to `NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)` that calls `coordinator.refreshAuthorizationStatus()` on every fire. Use `[weak coordinator]` to avoid retain. Add a smoke test in `NotificationCoordinatorTests` that injects a fake `UNUserNotificationCenter` and asserts `getNotificationSettings` is called when the publisher emits.

**A3 — OS Dismiss action wired.** Edit `apps/mac/codans/Notifications/OSNotifier.swift`. In init, register two `UNNotificationCategory` actions: `codans.focus` (default) and `codans.dismiss` (destructive). Edit (or create, if absent) the `UNUserNotificationCenterDelegate` adapter that v1 already wires (search for `userNotificationCenter(_:didReceive:withCompletionHandler:)`). Route `codans.focus` to `inbox.markRead([id])` + deeplink, `codans.dismiss` to `inbox.dismiss([id])`, default action to `markRead` + deeplink. Create `apps/mac/codans/Tests/NotificationsTests/OSNotifierTests.swift` (NEW file) with a mocked `UNUserNotificationCenter` and three tests covering the three action paths.

**A4 — Synchronous dock badge recompute.** Edit `apps/mac/codans/Notifications/NotificationCoordinator.swift`. The current `handleUnread()` ANDs `dockBadgeEnabled && inAppEnabled`. Add a `recomputeDockBadge()` method and a Combine subscription on `settings.publisher(for: \.notifications.inAppEnabled)` and `\.notifications.dockBadgeEnabled` (using whatever publisher facility the `SettingsStore` exposes — read `apps/mac/codans/App/Features/Settings/SettingsStore.swift` and use the existing `@Observable` change publisher). Add `NotificationCoordinatorTests.inAppDisabledClearsBadgeImmediately`.

**A5 — Rule-reload tracker invalidation.** Edit `apps/mac/codans/Notifications/RuleStore.swift`: `reloadAndRematerialise()` already exists; modify it to broadcast a `RulesReloaded(version: Int, ruleIDs: Set<RuleID>)` message via a new `AsyncStream<RulesReloaded>` exposed as `RuleStore.reloadEvents`. Edit `DetectionRouter.swift`: subscribe to `reloadEvents` and atomically replace its `[RuleID: AgentDetectionRule]` lookup table. Edit `TrackerRegistry.swift`: add `invalidateAll(_ newTable: [RuleID: AgentDetectionRule])` that calls each tracker's new `refreshRuleBindings(_:)` method. Edit `AgentStateTracker.swift`: add `refreshRuleBindings(_:)` that drops cached match contexts but DOES NOT reset `currentState`. Wire all three in `C6AppBootstrap.swift`. Create `apps/mac/codans/Tests/NotificationsTests/RuleStoreReloadTests.swift` (NEW) with two tests: `reloadInvalidatesActiveTrackers` and `reloadDoesNotResetCurrentState`.

### Milestone B — UX gap-closing

**Goal:** add the `dedupKey` cross-source dedup, user-typing suppression, sound mutex, worktree auto-promotion, master toggle, and complete focus → mark-read coverage. After this milestone, the user-visible behaviour of the notification system matches the v2 design doc's Goals section in full.

**Tasks B1–B11.** Order matters: B1/B2/B3 introduce model/state changes that B4/B5/B6 then consume; B7 wires B3 into the Pane input path; B8 unblocks B9 and (for Stage C) C5; B10/B11 are independent.

**B1 — `AgentNotification.dedupKey`.** Edit `apps/mac/CodansCore/Notifications/AgentNotification.swift`. Add `public var dedupKey: String?` after `createdAt`. Update synthesized Codable manually if v1 uses explicit `CodingKeys` (the file is short; check). Use `decodeIfPresent` so old `notifications.json` files decode unchanged. Update `AgentNotification.init` to accept `dedupKey: String? = nil` as the last parameter. Add a round-trip test in `AgentNotificationTests` (or wherever Codable tests live; check `apps/mac/Tests/CodansCoreTests/`).

**B2 — `NotificationsSettings.enabled` + `moveNotifiedWorktreeToTop`.** Edit `apps/mac/CodansCore/Settings/NotificationsSettings.swift`. Add two new fields with defaults `true` for both. Add to `CodingKeys`. Add `decodeIfPresent` with default `true`. Update the `init(...)` signature with both new parameters (defaulted, so call sites compile unchanged). Add round-trip test.

**B3 — Tracker user-input suppression (no wiring).** Edit `apps/mac/codans/Notifications/AgentStateTracker.swift`. Add `private var lastUserInputAt: Date?` and `private let userInteractionWindow: TimeInterval = 3.0`. Add `func recordUserInput(at: Date = .now)`. Add `private func shouldSuppress(_ transition: AgentStateTransition) -> Bool` per design doc D4. Modify the transition-emission path to skip emission if `shouldSuppress` returns true. Add three tests in `AgentStateTrackerTests`: `userInputSuppressesCompletionWithinWindow`, `userInputDoesNotSuppressBlockedOnInput`, `userInputAfterWindowAllowsCompletion`. No registry wiring yet — this task is testable in isolation against a directly-constructed tracker.

**B4 — Coordinator dedup window.** Edit `apps/mac/codans/Notifications/NotificationCoordinator.swift`. Add `private struct DedupRecord { let key: String; let postedAt: Date }` and `private var recentByPane: [PaneID: DedupRecord] = [:]`. Add `private let dedupWindow: TimeInterval = 2.0` (constant, not a setting per design doc). Add `private func computeDedupKey(_ n: AgentNotification, paneID: PaneID) -> String` returning `n.dedupKey ?? hash(paneID, n.title, n.body)`. At the entry of `handleTransition`, call `computeDedupKey`, look up `recentByPane[paneID]`, drop if same key + within window, otherwise insert/replace. Add `func clearDedupCache(_ paneID: PaneID)` and call it from `TrackerRegistry.teardown(paneID)`. Tests: `dedupBlocksDuplicateWithinWindow`, `dedupAllowsDuplicateAfterWindow`, `dedupKeyOverridesContentHash`, `paneTeardownClearsDedup`.

**B5 — Master toggle gate.** Edit `NotificationCoordinator.swift`. At entry of `handleTransition`, check `settings.notifications.enabled`; if false, return early — no inbox append, no surfaces. Edit `apps/mac/codans/App/Features/Settings/Panes/NotificationsSettingsView.swift` to add a top-level toggle row bound to `settings.notifications.enabled`; sub-toggles dim/disable when master is off. Test: `NotificationCoordinatorTests.masterEnabledFalseDropsAll`.

**B6 — Sound mutex.** Edit `OSNotifier.post` to set `content.sound = systemEnabled ? .default : nil`. Edit `NotificationCoordinator`'s in-app sound branch to use `let shouldPlayInAppSound = settings.notifications.soundEnabled && !settings.notifications.systemEnabled`. Edit `NotificationsSettingsView`: when `systemEnabled` is on, render the sound toggle disabled with a "Played by macOS" footnote. Test: `NotificationCoordinatorTests.soundMutexWithSystem`.

**B7 — Wire Pane key input → tracker.** Edit `TrackerRegistry.swift`: add `func recordKeyInput(paneID: PaneID)` that forwards to the matching tracker's `recordUserInput()`. Wire the call site in the Pane input path — read `apps/mac/codans/Infrastructure/Ghostty/GhosttySurfaceView.swift` and `apps/mac/codans/Infrastructure/Ghostty/GhosttySurfaceBridge.swift` to find where keystrokes flow; add a callback or direct invocation. Add an end-to-end test in `AgentStateTrackerTests` that exercises Registry → Tracker.

**B8 — `observeUnreadByWorktree`.** Edit `apps/mac/codans/Notifications/InboxStore.swift`: add `func observeUnreadByWorktree() -> AsyncStream<[Catalog.WorktreeID: Int]>` that re-derives per-worktree unread counts on every mutation by joining `notifications` against `Catalog`. Note: `InboxStore` does not currently hold a reference to `Catalog` — pass a `@Sendable () -> Catalog` snapshotter through the constructor or a setter so the store can re-derive on demand without coupling. Edit `InboxClient.swift`: add `var observeUnreadByWorktree: @MainActor @Sendable () -> AsyncStream<[Catalog.WorktreeID: Int]>` and the live + preview + test-fail implementations. Test: `InboxStoreObserveTests.observeUnreadByWorktreeEmitsPerGroup`.

**B9 — Worktree auto-promote.** Locate the worktree-list reducer (likely in `apps/mac/codans/App/Features/Sidebar/` or similar — search for the reducer that owns sidebar worktree ordering; if it is in the same area as `InboxSidebarFeature` they may live side-by-side). Subscribe to `inboxClient.observeUnreadByWorktree`. Track the previous unread map; on a `0 → N` transition for a worktree, send `.worktreePromoteRequested(worktreeID)` which reorders that worktree to the top of its repository group, preserving manual ordering for all others. Gate the entire mechanism on `settings.notifications.moveNotifiedWorktreeToTop`. Reducer test: 0 → 1 promotes; 1 → 2 does not promote (no flapping); cleared → re-fired re-promotes.

**B10 — `markReadForPane`.** Edit `apps/mac/codans/Notifications/InboxStore.swift`: add `func markRead(forPane paneID: PaneID)`. Edit `InboxClient.swift`: add `var markReadForPane: @MainActor @Sendable (_ paneID: PaneID) -> Void` and the live + preview + test-fail implementations. Test: `InboxClientLiveTests.markReadForPane`.

**B11 — `codans focus` calls markReadForPane.** Edit the `codans focus` CLI command implementation (search `apps/mac/codans/CLI/` or wherever the CLI lives — read the v1 exec plan 0003-hooks-and-cli.md if needed). Call `inboxClient.markReadForPane(paneID)` after the focus action succeeds. Add a CLI smoke test if the existing infrastructure supports it; otherwise document the manual QA path in `Validation and Acceptance`.

### Milestone C — New surfaces & telemetry

**Goal:** ship the three new affordances (status-bar bell hardening, DSL v2 with `surfaceIdle`, structured metrics + `codans notifications stats`).

**Tasks C1–C8.**

**C1 — `AgentDetectionRules` v2 + `surfaceIdle`.** Edit `apps/mac/CodansCore/Notifications/AgentDetectionRules.swift`. Bump `currentVersion` to `2`. Add `public var surfaceIdle: Bool = false` to `AgentDetectionRule`. Add to `CodingKeys`. Use `decodeIfPresent` with default `false`. Update the rule's `init` signature with the new parameter (defaulted). Round-trip test in `CodansCoreTests`.

**C2 — `RuleStore.load()` migration ladder.** Edit `apps/mac/codans/Notifications/RuleStore.swift`. Replace the current "`unsupportedVersion` if version != currentVersion" throw with: `if rawVersion == 1 { migrate v1 → v2 in memory; write back atomically }`; otherwise pass through. The migration is purely additive (add `surfaceIdle: false` to every rule + bump version stamp). Tests in `RuleStoreTests`: `migrateV1ToV2WritesBack`, `loadV2ReturnsAsIs`, `loadMissingVersionAssumesV1AndMigrates`.

**C3 — `DefaultRules.json` declares v2.** Edit `apps/mac/codans/Notifications/Defaults/DefaultRules.json`. Set `"version": 2` at the top. For each rule, explicitly set `"surfaceIdle": false` (or `true` for any idle rules where the bundled intent is to surface). Verify `DefaultRulesRoundTripTests` and `DefaultRulesTests` still pass.

**C4 — Coordinator `surfaceIdle` resolution.** Edit `NotificationCoordinator.swift`. In the resolution-order path (where `mute.surfaceIdle` is consulted), add the per-rule check: if `transition.to == .idle`, prefer `rule.surfaceIdle == true` (override global mute) over `settings.mute.surfaceIdle`. Tests cover all four cells: (global on, rule false), (global on, rule true), (global off, rule false), (global off, rule true).

**C5 — `HeaderBellView` master-disabled rendering.** Edit `apps/mac/codans/App/Features/WorktreeHeader/HeaderBellView.swift`. Read `settings.notifications.enabled` (likely via `@Environment` or via the store). When false: render `Image(systemName: "bell.slash")`, no badge regardless of unread, click still triggers `popoverToggled(true)`. Edit `HeaderBellPopover.swift`: when master is disabled, render a banner at the top: "Notifications globally disabled" with an "Open Settings" button that dispatches the existing settings-window action. Add a SwiftUI snapshot test or a state-driven view-model test in `WorktreeHeaderFeatureTests`.

**C6 — `WorktreeHeaderFeature.unreadCount` regression.** Read `WorktreeHeaderFeature.swift` `unreadCount(in:)` to confirm it correctly returns this-worktree-only and is not double-counting after D11 promotion. Add a regression test in `apps/mac/codans/Tests/NotificationsTests/WorktreeHeaderFeatureTests.swift` (create file if absent) that constructs a feature state with notifications across two worktrees and asserts each worktree's bell shows only its own unread count. Add a second test for master-disabled-suppresses-badge.

**C7 — `NotificationMetric` + sink + call sites.** Create `apps/mac/codans/Notifications/NotificationMetric.swift` defining the `enum NotificationMetric` (per design doc D14), the `protocol NotificationMetricSink { func record(_ metric: NotificationMetric, value: Int = 1, attributes: [String: String]) }`, and `final class OSLogMetricSink: NotificationMetricSink` writing structured `os.Logger` entries (`subsystem: "codans.notifications"`, `category: "metrics"`). Inject the sink through `C6AppBootstrap` and pass to: `DetectionRouter` (rulesEvaluated, rulesMatched, templateRenderFailures), `NotificationCoordinator` (dedupDropped, mutedDropped, masterDropped, userInputSuppressed propagated from tracker, osPostSucceeded/Failures propagated from notifier), `OSNotifier` (osPostSucceeded/Failures). Create `apps/mac/codans/Tests/NotificationsTests/MetricsTests.swift` with 4+ tests covering one counter per call site.

**C8 — `codans notifications stats` CLI.** Edit the CLI command tree (see B11 for location). Add a `notifications stats` subcommand that reads `os.Logger` entries for the last hour using `OSLogStore` (Foundation, macOS 12+) filtered by `subsystem == "codans.notifications" && category == "metrics"`, aggregates per-counter, and prints a fixed-width table to stdout. CLI smoke test or manual QA path in Validation.

### Final review tasks

**R1 — Full validation.** Run `make mac-build`, `make mac-test`, `make mac-lint`. Execute the manual QA checklist from `Validation and Acceptance`.

**R2 — Code reviewer agent.** Dispatch the `agent-skills:code-reviewer` agent on the v2 delta (commits since the start of this plan's execution). Address any findings before declaring v2 complete.

## Concrete Steps

Working directory for all commands is the repository root: `/Users/wanggang/.prowl/repos/codans/feature/notification`.

**Per-task workflow:**

1. Read the task's listed files.
2. Make the change.
3. Run the target test suite for the affected module:
   ```bash
   make mac-test  # full suite when in doubt
   ```
   Expected output ends with `Test Suite 'All tests' passed`. New tests added by the task should appear in the output.
4. Run lint:
   ```bash
   make mac-lint
   ```
   Expected output: empty (no warnings). If it fails, fix before committing.
5. Commit with a focused message. Conventional commits format, English (per project conventions). Example for B1:
   ```
   feat(notifications): add dedupKey field to AgentNotification

   Optional String field on AgentNotification, decoded with decodeIfPresent
   so v1 inbox.json files round-trip unchanged. Coordinator consumption
   lands in B4.
   ```
   Do NOT use `--no-verify`. Pre-commit hooks must pass.

**Stage A start:**

```bash
git checkout feature/notification
git pull --ff-only        # confirm clean before starting
make mac-build            # baseline must build green before any task
make mac-test             # baseline must be green
```

**Stage transitions:** after the last task in a stage commits, run `make mac-test` once more to confirm the stage is clean. Update the Progress checklist and the per-task Outcomes & Retrospective entry below.

**Agent Teams dispatch (per DEC-EP3).** When tasks are tagged `[parallel:N]`, dispatch them as Agent Teams using `git worktree`-based isolation. Brief each subagent with: the task ID, its acceptance criteria, the file paths to touch, and the test file(s) to add. Do NOT dispatch a parallel batch whose members touch shared files (check the per-task file list above for overlap).

Example dispatch for Stage A parallel batch (A1, A2, A3 all in `[parallel:A1]`):

```
Subagent 1 (worktree feat/c6v2-a1-c3-integration): A1 only.
Subagent 2 (worktree feat/c6v2-a2-perm-refresh):    A2 only.
Subagent 3 (worktree feat/c6v2-a3-os-dismiss):      A3 only.
```

After all three return green, rebase each onto `feature/notification` in the order A1 → A2 → A3 (alphabetic for predictability), running `make mac-test` between rebases. Then run A4 and A5 sequentially in the main worktree because they edit shared files.

## Validation and Acceptance

The plan is accepted when all of the following hold.

**Automated:**

- `make mac-test` → all suites green, including the 9 new test files / ~32 new test methods enumerated in the design doc § Tests Added.
- `make mac-lint` → clean.
- `make mac-build` → builds without warnings.
- `agent-skills:code-reviewer` agent run on the branch reports no critical findings.

**Manual QA:**

1. **Dedup (D3):** open a Pane with `claude` labelled. Cause both a Stop hook and a terminal OSC 9 sequence to fire for the same completion (run a long command then Ctrl+C — the Stop hook + terminal SIGTERM both fire). Inbox shows ONE row, not two.
2. **User-input suppression (D4):** open a Pane, type a multi-line command and press Enter. Within 3 s the agent emits its first response. No banner. Wait 5 s, type nothing, agent finishes. Banner appears.
3. **Permission refresh (D6):** revoke notification permission in System Settings → Notifications → codans. Send a synthetic notification — no banner. Re-grant permission in System Settings while codans is in the background. Switch to codans (causes `applicationDidBecomeActive`). Send another synthetic notification — banner appears.
4. **Rule reload (D7):** with two Panes running `claude`, edit `~/.config/codans/detection-rules.json` to change a regex. Run `codans notifications rules reload` (or trigger the in-app reload affordance). Cause both Panes to emit output that matches ONLY the new regex. Both Panes notify.
5. **Dock badge sync (D8):** with unread > 0, toggle "in-app notifications" off in Settings. Dock badge clears in the same UI tick.
6. **OS Dismiss (D9):** with a banner showing, click "Dismiss" on the banner. Open the inbox sidebar — the corresponding row is gone.
7. **Sound mutex (D10):** enable both system + sound. Trigger a notification — exactly one sound plays (the OS sound). Disable system, keep sound. Trigger — `notification.wav` plays.
8. **Worktree promote (D11):** with three worktrees in a repo and the third in the bottom of the list, cause an unread notification in the third. The third moves to the top.
9. **Master toggle (D5):** toggle "Notifications enabled" off. Trigger an event that would normally notify. No inbox row, no banner, no badge, no sound.
10. **Bell-slash (DEC-V11):** with master off, the per-worktree header bell renders as `bell.slash`. Click it — popover opens showing the disabled-banner with "Open Settings".
11. **DSL migration (D2):** with a hand-edited `~/.config/codans/detection-rules.json` at `version: 1`, launch the app. The file is rewritten with `version: 2` and every rule has explicit `surfaceIdle: false`. Existing user customisations are preserved.
12. **Per-rule `surfaceIdle` (D2):** with global `mute.surfaceIdle: true` and one rule's `surfaceIdle: true`, that rule's idle transitions notify; all others do not.
13. **Metrics CLI (D14):** run `codans notifications stats`. Output shows non-zero values for `rulesEvaluated`, `rulesMatched`, `osPostSucceeded`, etc. for the last hour.
14. **Focus → mark read (D13):** with two unread notifications for Pane A in the inbox, run `codans focus paneA-id` from a terminal. Inbox shows both rows now read.

## Idempotence and Recovery

- All tasks are idempotent: re-running a task that has already landed is a no-op (the target file already has the change, the test already passes). The migration step C2 is idempotent because it checks `version == 2` before writing back.
- If `make mac-test` fails mid-stage, do NOT stash and continue to the next task. Diagnose, fix, commit a fix-up commit (do not amend the prior task's commit), then move on.
- If a parallel-batch subagent fails, drop its worktree (`git worktree remove`) and retry that task in the main worktree as a sequential task.
- The detection-rules migration writes a backup at `~/.config/codans/detection-rules.json.broken-<ISO8601>` if the file is malformed. v1 already implements this pattern via `BrokenFileBackup.swift`; C2's migration uses it.
- The notifications-inbox file (`notifications.json`) is forward-compatible with v2 (B1's `dedupKey` is optional, `decodeIfPresent`) so no migration is needed there.

## Artifacts and Notes

The v1 exec plan [0006-agent-notifications.md](0006-agent-notifications.md) is the precedent for this plan's structure. Per-task `Outcomes & Retrospective` entries should follow its format: what landed, verification command + expected output, carry-forward.

For the `NotificationCoordinatorTests` extensions, examine the existing file's helper structure (mocked `OSNotifier`, in-memory `InboxStore`, fake `Clock<Duration>`) before adding tests — reuse, don't duplicate.

## Risks

- **Parallel work conflict.** Stage A's A1/A2/A3 are all in `[parallel:A1]` but A2 edits `C6AppBootstrap.swift` and A3 edits `OSNotifier.swift` + the `UNUserNotificationCenterDelegate`. If the delegate lives inside `C6AppBootstrap.swift`, A2 and A3 conflict. Mitigation: read `C6AppBootstrap.swift` before dispatching the batch; if the delegate is there, demote A2 and A3 to sequential.
- **B7 input wiring depth.** Wiring Pane keystrokes from `GhosttySurfaceBridge` up to `TrackerRegistry` may require touching a Ghostty integration layer that v2 hasn't otherwise touched. If the depth becomes a multi-file refactor, scope down to a Pane-input observer added at the `WorktreeTerminalState` (or equivalent) layer — keep the contract narrow.
- **B9 worktree-list ownership.** The reducer that owns sidebar worktree ordering may not exist as a single coherent "WorktreeListFeature" — the codans worktree sidebar is split across multiple TCA features per recent commits. The promotion may need to land in whichever reducer owns the per-repository ordering; identify it before starting B9 (read `apps/mac/codans/App/Features/Sidebar/` if present, otherwise grep for `worktree.*ordering` patterns).
- **C5 settings access from view.** `HeaderBellView` currently accesses `WorktreeHeaderFeature.State.unreadCount(in:)` — getting `settings.notifications.enabled` into the view requires either threading the settings into the feature state or reading it via an Environment value (which `SettingsStore` exposes). Pick the path consistent with v1 patterns; if uncertain, follow how `HeaderBellPopover` already accesses settings.
- **Real C3 dispatcher signatures.** A1 assumes `HookDispatcher` is constructible without heavy state; if its constructor requires the catalog and other live state, wrap the test setup in a helper that mirrors `C6AppBootstrap`'s wiring without the AppKit dependencies. If that's not possible the test downgrades to "real subscriber + fake dispatcher" — still better than "fake subscriber + fake dispatcher".

## Interfaces and Dependencies

End-state contracts that must exist after this plan lands.

**`apps/mac/CodansCore/Notifications/AgentNotification.swift`:**

```swift
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
    public var dedupKey: String?            // NEW (B1)
}
```

**`apps/mac/CodansCore/Notifications/AgentDetectionRules.swift`:**

```swift
public struct AgentDetectionRules: Codable {
    public static let currentVersion: Int = 2  // BUMPED (C1)
    public var version: Int
    public var idleThresholdSeconds: TimeInterval
    public var rules: [AgentDetectionRule]
}

public struct AgentDetectionRule: Codable {
    // existing fields unchanged …
    public var surfaceIdle: Bool = false       // NEW (C1)
}
```

**`apps/mac/CodansCore/Settings/NotificationsSettings.swift`:**

```swift
public struct NotificationsSettings: Equatable, Codable, Sendable {
    public var enabled: Bool                     = true   // NEW master (B2)
    public var inAppEnabled: Bool                = true
    public var systemEnabled: Bool               = true
    public var soundEnabled: Bool                = true
    public var dockBadgeEnabled: Bool            = true
    public var moveNotifiedWorktreeToTop: Bool   = true   // NEW (B2)
    public var mute: MuteSettings
    public var authStatus: AuthorizationStatusCache
    public var neverPrompt: Bool
    public var notNowUntil: Date?
}
```

**`apps/mac/codans/App/Clients/InboxClient.swift`:**

```swift
struct InboxClient {
    var dismiss:               @MainActor @Sendable (_ ids: [UUID]) -> Void
    var markRead:              @MainActor @Sendable (_ ids: [UUID]) -> Void
    var markReadForWorktree:   @MainActor @Sendable (_ worktreeID: WorktreeID, _ catalog: Catalog) -> Void
    var markReadForPane:       @MainActor @Sendable (_ paneID: PaneID) -> Void                              // NEW (B10)
    var clearAll:              @MainActor @Sendable () -> Void
    var observe:               @MainActor @Sendable () -> AsyncStream<NotificationInbox>
    var observeUnread:         @MainActor @Sendable () -> AsyncStream<Int>
    var observeUnreadByWorktree: @MainActor @Sendable () -> AsyncStream<[Catalog.WorktreeID: Int]>          // NEW (B8)
    var muteRule:              @MainActor @Sendable (_ ruleID: String, _ muted: Bool) -> Void
}
```

**`apps/mac/codans/Notifications/NotificationCoordinator.swift`:** gains `clearDedupCache(_:)`, `recomputeDockBadge()`, `recentByPane`, `dedupWindow`, the master-toggle gate, the sound-mutex computation, the per-rule `surfaceIdle` resolution, and metric-sink call sites.

**`apps/mac/codans/Notifications/OSNotifier.swift`:** gains `UNNotificationCategory` registration with `codans.focus` + `codans.dismiss` actions. Holds an `inbox: InboxClient` reference (or a callback shape) for the delegate to dispatch to.

**`apps/mac/codans/Notifications/RuleStore.swift`:** `reloadEvents: AsyncStream<RulesReloaded>`; `load()` migrates v1 → v2 with atomic write-back.

**`apps/mac/codans/Notifications/TrackerRegistry.swift`:** `recordKeyInput(paneID:)`, `invalidateAll(_ newTable:)`.

**`apps/mac/codans/Notifications/AgentStateTracker.swift`:** `recordUserInput(at:)`, `refreshRuleBindings(_:)`.

**`apps/mac/codans/Notifications/NotificationMetric.swift` (NEW, C7):**

```swift
enum NotificationMetric: String {
    case rulesEvaluated, rulesMatched
    case templateRenderFailures
    case dedupDropped, mutedDropped, masterDropped
    case userInputSuppressed
    case osPostFailures, osPostSucceeded
}

protocol NotificationMetricSink: Sendable {
    func record(_ metric: NotificationMetric, value: Int, attributes: [String: String])
}

final class OSLogMetricSink: NotificationMetricSink { /* … */ }
```

**External dependencies:** none new. v2 is in-tree and consumes only what v1 already depends on.
