# ExecPlan: Notifications v1.1 — Policy Chokepoint, Settings Wiring, and Command-Finished Suppression

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-05-20

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this plan ships, a user can flip any of five Notifications settings (in-app, system, sound, dock badge, command-finished threshold) and observe the next event obey the new value immediately — no relaunch, no edits to JSON files, no surprises. Command-finished events surface only when they cross the configured duration threshold, are not user-cancelled (Ctrl-C), and are not interrupted by recent keyboard activity in the same pane. Non-zero exit produces a visibly distinct banner title. A right-click "Mute notifications" on any pane silences that pane in one click. A worktree that gains its first unread notification moves to the top of its project's worktree list and stays there until the user manually reorders. The inbox file on disk grows a `{ version, entries }` envelope that survives a legacy upgrade in one save round-trip, and an accidental downgrade from a future build is recovered through a quarantine plus a one-shot "Inbox reset" entry in the bell popover.

Concretely, before this plan: toggles in Settings → Notifications persist but do nothing; every `commandFinished` event becomes a notification regardless of duration or intent; muting a pane requires hand-editing `~/.config/codans/catalog.json`; the inbox file is a bare JSON array with no migration path. After this plan: all five gates and the four command-finished suppression rules work as specified, the per-pane menu toggles the label live, and the inbox file is version-gated.

## Progress

**State:** Draft
**Active worker:** none
**Last handoff:** none yet
**Cases:** 0 / 34

### Task summary

- [ ] M1.T1 — Introduce `NotificationsSettings` schema + `Settings.notifications` field — `pending`
- [ ] M1.T2 — `InboxFile` envelope load/save + migrate `NotificationStore` to it — `pending`
- [ ] M2.T1 — `NotificationSettingsReader` protocol + `SettingsStoreReaderAdapter` — `pending`
- [ ] M2.T2 — `NotificationCoordinator` + Candidate emission from `NotificationDetector` + `OSNotifier.post(_:playSound:)` — `pending`
- [ ] M3.T1 — `NotificationsSettingsView` five controls + permission alert + Reveal-in-Finder — `pending`
- [ ] M4.T1 — `DetectionTranslator.Context` + commandFinished gates + differential titles + Step.drop — `pending`
- [ ] M5.T1 — `PaneKeyboardActivityTracker` + `GhosttySurfaceView` keystroke side channel — `pending`
- [ ] M6.T1 — `HierarchyClient.reorderWorktrees` + `setPaneLabel` mutation surfaces — `pending`
- [ ] M6.T2 — Coordinator unreadByWorktree cache + 0→N edge promote (respecting `isPinned`) — `pending`
- [ ] M7.T1 — `PaneContextMenu` + `LazyPaneHost.contextMenu` wiring — `pending`
- [ ] M8.T1 — Inbox-reset quarantine toast (synthetic InboxEntry + idempotency key) — `pending`
- [ ] M8.T2 — Cross-milestone runtime validation pass against all 34 cases — `pending`

### Recent handoffs

(None yet.)

### Dismissed items

(None yet.)

## Surprises & Discoveries

(None yet.)

## Decision Log

(None yet — this plan inherits the three D-OQ resolutions logged in the design doc; further AskUser exchanges during implementation get appended here.)

## Outcomes & Retrospective

(To be filled at milestone completion.)

## Context and Orientation

**Related documents:**

- Product spec: [docs/product-specs/notifications-v1-1.md](../product-specs/notifications-v1-1.md)
- Design doc: [docs/design-docs/notifications-v1-1.md](../design-docs/notifications-v1-1.md)
- User tests: [docs/user-tests/notifications-v1-1.md](../user-tests/notifications-v1-1.md)
- v1 design (still authoritative for the detection translation table, the inbox roll-up shape, and the navigation API): [docs/design-docs/notifications.md](../design-docs/notifications.md)
- v1 ExecPlan (completed; this plan extends on top of it): [docs/exec-plans/notifications.md](notifications.md)
- Settings v3 schema: [docs/exec-plans/settings-base.md](settings-base.md)
- Architecture: [docs/architecture.md](../architecture.md)
- Project conventions: [CLAUDE.md](../../CLAUDE.md) (top-level repository instructions)

**Key existing source files this plan depends on or modifies:**

- `apps/mac/CodansCore/Settings/Settings.swift` — root `Settings` Codable. M1 adds a `notifications: NotificationsSettings` field with `decodeIfPresent` default.
- `apps/mac/CodansCore/Settings/GeneralSettings.swift`, `DeveloperSettings.swift`, `WorktreeSettings.swift` — sibling sections that establish the file-per-section pattern. M1 mirrors this for `NotificationsSettings.swift`.
- `apps/mac/codans/App/Features/Settings/SettingsStore.swift` — `@MainActor @Observable` owner of `~/.config/codans/settings.json`. M1 adds a `mutateNotifications(_:)` section mutator alongside the existing `mutateGeneral` / `mutateDeveloper` / `mutateWorktree`.
- `apps/mac/CodansCore/Notifications/InboxStorage.swift` — pure dedup/age/cap policies for the inbox. Unchanged by this plan; M1 adds a new `InboxFile.swift` sibling that owns file I/O (the envelope) and `NotificationStore.init` switches to it.
- `apps/mac/codans/App/Features/Notifications/NotificationStore.swift` — current owner of `notifications.json`. M1 swaps its `AtomicFileStore.read([InboxEntry].self, …)` call for `InboxFile.load(from:)`, and its scheduled-save body for `InboxFile.save(_, to:)`.
- `apps/mac/codans/App/Features/Notifications/NotificationDetector.swift` — runtime-event consumer that currently calls `store.append` and `banner.post` directly. M2 changes its `emit` to construct a `NotificationCoordinator.Candidate` and route it; M4 changes the context build to feed `DetectionTranslator`'s new `Context`; M5 reads from `PaneKeyboardActivityTracker` to populate the keystroke timestamps.
- `apps/mac/CodansCore/Notifications/DetectionTranslator.swift` — pure event-to-Entry table. M4 extends its `translate(_:hasProducedOutput:)` signature to `translate(_:context:)` with a new `Context` value type, and adds the four command-finished suppression branches.
- `apps/mac/codans/App/Features/Notifications/OSNotifier.swift` — protocol + `UserNotificationsOSNotifier`. M2 adds `playSound: Bool` to `post`.
- `apps/mac/codans/App/Features/Settings/Panes/NotificationsSettingsView.swift` — current 122-LOC view that only shows authorization status. M3 rewrites the body into five-section form (in-app / system / sound / dock badge / command-finished / mute / permission).
- `apps/mac/codans/App/Features/SplitViewport/LazyPaneHost.swift` — pane chrome host. M7 adds a `.contextMenu` modifier hosting `PaneContextMenu`.
- `apps/mac/codans/App/Clients/HierarchyClient.swift` — catalog mutation surface. M6 adds `reorderWorktrees` and `setPaneLabel`; the existing `setWorktreePinned` is the reference shape for both.
- `apps/mac/codans/Runtime/Ghostty/GhosttySurfaceView.swift` — key-event delivery into libghostty. M5 adds one call into `PaneKeyboardActivityTracker.recordKey`.
- `apps/mac/CodansCore/Catalog.swift`, `Project.swift`, `Worktree.swift`, `Pane.swift` — domain types. Unchanged by this plan except indirectly through the mutation methods on `HierarchyClient`.

**Terminology used in this plan:**

- **Chokepoint** — `NotificationCoordinator`, the single class through which every notification decision flows. The detector hands it `Candidate` values; it returns `Decision` values; downstream side effects only execute from inside it.
- **Candidate** — a value type pairing an `InboxEntry` with the precomputed `sourceIsFocused: Bool` flag. The detector produces these; the coordinator consumes them.
- **Drop reason** — a string-coded enum (`InboxDropReason`, lives in `CodansCore`) shared between the pure translator's `Step.drop` and the coordinator's `Decision.dropped` so log lines collate across the two layers.
- **0 → N edge** — the transition for a worktree's unread count from zero to one. Only this edge fires the worktree-promote behaviour; subsequent unreads on the same worktree do not retrigger.
- **Envelope shape** — `{ "version": 1, "entries": [InboxEntry…] }` JSON top level. Replaces the v1.0 bare array; loader accepts both for one release cycle.
- **Quarantine** — renaming a forward-version `notifications.json` to `notifications.json.bak-<ISO date>` and starting the inbox empty. Followed by a one-shot synthetic "Inbox reset" entry so the user notices.

**How the parts fit together:** the runtime emits `TerminalEvent`s into `NotificationDetector`, which today calls `store.append` and `banner.post` inline. v1.1 inserts `NotificationCoordinator` between the detector and the sinks: detector translates an event (now via the extended `DetectionTranslator` that knows the command-finished knobs), produces a `Candidate`, calls `coordinator.handle(_:)`; the coordinator reads `NotificationSettingsReader` (an adapter over `SettingsStore` + the cached `OSNotifier` auth status) and dispatches to `NotificationStore.append`, `OSNotifier.post(_:playSound:)`, `DockBadger.setBadge`, and `HierarchyClient.reorderWorktrees` according to the four gates. The keystroke side channel (`PaneKeyboardActivityTracker`) is the only signal source that does not flow through `TerminalEvent`; it is read by the detector when it builds the `DetectionTranslator.Context` for each event. Pane right-click "Mute notifications" writes `Pane.labels` via the new `HierarchyClient.setPaneLabel`, which the detector continues to honour through its existing muted-label drop. Inbox persistence moves to `InboxFile`, which transparently handles both the legacy bare-array shape and the new envelope, and quarantines forward-version files.

## Plan of Work

The work is sliced vertically into eight milestones. Each is independently demonstrable and ends with one atomic commit on the working branch. Order is forced by dependency: M1's `NotificationsSettings` type and `InboxFile` are the data spine that M2's coordinator reads; M2's coordinator is what M3's settings pane writes into; M4's translator extension consumes M1's settings fields but is independently demonstrable through unit tests; M5's keystroke tracker is required by AC-V11-CF5 but not by any other CF gate so it lands separately; M6 needs M2's coordinator (the cache + edge detector lives there); M7 needs M6's `setPaneLabel`; M8 needs M1's `InboxFile` (the quarantine path) and M2's coordinator (the synthetic-entry path).

The user can dogfood after every milestone. M1 alone gives no user-visible behaviour but moves the inbox file format. M2 + M3 + M4 together cover the bulk of user-visible v1.1; M5..M8 are completion.

### Milestone 1 — Schema and inbox envelope

This milestone introduces the `NotificationsSettings` type as a sixth top-level section of `Settings` (additive via `decodeIfPresent`, no schema-version bump), and replaces the inbox file's bare-array shape with a `{ version: 1, entries: [...] }` envelope while preserving forward and backward compatibility. After M1 a user's existing `settings.json` and `notifications.json` continue to work; on the next inbox-touching event the inbox file rewrites in envelope shape.

**Task M1.T1 — `NotificationsSettings` schema.**

Add `apps/mac/CodansCore/Settings/NotificationsSettings.swift` (new file, ~80 LOC). Defines:

```swift
public nonisolated struct NotificationsSettings: Equatable, Sendable, Codable {
  public var inAppEnabled: Bool                   // default true
  public var systemEnabled: Bool                  // default true
  public var soundEnabled: Bool                   // default true
  public var dockBadgeEnabled: Bool               // default true
  public var moveNotifiedWorktreeToTop: Bool      // default true
  public var commandFinishedEnabled: Bool         // default true
  public var commandFinishedThresholdSec: Int     // default 10, clamped to [1, 3600]
  public var mute: MuteSettings                   // default = .init() empty sets
  public static let `default` = NotificationsSettings(/* all defaults */)
}

public nonisolated struct MuteSettings: Equatable, Sendable, Codable {
  public var mutedRuleIDs: Set<String>
  public var mutedPaneIDs: Set<PaneID>
}
```

Codable's `init(from:)` uses `decodeIfPresent` for every field and applies the clamp `max(1, min(3600, value))` to `commandFinishedThresholdSec`; an out-of-range loaded value is replaced with the clamped value and a single `os.Logger` warning is emitted under category `settings` (lifted from the existing settings logger). `encode(to:)` writes every field explicitly so the JSON is diffable.

Extend `apps/mac/CodansCore/Settings/Settings.swift`:

- Add `public var notifications: NotificationsSettings` to the struct (with default value `.default`).
- Add `.notifications` to `CodingKeys`.
- Add a `notifications` decode line using `decodeIfPresent`.
- Add a `notifications` encode line.

Extend `apps/mac/codans/App/Features/Settings/SettingsStore.swift`:

- Add `func mutateNotifications(_ transform: (inout NotificationsSettings) -> Void)` mirroring the existing section mutators.

**Files touched (M1.T1):**
- `apps/mac/CodansCore/Settings/NotificationsSettings.swift` — new
- `apps/mac/CodansCore/Settings/Settings.swift` — extend
- `apps/mac/codans/App/Features/Settings/SettingsStore.swift` — extend

**preconditions:** Settings v3 currently has no `notifications` section. `~/.config/codans/settings.json` from a v1.0 install must decode after M1.T1 with `settings.notifications == NotificationsSettings.default`.

**expected_behavior:** A pre-v1.1 `settings.json` decodes cleanly; a v1.1 launch writes the `notifications` section into the next debounced save. No user-visible UI change yet (M3 lands the pane).

**verification_steps:**
1. Manual: with no prior `settings.json`, launch the app, quit, inspect the file with `jq '.notifications' ~/.config/codans/settings.json`. Expect a JSON object whose keys are the eight `NotificationsSettings` fields at their defaults.
2. Manual: with an existing v1.0 `settings.json` (no `notifications` key), launch the app, mutate any unrelated setting (e.g., flip Appearance), quit, re-inspect. Expect the `notifications` object to now be present at defaults, and existing keys to be unchanged.
3. Automated: new `NotificationsSettingsCodableTests` cases under `apps/mac/CodansCoreTests/Settings/` round-trip default and non-default instances; out-of-range threshold is clamped on decode; missing `notifications` block decodes to defaults.

**fulfills:** [] — pure schema introduction; user-observable behaviour requires M2's chokepoint to consume the values.

---

**Task M1.T2 — `InboxFile` envelope and `NotificationStore` migration.**

Add `apps/mac/CodansCore/Notifications/InboxFile.swift` (new file, ~100 LOC). Defines:

```swift
public nonisolated enum InboxFile {
  public static let currentVersion: Int = 1

  public struct Envelope: Codable, Sendable {
    public let version: Int
    public let entries: [InboxEntry]
  }

  /// Returns `nil` when the file is absent. Returns `[]` and renames the file
  /// to `<base>.bak-<ISO>` when its `version` exceeds `currentVersion`. Reads
  /// both envelope and legacy bare-array shapes; the next save through
  /// `save(_:to:)` rewrites in envelope shape.
  public static func load(from url: URL, now: Date = Date()) throws -> [InboxEntry]?

  /// Always writes envelope shape.
  public static func save(_ entries: [InboxEntry], to url: URL) throws

  /// The path the loader renames a forward-version file to. Surfaced so the
  /// quarantine toast in M8 can quote the basename.
  public static func quarantinePath(for url: URL, at: Date) -> URL
}
```

Loader sequence is exactly as specified in the design doc §InboxFile (envelope decode first; on failure try bare array; on both failures return `[]` without rename; on envelope success with `version > currentVersion` rename and return `[]`). The rename uses `FileManager.moveItem(at:to:)`.

Change `apps/mac/codans/App/Features/Notifications/NotificationStore.swift`:

- In `init`: replace `try AtomicFileStore.read([InboxEntry].self, at: fileURL) ?? []` with `try InboxFile.load(from: fileURL, now: now) ?? []`.
- In `flush()` and the debounced save Task: replace `try AtomicFileStore.write(entries, to: fileURL)` and `try AtomicFileStore.write(snapshot, to: self.fileURL)` with `try InboxFile.save(entries, to: fileURL)` and `try InboxFile.save(snapshot, to: self.fileURL)` respectively.

Expose one new piece of state on the store so M8 can read it without re-walking the file system: `public private(set) var loadedQuarantineBackupURL: URL?` — set during `init` if the loader returned `[]` from the quarantine branch. Default nil.

**Files touched (M1.T2):**
- `apps/mac/CodansCore/Notifications/InboxFile.swift` — new
- `apps/mac/codans/App/Features/Notifications/NotificationStore.swift` — extend

**preconditions:** `NotificationStore.init` currently reads via `AtomicFileStore.read([InboxEntry].self, …)`; this is the only call site touching the file.

**expected_behavior:** New installs write envelope shape on first save. v1.0 inboxes load unchanged at launch and rewrite in envelope on the next mutation. A pre-seeded forward-version file is renamed and the inbox is empty at launch (with `loadedQuarantineBackupURL` populated for M8 to consume).

**verification_steps:**
1. Manual UT-V11-J-001: with no `notifications.json`, launch, trigger one OSC 9 event on an unfocused pane, wait ≥ 1 s, `jq '.version, (.entries | length)' ~/.config/codans/notifications.json` returns `1` and `1`.
2. Manual UT-V11-J-002: seed `notifications.json` with three legacy bare-array entries (two unread, one read), launch, open the bell popover (see 3 rows; badge shows `2`), trigger one new event, wait ≥ 1 s, re-inspect: file is now envelope and `entries | length` is `4`.
3. Manual UT-V11-J-003 partial (file moves only — the toast comes in M8): seed `notifications.json` with `{ "version": 99, "entries": [...] }`, launch. After launch, `ls -la ~/.config/codans/notifications.json*` shows a `.bak-<ISO>` file with the seeded content and either no `notifications.json` yet or an envelope with `entries: []`.
4. Automated: new `InboxFileTests` under `apps/mac/CodansCoreTests/` cover envelope round-trip; legacy bare array → envelope upgrade; forward-version quarantine path; corrupt file returns empty without rename.

**fulfills:** UT-V11-J-001, UT-V11-J-002

---

**Milestone 1 Exit Gate:**

- M1.T1 and M1.T2 each end with an atomic commit on the working branch.
- spec-reviewer ✅ and code-reviewer (no Critical) on both tasks.
- `make mac-build` and `make mac-lint` green.
- Static tests green: `NotificationsSettingsCodableTests`, `InboxFileTests`.
- User-test runtime validator returns PASS for {UT-V11-J-001, UT-V11-J-002} against a manually launched build.
- features.json status `completed` for M1.T1 and M1.T2.

### Milestone 2 — Coordinator chokepoint and OSNotifier playSound

This milestone routes every notification-worthy event through the new `NotificationCoordinator`. After M2 the four primary gates (`inAppEnabled`, `systemEnabled`, `dockBadgeEnabled`, `soundEnabled`) take effect even though the Settings pane UI is still permission-only (M3 lands the controls). Users with no UI access can hand-edit `settings.json` to observe the gates working end-to-end.

**Task M2.T1 — `NotificationSettingsReader` protocol and adapter.**

Add `apps/mac/codans/App/Features/Notifications/NotificationsSettingsReader.swift` (new file, ~50 LOC). Defines:

```swift
@MainActor
protocol NotificationSettingsReader: AnyObject {
  var notifications: NotificationsSettings { get }
  var authStatus: AuthorizationStatus { get }
  func onChange(_ handler: @escaping @MainActor () -> Void) -> AnyCancellable
}

@MainActor
final class SettingsStoreReaderAdapter: NotificationSettingsReader {
  init(settingsStore: SettingsStore, osNotifier: OSNotifier)
  // Observes settingsStore via withObservationTracking; refreshes authStatus on init
  // and on demand (refresh()), caching the latest value for synchronous reads.
  func refresh() async   // re-reads auth status from osNotifier
}
```

`onChange` returns a token whose `cancel()` removes the handler. Implementation uses `withObservationTracking` to invalidate on next change tick, then re-arms; the standard `@Observable` reactivity pattern.

Add a `FakeNotificationSettingsReader` in `apps/mac/codans/Tests/Notifications/Fakes/` (new directory):

```swift
@MainActor
final class FakeNotificationSettingsReader: NotificationSettingsReader {
  var notifications: NotificationsSettings   // mutable; setter calls handlers
  var authStatus: AuthorizationStatus
  func onChange(_:) -> AnyCancellable
  func fireChange()   // explicit test trigger
}
```

**Files touched (M2.T1):**
- `apps/mac/codans/App/Features/Notifications/NotificationsSettingsReader.swift` — new
- `apps/mac/codans/Tests/Notifications/Fakes/FakeNotificationSettingsReader.swift` — new

**preconditions:** `SettingsStore` is `@MainActor @Observable`; `OSNotifier` exposes `currentAuthorizationStatus()`.

**expected_behavior:** No user-visible change; the protocol exists for M2.T2 to bind to.

**verification_steps:**
1. Automated: new `SettingsStoreReaderAdapterTests` covers reading a known `settings.notifications` value, observing a mutation through `onChange`, and reading the cached `authStatus`.

**fulfills:** [] — protocol introduction, no observable surface.

---

**Task M2.T2 — `NotificationCoordinator`, OSNotifier playSound, detector emits Candidate.**

Add `apps/mac/codans/App/Features/Notifications/NotificationCoordinator.swift` (new file, ~150 LOC). Class and types per the design doc §NotificationCoordinator — `init`, `handle(_:)`, `recomputeDockBadge()`, `refreshAuthorizationStatus()`, `Candidate`, `Decision`, `DropReason`. The `unreadByWorktree` cache is initialised from `inbox.entries.filter { $0.isUnread }` at construction time. `handle` returns the `Decision` so callers and tests can inspect; production callers do not consume the return.

Routing inside `handle` follows the design doc's decision sequence: focused-source drop first, then `inAppEnabled` (gates inbox + dock recompute), then `systemEnabled` + `authStatus.isAuthorized` (gates OS post), then `moveNotifiedWorktreeToTop` + 0→N edge (gates promote — but the actual reorder call is wired in M6; M2 only updates the cache and computes the `promoted` field of `Decision`, dispatching the catalog call lands in M6.T2). Drop-reason log lines emit at `.debug` under `subsystem: "com.gumpw.codans.notifications"`, `category: "coordinator"`.

Extend `apps/mac/codans/App/Features/Notifications/OSNotifier.swift`:

- Change protocol method to `func post(_ entry: InboxEntry, playSound: Bool) async`.
- Change `UserNotificationsOSNotifier.post` to accept `playSound` and set `content.sound = playSound ? .default : nil`.

Add `apps/mac/codans/Tests/Notifications/Fakes/MockOSNotifier.swift`:

```swift
@MainActor
final class MockOSNotifier: OSNotifier {
  var authStatus: AuthorizationStatus = .authorized
  private(set) var posts: [(entry: InboxEntry, playSound: Bool)] = []
  func currentAuthorizationStatus() async -> AuthorizationStatus
  func requestAuthorization() async -> AuthorizationStatus
  func post(_ entry: InboxEntry, playSound: Bool) async
}
```

Change `apps/mac/codans/App/Features/Notifications/NotificationDetector.swift`:

- Add a `coordinator: NotificationCoordinator` dependency to `init`.
- In `emit(_:isTeardown:)`: stop calling `store.append`, `banner.post`, and the focused-pane drop directly. Instead build a `NotificationCoordinator.Candidate(entry: inbox, sourceIsFocused: resolved.source.paneID == globallyFocusedPane())` and pass to `coordinator.handle(_:)`. Keep `onProjectActivity?(resolved.source.projectID)` — the project activity bump is still detector-owned.

Wire the coordinator into `AppState.bringUp()` (search for the existing `NotificationDetector` instantiation site and add the coordinator next to it): the construction order becomes `NotificationStore` → `OSNotifier` → `DockBadger` → `SettingsStoreReaderAdapter` → `NotificationCoordinator` → `NotificationDetector(... coordinator: ...)`. Also wire `recomputeDockBadge` to be called whenever `settingsReader.onChange` fires (this drops the responsibility on the coordinator, not the bringup site, but the bringup site holds the cancellable token).

Wire `applicationDidBecomeActive` to call `coordinator.refreshAuthorizationStatus()` (likely already a hook point in `AppDelegate` or the SwiftUI `.onChange(of: scenePhase)` site).

**Files touched (M2.T2):**
- `apps/mac/codans/App/Features/Notifications/NotificationCoordinator.swift` — new
- `apps/mac/codans/App/Features/Notifications/OSNotifier.swift` — extend
- `apps/mac/codans/App/Features/Notifications/NotificationDetector.swift` — change `emit`
- `apps/mac/codans/Tests/Notifications/Fakes/MockOSNotifier.swift` — new
- `apps/mac/codans/App/` (wire-up in `AppState.bringUp` or equivalent) — change

**preconditions:** M1 lands; `NotificationsSettings` exists; detector currently calls `store.append`/`banner.post` directly.

**expected_behavior:** With `notifications.inAppEnabled = false` in `settings.json`, an OSC 9 event on an unfocused pane produces no inbox row and no dock badge change but does post a system banner (when `systemEnabled = true`, `authStatus = .authorized`). Inverse configurations behave as their controls dictate. Sound channel obeys `soundEnabled`. The drop log line appears under `.debug` filter.

**verification_steps:**
1. Manual UT-V11-CP-001 + CP-002: seed `settings.json` with `inAppEnabled: true`. Trigger event A → inbox grows, dock shows 1. Hand-edit `settings.json` to `inAppEnabled: false` (or wait until M3). Trigger event B → no inbox change, no dock change, log line `drop inAppDisabled` visible under `--debug`.
2. Manual UT-V11-S-001 through UT-V11-S-005: configure `settings.json` per each case's precondition, drive the event, observe the matrix per the user-test assertions.
3. Manual UT-V11-L-001: with `--debug` off, no drop lines. With `--debug` on, drop lines appear.
4. Automated: new `NotificationCoordinatorTests` under `apps/mac/codans/Tests/Notifications/`. Cases:
   - `evaluatesLiveSettingsAtDecisionTime` — flip a reader field between candidates, assert decision uses the new value.
   - `inAppOffSkipsInboxButPostsBanner`
   - `systemOffPreservesInbox`
   - `soundOffPostsWithNilSound` — asserts `MockOSNotifier.posts.last?.playSound == false`.
   - `dockBadgeOffClearsBadge`
   - `focusedSourceDropsBeforeAnySink`
   - `dropDoesNotResurfaceOnToggleFlip`

**fulfills:** UT-V11-CP-001, UT-V11-CP-002, UT-V11-S-001, UT-V11-S-002, UT-V11-S-003, UT-V11-S-005, UT-V11-L-001

---

**Milestone 2 Exit Gate:**

- M2.T1 and M2.T2 each end with an atomic commit.
- spec-reviewer ✅ and code-reviewer (no Critical) on both tasks.
- `make mac-build` green; `make mac-lint` clean on the touched files.
- Static tests green: `SettingsStoreReaderAdapterTests`, `NotificationCoordinatorTests`.
- User-test validator PASS for {UT-V11-CP-001, UT-V11-CP-002, UT-V11-S-001, UT-V11-S-002, UT-V11-S-003, UT-V11-S-005, UT-V11-L-001}.
- features.json `completed` for both tasks.

### Milestone 3 — Settings pane controls and permission alert

After M3 the user can flip the four toggles from the Notifications pane, see the Sound row disable when System is off (with a hover tooltip), get a permission alert with an Open System Settings deep-link when toggling System while denied, see a mute-rules summary line that collapses to "No mute rules" when empty, and click a button that reveals `detection-rules.json` in Finder (creating it on first use).

**Task M3.T1 — `NotificationsSettingsView` rewrite.**

Rewrite `apps/mac/codans/App/Features/Settings/Panes/NotificationsSettingsView.swift` body. Replace the current "About v1" section with four new sections:

1. **Notifications** — four `Toggle` rows bound to `settings.notifications.{inAppEnabled, systemEnabled, soundEnabled, dockBadgeEnabled}` via `settingsStore.mutateNotifications`. Sound row gets `.disabled(!settings.notifications.systemEnabled)` plus `.help("Sound requires System notifications to be on.")`. System-toggle `onChange` reads `osNotifier`'s cached auth status; when flipping to `true` while `authStatus == .denied`, sets `@State var showPermissionAlert = true`.
2. **Command-finished notifications** — `Toggle` for `commandFinishedEnabled` and a `TextField(value:, format: .number)` for `commandFinishedThresholdSec`. The text field's `format` modifier with `IntegerFormatStyle` and the binding's setter clamps to `[1, 3600]` before persisting (UI-layer rejection per AC-V11-CF7). Disabled when `commandFinishedEnabled` is off. Caption: "Commands shorter than this are silent. Cancelled commands (Ctrl-C) are always silent. Notifications are also suppressed for 1 second after you type in the pane."
3. **Mute rules** — read-only summary row + "Reveal rules.json in Finder…" button. Summary string formula: `"\(mute.mutedRuleIDs.count) rule(s), \(mute.mutedPaneIDs.count) pane(s) muted"`, collapsing to `"No mute rules"` when both counts are zero. Reveal button calls a helper `revealRulesFile()` that ensures `~/.config/codans/detection-rules.json` exists (creating it with a default empty-rules JSON if absent — borrow the format used by the existing detection-rules consumer or use `{"version": 1, "rules": []}` if no consumer exists yet) and then calls `NSWorkspace.shared.activateFileViewerSelecting([url])`.
4. **macOS permission** — the existing status row + action row, moved below the new sections.

Add the alert modifier:

```swift
.alert("Notifications are blocked", isPresented: $showPermissionAlert) {
  Button("Open System Settings…") { openSystemNotificationsPane() }
  Button("Cancel", role: .cancel) { }
} message: {
  Text("macOS is currently blocking notifications for codans. Open System Settings to allow them.")
}
```

`openSystemNotificationsPane()` builds `x-apple.systempreferences:com.apple.preference.notifications?id=<bundle-id>`, attempts `NSWorkspace.shared.open` — on `false` return, falls back to `x-apple.systempreferences:com.apple.preference.notifications`. Both URLs are constructed once and held in `let` locals.

The view's read path stays through `@Environment(SettingsStore.self)` (a binding seam this codebase already uses for Settings panes); add `@Environment(UserNotificationsOSNotifier.self)` (already present in the file for the permission row).

**Files touched (M3.T1):**
- `apps/mac/codans/App/Features/Settings/Panes/NotificationsSettingsView.swift` — rewrite

**preconditions:** M2 lands; `settings.notifications` field exists; coordinator consumes the gates.

**expected_behavior:** User opens Settings → Notifications and sees the five new controls. Toggling them produces the v1.1 user-visible effects established in M2. The Sound row disables/enables visibly as System toggles. The permission alert appears on the documented condition.

**verification_steps:**
1. Manual UT-V11-S-004: flip System off; Sound row visibly greys out; hover shows tooltip text exactly matching `.help` string. Flip System on; Sound becomes interactive without resetting its prior value.
2. Manual UT-V11-S-006 / S-007: seed `settings.json` mute fields with non-empty / empty values; observe summary text matches the formula or "No mute rules".
3. Manual UT-V11-S-008: click Reveal in Finder. Finder activates; `detection-rules.json` is selected (and created on first run).
4. Manual UT-V11-P-001 / P-002: with macOS notifications denied for the app, flip System on. Alert appears; click Open System Settings; System Settings opens at the Notifications pane (app row when supported, top of pane otherwise).
5. Manual UT-V11-CF-007: type `0` into the threshold field; field reverts or rejects. Type `10000`; same. `settings.json` never persists out-of-range values.
6. Automated: SwiftUI snapshot or `ViewInspector` tests for the disabled-Sound state and the alert presented-state.

**fulfills:** UT-V11-S-004, UT-V11-S-006, UT-V11-S-007, UT-V11-S-008, UT-V11-P-001, UT-V11-P-002

---

**Milestone 3 Exit Gate:**

- M3.T1 ends with one atomic commit.
- spec-reviewer ✅ and code-reviewer (no Critical).
- `make mac-build` and `make mac-lint` green.
- Static tests green: view-layer tests for the disabled state and the alert.
- User-test validator PASS for the six S/P cases above.
- features.json `completed` for M3.T1.

### Milestone 4 — Command-finished suppression in DetectionTranslator

This milestone teaches the pure translator three suppression rules (threshold, SIGINT/SIGTERM, recent keystroke) and the non-zero-exit title variant. After M4 a command that finishes under the threshold, was Ctrl-C'd, or fires while the user typed in the source pane within the last second produces no notification. The keystroke-window plumbing is split into M5; M4 lands the gate logic with a stub input (`lastUserKeystrokeAt = [:]`) and M5 fills it in.

**Task M4.T1 — `DetectionTranslator.Context` and command-finished gates.**

Change `apps/mac/CodansCore/Notifications/DetectionTranslator.swift`:

- Introduce a public nested type `DetectionTranslator.Context`:
  ```swift
  public struct Context: Equatable, Sendable {
    public let hasProducedOutput: Set<PaneID>
    public let lastUserKeystrokeAt: [PaneID: Date]
    public let now: Date
    public let commandFinishedEnabled: Bool
    public let commandFinishedThresholdSec: Int
  }
  ```
- Change the public signature `translate(_:hasProducedOutput:)` to `translate(_:context:)`. Move the previous `hasProducedOutput` Set into `Context.hasProducedOutput`.
- Add `Step.drop: DropReason?` field. `Step` becomes `(entry: Entry?, outputFlag: OutputFlag, drop: DropReason?)`. Existing call sites get `drop: nil` initialiser defaults.
- Extend `Entry` translation for the `.commandFinished(exitCode, duration)` case per the design doc §DetectionTranslator extension. The four suppression branches return `Step(entry: nil, outputFlag: .unchanged, drop: <reason>)` for the matching case; the success path returns the entry with `title: "Command finished", body: "Completed in <duration>."`; the non-zero path returns `title: "Command failed (exit \(code))", body: "Ran for <duration> before failing."`. Duration formatter: an internal `formatDuration(_:)` helper that renders `Double` seconds as `"5s"` / `"1m 23s"` / `"2h 14m"`.
- Move `DropReason` enum into `CodansCore` as `InboxDropReason` (new file `apps/mac/CodansCore/Notifications/InboxDropReason.swift`, ~20 LOC) so both the translator's `Step.drop` and the coordinator's `Decision.dropped` reference one type. `NotificationCoordinator.DropReason` becomes a typealias or reuses `InboxDropReason` directly.

Update `apps/mac/codans/App/Features/Notifications/NotificationDetector.swift`:

- Add a `lastKeystrokes: () -> [PaneID: Date]` closure to `init` (provided by `AppState.bringUp` and backed by `PaneKeyboardActivityTracker.snapshot()` in M5; for now M4 wires it to `{ [:] }`).
- In `handle(_:)`: construct `Context` from `hasProducedOutput`, the keystrokes closure, `Date()`, and reads of `settingsReader.notifications.commandFinishedEnabled / commandFinishedThresholdSec`. Pass to `DetectionTranslator.translate(event, context:)`.
- Handle `step.drop`: when non-nil, log under `coordinator` category at `.debug` and return without producing a Candidate. (Coordinator-side drops continue to log themselves; translator-side drops log here so the log subject is consistent.)

Update `NotificationCoordinator` to expose `let commandFinishedEnabled, commandFinishedThresholdSec` reads off `settingsReader.notifications` — already covered by M2's reader injection; verify they are surfaced for the detector context build.

**Files touched (M4.T1):**
- `apps/mac/CodansCore/Notifications/DetectionTranslator.swift` — extend
- `apps/mac/CodansCore/Notifications/InboxDropReason.swift` — new
- `apps/mac/codans/App/Features/Notifications/NotificationDetector.swift` — extend (Context build + keystroke closure)
- `apps/mac/codans/App/Features/Notifications/NotificationCoordinator.swift` — minor (use `InboxDropReason`)

**preconditions:** M2 lands; settings reader provides `commandFinishedEnabled / commandFinishedThresholdSec`.

**expected_behavior:** A `commandFinished` event with duration under threshold, with SIGINT/SIGTERM exit code, or with the source pane in the (currently empty) keystroke map produces no notification. Long-running successful commands surface with a success-toned title; non-zero exits surface with a "failed" / "exit N" title.

**verification_steps:**
1. Manual UT-V11-CF-001: set `commandFinishedEnabled: false`, run `sleep 30`, observe no notification.
2. Manual UT-V11-CF-002: set threshold to 10, run `sleep 5`, no notification.
3. Manual UT-V11-CF-003: same threshold, run `sleep 30`, banner appears with title containing no `failed`.
4. Manual UT-V11-CF-004: run `sleep 60`, press Ctrl-C at 15s, no notification, `drop commandCancelled` line under `--debug`.
5. Manual UT-V11-CF-006: run `sleep 30 && false`, banner title contains `failed` or `exit 1`.
6. CF-005 not yet covered (M5).
7. Automated: extend `DetectionTranslatorTests` with the cases listed in the design doc §Testing strategy — threshold boundary (5/10/30 s), SIGINT/SIGTERM with various durations, keystroke window edges with hand-built `lastUserKeystrokeAt`, title differential between zero and non-zero exit, clamp-on-decode for the threshold field.

**fulfills:** UT-V11-CF-001, UT-V11-CF-002, UT-V11-CF-003, UT-V11-CF-004, UT-V11-CF-006, UT-V11-CF-007

---

**Milestone 4 Exit Gate:**

- M4.T1 ends with one atomic commit.
- spec-reviewer ✅ and code-reviewer (no Critical).
- `make mac-build` and `make mac-lint` green.
- Static tests green: extended `DetectionTranslatorTests` plus a small `InboxDropReason` round-trip test.
- User-test validator PASS for the six CF cases (CF-005 deferred to M5).
- features.json `completed` for M4.T1.

### Milestone 5 — PaneKeyboardActivityTracker and keystroke side channel

After M5, the 1-second keystroke window from the spec actually fires. The detector reads `PaneKeyboardActivityTracker.snapshot()` when building the `DetectionTranslator.Context` for every event; `GhosttySurfaceView`'s key-event delivery site populates the tracker. Lifecycle teardown purges the per-pane entry.

**Task M5.T1 — `PaneKeyboardActivityTracker` + wiring.**

Add `apps/mac/codans/App/Features/Notifications/PaneKeyboardActivityTracker.swift` (new file, ~40 LOC):

```swift
@MainActor
final class PaneKeyboardActivityTracker {
  private var lastByPane: [PaneID: Date] = [:]
  func recordKey(in paneID: PaneID, at: Date = Date())
  func snapshot() -> [PaneID: Date]
  func purge(_ paneID: PaneID)
}
```

Change `apps/mac/codans/Runtime/Ghostty/GhosttySurfaceView.swift`:

- Identify the call site that delivers a user key event into libghostty (search for `sendKey`, `keyDown`, or `NSEvent` handlers inside the `NSViewRepresentable`). Immediately before the libghostty dispatch, call `tracker.recordKey(in: paneID)`. The tracker reference must be reachable from the surface view; inject it via the existing `PaneSurface` chain or through `Environment` if the surface view already takes environment objects (read the file to confirm; the simpler injection wins).

Change `apps/mac/codans/App/Features/Notifications/NotificationDetector.swift`:

- Replace the M4 stub closure `{ [:] }` with `{ [weak tracker] in tracker?.snapshot() ?? [:] }`.
- In the existing teardown branches (`paneExited` / `paneCrashed` / `paneClosedByTab` — where `paneSourceCache` is cleared today), also call `tracker?.purge(paneID)`.

Wire the tracker in `AppState.bringUp()` between `NotificationStore` and `NotificationCoordinator` — single instance held alongside the other Notifications singletons.

**Files touched (M5.T1):**
- `apps/mac/codans/App/Features/Notifications/PaneKeyboardActivityTracker.swift` — new
- `apps/mac/codans/Runtime/Ghostty/GhosttySurfaceView.swift` — extend (one call site)
- `apps/mac/codans/App/Features/Notifications/NotificationDetector.swift` — extend (closure swap + purge calls)
- `apps/mac/codans/App/` (`AppState.bringUp`) — extend (one wire)

**preconditions:** M4 lands; `DetectionTranslator.Context.lastUserKeystrokeAt` is consulted; detector's keystroke closure is currently `{ [:] }`.

**expected_behavior:** Typing in pane P followed within 1 second by a `commandFinished` event for P produces no notification (suppressed). Typing in pane Q does not suppress an event for P (per-pane isolation). Closing pane P removes its keystroke entry on next teardown event.

**verification_steps:**
1. Manual UT-V11-CF-005: with threshold low (1s) so the wait is short, run `(sleep 2; echo done)` in pane P after pressing one key into P; observe no notification, `drop userTypingRecently` line under `--debug`.
2. Manual: same setup but skip the keypress; observe a notification appears.
3. Manual: same setup but press the key into pane Q (a sibling pane); observe a notification appears for P (cross-pane isolation).
4. Automated: extend `DetectionTranslatorTests` with a deterministic `Context` carrying a `lastUserKeystrokeAt` map; assert the 999 ms / 1000 ms / 1001 ms edge behaviour. (Tracker class itself is too small to warrant a unit suite beyond a smoke test of `recordKey` → `snapshot` round-trip.)

**fulfills:** UT-V11-CF-005

---

**Milestone 5 Exit Gate:**

- M5.T1 ends with one atomic commit.
- spec-reviewer ✅ and code-reviewer (no Critical).
- `make mac-build` and `make mac-lint` green.
- Static tests green: `DetectionTranslatorTests` extended for the keystroke edge cases.
- User-test validator PASS for UT-V11-CF-005.
- features.json `completed` for M5.T1.

### Milestone 6 — Worktree promote and label mutation surface

After M6, the first unread notification for a worktree promotes it to the top of its project's unpinned section (pinned worktrees never participate); the order persists across relaunch; subsequent unreads on the same worktree do not re-promote; marking the worktree's notifications read does not auto-demote; flipping the global toggle off prevents the reorder. The new `HierarchyClient.setPaneLabel` also lands here as part of the same catalog-mutation chunk so M7 can call it.

**Task M6.T1 — `HierarchyClient.reorderWorktrees` and `setPaneLabel` mutations.**

Extend `apps/mac/codans/App/Clients/HierarchyClient.swift`:

```swift
var reorderWorktrees: @MainActor @Sendable (
  ProjectID,
  _ worktreeID: WorktreeID,
  _ mode: WorktreeReorderMode
) -> Void

var setPaneLabel: @MainActor @Sendable (
  PaneID,
  _ label: String,
  _ present: Bool
) -> Void

enum WorktreeReorderMode: Sendable {
  case moveToFrontWithinUnpinned
  // case toIndex(Int) — reserved for explicit reorder UI; v1.1 does not implement
}
```

Implement both in `apps/mac/codans/App/Clients/HierarchyManager.swift` (or wherever the live impl lives — search for `setWorktreePinned` for the precedent shape):

- `reorderWorktrees(projectID, worktreeID, .moveToFrontWithinUnpinned)`: locate the project; split worktrees into pinned + unpinned; if target is pinned, no-op and return; otherwise remove the target from `unpinned`, insert at index 0; rejoin `pinned + unpinned`; call `catalogStore.scheduleSave`.
- `setPaneLabel(paneID, label, present)`: walk the catalog to the pane; mutate `pane.labels.insert(label)` or `pane.labels.remove(label)`; call `catalogStore.scheduleSave` (the existing 500 ms debounce per CatalogStore.scheduleSave).

Tests under `apps/mac/codans/Tests/Clients/HierarchyClientTests.swift` (or a new `HierarchyManagerWorktreeTests.swift` sibling): pinned exclusion, no-op when target is already at position 0, correct rejoin order, persistence after debounce.

**Files touched (M6.T1):**
- `apps/mac/codans/App/Clients/HierarchyClient.swift` — extend
- `apps/mac/codans/App/Clients/HierarchyManager.swift` — extend (or wherever live impl is)
- `apps/mac/codans/Tests/Clients/HierarchyClientTests.swift` — extend

**preconditions:** `HierarchyClient` has `reorderProjects` / `setWorktreePinned` precedents.

**expected_behavior:** Calling `reorderWorktrees` against an unpinned target moves it to position 0 of the unpinned section; against a pinned target is a no-op. Calling `setPaneLabel` adds / removes a label string from the pane's labels.

**verification_steps:**
1. Automated: new tests assert pinned-target no-op, unpinned reorder, in-memory state mutates immediately, disk file mtime advances within the debounce window.
2. Manual: drive via lldb / unit-test target; M6.T2 covers the user-visible verification.

**fulfills:** [] — pure mutation API; user-observable behaviour lands in M6.T2.

---

**Task M6.T2 — Coordinator unreadByWorktree + 0→N edge promote.**

Extend `NotificationCoordinator`:

- Convert the M2 stub `unreadByWorktree` cache into a live value: init from `inbox.entries.filter { $0.isUnread }`, maintain on every `handle` call when `didAppend == true`, decrement when `markReadForPane` or `markAllRead` fires (subscribe via the existing `@Observable` mechanism on `NotificationStore.entries`).
- In `handle`: after the inbox append branch, if `didAppend && settingsReader.notifications.moveNotifiedWorktreeToTop && priorUnread == 0`, call `catalog.reorderWorktrees(entry.source.projectID, entry.source.worktreeID, .moveToFrontWithinUnpinned)`. Bookkeeping: increment the cache *after* reading `prior`, then conditionally fire the reorder.
- Pass the catalog dependency in via the existing M2 `init` (which already takes `catalog: HierarchyClient`).

**Files touched (M6.T2):**
- `apps/mac/codans/App/Features/Notifications/NotificationCoordinator.swift` — extend

**preconditions:** M6.T1 lands; `reorderWorktrees` is callable. M2's cache stub exists.

**expected_behavior:** User triggers notification for an unpinned worktree at position 2; sidebar refreshes with the worktree at position 0; relaunch preserves the order; second notification on the same worktree does not re-fire the reorder; marking read does not auto-demote; pinned worktree is never moved; toggle off prevents reorder.

**verification_steps:**
1. Manual UT-V11-WT-001 through UT-V11-WT-006 per the user-test cases; observe sidebar order and `catalog.json` snapshots.
2. Manual UT-V11-D-001: rapid-toggle the per-pane mute three times via the (M7-pending) context menu OR directly via test infra; observe in-memory state reflects the final toggle, disk write coalesces within the catalog debounce window.
   *Note:* D-001's full user-test requires M7's menu UI to drive it from the user's perspective; until M7 lands, the case can be exercised programmatically by calling `setPaneLabel` repeatedly. The runtime validator probes M7-level UI, so D-001 may be deferred to be re-probed at the M8 final gate.
3. Automated: extend `NotificationCoordinatorTests` with: `firstUnreadForWorktreePromotesIt`, `secondUnreadDoesNotRetrigger`, `markReadDoesNotDemote`, `pinnedWorktreeIsNotPromoted`, `disabledTogglePreventsPromote`, `relaunchPreservesPromotedOrder` (this last one builds a coordinator against a seeded inbox + catalog and asserts the init-time cache rebuild does *not* fire a reorder).

**fulfills:** UT-V11-WT-001, UT-V11-WT-002, UT-V11-WT-003, UT-V11-WT-004, UT-V11-WT-005, UT-V11-WT-006, UT-V11-D-001

---

**Milestone 6 Exit Gate:**

- M6.T1 and M6.T2 each end with an atomic commit.
- spec-reviewer ✅ and code-reviewer (no Critical) on both.
- `make mac-build` and `make mac-lint` green.
- Static tests green: extended `HierarchyClientTests` and `NotificationCoordinatorTests`.
- User-test validator PASS for {UT-V11-WT-001..006}. UT-V11-D-001 may be re-probed at M8 final gate after M7's menu lands.
- features.json `completed` for both tasks.

### Milestone 7 — Pane right-click "Mute notifications" menu

After M7, right-clicking any pane reveals a context menu whose first item is "Mute notifications" with a checkmark when the pane is muted. Toggling the item writes `notifications:muted` into `Pane.labels` immediately (in-memory) with the disk write riding the catalog's standard debounce. The detector's existing muted-label drop continues to honour the label.

**Task M7.T1 — `PaneContextMenu` + `LazyPaneHost` wiring.**

Add `apps/mac/codans/App/Features/SplitViewport/PaneContextMenu.swift` (new file, ~40 LOC):

```swift
struct PaneContextMenu: View {
  let paneID: PaneID
  @Dependency(HierarchyClient.self) var hierarchy

  var body: some View {
    Button(action: toggleMute) {
      Label(
        "Mute notifications",
        systemImage: isMuted ? "checkmark" : "bell.slash"
      )
    }
  }

  private var isMuted: Bool {
    hierarchy.snapshot().pane(paneID)?.labels.contains(InboxLabels.muted) ?? false
  }

  private func toggleMute() {
    hierarchy.setPaneLabel(paneID, InboxLabels.muted, !isMuted)
  }
}
```

The `Catalog.pane(_:)` helper does not exist today as written; if absent, add it as a small lookup extension in `CodansCore/Catalog+Lookup.swift` (new file or sibling) — a single `func pane(_ id: PaneID) -> Pane?` that walks projects → worktrees → tabs → panes. If the project already has such a helper (search before adding), reuse it.

Extend `apps/mac/codans/App/Features/SplitViewport/LazyPaneHost.swift`:

- Wrap the existing `content` view in a `.contextMenu { PaneContextMenu(paneID: store.paneID) }` modifier. Place it on the `PaneHostView` branch of the `switch store.phase`, not on the loading / failed placeholders (the menu only makes sense once the pane is ready).

**Files touched (M7.T1):**
- `apps/mac/codans/App/Features/SplitViewport/PaneContextMenu.swift` — new
- `apps/mac/codans/App/Features/SplitViewport/LazyPaneHost.swift` — extend
- `apps/mac/CodansCore/Catalog+Lookup.swift` — new (only if no existing helper)

**preconditions:** M6.T1 lands; `setPaneLabel` is callable.

**expected_behavior:** User right-clicks any pane and sees "Mute notifications" in the context menu. Selecting it toggles the muted state, observable both in subsequent menu opens (checkmark presence) and in `catalog.json` on disk after the standard debounce.

**verification_steps:**
1. Manual UT-V11-M-001 through UT-V11-M-004 per the user-test cases.
2. Manual UT-V11-D-001 (now end-to-end from the menu): rapid-click the menu item three times within 200 ms intervals; observe checkmark state matches the final toggle; observe `catalog.json` mtime advances once after the debounce window.
3. Automated: `PaneContextMenuTests` — a small test that constructs the view with a fake `HierarchyClient`, simulates the button action, asserts `setPaneLabel` was called with the inverted `present` value and the correct label constant.

**fulfills:** UT-V11-M-001, UT-V11-M-002, UT-V11-M-003, UT-V11-M-004

---

**Milestone 7 Exit Gate:**

- M7.T1 ends with one atomic commit.
- spec-reviewer ✅ and code-reviewer (no Critical).
- `make mac-build` and `make mac-lint` green.
- Static tests green: `PaneContextMenuTests`.
- User-test validator PASS for {UT-V11-M-001..004}. UT-V11-D-001 re-probed (was provisional at M6) — now expected PASS via the menu path.
- features.json `completed` for M7.T1.

### Milestone 8 — Inbox-reset quarantine toast + final runtime gate

After M8, an accidental downgrade (a forward-version `notifications.json` from a future build) is recovered through a one-shot synthetic `InboxEntry` titled "Inbox reset" in the bell popover, referencing the quarantine backup filename. The idempotency key prevents re-firing on a relaunch where no new quarantine occurred.

**Task M8.T1 — Inbox-reset quarantine toast.**

Extend `apps/mac/codans/App/Features/Notifications/NotificationCoordinator.swift`:

- Add a method `func emitQuarantineNotice(backupURL: URL) async` that constructs an `InboxEntry` with kind `.taskFinished`, title `"Inbox reset"`, body `"Your inbox was reset because notifications.json had an unsupported version. Backup saved as \(backupURL.lastPathComponent)."`, source `InboxEntry.SourcePath` whose IDs are all zero-UUIDs (so navigation falls back to the deepest existing ancestor — practically the inbox itself).
- Idempotency: write a `quarantine-shown.json` marker under `~/.config/codans/state/` (or whatever state-cache directory the project uses — search for `state/` or `cache/`; if none exists, the marker can live alongside the inbox file as `notifications.json.quarantine-shown`) containing `{ "backupBasename": "<file>" }`. On `emitQuarantineNotice`, read the marker first; if its `backupBasename` matches the current `backupURL.lastPathComponent`, return without emitting. Otherwise write the marker and emit.
- The synthetic entry is routed through `coordinator.handle(Candidate(entry: synthetic, sourceIsFocused: false))` so the standard gates apply — `inAppEnabled` off would silence the recovery toast too, which is acceptable (the user explicitly silenced in-app surfaces; the backup file is still present on disk for them to inspect).

Wire `AppState.bringUp()`:

- After constructing `NotificationStore`, read its `loadedQuarantineBackupURL` (added in M1.T2). If non-nil, schedule `coordinator.emitQuarantineNotice(backupURL:)` on the next runloop tick (after detector and coordinator are fully constructed).

**Files touched (M8.T1):**
- `apps/mac/codans/App/Features/Notifications/NotificationCoordinator.swift` — extend
- `apps/mac/codans/App/` (`AppState.bringUp`) — extend (call site)

**preconditions:** M1.T2 lands `loadedQuarantineBackupURL`; M2.T2 lands the coordinator.

**expected_behavior:** A user who seeds a forward-version `notifications.json` and launches the app sees exactly one new row in the bell popover titled "Inbox reset"; relaunching without a fresh quarantine does not produce a second row.

**verification_steps:**
1. Manual UT-V11-J-003 (full): seed `notifications.json` with `version: 99`; launch; observe the bell popover shows one "Inbox reset" row whose body mentions the backup filename; click the row → marks read, no crash. Relaunch the app → bell popover still shows the one row (now read); no second "Inbox reset" row added.
2. Automated: a `NotificationCoordinatorTests.emitQuarantineNoticeIsIdempotent` test that calls `emitQuarantineNotice` twice with the same `backupURL`; asserts the second call is a no-op (no second post). A `…ReFiresOnDifferentBackup` test changes the URL and asserts the second call does emit.

**fulfills:** UT-V11-J-003

---

**Task M8.T2 — Cross-milestone runtime validation pass.**

Run the full runtime validator (`/hs-user-test`) against all 34 cases in `docs/user-tests/notifications-v1-1.md`. Capture the validation matrix and evidence under `docs/runs/notifications-v1-1/state/validation-state.json`. Surface any FAILs through `/hs-followup-scope` (merge into the current task / open a new task / drop into the milestone misc bucket / escalate to a human, per project policy).

This task contains no code change; its purpose is to close the loop on the user-test coverage with evidence captured.

**Files touched (M8.T2):**
- `docs/runs/notifications-v1-1/state/validation-state.json` — populate
- `docs/runs/notifications-v1-1/state/features.json` — final task completion

**preconditions:** M1..M7 plus M8.T1 have all landed with green Exit Gates.

**expected_behavior:** Every case in the user-test set has been probed with evidence on a live build of the app.

**verification_steps:**
1. Run the user-test validator end-to-end; expect 34/34 PASS or a triaged set of follow-up tasks for any FAILs.
2. Confirm `validation-state.json` records `verifier_outcome: pass` for every case ID.

**fulfills:** [] — verification only, no new code.

---

**Milestone 8 Exit Gate:**

- M8.T1 ends with one atomic commit; M8.T2 produces validator artifacts under `docs/runs/`.
- spec-reviewer ✅ and code-reviewer (no Critical) on M8.T1.
- `make mac-build` and `make mac-lint` green.
- Static tests green: extended `NotificationCoordinatorTests` for the idempotency cases.
- User-test validator PASS for the full 34-case set including UT-V11-J-003 (full), UT-V11-L-001 (re-probed), UT-V11-D-001 (re-probed).
- features.json `completed` for M8.T1 and M8.T2.
- Plan-level status flipped from `In Progress` → `Completed`.

## User Test Coverage

The 34 cases in `docs/user-tests/notifications-v1-1.md` are partitioned across the leaf tasks below. The union is the full set; no case appears in two tasks.

| Task | fulfills | Reason if `—` |
|---|---|---|
| M1.T1 | — | Pure schema introduction; user-observable behaviour requires M2's chokepoint |
| M1.T2 | UT-V11-J-001, UT-V11-J-002 | |
| M2.T1 | — | Protocol introduction; no observable surface |
| M2.T2 | UT-V11-CP-001, UT-V11-CP-002, UT-V11-S-001, UT-V11-S-002, UT-V11-S-003, UT-V11-S-005, UT-V11-L-001 | |
| M3.T1 | UT-V11-S-004, UT-V11-S-006, UT-V11-S-007, UT-V11-S-008, UT-V11-P-001, UT-V11-P-002 | |
| M4.T1 | UT-V11-CF-001, UT-V11-CF-002, UT-V11-CF-003, UT-V11-CF-004, UT-V11-CF-006, UT-V11-CF-007 | |
| M5.T1 | UT-V11-CF-005 | |
| M6.T1 | — | Mutation API; user-observable behaviour in M6.T2 |
| M6.T2 | UT-V11-WT-001, UT-V11-WT-002, UT-V11-WT-003, UT-V11-WT-004, UT-V11-WT-005, UT-V11-WT-006, UT-V11-D-001 | |
| M7.T1 | UT-V11-M-001, UT-V11-M-002, UT-V11-M-003, UT-V11-M-004 | |
| M8.T1 | UT-V11-J-003 | |
| M8.T2 | — | Verification-only task; runs the validator across the full set |

Union check: 2 + 7 + 6 + 6 + 1 + 7 + 4 + 1 = **34 cases** = full set. No duplicates.

## Concrete Steps

Run from the repo root unless stated otherwise.

**Per-milestone build & lint loop** (idempotent — repeat as files are added):

```bash
make mac-generate    # only on first add of a new file or new buildable folder
make mac-build       # incremental Swift build
make mac-lint        # swiftlint --quiet
```

Expected on success: `mac-build` ends with a build-succeeded line; `mac-lint` exits 0 with no output on the touched files (pre-existing failures elsewhere are out of scope).

**Per-milestone test loop:**

```bash
xcodebuild test \
  -workspace apps/mac/codans.xcworkspace \
  -scheme codans \
  -destination 'platform=macOS' \
  -only-testing:CodansCoreTests 2>&1 | xcbeautify

xcodebuild test \
  -workspace apps/mac/codans.xcworkspace \
  -scheme codans \
  -destination 'platform=macOS' \
  -only-testing:codansTests/Notifications 2>&1 | xcbeautify
```

The second invocation requires that the `codansTests` target build successfully on the working branch (it was broken on `main` per the v1 ExecPlan §Surprises S1). If the target is still broken when M2.T2 lands, surface that as a Surprise & Discovery and route the fix through `/hs-followup-scope` — the project has the option of fixing the target as part of this plan's scope or opening a separate task.

**Manual smoke commands (per-milestone, ad-hoc):**

```bash
# Fire an OSC 9 desktop notification from inside a pane:
printf '\033]9;hello\007'

# Fire a long-running command that crosses the threshold:
sleep 30 && echo done

# Inspect the inbox file:
jq '{version, count: (.entries | length)}' ~/.config/codans/notifications.json

# Inspect the settings file:
jq '.notifications' ~/.config/codans/settings.json

# Watch coordinator drops:
log stream --predicate 'subsystem == "com.gumpw.codans.notifications" && category == "coordinator"' --debug

# Seed a forward-version inbox file (M8 manual smoke):
printf '{"version":99,"entries":[]}' > ~/.config/codans/notifications.json
```

**Per-milestone commit:**

Each task ends with one atomic commit. Suggested subjects (conventional-commit style; no attribution trailers per project policy):

- `feat(notifications): add NotificationsSettings schema section`
- `feat(notifications): InboxFile envelope load/save with legacy + quarantine`
- `feat(notifications): NotificationSettingsReader protocol + SettingsStore adapter`
- `feat(notifications): NotificationCoordinator chokepoint + OSNotifier playSound`
- `feat(notifications): Settings → Notifications pane controls + permission alert`
- `feat(notifications): commandFinished suppression in DetectionTranslator`
- `feat(notifications): PaneKeyboardActivityTracker keystroke side channel`
- `feat(notifications): HierarchyClient.reorderWorktrees + setPaneLabel mutations`
- `feat(notifications): worktree promote on first unread`
- `feat(notifications): pane right-click Mute notifications menu`
- `feat(notifications): Inbox-reset quarantine toast`

## Validation and Acceptance

Two layers of validation must pass before the plan is `Completed`:

1. **Static** — `make mac-build`, `make mac-lint`, the relevant `xcodebuild test` invocations, code-reviewer (no Critical), spec-reviewer (every diff satisfies the spec line it claims to). These run on every milestone commit.
2. **Runtime** — the user-test validator described in `docs/user-test-patterns.md`, run against a live build at each milestone Exit Gate (the subset that milestone's tasks claim via `fulfills`) and once at the end across the full 34-case set.

A case PASSes when all of its observable assertions hold; FAILs trigger `/hs-followup-scope`. Inconclusive runs (e.g., UT-V11-S-003's "no sound played" assertion if the runner cannot capture audio) are explicitly allowed by the user-test doc's Open Questions and are routed through the same `/hs-followup-scope` path with the limitation documented.

The plan is `Completed` when M8.T2 records `verifier_outcome: pass` for every case ID in `validation-state.json` (or a `dismissed[]` entry exists with justification for every Inconclusive).

## Idempotence and Recovery

Every milestone is repeatable:

- **Builds and lints** are incremental; rerunning is safe.
- **`make mac-generate`** is idempotent (Tuist regenerates from `Project.swift`); rerun when a new file or `buildableFolders` entry is added.
- **`InboxFile.save`** and `AtomicFileStore.write` both use temp-file + rename; a crash mid-write leaves the prior file intact.
- **`SettingsStore`** debounces 500 ms trailing; calling `flush()` is safe at any moment.
- **Catalog reorder** mutates an existing field (`Project.worktrees` order); reverting is one more `reorderWorktrees` call to a different target, or a manual sidebar drag.
- **Quarantine** is a rename, not a delete; the user can restore by renaming `notifications.json.bak-<ISO>` back to `notifications.json` while the app is quit.
- **The quarantine-shown marker** is a small JSON file under `~/.config/codans/state/`; deleting it forces the next launch to re-emit the toast (useful during dogfooding).

The one explicitly destructive operation is editing `settings.json` while the app is running — `SettingsStore` will overwrite the file on its next debounced save. Restore from `settings.json.v3-<ts>` backups if present, or accept the loss.

## Artifacts and Notes

This plan inherits the prototype-grade evidence that the v1 ExecPlan landed (52 passing tests, 11 working files, working manual smoke for OSC 9). The v1.1 work proceeds on top of that baseline without re-validating the v1 surface.

Sample expected log output (during M2 dogfood with `inAppEnabled: false`):

```
com.gumpw.codans.notifications coordinator drop inAppDisabled — entry NotificationID(...) source PaneID(...)
com.gumpw.codans.notifications coordinator drop systemDisabled — entry NotificationID(...) source PaneID(...)
com.gumpw.codans.notifications coordinator posted — entry NotificationID(...) inApp=true os=true sound=true badge=1 promoted=false
```

Sample expected `notifications.json` after the first envelope write (M1.T2 acceptance):

```json
{
  "version": 1,
  "entries": [
    {
      "id": "...",
      "kind": "taskFinished",
      "title": "...",
      "body": "...",
      "createdAt": "2026-05-20T08:31:42Z",
      "source": {
        "projectID": "...",
        "worktreeID": "...",
        "tabID": "...",
        "paneID": "..."
      }
    }
  ]
}
```

Sample expected `settings.json` after M1 (showing the new section at defaults):

```json
{
  "version": 3,
  "general": { ... },
  "developer": { ... },
  "worktree": { ... },
  "projects": { ... },
  "notifications": {
    "inAppEnabled": true,
    "systemEnabled": true,
    "soundEnabled": true,
    "dockBadgeEnabled": true,
    "moveNotifiedWorktreeToTop": true,
    "commandFinishedEnabled": true,
    "commandFinishedThresholdSec": 10,
    "mute": {
      "mutedRuleIDs": [],
      "mutedPaneIDs": []
    }
  }
}
```

## Interfaces and Dependencies

The end-state types and signatures, prescriptive. Every signature below must exist at the conclusion of the named milestone.

In `apps/mac/CodansCore/Settings/NotificationsSettings.swift` (M1):

```swift
public nonisolated struct NotificationsSettings: Equatable, Sendable, Codable {
  public var inAppEnabled: Bool
  public var systemEnabled: Bool
  public var soundEnabled: Bool
  public var dockBadgeEnabled: Bool
  public var moveNotifiedWorktreeToTop: Bool
  public var commandFinishedEnabled: Bool
  public var commandFinishedThresholdSec: Int   // clamped [1, 3600] on decode
  public var mute: MuteSettings
  public static let `default`: NotificationsSettings
}

public nonisolated struct MuteSettings: Equatable, Sendable, Codable {
  public var mutedRuleIDs: Set<String>
  public var mutedPaneIDs: Set<PaneID>
}
```

In `apps/mac/CodansCore/Notifications/InboxFile.swift` (M1):

```swift
public nonisolated enum InboxFile {
  public static let currentVersion: Int
  public struct Envelope: Codable, Sendable {
    public let version: Int
    public let entries: [InboxEntry]
  }
  public static func load(from url: URL, now: Date) throws -> [InboxEntry]?
  public static func save(_ entries: [InboxEntry], to url: URL) throws
  public static func quarantinePath(for url: URL, at: Date) -> URL
}
```

In `apps/mac/CodansCore/Notifications/InboxDropReason.swift` (M4):

```swift
public nonisolated enum InboxDropReason: String, Sendable, Codable, Equatable {
  case sourceIsFocused
  case inAppDisabled
  case systemDisabled
  case paneMuted
  case commandFinishedDisabled
  case commandFinishedShort
  case commandCancelled
  case userTypingRecently
  case authorizationDenied
}
```

In `apps/mac/CodansCore/Notifications/DetectionTranslator.swift` (M4 extension):

```swift
extension DetectionTranslator {
  public struct Context: Equatable, Sendable {
    public let hasProducedOutput: Set<PaneID>
    public let lastUserKeystrokeAt: [PaneID: Date]
    public let now: Date
    public let commandFinishedEnabled: Bool
    public let commandFinishedThresholdSec: Int
  }
}
public extension DetectionTranslator {
  static func translate(_ event: TerminalEvent, context: Context) -> Step
}
public struct Step: Equatable, Sendable {
  public let entry: Entry?
  public let outputFlag: OutputFlag
  public let drop: InboxDropReason?
}
```

In `apps/mac/codans/App/Features/Notifications/OSNotifier.swift` (M2 change):

```swift
@MainActor
public protocol OSNotifier: AnyObject {
  func currentAuthorizationStatus() async -> AuthorizationStatus
  func requestAuthorization() async -> AuthorizationStatus
  func post(_ entry: InboxEntry, playSound: Bool) async
}
```

In `apps/mac/codans/App/Features/Notifications/NotificationsSettingsReader.swift` (M2):

```swift
@MainActor
protocol NotificationSettingsReader: AnyObject {
  var notifications: NotificationsSettings { get }
  var authStatus: AuthorizationStatus { get }
  func onChange(_ handler: @escaping @MainActor () -> Void) -> AnyCancellable
}
```

In `apps/mac/codans/App/Features/Notifications/NotificationCoordinator.swift` (M2):

```swift
@MainActor
final class NotificationCoordinator {
  init(
    inbox: NotificationStore,
    osNotifier: OSNotifier,
    dockBadger: DockBadger.Type = DockBadger.self,
    settingsReader: any NotificationSettingsReader,
    catalog: HierarchyClient,
    now: @MainActor @escaping () -> Date = { Date() }
  )

  @discardableResult
  func handle(_ candidate: Candidate) async -> Decision

  func recomputeDockBadge()
  func refreshAuthorizationStatus() async
  func emitQuarantineNotice(backupURL: URL) async   // added in M8

  struct Candidate: Equatable, Sendable {
    let entry: InboxEntry
    let sourceIsFocused: Bool
  }

  enum Decision: Equatable, Sendable {
    case posted(inAppAppended: Bool, osBannerPosted: Bool, soundPlayed: Bool, badgeUpdated: Bool, promoted: Bool)
    case dropped(reason: InboxDropReason)
  }
}
```

In `apps/mac/codans/App/Features/Notifications/PaneKeyboardActivityTracker.swift` (M5):

```swift
@MainActor
final class PaneKeyboardActivityTracker {
  func recordKey(in paneID: PaneID, at: Date = Date())
  func snapshot() -> [PaneID: Date]
  func purge(_ paneID: PaneID)
}
```

In `apps/mac/codans/App/Clients/HierarchyClient.swift` (M6 extension):

```swift
struct HierarchyClient { /* existing closures */
  var reorderWorktrees: @MainActor @Sendable (ProjectID, _ worktreeID: WorktreeID, _ mode: WorktreeReorderMode) -> Void
  var setPaneLabel: @MainActor @Sendable (PaneID, _ label: String, _ present: Bool) -> Void
}

enum WorktreeReorderMode: Sendable {
  case moveToFrontWithinUnpinned
}
```

In `apps/mac/codans/App/Features/SplitViewport/PaneContextMenu.swift` (M7):

```swift
struct PaneContextMenu: View {
  let paneID: PaneID
  var body: some View { /* one Button rendering the Mute notifications row */ }
}
```

Dependencies: no new external libraries. The plan uses `UserNotifications`, `AppKit`, `Foundation`, `Observation`, and the existing in-repo `CodansCore` / `CodansIPC`. SwiftUI for the pane and the menu. `XCTest` for the new test suites.

## Testing growth per milestone

| Milestone | New test files | New test methods (rough) | Target |
|---|---|---|---|
| M1 | `NotificationsSettingsCodableTests.swift`, `InboxFileTests.swift` | ~12 | `CodansCoreTests` |
| M2 | `SettingsStoreReaderAdapterTests.swift`, `NotificationCoordinatorTests.swift`, `MockOSNotifier`, `FakeNotificationSettingsReader` | ~10 | `codansTests/Notifications` (gated on the target's build success) |
| M3 | `NotificationsSettingsViewTests.swift` (snapshot or ViewInspector for the disabled-Sound state and the alert presented-state) | ~4 | `codansTests` |
| M4 | extend `DetectionTranslatorTests.swift` for the new `Context` and Step.drop matrix; one round-trip test for `InboxDropReason` | ~12 | `CodansCoreTests` |
| M5 | extend `DetectionTranslatorTests.swift` for keystroke edges (999/1000/1001 ms); one smoke test for `PaneKeyboardActivityTracker` | ~4 | `CodansCoreTests` + a small app-target tracker test |
| M6 | extend `HierarchyClientTests.swift` for reorder + setPaneLabel; extend `NotificationCoordinatorTests.swift` for unreadByWorktree edge + pinned exclusion | ~8 | mixed |
| M7 | `PaneContextMenuTests.swift` | ~3 | `codansTests` |
| M8 | extend `NotificationCoordinatorTests.swift` for quarantine notice idempotency | ~3 | `codansTests` |

Cumulative target: ~56 new unit-test methods on top of the v1 baseline of 52 in `CodansCoreTests`. The exact target counts are estimates — the plan does not block on hitting a number; it blocks on the user-test validator returning PASS for every case ID at the M8 final gate.
