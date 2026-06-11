# Design Doc: Settings Window — Notifications Pane (T2)

**Status:** Draft
**Author:** Gump (agent: feat/settings-notifications)
**Date:** 2026-04-21
**Product spec:** [ui-settings-window.md](../product-specs/ui-settings-window.md)
**Depends on:** [settings-base.md](settings-base.md) (T1 — merged)

## Context and Scope

T1 landed the Settings window shell and the `Settings` v2 persistence layer
with four UI-owned toggle fields ready on `NotificationsSettings`:
`inAppEnabled`, `systemEnabled`, `soundEnabled`, `dockBadgeEnabled`.
T1 also delivered a placeholder `NotificationsSettingsView` whose body is
`Text("TODO: supplied by T2")`, and the `NotificationSettingsReader`
protocol that `SettingsStore` already conforms to.

T2 replaces the pane body with spec M5's five controls and **completes the
coordinator wiring that T1 stopped short of**: the codex review of PR #22
(K4/K5) found that `NotificationCoordinator` still reads the legacy
`mute.badgeEnabled` for the Dock badge and entirely ignores the three new
toggles `systemEnabled` / `soundEnabled` / `inAppEnabled`. Master classified
that wiring as T2 scope, so this doc covers both the UI and the backend
contract completion — UI alone would ship a pane whose toggles are
persisted but inert.

Reference files this change touches:

- `apps/mac/codans/App/Features/Settings/Panes/NotificationsSettingsView.swift` — body replace.
- `apps/mac/codans/Notifications/NotificationCoordinator.swift` — wire three toggles + swap Dock badge source.
- `apps/mac/codans/Notifications/OSNotifier.swift` — extend `post` with `playSound:`.
- `apps/mac/codans/Tests/NotificationsTests/NotificationCoordinatorTests.swift` — three new tests.

Out of scope (T3 / T4 / future):

- Developer / Shortcuts / Updates / Repository panes.
- Mute-rules visual editing. Pane offers "Reveal rules.json" only.
- Any change to `Settings` v2 schema, `SettingsStore` API, or the detail
  switch in `SettingsWindowView` — T1 contracts are frozen.
- A standalone in-app banner surface. Touch-code's only in-app surface
  today is the inbox (bell + unread list); `inAppEnabled` gates that, see
  D2 below.

## Goals and Non-Goals

### Goals

- G1 — Deliver the five M5 controls in `NotificationsSettingsView`
  wired read-path through `NotificationSettingsReader` and write-path
  through `SettingsStore.mutateNotifications`.
- G2 — Permission alert (M5.2): toggling System notifications while
  `authStatus == .denied` surfaces a modal alert with an
  "Open System Settings" button that deep-links to the Notifications
  pane in macOS System Settings.
- G3 — Mute-rules summary (M5.5): read-only count + "Reveal rules.json
  in Finder" button reveals `~/.config/codans/detection-rules.json`.
- G4 — Wire `NotificationCoordinator`:
  - G4a — `dockBadgeEnabled` replaces `mute.badgeEnabled` as the
    authority for the Dock badge branch in `consumeUnreadPublisher`.
  - G4b — `systemEnabled == false` suppresses the OS banner post
    (but not the inbox append).
  - G4c — `soundEnabled == false` posts a silent OS banner (no
    `UNNotificationSound` on the content).
  - G4d — `inAppEnabled == false` suppresses `inbox.append` entirely,
    which satisfies spec M5.1's "主窗口不出现应用内通知横幅" by removing
    the only in-app surface (inbox + bell + dock badge, since the badge
    is derived from the inbox's unread publisher).
- G5 — Three new coordinator tests (systemEnabled / soundEnabled /
  dockBadgeEnabled off paths), plus one inAppEnabled test by extension.

### Non-Goals

- NG1 — A separate "in-app banner" transient toast surface. None exists
  in the codebase today; spec M5.1 acceptance maps cleanly onto suppressing
  the inbox surface. See D2.
- NG2 — New SettingsStore APIs or schema fields. All four toggles already
  exist on `NotificationsSettings` per T1.
- NG3 — Editing muted rule IDs / pane IDs from inside the pane. M5.5
  is explicitly "summary + Reveal in Finder".
- NG4 — Changing how `authStatus` is refreshed. `NotificationCoordinator.
  refreshAuthorizationStatus()` already handles the external-flip case on
  app activation; the pane reads the cached status.

## Design

### Overview

Two independent edits:

```
┌───────────────────────────────────────────────────┐
│ NotificationsSettingsView      (UI — this PR)    │
│   reads  SettingsStore (NotificationSettingsReader)│
│   writes SettingsStore.mutateNotifications {…}    │
│   owns  local @State for permission alert         │
└────────────────┬──────────────────────────────────┘
                 │ same SettingsStore instance
                 ▼
┌───────────────────────────────────────────────────┐
│ NotificationCoordinator        (backend — this PR)│
│   reads  systemEnabled / soundEnabled /           │
│          inAppEnabled / dockBadgeEnabled          │
│   gates  inbox.append  /  osNotifier.post  /      │
│          badger.setUnreadCount                    │
└───────────────────────────────────────────────────┘
```

The pane writes a toggle → `SettingsStore` publishes an `@Observable` change
→ next router output the coordinator evaluates the new value from the same
reader. Debounced save (500 ms) persists to disk. No new dependency wiring,
no new bootstrap step.

### UI architecture — direct view + settingsStore (no new TCA reducer)

**Decision:** `NotificationsSettingsView` reads directly from
`SettingsStore` and writes via `mutateNotifications`, matching the
Appearance section's shape in `SettingsGeneralView`. A dedicated
`NotificationsFeature` reducer is **not** introduced.

Rationale:

- The entire pane is toggles + one alert flow + one reveal button. No
  async effects the reducer would coordinate: the alert is view-local
  `@State`; reveal is a single `NSWorkspace.shared.activateFileViewerSelecting`
  call.
- The Appearance control already follows the same pattern in
  `SettingsGeneralView` (picker bound to `settingsStore.settings.general.appearance`,
  write via `setAppearance(_:)`). Introducing a reducer just for
  notifications would be gratuitous divergence.
- T1's `SettingsWindowFeature.State` comment anticipated this choice
  ("T2/T3/T4 add child states here behind a Wave-1-introduced
  TODOPaneFeature.State placeholder keyed by SettingsSection"); that
  placeholder was never added because the pattern fits without it.
- Trade-off accepted: if a future wave needs effect orchestration here
  (e.g. a "Test notification" button that invokes `OSNotifier`), we
  introduce a reducer then. Today it is dead weight.

The pane receives `settingsStore: SettingsStore` the same way
`SettingsGeneralView` does, injected from `SettingsWindowView`'s detail
switch. No change to the switch shape or other panes.

### `NotificationsSettingsView` composition

One `ScrollView` containing a `VStack(alignment: .leading, spacing: 28)`
with five sections, each a section header + control:

1. **In-app notifications** — `Toggle` bound to
   `settings.notifications.inAppEnabled`. Caption: "Also gates the bell
   unread list and Dock badge."
2. **System notifications** — `Toggle` bound to
   `settings.notifications.systemEnabled`, with an `onChange` side-effect
   that triggers the permission alert if the new value is `true` and
   `authStatus == .denied`. See D1 for alert semantics.
3. **Sound** — `Toggle` bound to `settings.notifications.soundEnabled`.
   Disabled-with-tooltip when `systemEnabled` is false, so it's visually
   clear sound is derived from the system surface (no sound without a
   banner). Writes still persist on change — the derived-disabled state
   is a UI hint, not a write gate.
4. **Dock badge** — `Toggle` bound to `settings.notifications.dockBadgeEnabled`.
   Caption: "Shows the unread notification count on the app icon."
5. **Mute rules** — read-only summary row + "Reveal rules.json in Finder"
   button. Summary is strictly counts-only per spec M5.5 (Q2 APPROVE):
   `"<N> rule(s), <M> pane(s) muted"` where N = `mute.mutedRuleIDs.count`
   and M = `mute.mutedPanelIDs.count`; when both counts are zero the
   summary collapses to `"No mute rules"`. `surfaceIdle` / `redactBodies`
   are intentionally omitted — users who want detail click Reveal.

Write path:

```swift
let inAppEnabled = Binding<Bool>(
  get: { settingsStore.settings.notifications.inAppEnabled },
  set: { newValue in
    settingsStore.mutateNotifications { $0.inAppEnabled = newValue }
  }
)
```

Read of live `authStatus` for the alert: `settingsStore.authStatus` (via
`NotificationSettingsReader` conformance; same value the coordinator sees).

### D1 — Permission alert flow (M5.2)

SwiftUI `@State var showPermissionAlert = false` in the pane. When the
System notifications toggle is flipped to `true`:

- If `authStatus.isAuthorized == true`, do nothing extra. Write lands.
- If `authStatus == .notDetermined`, do nothing extra. The existing
  `onAgentPanelCreated` pre-prompt flow still governs the real request.
  (The pane does not initiate an OS permission request — that is
  `NotificationCoordinator`'s job and happens on pane creation.)
- If `authStatus == .denied`, set `showPermissionAlert = true`. The
  toggle value stays `true` (write persists). Rationale: once the user
  grants permission in System Settings, the `refreshAuthorizationStatus`
  sweep on `applicationDidBecomeActive` picks it up and subsequent
  router outputs post correctly. Reverting the toggle would force the
  user to flip it again after granting — bad UX.

Alert body: "Notifications are blocked for codans. Open System
Settings to allow them." Buttons:

- "Open System Settings" (default) — opens
  `x-apple.systempreferences:com.apple.preference.notifications?id=<bundle-id>`
  via `NSWorkspace.shared.open`. The `?id=...` deep-link is best-effort
  per Apple; if the URL variant is unsupported on the running macOS
  version, the System Settings app opens at its top-level Notifications
  pane (still useful, documented behaviour).
- "Cancel" (role: `.cancel`) — dismisses the alert. Toggle stays on.

### D2 — Semantics of `inAppEnabled` without an in-app banner surface

**Decision:** `inAppEnabled == false` suppresses `inbox.append` inside
`NotificationCoordinator.handle(output:)`. The inbox (bell popover + unread
list) IS the in-app surface codans has; suppressing it satisfies spec
M5.1's acceptance criterion ("主窗口不出现应用内通知横幅") by removing the
only in-app surface the app exposes today.

Consequences:

- Dock badge (fed by `inbox.unreadPublisher`) naturally drops to zero on
  new outputs while `inAppEnabled` is off. `dockBadgeEnabled` remains the
  fine-grained toggle to hide the badge while the inbox itself is on.
- OS banner is unaffected by `inAppEnabled` — it is gated by `systemEnabled`
  + `authStatus` only, matching user mental model ("in-app" vs "system").
- Dismissed outputs while `inAppEnabled` is off are lost; the inbox does
  not buffer them. This is consistent with current `mute.enabled == false`
  behaviour (the coordinator already drops everything in that branch
  today).

I'm surfacing this as a firm decision rather than a Q. If master reads
"in-app" differently (e.g. "add a new transient toast surface and gate
only that"), REVISE and I'll fork the design. But building a new toast
surface is >T2 scope, so the pragmatic reading is "the inbox is the
in-app surface".

### D3 — `OSNotifier.post` signature change

**Current:**

```swift
func post(_ notification: AgentNotification) async
```

**Proposed:**

```swift
func post(_ notification: AgentNotification, playSound: Bool) async
```

Inside `UserNotificationsOSNotifier.post`:

```swift
content.sound = playSound ? .default : nil
```

Coordinator call site passes `playSound: settingsReader.soundEnabled`.
`MockOSNotifier` in the test harness records `playSound` alongside the
posted notification so the new `soundEnabled=false` test can assert on
it. This is the smallest possible surface change — one parameter, one
line of adapter code, one mock field.

Rejected alternative: stash the preference on the adapter itself (a
settable property). That turns a pure adapter into a stateful one and
makes it harder to reason about multi-notification batches if a setting
flips mid-batch. Per-call parameter is stateless.

### Coordinator wiring diff

`consumeUnreadPublisher` (Dock badge branch) — replace
`settingsReader.mute.badgeEnabled` with `settingsReader.dockBadgeEnabled`.
Nothing else in that loop changes.

`handle(output:)` — today:

```swift
guard settingsReader.mute.enabled else { ...drop... }
// ...
inbox.append(notification)
// OS gate
guard shouldPostToOS(..., muting: muting) else { return }
guard settingsReader.authStatus.isAuthorized else { return }
await osNotifier.post(posted)
```

After T2:

```swift
guard settingsReader.mute.enabled else { ...drop... }
// ...
if settingsReader.inAppEnabled {
  inbox.append(notification)
}
// OS gate
guard settingsReader.systemEnabled else { return }
guard shouldPostToOS(..., muting: muting) else { return }
guard settingsReader.authStatus.isAuthorized else { return }
await osNotifier.post(posted, playSound: settingsReader.soundEnabled)
```

The `shouldPostToOS` mute-rules predicate stays unchanged — T1 kept it
on `MuteSettings`, T2 does not rescope muting. `systemEnabled` is an
outer guard so a "disabled system banner" path never even evaluates
muting.

Protocol `NotificationSettingsReader` already exposes all four fields,
so no contract change needed.

### Mute-rules summary source of truth

The pane reads `settingsStore.settings.notifications.mute` (already
exposed via the reader's `mute` property) and renders counts. The
"Reveal rules.json in Finder" button reveals
`ConfigPaths.detectionRules()` (absolute path
`~/.config/codans/detection-rules.json`). If the file does not exist
yet, `DefaultRules.installIfMissing` is invoked first (mirroring the
behaviour `RuleStore.reloadAndRematerialise` already relies on) so the
reveal target is real. This sidesteps the "Finder opens on nothing"
failure mode that spec M6 flagged for Developer's hooks.json reveal.

`ConfigPaths` is in the Notifications module (app target), same target
as the view, so no import dance is needed.

### Testing strategy

Add to `NotificationCoordinatorTests.swift`:

- **T-sys** — `systemEnabledFalseStillInboxesButSkipsOSPost`: harness
  with `authStatus = .authorized`, `systemEnabled = false`. Feed one
  transition. Expect `inbox.count == 1`, `postedNotifications.isEmpty`.
- **T-snd** — `soundEnabledFalsePostsWithoutSound`: harness with
  `authStatus = .authorized`, `soundEnabled = false`. Feed one
  transition. Expect `postedNotifications.count == 1` **and** the
  recorded `playSound` for that call is `false`.
- **T-dock** — `dockBadgeEnabledFalseClearsBadgeOnUnreadChange`:
  harness with `dockBadgeEnabled = false`. Start `bind()` (or drive
  `consumeUnreadPublisher` via an exposed method); expect
  `badger.calls.last == 0` after an append that raised unread to 1.
- **T-inapp** — `inAppEnabledFalseSkipsInboxAppend`: harness with
  `inAppEnabled = false`, `authStatus = .authorized`. Feed one
  transition. Expect `inbox.count == 0`, `postedNotifications.isEmpty`
  (no inbox ⇒ no "new" to surface, and the OS gate is orthogonal —
  actually: is OS gate on or off? It's on by default; per D2
  `inAppEnabled` does **not** gate OS. Expect `postedNotifications.count == 1`
  — demonstrates the independence and prevents someone from later
  coupling them.)

`T-dock` needs access to `consumeUnreadPublisher`. Currently it is
private and called from `bind()`. Two options:

- (a) Expose `func handleUnread(_ count: Int) async` at `internal`
  visibility — thin wrapper the test calls directly.
- (b) Start `bind()` and push through the real inbox publisher.

Option (a) is surgical (3 lines of source) and matches how
`handle(output:)` is already `internal` for testing. Going with (a).

Harness extension: `Self.make` grows four optional parameters
(`systemEnabled`, `soundEnabled`, `inAppEnabled`, `dockBadgeEnabled`)
with defaults `true, true, true, true` so existing tests are unchanged.
`MockOSNotifier.post` captures `(notification, playSound)` tuples.

Manual QA against spec Acceptance Criteria / Notifications:

- AC1 (permission denied → alert with "Open System Settings"): flip
  system off → on with Notifications permission revoked in System
  Settings. Alert appears with the deep-link button.
- AC2 (in-app off suppresses banners): toggle off, drive an agent
  transition, confirm bell popover does not surface and dock badge
  stays at 0.
- AC3 (sound + system both on, permission granted): toggle sound on,
  system on, grant permission. Trigger transition. Banner appears with
  sound.
- AC4 (dock badge off hides count): toggle off, trigger transition,
  dock badge stays hidden even though inbox has unread items.
- AC5 (Reveal rules.json): click button, Finder opens with
  `detection-rules.json` selected.

Verification commands (T2 PR gate):

```
make mac-generate
xcodebuild -workspace apps/mac/codans.xcworkspace -scheme codans \
  -configuration Debug test -destination 'platform=macOS' | xcbeautify
make mac-lint
make mac-format
```

### Rollback

No schema change, no migration — rollback is the git revert of this PR.
Users who flipped toggles while on T2 and then revert to T1 keep their
persisted values in `settings.json` (T1's decoder already tolerates the
fields via `decodeIfPresent`); T1 just doesn't read three of them.

## Alternatives Considered

### A1 — Introduce `NotificationsFeature` TCA reducer

Each toggle lives as `State.Bool`, actions are `case setSystemEnabled(Bool)`,
etc. Reducer calls out to a `SettingsClient` dependency (new).

- Pros: Uniform pattern if someday other panes add complex effects.
- Cons: Five toggles + one alert does not justify a reducer, a new
  client dependency, a `Scope` in `SettingsWindowFeature`, and doubled
  indirection compared to a direct binding. The Appearance section sets
  the direct-view precedent; introducing a reducer here is inconsistent
  with the neighbouring pane.
- Verdict: **Rejected** — no effect orchestration to coordinate. Revisit
  if a later feature (e.g. "Send test notification") forces an effect.

### A2 — Gate sound via a mutable property on the adapter

Give `OSNotifier` a settable `playSound: Bool` property; coordinator
sets it from `settingsReader.soundEnabled` before each `post`.

- Pros: Signature of `post` stays unchanged.
- Cons: Stateful adapter; racy if a batch of `post` calls interleaves
  with a settings flip (the second `post` sees the new value). Pass-by-
  parameter is deterministic.
- Verdict: **Rejected**.

### A3 — `inAppEnabled` gates a new in-app toast surface instead of the inbox

Build a transient SwiftUI banner inside `ContentView`, gated by
`inAppEnabled`. Inbox append always happens.

- Pros: Matches a literal reading of "in-app 横幅".
- Cons: No banner exists; building one is a multi-file feature
  (overlay on `ContentView`, auto-dismiss timer, possibly stacking) that
  drags two or three more days onto T2. Spec does not require a new
  surface — it describes a toggle. Conflating toggle-wiring with a new
  surface mismatches the T2 task description.
- Verdict: **Rejected**. Inbox is the in-app surface; gate that.

### A4 — Suppress the alert and auto-revert the toggle on denied

If `authStatus == .denied`, reject the toggle flip (don't persist,
don't show alert — or show alert + revert).

- Pros: The persisted state always matches "can actually send".
- Cons: The user's intent is lost the moment they grant permission.
  Forces a second toggle flip after granting. Worse UX.
- Verdict: **Rejected**. Persist intent, surface the block via alert.

### A5 — Read `systemEnabled` inside `OSNotifier.post` itself

Instead of guarding in the coordinator, the adapter decides based on a
reader it captures.

- Pros: Single gate.
- Cons: `OSNotifier` becomes coupled to `NotificationSettingsReader`,
  which today it knows nothing about. The coordinator is the right
  place for policy; the adapter should do exactly one thing (post an
  `UN*` notification).
- Verdict: **Rejected**.

## Cross-Cutting Concerns

### Security / Privacy

- No new secrets, no new files, no change to `settings.json` permissions
  (still 0600 via T1's `AtomicFileStore`).
- The System Settings deep-link is an `open-url` equivalent; macOS gates
  that without further prompting.

### Observability

- No new log categories. The coordinator already logs under
  `com.gumpw.codans.notifications / coordinator`; add one `.debug` line
  on the "systemEnabled off drops OS post" branch so the drop is
  visible during test triage. Similarly one `.debug` on the `inAppEnabled`
  drop path.

### Accessibility

- All toggles use `Toggle(isOn:)` with an explicit label; VoiceOver
  reads them without extra work. The "Reveal rules.json" button has
  `accessibilityLabel` / `accessibilityHint` consistent with existing
  reveal-style buttons.
- The alert is a native SwiftUI `.alert(...)` — inherits standard
  accessibility.

### Localisation

- All new strings go through `Text("...")` with en-US copy; no
  localisation file changes in T2. Matches the rest of the Settings
  window which is en-US only.

## Risks

- **R1 — `inAppEnabled` semantics mismatch master's intent.** Mitigation:
  D2 surfaces the decision explicitly. If REVISE asks for a transient
  toast instead, I fork to A3 and extend T2 scope, or punt
  `inAppEnabled` wiring to a later T (keeping the toggle persisted
  but inert, same state as T1 shipped). Flagging up-front rather than
  after implementation.
- **R2 — The "open System Settings" deep-link breaks on some macOS
  version.** Mitigation: fall back to top-level Notifications pane;
  never rely on the `?id=` anchor. Call-site checks
  `NSWorkspace.shared.open` result; on `false` the first URL, try the
  bare `x-apple.systempreferences:com.apple.preference.notifications`.
- **R3 — `OSNotifier.post` signature change ripples.** Mitigation:
  one caller (the coordinator) and one mock + one production adapter —
  all three updated in the same commit. `xcodebuild` catches any miss.
- **R4 — Coordinator change breaks an existing test.** Mitigation: the
  existing `authorizedUnmutedRuleAppendsInboxAndPostsOS` passes
  `systemEnabled: true` (default) so behaviour is unchanged. The only
  existing test that exercises the Dock badge path is not yet present
  (T-dock is net new) — so swapping `mute.badgeEnabled` →
  `dockBadgeEnabled` has no existing assertion to break. Migration
  already maps v1 `mute.badgeEnabled` → `dockBadgeEnabled` so user
  state is preserved across the wire change.
- **R5 — `handleUnread` helper surface leaks testability-only API.**
  Mitigation: mark it `internal` with a doc comment "test entry point;
  prefer `bind(to:)` in production". Matches the existing
  `handle(output:)` surface pattern.

## Open Questions

- **Q1 — In-app surface semantics.** Does master accept D2
  (`inAppEnabled` gates `inbox.append`), or require a new transient
  banner surface? If the latter: scope grows by ~2 days for the toast
  UI; alternatively leave `inAppEnabled` inert and ship pane toggles
  only (A3 variant).
- **Q2 — Mute-rules summary fidelity.** D2's summary reports rule /
  pane counts only. Should it also list the rule IDs themselves (up
  to N with a "…" overflow)? Spec M5.5 says "摘要" which is ambiguous.
  My read: counts only; users who want specifics hit Reveal. Flag if
  this is wrong.

Unless REVISEd, I'll proceed with D1/D2/D3 as stated and move to Plan
on APPROVE.
