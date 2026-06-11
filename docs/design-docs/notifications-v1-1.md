# Design Doc: Notifications v1.1 — Policy Chokepoint, Settings Wiring, Command-Finished Suppression

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-05-20
**Product spec:** [notifications-v1-1.md](../product-specs/notifications-v1-1.md)
**Supersedes (scoped):**
- [settings-notifications.md](settings-notifications.md) — T2 Notifications-pane design. The pane-body decisions are absorbed here; the coordinator-wiring section is reframed around the broader chokepoint introduced below.

## Context and Scope

The v1 Notifications system, designed in [notifications.md](notifications.md) and shipped per [exec-plans/notifications.md](../exec-plans/notifications.md), wired the runtime event stream into a persistent inbox, a four-level roll-up of unread indicators, and a status-bar bell. The current code path is:

```
TerminalEvent ──▶ NotificationDetector ──▶ NotificationStore.append
                                       └─▶ OSNotifier.post
                                       └─▶ (Dock badge derives from store)
```

There is no gate between the detector and the side effects. Settings v3 (`apps/mac/CodansCore/Settings/Settings.swift`) has no `notifications` section at all — the toggles previously specced in [settings-notifications.md](settings-notifications.md) were never persisted and the Settings → Notifications pane (`apps/mac/codans/App/Features/Settings/Panes/NotificationsSettingsView.swift`) is permission-status-only.

This document covers the v1.1 build that lands the spec at [notifications-v1-1.md](../product-specs/notifications-v1-1.md): a single policy chokepoint (`NotificationCoordinator`) sitting between the detector and the side effects, the `NotificationsSettings` section that the chokepoint reads, the five Settings-pane controls, command-finished threshold/suppression in the pure translation layer, the per-pane mute UI affordance, the worktree-promote behaviour and the underlying `HierarchyClient.reorderWorktrees` mutation API, and a versioned inbox JSON envelope with a backward-compatible loader.

## Goals and Non-Goals

### Goals

- **G1.** One in-process policy chokepoint that every emitted notification flows through; no other call site invokes `OSNotifier.post` or `store.append` directly for fresh events.
- **G2.** Five Settings controls (`inAppEnabled`, `systemEnabled`, `soundEnabled`, `dockBadgeEnabled`, mute summary) wired read-and-write through `SettingsStore`, with the sound-row disabled-when-system-off UI behaviour and the denied-permission alert.
- **G3.** `OSNotifier.post` carries `playSound: Bool` per call — the adapter is otherwise stateless w.r.t. settings.
- **G4.** Command-finished translation honours an enable toggle, a duration threshold, exit-code 130/143 suppression, a 1 s recent-keystroke suppression window, and a distinguishable title for non-zero exit. All decisions land in the pure `DetectionTranslator`; only the keystroke timestamp is sourced from outside the pure layer.
- **G5.** Worktree promote-on-first-unread is implemented as a `HierarchyClient.reorderWorktrees` mutation, observed via the chokepoint and gated by `moveNotifiedWorktreeToTop`.
- **G6.** Pane right-click "Mute notifications" toggle on the pane chrome, writing `notifications:muted` into `Pane.labels` via a new `HierarchyClient.setPaneLabel(_:_:)` surface.
- **G7.** Inbox JSON gains a `{ version: 1, entries: [...] }` envelope. Loader reads both the new shape and the legacy bare-array shape; writer always emits the new shape; greater-version files are quarantined and the inbox starts empty.

### Non-Goals

- **NG1.** No new in-app banner / toast surface. The "in-app surface" gated by `inAppEnabled` is the inbox (bell badge + popover + Dock badge), as established in v1.
- **NG2.** No mute-rules editor. The pane shows counts and a Reveal-in-Finder button; the JSON is hand-edited.
- **NG3.** No CLI surface for `codans notifications …` in v1.1.
- **NG4.** No "snooze" / time-bounded mute, no per-event sound choice, no per-pane-type threshold. The only threshold is the global `commandFinishedThresholdSec`.
- **NG5.** No retroactive surfacing. Notifications dropped while a toggle was off do not reappear when the toggle flips back on.
- **NG6.** No auto-demote when a promoted worktree returns to zero unread.

## Design

### Overview

The single insight: **mixing detection (translating events into candidates) with policy (deciding whether to surface them) is what made the v1 detector grow into a thicket of inline `if` blocks the moment settings appeared.** v1.1 splits the two: `DetectionTranslator` stays pure and grows command-finished knobs as inputs of its `translate` function; `NotificationDetector` orchestrates the catalog walk and emits a `Candidate`; `NotificationCoordinator` is the new chokepoint that consumes `Candidate`s and turns them into side effects.

```
TerminalEvent ──▶ NotificationDetector ─Candidate─▶ NotificationCoordinator ──▶ NotificationStore.append   (gated by inAppEnabled)
                  (catalog walk,                                          ├──▶ OSNotifier.post(_, playSound:) (gated by systemEnabled + authStatus)
                   muted-label drop)                                      └──▶ DockBadger.setBadge          (gated by dockBadgeEnabled + inAppEnabled)
                                                                          └──▶ HierarchyClient.reorderWorktrees (gated by moveNotifiedWorktreeToTop, 0→N edge)
```

Three other ride-along surfaces complete the work:

1. **`NotificationsSettings`** is added to `Settings.swift` as a sixth top-level section — a one-shot schema change, additive, version stays at 3 (all new fields are optional via `decodeIfPresent`).
2. **`InboxStorage` file I/O** moves to a small `InboxFile` wrapper that owns the version envelope. `NotificationStore` calls into this wrapper instead of using `AtomicFileStore.read([InboxEntry].self, …)` directly.
3. **Pane right-click menu** is introduced as a SwiftUI `.contextMenu` on `LazyPaneHost`, hosting "Mute notifications" as its first item. The catalog mutation rides `HierarchyClient.setPaneLabel`.

### Trade-offs taken

| Tension | Decision | What we give up | Why we accept that |
|---|---|---|---|
| Coordinator: TCA reducer vs. plain `@MainActor` class | Plain class | A symmetric "everything is a reducer" story | The chokepoint has no UI state — it consumes Candidates and dispatches side effects. A reducer here would be three files to express what a 60-LOC class expresses; settings-pane direct-view pattern (`SettingsGeneralView`) already establishes the precedent. |
| Sound knob: stateful adapter property vs. per-call parameter | Per-call parameter | Slightly larger call surface | Stateful adapters are racy when batched posts straddle a settings flip; per-call is deterministic and keeps `UserNotificationsOSNotifier` ignorant of `SettingsStore`. |
| 1 s keystroke window: TerminalEvent enum case vs. side channel | Side channel (`PaneKeyboardActivityTracker`) | Symmetric event-stream story | A new `TerminalEvent.paneUserInput` case ripples through every consumer (`RootFeature`, `Detector`, `DockBadger`, tests). Side channel is 30 LOC and concerns only the detector — same scope as `hasProducedOutput`. |
| Worktree promote: in `HierarchyClient` vs. in coordinator | In `HierarchyClient` as `reorderWorktrees` | Coordinator owns slightly less | The mutation belongs to catalog ownership; the coordinator only decides *when* to call it. This matches `reorderProjects` / `setWorktreePinned` shape and keeps catalog mutation linear (one writer surface). |
| JSON envelope: bump file-name vs. add version key | Add version key, keep file name | A clean break would be self-documenting | Renaming would orphan every existing user's inbox on update. The version key is the cheaper migration story; the loader handles both shapes for one release cycle. |
| `NotificationsSettings` location: standalone file vs. inline in `Settings.swift` | Standalone file (`Settings/NotificationsSettings.swift`) | Slightly more files | Matches `GeneralSettings`, `DeveloperSettings`, `WorktreeSettings` layout — every other section is its own file. |
| Pinned-worktree interaction with promote | Promote only inside the unpinned section | Pinned worktrees never auto-reorder | Pinned is a stronger user signal than "got a notification"; respecting it preserves the user's explicit ordering. |

### System Context Diagram

```
                                    ┌──────────────────────────┐
                                    │  SettingsStore (v3)      │
                                    │  .settings.notifications │
                                    │  • inAppEnabled          │
                                    │  • systemEnabled         │
                                    │  • soundEnabled          │
                                    │  • dockBadgeEnabled      │
                                    │  • commandFinishedEnabled│
                                    │  • commandFinishedThresholdSec
                                    │  • moveNotifiedWorktreeToTop
                                    └─────────┬────────────────┘
                                              │ NotificationSettingsReader
                                              ▼
   ┌──────────────────┐  TerminalEvent   ┌────────────────────────┐
   │  TerminalEngine  │─────────────────▶│ NotificationDetector   │
   └──────────────────┘                  │  • catalog walk        │
                                         │  • muted-label drop    │
   ┌──────────────────┐  paneKey input   │  • hasProducedOutput   │
   │ GhosttySurface   │─────────────────▶│  • keyActivity         │
   │      View        │                  └────────┬───────────────┘
   └──────────────────┘                           │ Candidate (or drop)
                                                  ▼
                          ┌──────────────────────────────────────────┐
                          │     NotificationCoordinator (new)        │
                          │  • read settings + authStatus            │
                          │  • dispatch to sinks                     │
                          │  • track unreadByWorktree for 0→N edge   │
                          └────┬──────────┬──────────┬───────┬──────┘
                               ▼          ▼          ▼       ▼
                       ┌──────────┐ ┌──────────┐ ┌────────┐ ┌──────────────────┐
                       │ Inbox    │ │ OSNotif. │ │ Dock   │ │HierarchyClient   │
                       │ Store    │ │ post(_,  │ │ Badger │ │.reorderWorktrees │
                       │ .append  │ │ playSnd) │ │.setBadge│ └──────────────────┘
                       └──────────┘ └──────────┘ └────────┘
```

External touchpoints unchanged from v1: `UNUserNotificationCenter`, `NSApp.dockTile`, `AtomicFileStore`. New side-channel input only: `GhosttySurfaceView` → `PaneKeyboardActivityTracker`.

### Component Boundaries

```
CodansCore/
  Settings/
    NotificationsSettings.swift                  // NEW — Codable struct, all defaults
  Notifications/
    InboxEntry.swift                             // unchanged
    InboxStorage.swift                           // unchanged
    DetectionTranslator.swift                    // EXTEND — Context input, commandFinished gates
    DetectionTranslatorContext.swift             // NEW — pure context value type
    InboxFile.swift                              // NEW — envelope load/save with legacy fallback
    RollupIndex.swift                            // unchanged

codans/App/Features/Notifications/
  NotificationCoordinator.swift                  // NEW — policy chokepoint, ~120 LOC
  NotificationsSettingsReader.swift              // NEW — protocol bridging SettingsStore (~20 LOC)
  NotificationDetector.swift                     // CHANGE — emits Candidate to coordinator
  NotificationStore.swift                        // CHANGE — uses InboxFile for I/O
  OSNotifier.swift                               // CHANGE — post signature gains playSound
  DockBadger.swift                               // unchanged
  PaneKeyboardActivityTracker.swift              // NEW — last-keystroke per pane

codans/App/Features/Settings/Panes/
  NotificationsSettingsView.swift                // REWRITE — 5 controls + alert + mute summary

codans/App/Features/SplitViewport/
  LazyPaneHost.swift                             // CHANGE — .contextMenu wrapper
  PaneContextMenu.swift                          // NEW — context-menu content

codans/App/Clients/
  HierarchyClient.swift                          // EXTEND — reorderWorktrees, setPaneLabel
```

Dependency direction is preserved: `Notifications/` depends on `CodansCore.*`, `Settings`, and `HierarchyClient`; it never imports UI types other than the SwiftUI bits in the settings pane and the context menu file.

### NotificationCoordinator

The chokepoint is a `@MainActor final class` (not `@Observable` — no UI binds to it). It is constructed once at app bringup in `AppState` and lives as long as the app process.

```swift
@MainActor
final class NotificationCoordinator {
  init(
    inbox: NotificationStore,
    osNotifier: OSNotifier,
    settingsReader: any NotificationSettingsReader,   // bridge to SettingsStore + auth status
    catalog: HierarchyClient,
    promoteEnabled: @MainActor () -> Bool,            // captures settingsReader.moveNotifiedWorktreeToTop
    now: @MainActor () -> Date = { Date() }
  )

  /// Called by `NotificationDetector` for every candidate notification.
  /// Returns the decision so tests can assert what the chokepoint did
  /// without having to inspect side-effect collaborators.
  @discardableResult
  func handle(_ candidate: Candidate) async -> Decision

  /// Recomputes the Dock badge from the current inbox unread count.
  /// Called when `inAppEnabled` or `dockBadgeEnabled` flips so the
  /// badge doesn't lag a settings change.
  func recomputeDockBadge()

  /// Refreshes the cached `authStatus` value via the OS notifier.
  /// Wired to `applicationDidBecomeActive`.
  func refreshAuthorizationStatus() async
}

extension NotificationCoordinator {
  struct Candidate: Equatable, Sendable {
    let entry: InboxEntry
    /// True when the source pane is the user's current global focus.
    /// Detector pre-computes this; if true, the coordinator drops the
    /// candidate before any side effect.
    let sourceIsFocused: Bool
  }

  enum Decision: Equatable, Sendable {
    case posted(inAppAppended: Bool, osBannerPosted: Bool, soundPlayed: Bool, badgeUpdated: Bool, promoted: Bool)
    case dropped(reason: DropReason)
  }

  enum DropReason: String, Sendable {
    case sourceIsFocused, inAppDisabled, systemDisabled, paneMuted,
         commandFinishedDisabled, commandFinishedShort, commandCancelled,
         userTypingRecently, authorizationDenied
  }
}
```

Decision logic (in order):

```
handle(candidate):
  if candidate.sourceIsFocused:                          → drop(sourceIsFocused)

  let s = settingsReader.notifications
  let auth = settingsReader.authStatus

  // 1. inbox + dock derived from inAppEnabled
  let didAppend: Bool
  if s.inAppEnabled:
    inbox.append(candidate.entry)
    didAppend = true
    recomputeDockBadge()             // s.dockBadgeEnabled gate inside
  else:
    didAppend = false

  // 2. OS banner derived from systemEnabled + authStatus
  let didPost: Bool
  let didSound: Bool
  if s.systemEnabled and auth == .authorized:
    await osNotifier.post(candidate.entry, playSound: s.soundEnabled)
    didPost = true
    didSound = s.soundEnabled
  else:
    didPost = false; didSound = false

  // 3. Worktree promote on 0→N edge inside inbox-driven counts
  let didPromote = didAppend and s.moveNotifiedWorktreeToTop
    and unreadCountForWorktreeBefore == 0 and currentUnreadCount > 0
  if didPromote:
    catalog.reorderWorktrees(projectID, candidate.entry.source.worktreeID, .moveToFrontWithinUnpinned)

  return .posted(...)
```

The coordinator owns an `unreadByWorktree` cache so the 0→N edge can be detected without scanning the inbox on every candidate. It is rebuilt at init from the loaded inbox and updated incrementally.

`NotificationSettingsReader` is the seam against `SettingsStore`:

```swift
@MainActor
protocol NotificationSettingsReader: AnyObject {
  var notifications: NotificationsSettings { get }
  var authStatus: AuthorizationStatus { get }
  /// Fires whenever `notifications` or `authStatus` changes. The
  /// coordinator subscribes once and recomputes the Dock badge on tick.
  func onChange(_ handler: @escaping @MainActor () -> Void) -> Cancellable
}
```

A `SettingsStoreReaderAdapter` wraps `SettingsStore` + the cached auth status (`Observable` tracking on settings; manual refresh on auth). For tests, a `FakeReader` exposes mutable fields directly. The protocol exists because `SettingsStore` is internal to the app target and there is value in injecting a fake; we do not declare a public-facing dependency container here.

### NotificationsSettings (schema)

A new top-level section on `Settings`, additive at the same version (`3`):

```swift
public struct NotificationsSettings: Equatable, Sendable, Codable {
  public var inAppEnabled: Bool                   // default true
  public var systemEnabled: Bool                  // default true
  public var soundEnabled: Bool                   // default true
  public var dockBadgeEnabled: Bool               // default true
  public var moveNotifiedWorktreeToTop: Bool      // default true
  public var commandFinishedEnabled: Bool         // default true
  public var commandFinishedThresholdSec: Int     // default 10, clamped to [1, 3600]
  public var mute: MuteSettings                   // default = .init() — empty rules/panes set

  public static let `default` = NotificationsSettings(/* all defaults */)
}

public struct MuteSettings: Equatable, Sendable, Codable {
  public var mutedRuleIDs: Set<String>            // free-form rule keys; v1.1 only reads counts
  public var mutedPaneIDs: Set<PaneID>            // counts only in v1.1; not authoritative for per-pane mute (Pane.labels is)
}
```

**Schema decisions:**

- All fields are optional via `decodeIfPresent` defaults. A pre-v1.1 `settings.json` decodes cleanly with `NotificationsSettings.default` filling in.
- `commandFinishedThresholdSec` decode applies the clamp `max(1, min(3600, value))` and logs a one-line warning on out-of-range loads. The UI input layer enforces the same range upfront so the persisted value is never out of range when written by the app itself.
- `mute` is a sub-struct kept at v1.1 size: the existing v1 mute-rules JSON file (`detection-rules.json`) is **not** ingested into `settings.json`; the in-`Settings` `mute` is a separately authored cache used only by the summary row. The "Reveal in Finder" button still resolves to `~/.config/codans/detection-rules.json` (the v1 cache file).
- We deliberately do not collapse the boolean toggles into an enum (e.g. `level: .silent | .inAppOnly | .full`) — the four switches are orthogonal and users have asked for the cross-products that an enum would not express (in-app off + system on for "background-only" mode).

`Settings` integration:

```swift
// Settings.swift
public struct Settings { ... existing fields ...
  public var notifications: NotificationsSettings = .default
}
// CodingKeys gains .notifications; init(from:) uses decodeIfPresent.
// SettingsStore gains `mutateNotifications(_ transform: (inout NotificationsSettings) -> Void)`.
```

No schema-version bump; we rely on `decodeIfPresent`. Rationale: the v2 → v3 migration is still recent (`SettingsMigration.load`) and another bump just to introduce one optional section would dwarf the actual change. The garbage-collect pass leaves `notifications` alone (we never drop sections that are at their default values; the JSON renders the defaults explicitly, which costs ~150 bytes and is worth the diffability).

### DetectionTranslator extension

`DetectionTranslator.translate` currently takes `(event, hasProducedOutput)`. v1.1 introduces a `Context` value so the pure layer stays pure:

```swift
public struct DetectionTranslator.Context: Equatable, Sendable {
  public let hasProducedOutput: Set<PaneID>
  public let lastUserKeystrokeAt: [PaneID: Date]            // side-channel input
  public let now: Date                                       // injected clock
  public let commandFinishedEnabled: Bool                   // from settings
  public let commandFinishedThresholdSec: Int               // from settings, clamped
}

public static func translate(_ event: TerminalEvent, context: Context) -> Step
```

`commandFinished` (the only branch with new logic) becomes:

```swift
case .commandFinished(let exitCode, let durationNs):
  guard context.commandFinishedEnabled else {
    return Step(entry: nil, outputFlag: .unchanged, drop: .commandFinishedDisabled)
  }
  // Exit-code suppression: 130 (SIGINT) / 143 (SIGTERM) — user cancellation
  if exitCode == 130 || exitCode == 143 {
    return Step(entry: nil, outputFlag: .unchanged, drop: .commandCancelled)
  }
  // Threshold check (duration is ns)
  let durationSec = Double(durationNs) / 1_000_000_000
  guard durationSec >= Double(context.commandFinishedThresholdSec) else {
    return Step(entry: nil, outputFlag: .unchanged, drop: .commandFinishedShort)
  }
  // 1 s keystroke window
  if let lastKey = context.lastUserKeystrokeAt[paneID],
     context.now.timeIntervalSince(lastKey) < 1.0 {
    return Step(entry: nil, outputFlag: .unchanged, drop: .userTypingRecently)
  }
  // Differential title for non-zero exit
  let (title, body) = exitCode == 0
    ? ("Command finished", "Completed in \(formatDuration(durationSec)).")
    : ("Command failed (exit \(exitCode))", "Ran for \(formatDuration(durationSec)) before failing.")
  return Step(
    entry: Entry(paneID: paneID, kind: .taskFinished, title: title, body: body),
    outputFlag: .unchanged,
    drop: nil
  )
```

`Step` grows an optional `drop: DropReason?` field so tests can assert which suppression path fired. The detector / coordinator currently routes `drop != nil` into the same `DropReason` log line as the coordinator's later drops, giving a unified drop log.

`Step.drop` enum cases are a strict subset of `NotificationCoordinator.DropReason` — the same string-coded enum is shared (lives in `CodansCore` so both the pure translator and the app-layer coordinator reference one type).

### PaneKeyboardActivityTracker

A tiny actor-free `@MainActor` class that owns `[PaneID: Date]`:

```swift
@MainActor
final class PaneKeyboardActivityTracker {
  private var lastByPane: [PaneID: Date] = [:]
  func recordKey(in paneID: PaneID, at: Date = Date())
  func snapshot() -> [PaneID: Date]
  func purge(_ paneID: PaneID)
}
```

**Wiring:** `GhosttySurfaceView` already routes user key events to libghostty via `surface.sendKey(...)` (see `Runtime/Ghostty/GhosttySurfaceView.swift`). We add one call site immediately before the key is dispatched: `tracker.recordKey(in: paneID)`. The tracker is held by the same root that owns `NotificationDetector` and is passed by reference into the detector's per-event context build.

**Purge cadence:** the map can grow over a long-lived session. We purge on `paneExited` / `paneCrashed` / `paneClosedByTab` (the detector already runs through these for its own cache cleanup, so we can piggyback). No periodic sweep is needed — the upper bound is "every open pane plus a few that just closed", which is small.

**Why not put the timestamp in `Pane.labels` or a `@Observable` field on `PaneSurface`:**

- `Pane.labels` is persisted; the timestamp is ephemeral and per-process. Writing to labels would also trigger catalog saves on every keystroke.
- `PaneSurface` (`@Observable`) would force SwiftUI re-renders on every keystroke, which `GhosttySurfaceView` explicitly avoids by routing input through callbacks.

A dedicated container is the right size for this signal.

### OSNotifier protocol change

```swift
@MainActor
public protocol OSNotifier: AnyObject {
  func currentAuthorizationStatus() async -> AuthorizationStatus
  func requestAuthorization() async -> AuthorizationStatus
  func post(_ entry: InboxEntry, playSound: Bool) async   // CHANGED
}
```

`UserNotificationsOSNotifier.post`:

```swift
public func post(_ entry: InboxEntry, playSound: Bool) async {
  var status = await currentAuthorizationStatus()
  if status == .notDetermined {
    status = await requestAuthorization()
  }
  guard status == .authorized else { return }
  let content = UNMutableNotificationContent()
  content.title = entry.title
  content.body = entry.body
  content.threadIdentifier = entry.source.paneID.raw.uuidString
  content.categoryIdentifier = entry.kind.rawValue
  content.userInfo = ["deeplink": Self.deeplink(for: entry.source).absoluteString]
  content.sound = playSound ? .default : nil
  let request = UNNotificationRequest(identifier: entry.id.raw.uuidString, content: content, trigger: nil)
  try? await center.add(request)
}
```

`MockOSNotifier` (test target) records `(entry, playSound)` tuples so the four-toggle behaviour matrix tests can assert sound state independently. Only one call site exists — the coordinator — so the API ripple is exactly one Swift compile error to fix.

### Settings → Notifications pane

The pane is **direct view + settingsStore** — no TCA reducer. This matches `SettingsGeneralView`'s pattern and is also the precedent the prior settings-notifications design landed on (see [settings-notifications.md §UI architecture](settings-notifications.md)).

Composition:

```
Form {
  Section("Notifications") {
    Toggle("In-app notifications", isOn: inAppBinding)        // caption: "Gates the bell unread list and the Dock badge."
    Toggle("System notifications", isOn: systemBinding)       // .onChange triggers permission alert when needed
    Toggle("Sound", isOn: soundBinding)                       // .disabled(!systemEnabled), .help("Sound requires System notifications to be on.")
    Toggle("Dock badge", isOn: dockBadgeBinding)              // caption: "Shows the unread count on the app icon."
  }

  Section("Command-finished notifications") {
    Toggle("Notify when a command finishes", isOn: cmdFinishedBinding)
    HStack {
      Text("Minimum duration")
      Spacer()
      TextField("Seconds", value: thresholdBinding, format: .number)
        .frame(width: 60)
        .textFieldStyle(.roundedBorder)
        .disabled(!commandFinishedEnabled)
      Text("seconds")
    }
    Text("Commands shorter than this are silent. Cancelled commands (Ctrl-C) are always silent. Notifications are also suppressed for 1 second after you type in the pane.")
      .font(.caption).foregroundStyle(.secondary)
  }

  Section("Mute rules") {
    HStack {
      Text(muteSummaryString)        // "3 rule(s), 2 pane(s) muted" or "No mute rules"
      Spacer()
      Button("Reveal rules.json in Finder…") { revealRulesFile() }
    }
  }

  Section("macOS permission") {
    // existing v1 status row + Request permission / Open System Settings,
    // unchanged behaviour — moved below the new sections so the toggles
    // are the primary focus.
  }
}
```

**Binding shape (one for each toggle, written once and reused):**

```swift
let inAppBinding = Binding<Bool>(
  get: { settingsStore.settings.notifications.inAppEnabled },
  set: { newValue in
    settingsStore.mutateNotifications { $0.inAppEnabled = newValue }
  }
)
```

**Sound-disabled state:** when `systemEnabled == false`, the Sound `Toggle` is `.disabled(true)` and gets a `.help("…")` tooltip. The persisted value is **not** cleared — flipping system back on restores the user's intent. This matches the spec N1.1-S3.

**System toggle onChange:** when the user flips System notifications to `true`, the view reads the cached `authStatus` from `settingsStore`. If `.denied`, set `@State var showPermissionAlert = true`. The toggle value remains `true` regardless of the alert outcome:

```swift
.alert("Notifications are blocked", isPresented: $showPermissionAlert) {
  Button("Open System Settings…") { openSystemNotificationsPane() }
  Button("Cancel", role: .cancel) { }
} message: {
  Text("macOS is currently blocking notifications for codans. Open System Settings to allow them.")
}
```

**System Settings deep-link with fallback:**

```swift
private func openSystemNotificationsPane() {
  let bundleID = Bundle.main.bundleIdentifier ?? "com.gumpw.codans.codans"
  let withID = URL(string: "x-apple.systempreferences:com.apple.preference.notifications?id=\(bundleID)")
  let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
  if let withID, NSWorkspace.shared.open(withID) { return }
  NSWorkspace.shared.open(fallback)
}
```

The `?id=<bundle-id>` form lands on the app's row on macOS versions that support it; the fallback covers older versions. `NSWorkspace.shared.open(URL)` returns `Bool` so we can detect the rejection.

**Mute summary:**

```swift
private var muteSummaryString: String {
  let m = settingsStore.settings.notifications.mute
  if m.mutedRuleIDs.isEmpty && m.mutedPaneIDs.isEmpty { return "No mute rules" }
  return "\(m.mutedRuleIDs.count) rule(s), \(m.mutedPaneIDs.count) pane(s) muted"
}
```

The Reveal-in-Finder button calls `NSWorkspace.shared.activateFileViewerSelecting([url])`. The file must exist for the reveal to land cleanly; if absent, we create an empty default file before revealing. This mirrors the existing developer-pane Reveal behaviour for `hooks.json`.

### Pane right-click "Mute notifications"

The current pane chrome (`apps/mac/codans/App/Features/SplitViewport/LazyPaneHost.swift`) has no `.contextMenu`. We add one at the top of the `content` view:

```swift
content
  .contextMenu { PaneContextMenu(paneID: store.paneID, store: store) }
  .task(id: store.paneID) { store.send(.task) }
```

`PaneContextMenu` is a new SwiftUI struct in the same folder. Body:

```swift
struct PaneContextMenu: View {
  let paneID: PaneID
  @Bindable var store: StoreOf<PaneHostFeature>
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

`HierarchyClient` gains:

```swift
var setPaneLabel: @MainActor @Sendable (PaneID, _ label: String, _ present: Bool) -> Void
```

Implementation in `HierarchyManager` (the actor behind the client): walk the catalog to the pane, mutate `labels.insert` / `labels.remove`, schedule catalog save. Single linear writer surface; matches the shape of `setWorktreeArchived` / `setWorktreePinned`.

**Why the menu reads via `hierarchy.snapshot()` rather than from `store.state`:** the menu item must reflect the current label state every time it opens, not the state at view-construct time. `snapshot()` is a cheap value-type read; the menu only re-evaluates when SwiftUI opens it.

### Worktree promote

`HierarchyClient` gains:

```swift
var reorderWorktrees: @MainActor @Sendable (
  ProjectID,
  _ worktreeID: WorktreeID,
  _ mode: ReorderMode
) -> Void

enum ReorderMode: Sendable {
  case moveToFrontWithinUnpinned       // place after all pinned worktrees, before all other unpinned
  case toIndex(Int)                    // unused in v1.1; reserved for explicit reorder UI
}
```

Implementation in `HierarchyManager`:

1. Locate the project.
2. Identify the target worktree's current index.
3. Split `worktrees` into `pinned = worktrees.filter(\.isPinned)` and `unpinned = worktrees.filter { !$0.isPinned }`.
4. If the target is pinned, no-op (pinned worktrees are not auto-reordered; spec OQ-V11-3 resolution).
5. Otherwise remove the target from `unpinned` and insert it at index 0 of `unpinned`.
6. Rejoin `pinned + unpinned` and assign back to `worktrees`.
7. Schedule catalog save.

The coordinator drives this from its `unreadByWorktree` cache:

```swift
private var unreadByWorktree: [WorktreeID: Int] = [:]   // from inbox at init + incremental

private func handlePromote(for entry: InboxEntry) {
  guard settingsReader.notifications.moveNotifiedWorktreeToTop else { return }
  let prior = unreadByWorktree[entry.source.worktreeID] ?? 0
  unreadByWorktree[entry.source.worktreeID] = prior + 1
  if prior == 0 {
    catalog.reorderWorktrees(entry.source.projectID, entry.source.worktreeID, .moveToFrontWithinUnpinned)
  }
}
```

**Interaction with `Project.lastActiveAt`:** the existing `bumpProjectActivity` (which the detector calls today on every notification) drives the **Project**-level sort. The new `reorderWorktrees` drives the **Worktree** ordering within a project. They are orthogonal — projects can sort by `.recent` independently of worktree promotion within each project. We keep the existing `bumpProjectActivity` call (in `NotificationDetector.emit`) as-is; the coordinator does not duplicate it.

**Why the 0 → N edge is detected by the coordinator's cache rather than by observing the store:** observing the store would re-emit on every `markRead` / dedup-collapse, which would either re-promote already-promoted worktrees (annoying) or require the coordinator to track "did we already promote this worktree". The cache-edge approach in the coordinator is one place to reason about it.

**Persistence:** the reorder mutates `Catalog.projects[i].worktrees`, which `CatalogStore` saves on its existing debounce. Relaunch reads the promoted order — AC-V11-WT5 holds without extra work.

### InboxFile (versioned envelope)

```swift
public nonisolated enum InboxFile {
  public static let currentVersion: Int = 1

  public struct Envelope: Codable, Sendable {
    public let version: Int
    public let entries: [InboxEntry]
  }

  /// Read the inbox from disk, transparently accepting legacy bare-array
  /// files. Returns `nil` when the file is missing; returns `[]` and
  /// quarantines the file when its version is newer than `currentVersion`.
  public static func load(from url: URL, now: Date = Date()) throws -> [InboxEntry]?

  /// Always writes the envelope shape.
  public static func save(_ entries: [InboxEntry], to url: URL) throws
}
```

**Loader algorithm:**

1. If the file does not exist → return `nil`.
2. Read raw bytes.
3. Try `JSONDecoder().decode(Envelope.self, from: data)`. On success:
   - If `version > currentVersion`: rename to `<file>.bak-<ISO8601>` (atomic rename), return `[]`.
   - Else: return `envelope.entries`.
4. On envelope decode failure, try `JSONDecoder().decode([InboxEntry].self, from: data)`. On success: return that array (legacy shape).
5. On both decode failures: log and return `[]`. Do not rename — the file may be a partial write and we let `AtomicFileStore`'s next save overwrite it.

**Writer:** `JSONEncoder().encode(Envelope(version: currentVersion, entries: entries))` then `AtomicFileStore.write` (which is just an atomic-rename helper around the encoded bytes; we will adapt the call to bypass its `Encodable<T>` generic since we need a specific envelope shape — `AtomicFileStore.writeData(_:to:)` already exists for this purpose).

**Behaviour with existing on-disk inboxes:** a user upgrading from v1.0 to v1.1 has a bare-array file. First launch: loader takes the legacy path, store loads the entries, next debounced save writes the envelope. Round-trip complete, one save later the user is on the new shape.

**Why not bump `NotificationsSettings.version` instead and use the existing `SettingsMigration` helper:** the inbox is its own file and its lifecycle (debounced trailing writes, cap/age sweeps) is unrelated to settings. Tying the two together would force a settings-save on every inbox save during the migration window — a needless coupling. `InboxFile` localises the versioning to the file that needs it.

`NotificationStore.init` switches its load call from `AtomicFileStore.read([InboxEntry].self, at:)` to `InboxFile.load(from:)`. Its save scheduler switches from `AtomicFileStore.write(entries, to:)` to `InboxFile.save(entries, to:)`. No other behavioural change.

### Testing strategy

**Pure layer** (lands in `CodansCoreTests/`):

| AC ID(s) | Test file | What it asserts |
|---|---|---|
| AC-V11-CF1..CF7 | `DetectionTranslatorTests.swift` (extend) | New `Context` cases. Threshold edge (5 s vs 30 s vs 10 s exactly), SIGINT/SIGTERM suppression with various durations, keystroke window edges (999 ms vs 1000 ms vs 1001 ms), non-zero title differs from zero title. Clamp behaviour for out-of-range threshold. |
| AC-V11-J1..J3 | `InboxFileTests.swift` (NEW) | Round-trip envelope. Legacy bare array decodes and re-encodes as envelope. Forward-version file is renamed to `.bak-<date>` and load returns empty. Partial / corrupt file returns empty without rename. |
| AC-V11-S6, S7 | `NotificationsSettingsCodableTests.swift` (NEW) | Defaults round-trip. Missing section in `settings.json` decodes to defaults. Out-of-range `commandFinishedThresholdSec` is clamped on decode. Encoded JSON keys match snake / camel case convention. |

**Coordinator layer** (lands in `apps/mac/codans/Tests/Notifications/`):

| AC ID(s) | Test | Approach |
|---|---|---|
| AC-V11-CP1..CP3 | `NotificationCoordinatorTests.swift` (NEW) — `evaluatesLiveSettingsAtDecisionTime`, `dropDoesNotResurfaceOnToggleFlip` | `FakeReader` with mutable fields. Feed candidate, flip setting, feed second candidate, assert decisions. |
| AC-V11-S1..S5 | same file — `inAppOffSkipsInboxButPostsBanner`, `systemOffPreservesInbox`, `soundOffPostsWithNilSound`, `dockBadgeOffClearsBadge` | `MockOSNotifier` records `(entry, playSound)`; `FakeDockBadger` records every `setBadge` call; assert at the boundaries. |
| AC-V11-WT1..WT5 | same file — `firstUnreadForWorktreePromotesIt`, `secondUnreadDoesNotRetrigger`, `markReadDoesNotDemote`, `pinnedWorktreeIsNotPromoted`, `disabledTogglePreventsPromote` | `FakeHierarchyClient` records `reorderWorktrees` calls; assert call presence + arguments. |
| AC-V11-CP focused-pane drop | `focusedSourceDropsBeforeAnySink` | Build candidate with `sourceIsFocused: true`; assert `.dropped(.sourceIsFocused)` and zero collaborator calls. |
| AC-V11-P1..P2 | `NotificationsSettingsViewTests.swift` (NEW, SwiftUI ViewInspector or snapshot if available) — `deniedAuthShowsAlertOnSystemFlip`, `systemDisabledDisablesSoundRow` | Drive the view with a `FakeReader`; toggle the System binding; assert the alert state flips and the Sound toggle renders disabled. |

**UI / catalog wiring** (lands in `apps/mac/codans/Tests/`):

| AC ID(s) | Test |
|---|---|
| AC-V11-M1..M4 | `PaneContextMenuTests.swift` (NEW) — read pane labels via fake hierarchy client, assert toggle adds/removes the mute label. Existing inbox-row tests already cover M4 implicitly (label change doesn't touch persisted entries). |
| AC-V11-J2 acceptance (manual) | Manual smoke recorded in the exec plan: pre-populate `~/.config/codans/notifications.json` with the legacy bare-array shape; launch; observe the bell badge matches the legacy file's unread count; force a save; verify `jq .version notifications.json` returns `1`. |

**Test fakes added:**

- `FakeOSNotifier` — captures posts with playSound; configurable `authStatus`.
- `FakeDockBadger` — records every badge value.
- `FakeHierarchyClient` (extension to existing fake) — captures `reorderWorktrees` and `setPaneLabel` calls.
- `FakeNotificationSettingsReader` — mutable struct fields plus a manual change-fire helper.

The pre-existing `codansTests` target was broken on `main` per [exec-plans/notifications.md §Surprises S1](../exec-plans/notifications.md). The coordinator tests are the first non-trivial app-target Notifications tests we are committing to that target; the v1.1 work includes whatever target-config / `buildableFolders` adjustment that target needs, since the build is no longer optional for v1.1's coverage gates.

## Alternatives Considered

### A1 — Push the chokepoint into the existing `NotificationDetector`

Skip the coordinator class; add the four-toggle gating directly inside `NotificationDetector.emit`. The detector already holds the catalog snapshot closure and the OS notifier reference, so on paper the addition is small.

- **Pros:** Fewer files, no new collaborator.
- **Cons:** The detector's responsibility grows from "translate event → entry" to "translate + gate + dispatch + maintain unread-per-worktree cache + observe settings changes". It is already a 200-LOC class with `hasProducedOutput`, `paneSourceCache`, the catalog walk, and the keystroke side-channel about to be added. Cramming policy in there blurs the line that the v1 design explicitly preserved: detection is testable in pure form (`DetectionTranslator`), the detector is orchestration, the chokepoint is policy.
- **Verdict:** Rejected. The two-class split is the cleanest way to keep policy reviewable in one place, and the test matrix above gets shorter — coordinator tests don't need to set up runtime events at all.

### A2 — Make `inAppEnabled` gate a new in-app transient toast surface

Build a new transient SwiftUI toast surface in the main window, gate it by `inAppEnabled`, and leave the inbox always-on.

- **Pros:** Literal reading of "in-app notifications".
- **Cons:** New surface (overlay component, auto-dismiss timer, stacking model) — a multi-day add. The user expectation in v1 was "in-app" meaning "the inbox + bell + Dock badge" (collectively the surfaces inside the app). The existing usage scales: in-app off ⇒ nothing in the app changes silently in the background; system on ⇒ macOS still alerts you across the OS. Adding a toast would create a third axis the user has to model.
- **Verdict:** Rejected. The inbox is the in-app surface; v1.1 honours the v1 mental model.

### A3 — Stateful adapter property on `OSNotifier` instead of `playSound:` per call

Add `var playSound: Bool` to the protocol, the coordinator sets it before calling `post`.

- **Pros:** `post` signature stays.
- **Cons:** Stateful adapters are racy when posts batch and a setting changes mid-batch; the bug is silent (a notification gets the previous sound state, not the new one). Per-call parameter is deterministic and matches how `threadIdentifier` / `categoryIdentifier` already travel as part of the post.
- **Verdict:** Rejected.

### A4 — Add a `TerminalEvent.paneUserInput(PaneID, at: Date)` event case

Route the keystroke signal through the same `TerminalEvent` stream used by the detector, treating it as a first-class lifecycle event.

- **Pros:** Symmetric — every signal that matters to detection flows through one channel.
- **Cons:** Adds noise to every consumer of `TerminalEvent` (`RootFeature`, tests, future analytics) that has no business knowing about per-keystroke timestamps. Keystroke cadence is human-scale (sometimes 10 Hz) — flowing it through `for await event in eventStream` is wasted work for every consumer except the detector.
- **Verdict:** Rejected. A side channel (`PaneKeyboardActivityTracker`) is scoped to the one consumer that needs it.

### A5 — Encode the four toggles as one enum

`NotificationsSettings.mode: enum { off, inbox, system, both }` instead of four booleans.

- **Pros:** Fewer states to test (4 vs 16).
- **Cons:** Removes the orthogonality users actually want. "Background-only" mode is "in-app off + system on": the cross-product. The enum forces hierarchy where there is none. Sound and Dock badge are further orthogonal axes that the enum can't fold cleanly.
- **Verdict:** Rejected. The 16-cell test matrix is small; we test the corners that matter (S1..S5 above) and rely on coverage of the chokepoint logic for the rest.

### A6 — Drive worktree promote from the inbox store, not the coordinator

`NotificationStore` already knows when an entry appends; observing its unread set could detect 0 → N edges per worktree.

- **Pros:** Coordinator gets thinner.
- **Cons:** Store would have to know about `HierarchyClient` and `moveNotifiedWorktreeToTop` (a settings reader) — both backward dependencies. Store is currently UI-and-OS-ignorant by design (the v1 design doc §Component Boundaries explicitly puts it as the leaf type). Driving the reorder from the coordinator keeps the store's surface intact.
- **Verdict:** Rejected.

### A7 — File-name bump for inbox envelope migration

Rename to `notifications.v1.json` for the new shape; old `notifications.json` is read once and copied across.

- **Pros:** A clean break — version-in-name is self-documenting.
- **Cons:** Every existing user gets one round of "where did my inbox go" until the migration completes. Risk of orphan files if migration fails halfway. The version-key approach is one decode-try, zero file operations on the happy path.
- **Verdict:** Rejected.

## Cross-Cutting Concerns

### Security and privacy

- `NotificationsSettings` adds no secrets. `settings.json` permissions (0600 via `AtomicFileStore`) carry through unchanged.
- The System Settings deep-link goes through `NSWorkspace.shared.open`, which is gated by macOS without further prompting.
- The mute summary reads `mute.mutedPaneIDs` (which are UUIDs) and `mutedRuleIDs` (free-form strings) — count-only display; no PII surface change.

### Observability

- One new log category: drop reasons logged at `.debug` under `subsystem: "com.gumpw.codans.notifications"`, `category: "coordinator"`. Each drop emits one structured line: `drop \(reason) for entry \(entryID) source \(paneID)`.
- The coordinator's `Decision` return value is the inspectable artefact for tests; production code does not call `handle` for its return.
- `InboxFile.load` logs one warning when it quarantines a forward-version file (`renamed notifications.json with version=N to notifications.json.bak-<date>`).
- `DetectionTranslator` is pure; suppression decisions are visible via the `Step.drop` field, which the detector forwards to the same coordinator log.

### Accessibility

- All toggles use `Toggle(_:isOn:)` with explicit labels; VoiceOver picks them up.
- The `.help(...)` tooltip on the disabled Sound row reads "Sound requires System notifications to be on." — same text as the visible caption variant for `accessibilityHint`.
- The context-menu item "Mute notifications" carries an explicit `Label("Mute notifications", systemImage:)` so the menu reader announces it without the icon swallowing the text.

### Performance

- Coordinator decision is O(1) per candidate. `unreadByWorktree` is a `[WorktreeID: Int]` map, updated incrementally. The init-time rebuild from the loaded inbox is O(N) where N ≤ 500 — sub-millisecond.
- `PaneKeyboardActivityTracker` is O(1) per keystroke. Map size bounded by open panes; purged on lifecycle teardown.
- Settings change notifications coalesce inside `@Observable` tracking; the coordinator's `recomputeDockBadge` runs at most once per event-loop tick even under rapid toggling.
- `InboxFile.load` does one extra JSON-decode attempt on legacy files (envelope first, bare array second); negligible cost on the load-once-per-launch path.

### Migration

- **Settings:** purely additive via `decodeIfPresent`. No version bump. A pre-v1.1 `settings.json` decodes to `NotificationsSettings.default`. A v1.1-and-later `settings.json` read by an earlier build silently ignores the `notifications` section (Codable's `decodeIfPresent` on the older version's struct).
- **Inbox:** envelope-key bump handled by `InboxFile.load`. One save after launch rewrites legacy files in the new shape. No data loss path under normal conditions.
- **Catalog:** the new `reorderWorktrees` mutates an existing field (`Project.worktrees` ordering); no schema change.

### Rollback

- Code-level rollback is a `git revert` of the implementation PR. Persisted state on disk after rollback:
  - `settings.json` may contain a `"notifications": { ... }` block that the older build will silently drop on its next garbage-collect save. No user-visible regression except the user re-flips toggles on their next install.
  - `notifications.json` may be in envelope shape; the older build's loader will fail-soft to empty (since v1.0 also has a `?? []` fallback) — the user's inbox appears empty. To preserve the inbox across a rollback the user can manually unwrap: `jq '.entries' notifications.json > notifications.json.tmp && mv notifications.json.tmp notifications.json`. This is documented in the exec plan's manual recovery section but not automated.

## Risks

| Risk | Mitigation |
|---|---|
| **Coordinator under-tested at edges.** A misordered gate or a stale `unreadByWorktree` could silently misroute notifications. | The `Decision` return value is asserted in every coordinator test; the `unreadByWorktree` cache has its own init-from-inbox test path. We require the full S1..S5 + WT1..WT5 + CF1..CF7 matrix green before merge. |
| **`@Observable` tracking gap on `NotificationsSettings`.** SwiftUI may not invalidate the pane on nested-struct mutations as eagerly as on top-level Settings mutations. | All settings reads in the pane go through the `settingsStore.settings.notifications.…` keypath, which `@Observable` tracks correctly because `Settings` itself is the observed root. Confirmed by the existing Appearance pane's identical pattern. |
| **1 s keystroke window misses across IME composition.** Some IMEs emit batched key events; a long composition could leave `lastKeystrokeAt` stale. | The tracker records on every `sendKey` invocation, including composition events. If a real IME case proves problematic, the fix is to lift the 1 s constant to a setting in v1.2 — the contract is keyed by the existence of `lastKeystrokeAt`, not its semantics. |
| **`reorderWorktrees` racing with the user's manual drag-reorder.** The user is drag-reordering a worktree at the exact moment a notification fires for that worktree's project. | Both writers are `@MainActor`; they serialise on the actor. The last write wins, which is acceptable — auto-promote losing to an in-progress manual drag is the correct outcome from the user's perspective. |
| **Forward-version inbox file mistakenly quarantined.** A user runs a v1.2 build, downgrades to v1.1, finds an empty inbox. | The quarantine is a rename, not a delete; the user can restore by renaming `notifications.json.bak-<date>` back. Documented as an Open Question OQ-V11-* in the spec; we accept the trade for now. |
| **Permission alert flashing on every system-on flip after denial.** A user with denied permission toggles System on/off repeatedly. | The alert fires once per flip-to-on transition; flipping off then on again is a fresh transition. This is the intended behaviour — the alert is informational, not nagware. If users complain, we add a `@State var suppressUntilUserAction` flag in v1.2. |
| **Mute summary drift from the actual rules file.** `settings.notifications.mute` and `~/.config/codans/detection-rules.json` are not the same source of truth. | Documented: the summary is a count cache. The Reveal-in-Finder button is the escape hatch for users who need accuracy. v1.2 may unify the two sources. |
| **Coordinator and detector both call `bumpProjectActivity`.** Existing detector call + a coordinator add would double-bump. | Coordinator does NOT call `bumpProjectActivity`. Detector keeps its call. Explicit non-duplication. |

## Resolved Decisions

- **D-OQ1 — Forward-version inbox quarantine surfaces a one-shot user-visible toast on the next launch.** After `InboxFile.load` renames a forward-version file to `notifications.json.bak-<ISO>` and starts the inbox empty, the coordinator posts one synthetic `InboxEntry` of kind `.taskFinished` titled "Inbox reset" with a body pointing at the backup file's basename. The entry uses a synthetic `SourcePath` whose IDs do not resolve in the live catalog, so click-through lands at the deepest existing ancestor (the inbox itself, in practice). The toast fires through the chokepoint exactly once per quarantine event (gated by an idempotency key derived from the backup filename) so a relaunch without a fresh quarantine does not re-fire it.
- **D-OQ2 — Drop-reason logging is uniformly `.debug`.** No info-level escalation for "first drop of each reason per launch" — the per-reason novelty signal does not survive the user's first restart, and tying log severity to launch-local state makes the log line non-reproducible. Users diagnosing silence enable `.debug` for `subsystem: "com.gumpw.codans.notifications"`, `category: "coordinator"` via `Console.app` filter or `log stream`.
- **D-OQ3 — `setPaneLabel` debounces.** Goes through the existing `CatalogStore.scheduleSave` 500 ms trailing window — same as every other catalog mutation. The in-memory `Catalog` mutates immediately so a re-opened menu reads the new state; only the disk write is debounced. This matches the `setWorktreePinned` / `setWorktreeArchived` precedent and avoids inventing a parallel write cadence for one label.

---

## References

- Product spec: [notifications-v1-1.md](../product-specs/notifications-v1-1.md)
- v1 design: [notifications.md](notifications.md)
- v1.1's predecessor for the pane only: [settings-notifications.md](settings-notifications.md) (superseded by this doc)
- Settings v3 schema: `apps/mac/CodansCore/Settings/Settings.swift`
- Hierarchy mutation surface: `apps/mac/codans/App/Clients/HierarchyClient.swift`
- Pane chrome host: `apps/mac/codans/App/Features/SplitViewport/LazyPaneHost.swift`
- Inbox primitives: `apps/mac/CodansCore/Notifications/`
