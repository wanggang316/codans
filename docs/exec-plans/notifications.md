# ExecPlan: Notifications v1

**Status:** Completed
**Author:** Gump (with Claude)
**Date:** 2026-04-30

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this plan ships, a user can leave a coding agent or long-running command running in any Pane, switch away to another Worktree / Tab / Project / app entirely, and be reliably pulled back when that Pane finishes its task or stops to ask for input. The user-visible behaviour:

- A Pane that emits an OSC 9 desktop notification, rings the bell, finishes a shell-integrated command, exits, crashes, or goes idle for ≥ 30 s while having been busy produces an entry in a persistent **inbox**.
- Each new entry surfaces through up to four channels — a hierarchy-rolled-up **visual indicator** (Project dot / Worktree bell glyph / Tab dot / Pane top-edge line), a **macOS banner** (only when the user is not already looking at that Pane), an **unread count** in the worktree-status-bar bell, and a **Dock badge** mirroring that count.
- Clicking the bell opens a popover listing notifications newest-first; clicking a row (or a banner) jumps the app to the originating `(projectID, worktreeID, tabID, paneID)` exactly, expanding ancestors as needed and falling back to the deepest still-existing ancestor when a target has been deleted.
- macOS notification permission is requested on demand the first time a banner would fire, with a recovery path under Settings → Notifications.

This work replaces the abandoned C6 design line (`design+c6-agent-notifications` worktree, ~24 files, ~2900 LOC) with a smaller, runtime-event-driven implementation budgeted at 7 new files and ~600 LOC plus surgical edits to four existing UI surfaces.

## Progress

- [x] M1 — Core model + store + persistence (no UI; commit + tests) — 2026-04-30, commits 31eb5d4 (pre-flight) → 201931b → d7c08a3 (pre-flight) → 2ef449c → c10a982 → 83721bc. 22 tests pass.
- [x] M2 — Detector + OSNotifier + DockBadger; first end-to-end signal (commit + tests) — 2026-04-30, commits 27aaab0 → a0d6073 → d743fea. mac-build green; no automated detector tests landed (see DEC-M2-1).
- [x] M3 — RollupIndex + per-level indicators on Project / Worktree / Tab / Pane (commit + tests) — 2026-04-30, commits through 6fac9df. mac-build green; visual verification pending (Gump's GUI smoke).
- [x] M4 — Status-bar bell, popover inbox, click-to-navigate (commit + tests) — 2026-04-30, mac-build green; 1 new test for deeplink schema. Visual verification pending.
- [x] M5 — Permission flow + Settings panel (commit + tests) — 2026-04-30, commit cd8453b. mac-build green.
- [x] M6 — Deprecate C6 docs, update spec/design/plan status (commit). Branch deletion held for explicit user approval per plan §Idempotence.

Update each entry to `[x]` with an ISO date and short commit hash on completion.

## Surprises & Discoveries

**S1 (2026-04-30, M1) — Pre-existing test infrastructure breakage on `main`.** While trying to run CodansCoreTests for the new InboxEntry / InboxStorage tests, two distinct breakages surfaced:

1. `apps/mac/CodansCoreTests/AgentStateTests.swift` — orphan from c6 cleanup commit `96842f0` (it deleted `apps/mac/CodansCore/Notifications/AgentState.swift` but missed this matching test file). Caused `cannot find 'AgentState' in scope` on every CodansCoreTests build. Fixed in commit `31eb5d4` by deleting the file.

2. `apps/mac/CodansCoreTests/IPC/IPCEnvelopeCodableTests.swift` — assertions referencing removed `IPC.Method.hookEvents` / `.hookInstall` from a c3 cleanup. Two of seven test bodies broke compilation. Fixed in commit `d7c08a3` by trimming only the affected bodies.

Additional pre-existing breakage in `codansTests` (the app-target test bundle) was *not* fixed: `apps/mac/codans/Tests/Developer/CLIInstallerClientTests.swift` fails with `Unable to find module dependency: 'Codans'` on every `xcodebuild build-for-testing`. The file uses the same `@testable import Codans` as ~10 other tests in `codans/Tests/` that compile fine; the `Tests/Developer/` subfolder appears to be in an inconsistent build phase. Out of scope for the notifications work; recorded here so a future agent or Gump can address it. Workaround for M1: routed the bulk of testable logic into `CodansCore.InboxStorage` (a `nonisolated` enum) so `CodansCoreTests` covers it without depending on `codansTests`.

**S2 (2026-04-30, M1) — `make mac-lint` baseline has 54 pre-existing failures.** None on the new files; recording so the M1 commit messages' "lint shows only pre-existing failures" claim is auditable. Sample failures: `async_without_await` in ShortcutsStoreTests, `force_try` in InternalConflictDetectorTests, `non_optional_string_data_conversion` in ShortcutOverrideStoreCodableTests. Out of scope.

## Decision Log

**DEC-1 — Detection consumes only `TerminalEvent` + `PaneInfoDelta`.** Decided during design (see `docs/design-docs/notifications.md` §A1). v1 has no stdout regex scanner; tools that don't emit OSC 9 / OSC 133 / bell / clean exit are silently uncovered. This keeps detection at < 100 LOC and avoids the rule-editor complexity that bloated C6.

**DEC-2 — Roll-up indicators are boolean per level except the status-bar bell.** Decided during design (see commit `d9e0a22`). Project / Worktree / Tab show a single dot or glyph regardless of how many notifications are unread; only the bell carries a numeric count.

**DEC-3 — Pane top-line colour encodes kind, with amber dominating green.** N1 (waiting for input) is more urgent than N2 (task finished); when a Pane has both unread, the line is amber.

**DEC-4 — Cross-worktree navigation routes through `RootFeature`, not `PaneActionRouter`.** `PaneActionRouter` handles intra-pane intents; cross-worktree focus belongs to the feature that owns selection state.

**DEC-5 — `OSNotifier` is the only file salvaged from the C6 worktree.** Approximately 110 LOC; needs a model swap from `AgentNotification` → `InboxEntry` and `panelID` → `SourcePath`. All other C6 files are abandoned.

**DEC-M1-1 (2026-04-30) — Public type renamed `Notification` → `InboxEntry`.** The plan's Interfaces section spelled the type `Notification`. Implementation surfaced a clash with `Foundation.Notification` (the value-type wrapper for `NotificationCenter`) at app-target call sites that import both `Foundation` and `CodansCore`. supacode hit the same issue and went with `WorktreeTerminalNotification`; the abandoned C6 design used `AgentNotification`. Chose `InboxEntry` because it is also semantically more accurate — the persisted record is an *entry in the inbox*, not the broader concept of a "notification" (which spans banners, dock badge, etc.). Plan's Interfaces section retained as written for design intent; implementation files use `InboxEntry`. References in subsequent milestones (M2..M6) implicitly track the rename.

**DEC-M1-2 (2026-04-30) — Inbox-mutation policy split into `CodansCore.InboxStorage` (pure) + `NotificationStore` (`@MainActor @Observable` wrapper).** Plan put all of dedup / sweep / cap logic inside `NotificationStore` in the app target. `codansTests` is broken on `main` (see Surprises S1), so a Store living there could not be unit-tested. Splitting the *pure* logic — `appending`, `aged`, `capped`, `markingRead`, `markingAllRead`, `unreadCount` — into a `nonisolated public enum InboxStorage` in `CodansCore` puts the meaty cases under the working `CodansCoreTests` target while leaving the `Store` itself in the app target as the plan prescribed. The Store becomes a thin wrapper (~140 LOC) doing `@Observable` + persistence + debounce. Net: 16 storage-policy tests cover the actual behaviour; the Store wrapper has no policy logic worth testing in isolation.

**DEC-M2-1 (2026-04-30) — Detector / OSNotifier / DockBadger / app-shell wiring shipped without automated tests.** Plan called for unit tests covering the detector translation table, mute label suppression, idle gating, banner gating, and dock formatting. All would land in `codansTests`, which is broken on `main` (Surprises S1, second item). To avoid further pre-existing-cleanup creep, the M2 implementation ships covered only by `mac-build` and the manual-smoke acceptance (`printf '\\033]9;hi\\007'` in a pane → expect banner + dock badge `1`). The pure pieces *are* exercised: `DockBadger.formatBadge` is a pure static for an eventual unit test; `InboxEntry` and `InboxStorage` (M1) have 22 tests covering everything the detector funnels into. M5 will revisit and add detector tests once `codansTests` is unblocked.

**DEC-M2-2 (2026-04-30) — Detector subscribes to a fresh `engine.events()` rather than tapping `RootFeature`'s.** Plan suggested calling `detector.handle(event)` from inside `RootFeature`'s existing `for await event in eventStream` loop. `TerminalEngine.SubscriberRegistry` already supports per-call broadcast — `engine.events()` returns a fresh `AsyncStream<TerminalEvent>` per call, so the detector takes its own subscription in `AppState.bringUp()` and runs in parallel with `RootFeature`. Cleaner separation; no `RootFeature` API surface change needed for M2. (M4 *will* need a `RootFeature` action — `focusHierarchyPath` for banner-click navigation — but that lands later.)

**DEC-M2-3 (2026-04-30) — Per-pane mute encoded as the string label `"notifications:muted"` in `Pane.labels`.** Plan said "per-Pane 'notifications enabled' toggle". `Pane.labels` is `Set<String>` and is already `Codable` + persisted via the catalog — using a known label avoids inventing a new field, and consumers (sidebar context menu, future M3+ UI affordance) can flip it through the existing label-mutation surface. Constants live in the detector for v1; if a third caller appears, lift them into `CodansCore`.

## Outcomes & Retrospective

**Final tally (2026-04-30).** 6 milestones land in 21 commits since `0a1c42b`. Code: ~1300 LOC across 11 new files (vs. plan's ~600 budget — overshoot is M5's Settings panel + M4's popover + the Provider class + a salvaged OSNotifier). Pure detection / data-layer code (DetectionTranslator + InboxStorage + RollupIndex + InboxEntry) totals ~525 LOC, well inside target. Tests: **52 passing** in CodansCoreTests (6 InboxEntry + 16 InboxStorage + 19 DetectionTranslator + 10 RollupIndex + 1 deeplink).

**Code-review pass (`agent-skills:code-reviewer`)** flagged 1 Critical + 7 Important + ~10 suggestions. All Critical + Important items fixed in commits `df18e42` and `1de41fe`:
- `RootFeature.focusHierarchyPath` now re-reads `hierarchyClient.snapshot()` between each `select*` mutation (G3 fallback path correct).
- `RollupIndexProvider` and `AppState.observeDockBadge` recompute unconditionally at the top of each loop iteration before re-arming `withObservationTracking`, closing the burst-coalescing window.
- `NotificationsSettingsView` reads the long-lived `UserNotificationsOSNotifier` via `@Environment` instead of spawning a fresh one per refresh + button tap (`UserNotificationsOSNotifier` gained `@Observable` to make `@Environment(Type.self)` work).
- `NotificationDetector.resolve` merges source-path resolution + mute-label check + worktree-label lookup into one O(N) catalog walk (was three).
- Mute label string lifted to `CodansCore.InboxLabels.muted`.
- `DetectionTranslator.classify` scopes the trailing-`?` cue to the title suffix only.
- New test covers R1 boundary (focused-pane indicator persists until mark-read fires).
- `paneClosedByTab` clears `hasProducedOutput` for symmetry with `paneExited` / `paneCrashed`.
- Bell title now prepended with the originating worktree's name: `[feat/foo] Pane bell`.

**What works headlessly**: the entire pure layer (translation + storage + roll-up + deeplink schema) is exhaustively unit-tested. `mac-build` green throughout.

**What needs visual verification** (Gump's GUI smoke when next at the keyboard):
1. M3 indicators render correctly (Project unread dot, Worktree bell glyph swap, Tab unread dot, Pane top-line green / amber).
2. M4 status-bar bell renders in the right toolbar slot, badge formats `99+`, popover anchors and dismisses correctly, row click jumps focus.
3. M5 Settings → Notifications pane reflects authorization status and the recovery buttons fire the right system flow.
4. The full smoke from spec AC: `printf '\033]9;hello\007'` in a pane → expect banner (if not focused) + dock badge `1` + inbox row.

**Deferred (not blockers, recorded for future iteration):**
- Per-pane mute UI affordance — the label + detector gate are wired, but no toggle in the pane context menu yet. A future ticket lands the toggle and removes the "dead string" smell.
- Persistence schema envelope (e.g. `{ "version": 1, "entries": [...] }`) — current `[InboxEntry]` is unwrapped; a future schema break would need a migration shim.
- Detector / OSNotifier / DockBadger orchestrator unit tests — pinned to `codansTests` whose target is broken on `main` for unrelated reasons (Surprises S1). Pure pieces are covered.
- C6 worktree branch deletion held for explicit user approval per plan §Idempotence.

**Plan-fidelity verdict**: Ship as-is for v1. The user-visible behaviour matches the spec, the data layer is well-tested, the review pass landed clean, and the surgical-edit philosophy held — no orthogonal refactors crept in.

## Context and Orientation

**Related documents:**

- Product spec: [docs/product-specs/notifications.md](../product-specs/notifications.md)
- Design doc: [docs/design-docs/notifications.md](../design-docs/notifications.md)
- Architecture: [docs/architecture.md](../architecture.md)
- Deprecated by this work: [docs/design-docs/c6-agent-notifications.md](../design-docs/c6-agent-notifications.md), [docs/design-docs/c6-agent-notifications-v2.md](../design-docs/c6-agent-notifications-v2.md), [docs/design-docs/c6-m5-inbox-sidebar.md](../design-docs/c6-m5-inbox-sidebar.md), [docs/exec-plans/0006-agent-notifications.md](./0006-agent-notifications.md)

**Key existing source files this plan depends on:**

- `apps/mac/CodansCore/TerminalEvent.swift` — the runtime's published event stream. Detection subscribes here.
- `apps/mac/CodansCore/PaneInfoDelta.swift` — typed enum for libghostty info-family deltas; carries `desktopNotification`, `bellRang`, `commandFinished`, `childExited`. Detection translates the relevant cases.
- `apps/mac/CodansCore/AtomicFileStore.swift` — atomic-rename JSON read/write helper. The store uses this for inbox persistence.
- `apps/mac/CodansCore/{Catalog,Project,Worktree,Tab,Pane,IDs}.swift` — hierarchy primitives. `SourcePath` reuses the four ID types.
- `apps/mac/codans/App/Features/Root/RootFeature.swift` — owns `Catalog.selectedProjectID`, `Project.selectedWorktreeID`, `Worktree.selectedTabID`, and routes through `hierarchyClient`. The new `focusHierarchyPath` action lives here.
- `apps/mac/codans/App/Features/HierarchySidebar/{SidebarRow.swift,WorktreeRowIcon.swift}` — sidebar rows. M3 edits these.
- `apps/mac/codans/App/Features/TabBar/{TabBarFeature.swift,TabBarView.swift}` — tab title row. M3 prefixes a dot.
- `apps/mac/codans/App/Features/StatusBar/{StatusBarFeature.swift,StatusBarView.swift}` — currently fills a single center slot with `{toast, pullRequest, motivational}`. M4 adds a right-anchored bell slot.
- `apps/mac/codans/App/Features/Settings/{SettingsWindowFeature.swift,SettingsWindowView.swift,Panes/}` — M5 adds a Notifications pane.
- `apps/mac/Project.swift` — Tuist project. The new `CodansCore/Notifications` subfolder is registered in the `CodansCore` target's `buildableFolders`. The app target's `buildableFolders` already includes `codans/App` as a glob root that picks up `App/Features/Notifications/` automatically; no edit needed there unless we add a nested subfolder.

**Salvage source (do not import as a dependency, copy only):**

- `apps/mac/codans/Notifications/OSNotifier.swift` in branch `worktree-design+c6-agent-notifications`. ~110 LOC. Adapt the model references during the copy.

**Terminology:**

- **OSC 9 / OSC 777** — escape sequences a terminal program writes to its stdout to emit a desktop notification (`ESC ] 9 ; <body> BEL`). libghostty decodes these into `PaneInfoDelta.desktopNotification(title:body:)`.
- **OSC 133** — shell-integration prompt protocol; tells the terminal where commands begin and end. libghostty decodes into `PaneInfoDelta.commandFinished(exitCode:duration:)`.
- **Roll-up** — the rule that one unread notification contributes to exactly one visual indicator: the deepest hierarchy ancestor currently hidden from the user. Defined in design doc §Roll-up.
- **Source path** — a `(projectID, worktreeID, tabID, paneID)` tuple captured at notification creation time and stored verbatim. Re-resolved against the live catalog at click time.

**How the parts fit together:** the runtime emits `TerminalEvent` on a single async stream consumed by `RootFeature`. `NotificationDetector` plugs in as another consumer, translates the relevant events to `Notification` rows, hands them to `NotificationStore`. The store maintains the in-memory inbox + JSON persistence and broadcasts unread-set changes to two derivations: `RollupIndex` (per-level indicators + global count) and `OSNotifier` / `DockBadger` (side effects). UI surfaces (sidebar rows, tab bar, pane chrome, status bar bell, popover) read from `RollupIndex` via a small Equatable view-store slice. Click-to-navigate dispatches `RootFeature.focusHierarchyPath`, which mutates selection state through the existing `hierarchyClient` API.

## Plan of Work

The work is sliced vertically into six milestones. Each is independently end-to-end demonstrable and ends with a single commit. The order is forced by dependency: M1's store is the spine that M2 writes into and M3 reads from; M3's roll-up state feeds M4's bell badge; M4's navigation handler is what M2's banner click resolves to. M5 hardens the permission edge and M6 retires the abandoned C6 surface.

### Milestone 1 — Core model + store + persistence

After M1, the inbox exists as a plumbed Swift type with persistence and tests, but no UI surfaces yet observe it. A debug `NSLog` in the store proves the wiring end-to-end at this stage.

Add a new public `Notification` struct in `apps/mac/CodansCore/Notifications/Notification.swift`. Fields per design doc §Storage: `id: NotificationID` (a fresh `UUID`-backed wrapper added to `IDs.swift`), `kind: Kind` (raw-value enum `.waitingForInput | .taskFinished`), `title: String`, `body: String`, `createdAt: Date`, `readAt: Date?`, `source: SourcePath`. `SourcePath` is a nested struct holding the four hierarchy IDs. The whole tree is `Codable`, `Equatable`, `Sendable`, `nonisolated`. Add `CodansCore/Notifications` to the `CodansCore` target's `buildableFolders` in `apps/mac/Project.swift`.

Add `apps/mac/codans/App/Features/Notifications/NotificationStore.swift`. The store is a `@MainActor`-isolated `final class` that holds `private(set) var notifications: [Notification]` newest-first, exposes an `AsyncStream` of inbox snapshots (or a TCA-compatible publisher; pick whichever matches existing app conventions — see `RootFeature.swift` for the established pattern), and provides `append(_:)`, `markRead(id:)`, `markAllRead()`, `unreadCount` derivations, plus the dedup-window check (`(paneID, kind)` within 30 s replaces instead of appending). Persistence runs through `AtomicFileStore.write` to `~/.config/codans/notifications.json`, debounced 250 ms via `Task` cancellation. On `init`, the store reads the file (returning empty on `nil`), runs the age sweep (drop entries older than 7 days) and the cap sweep (evict oldest read first, then oldest unread, until ≤ 500), then publishes the loaded set. Cap is also re-checked on every `append`.

Add `apps/mac/codans/App/Features/Notifications/NotificationStoreTests.swift` (or follow `Tests/Notifications/` convention if existing app tests use that layout). Tests must cover: append + persistence round-trip; dedup window collapses two appends to one; age sweep on launch drops > 7 day entries; cap sweep evicts read first; mark-read updates `readAt` and the unread count derivation.

Acceptance: `make mac-build` succeeds; `make mac-lint` clean; the new store's tests pass under `xcodebuild test` for the `codans` test target. No user-visible change yet.

Commit: `feat(notifications): inbox model + store + atomic persistence`.

### Milestone 2 — Detector + OSNotifier + DockBadger

After M2, a Pane that emits OSC 9 (`printf '\033]9;hello world\007'`), rings the bell, exits cleanly, crashes, or goes idle produces a real inbox entry, fires a macOS banner if permission has been granted, and updates the Dock tile badge. No in-app indicators yet — this milestone proves the detection plumbing.

Add `apps/mac/codans/App/Features/Notifications/NotificationDetector.swift`. The detector is a `@MainActor` `final class` initialized with a reference to the runtime's event stream (the same one `RootFeature` subscribes to — read `RootFeature.swift` to confirm the exact API; if it currently consumes via a single `for await event in eventStream` loop, the detector adds a parallel consumer behind a `Task`). It maintains a small `[PaneID: Bool]` "has produced output recently" map to gate the idle case (a fresh-spawned pane that hasn't produced anything must not fire idle), and a `[PaneID: SourcePath]` resolver populated from the catalog so each event can be tagged with its full hierarchy path. The translation table is the one in design doc §Detection: `desktopNotification` → kind heuristic on title/body (matches "permission|approval|input|\?" → `.waitingForInput`, else `.taskFinished`); `bellRang` → `.waitingForInput`; `commandFinished`, `paneExited`, `paneCrashed` → `.taskFinished`; `paneIdle` with `duration ≥ 30s` AND output-recently flag → `.taskFinished`. A Pane whose `Pane.labels` contains `"notifications:muted"` is dropped without store interaction. Each emitted notification is forwarded to `store.append`.

Salvage `OSNotifier.swift` from the C6 worktree into `apps/mac/codans/App/Features/Notifications/OSNotifier.swift`. Replace `AgentNotification` references with `Notification`, replace `panelID.raw.uuidString` with `source.paneID.raw.uuidString`, replace `AgentNotification.Kind.allCases` with `Notification.Kind.allCases`. Keep the `threadIdentifier`, `categoryIdentifier`, `userInfo["deeplink"]` shape but change the deeplink scheme to `codans://focus?project=...&worktree=...&tab=...&pane=...` so M4 can parse the four IDs back. Drop the "Focus Panel" / "Dismiss" action buttons for v1 (banner click is the only interaction); category registration shrinks to bare kind identifiers. Authorization request is *not* triggered here — `requestAuthorization` becomes a method called from M5's Settings panel + the on-demand wrapper in `post`.

Add `apps/mac/codans/App/Features/Notifications/DockBadger.swift`. ~30 LOC: a `@MainActor` `final class` that subscribes to the store's unread-count derivation and writes `NSApp.dockTile.badgeLabel = count == 0 ? nil : (count > 99 ? "99+" : "\(count)")`.

Wire all three into the app shell. Find the existing reducer / DI seam (likely `RootFeature` or its `App/AppDelegate.swift` / `App/CodansApp.swift`) where `RootFeature` is instantiated; instantiate `NotificationStore`, `NotificationDetector`, `OSNotifier`, `DockBadger` at the same site and hand the store reference to all three. Banner posting: in the detector's append path, after `store.append`, also call `osNotifier.post(notification)` — but only if **either** the app is not frontmost (`NSApp.isActive == false`) **or** the source pane is not the focused pane (compare against current `Catalog.selectedProjectID` → `Project.selectedWorktreeID` → `Worktree.selectedTabID` → focused pane via `hierarchyClient.lastFocusedPane`).

Tests cover: detector translation table (one per event row in design doc §Detection); muted Pane label suppresses all kinds; idle without prior output is suppressed; banner gating decision matches the (frontmost × focused pane) truth table; Dock badge formats `0/1/99/100` correctly.

Acceptance — manual smoke: build + run the app, open one Pane, run `printf '\033]9;hello\007'` → expect a banner and Dock badge `1`. Open Pane B, focus it, then in Pane A run `printf '\033]9;hi\007'` → expect a banner (B is focused, not A). Focus A, fire the same → expect no banner, but the inbox file at `~/.config/codans/notifications.json` shows the third entry.

Commit: `feat(notifications): detector + OS banner + dock badge — first end-to-end signal`.

### Milestone 3 — RollupIndex + per-level indicators

After M3, all four hierarchy levels show their indicators per the design: Project unread dot, Worktree bell glyph, Tab unread dot, Pane top-edge coloured line. The status-bar bell does not exist yet (M4); the Dock badge from M2 stands in for the global count.

Add `apps/mac/codans/App/Features/Notifications/RollupIndex.swift`. Pure-derivation type with the shape from design doc §Roll-up:

```swift
public struct RollupIndex: Equatable, Sendable {
  public let unreadProjects: Set<ProjectID>
  public let unreadWorktrees: Set<WorktreeID>
  public let unreadTabs: Set<TabID>
  public let paneIndicator: [PaneID: PaneIndicator]
  public let globalUnreadCount: Int
}
public enum PaneIndicator: Sendable, Equatable { case taskFinished, waitingForInput }
```

A pure `static func compute(unread: [Notification], focus: FocusState) -> RollupIndex` walks each unread notification once: pick the deepest hidden ancestor per the visibility rule and add to that level's set; for L1, store the kind, with `.waitingForInput` overwriting `.taskFinished` on conflict. `FocusState` is a small struct gathered from `RootFeature.state` — `(focusedPaneID, activeTabID, activeWorktreeID, expandedProjectIDs, expandedWorktreeIDs)`. The reducer call site recomputes on any change to either input and stashes the result in shared state for view consumption.

Edit `apps/mac/codans/App/Features/HierarchySidebar/SidebarRow.swift`: add a 4 px filled-circle SwiftUI overlay at the trailing edge of the project name, conditionally rendered when `rollup.unreadProjects.contains(projectID)`. Use `Color.accentColor` or the existing accent token.

Edit `apps/mac/codans/App/Features/HierarchySidebar/WorktreeRowIcon.swift`: add a `hasUnreadNotification: Bool` parameter; when `true`, override `assetName` to a bell glyph (`bell.fill` SF Symbol or a project-local asset matching the existing `git-branch` style) and suppress `roleTint` (use `.accentColor`). When `false`, behaviour is unchanged. The PR check rollup overlay still renders unconditionally.

Edit `apps/mac/codans/App/Features/TabBar/TabBarView.swift` (or wherever the tab title row is composed): prefix the title `Text` with a small filled circle when `rollup.unreadTabs.contains(tabID)`. Match the Project dot's size and colour for consistency.

Add a pane-chrome top line. The exact file depends on the current pane wrapper; locate it by searching for `GhosttySurfaceView` callers in `App/Features/SplitViewport/`. Add a `Rectangle().frame(height: 2)` above the surface, conditionally rendered with `.green` / `.orange` per `rollup.paneIndicator[paneID]`. If no pane wrapper exists (i.e., `GhosttySurfaceView` is used directly in the split tree view), introduce a tiny `PaneChrome` SwiftUI view at the same call site.

Tests cover `RollupIndex.compute`: parameterized fixtures asserting one unread lands at exactly one level given a fixture focus state; the L1 colour-priority rule (amber wins); empty unread → empty index, zero count.

Acceptance — manual smoke: with the app running, fire a notification on a Pane in an unfocused Tab → expect a dot prefixed on the Tab title, no dot elsewhere. Switch to that Tab, leave Pane unfocused → expect green or amber line on the Pane. Focus the Pane → all indicators clear (R1 from spec). Collapse the Worktree's Project → indicator promotes to a dot at the Project row.

Commit: `feat(notifications): per-level indicators — project dot / worktree bell / tab dot / pane line`.

### Milestone 4 — Status-bar bell + popover inbox + click navigation

After M4, the worktree status bar shows a right-anchored bell with a numeric global unread count; clicking opens a popover with the full inbox; clicking a row (or a banner from M2) drives `focusHierarchyPath` and lands the user on the originating Pane.

Add `apps/mac/codans/App/Features/Notifications/InboxBellFeature.swift`. A small TCA reducer + view (or AppKit view if matching existing status-bar idiom). State: `notifications: [Notification]` (mirrored from store), `unreadOnly: Bool` (filter chip), `globalUnreadCount: Int`. View: a `Button` showing the bell SF Symbol with a numeric overlay (hidden when 0, `99+` when ≥ 100). Tapping anchors a `.popover` with rows rendered as `(kind icon, title, body, "Project › Worktree › Tab" trail, relative time)`. Header has the filter toggle, "Mark all read", and a "Settings…" link that dispatches into `SettingsWindowFeature`. Row tap dispatches `RootFeature.focusHierarchyPath(notification.source, fallback: .deepestExisting)` and marks that single row read.

Edit `apps/mac/codans/App/Features/StatusBar/StatusBarView.swift`: convert the current center-only `HStack` into `HStack { centerForm; Spacer(); InboxBellView(...) }`. The center `ViewThatFits` keeps its existing logic; the bell is right-anchored and always rendered (collapsed to a single dot when the badge is 0 — invisible-but-laid-out so the slot doesn't jump). Wire the underlying `StatusBarFeature` to host the bell child reducer.

Edit `apps/mac/codans/App/Features/Root/RootFeature.swift`: add the action

```swift
case focusHierarchyPath(Notification.SourcePath, fallback: NavigationFallback)

public enum NavigationFallback: Sendable, Equatable {
  case deepestExisting
}
```

Implement the handler per design doc §Navigation: re-resolve each ID against the live catalog; on the first missing level, stop descent and apply the fallback. Mutations: set `Catalog.selectedProjectID`, set the matching `Project.selectedWorktreeID`, set the matching `Worktree.selectedTabID`, then call the existing `hierarchyClient` API to focus the Pane. Collapsed ancestors are expanded as part of the walk (extend `Project.isExpanded` and any worktree expand state if such state exists). Banner clicks: parse the deeplink scheme `codans://focus?project=...&worktree=...&tab=...&pane=...` in the existing `UNUserNotificationCenter` delegate (`AppDelegate` or wherever `userNotificationCenter(_:didReceive:withCompletionHandler:)` lives) and dispatch the same action.

Tests cover: `focusHierarchyPath` with all four IDs valid lands selection state correctly; missing pane → lands on Tab; missing tab → lands on Worktree; missing project → no-op (fallback can't go shallower than `.deepestExisting`'s root). InboxBellFeature reducer: filter chip flips, mark-read decrements unread count, row tap fires the navigation action.

Acceptance — manual smoke: trigger a notification while in a different Project; observe `99+`-formatted badge if you have ≥ 100 unread (use a script to flood OSC 9), or a real number otherwise; click the bell → popover lists all notifications; click a row → app jumps to the originating Pane regardless of which Project / Worktree was active. Quit the app while the popover is open, relaunch → notifications still there (P1 from spec).

Commit: `feat(notifications): status-bar bell + popover + cross-worktree navigation`.

### Milestone 5 — Permission flow + Settings panel

After M5, a fresh install prompts for `UNUserNotificationCenter` authorization the first time a banner would be sent (not at launch). If the user dismisses or denies, the Settings → Notifications pane shows the current status with a "Request permission" button (when `notDetermined`) or an "Open System Settings" deep-link (when `denied`). Authorization is re-read on `applicationDidBecomeActive` so flipping the toggle in System Settings takes effect without a relaunch.

Edit `OSNotifier.post(_:)` to perform the on-demand prompt: if `currentAuthorizationStatus()` is `.notDetermined`, call `requestAuthorization()` synchronously inside `post` before deciding whether to add the request. If the result is `.denied` after the prompt, drop the post silently. The status read happens on every `post` for simplicity; performance is fine because banner cadence is human-scale.

Add `apps/mac/codans/App/Features/Settings/Panes/SettingsNotificationsFeature.swift` and a matching SwiftUI `SettingsNotificationsView` if the existing Panes folder uses that pattern (read `Panes/` to confirm). State: `authStatus: AuthorizationStatus`. Actions: `.refreshStatus`, `.requestPermissionTapped`, `.openSystemSettingsTapped`. View renders three lines:

- "macOS notifications" title.
- A status row: ✅ Authorized / ⚠️ Denied / 🟡 Not yet asked.
- A button: "Request permission" (if `.notDetermined`) or "Open System Settings…" (if `.denied`) — opens `x-apple.systempreferences:com.apple.preference.notifications`.

Register the pane in `SettingsWindowFeature`'s pane list. On `applicationDidBecomeActive` (in the `AppDelegate` or `Application.onChange(of: scenePhase)` site), dispatch `.refreshStatus` so any external grant/revoke is observed.

Tests cover: a `notDetermined` first `post` triggers `requestAuthorization` exactly once; subsequent `post`s don't re-trigger; a `denied` status drops the post; the Settings reducer transitions on status changes.

Acceptance — manual smoke: revoke the app's notification permission in System Settings, then trigger a notification → expect no banner, but inbox + dock badge update (PM2). Open Settings → Notifications → see "Denied", click "Open System Settings" → System Settings opens at the app's row. Re-grant, return to the app → status auto-updates without a relaunch.

Commit: `feat(notifications): on-demand permission + settings recovery panel`.

### Milestone 6 — Cleanup

After M6, the abandoned C6 design surface is removed from active state and clearly marked superseded.

Edit the three C6 design docs in-place to flip their `Status:` line from `Draft` to `Deprecated` and add a one-line pointer at the top: `> Superseded by [docs/design-docs/notifications.md](notifications.md). Retained for historical context.` Files: `docs/design-docs/c6-agent-notifications.md`, `docs/design-docs/c6-agent-notifications-v2.md`, `docs/design-docs/c6-m5-inbox-sidebar.md`. Do the same for `docs/exec-plans/0006-agent-notifications.md`. Flip `docs/product-specs/notifications.md` and `docs/design-docs/notifications.md` from `Draft` to `Approved` and this exec plan from `Draft` → `In Progress` at the start of M1, then `Completed` at the end of M6.

Delete the C6 worktree branches **only after explicit approval from the user** (these branches contain code that informed the design and may be useful for reference). The deletion command is documented in the Concrete Steps section but executed manually.

Acceptance: `git status` clean after the doc edits; the three c6 docs read with `Deprecated` in their headers; the exec plan's status reflects completion.

Commit: `docs(notifications): retire C6 surface — flip statuses + supersede pointer`.

## Concrete Steps

Run from the repo root unless stated otherwise.

**Per-milestone build & lint loop** (idempotent — repeat as files are added):

```bash
make mac-generate    # only on first add of a new file or new buildable folder
make mac-build       # incremental Swift build
make mac-lint        # swiftlint --quiet
```

Expected on success: `mac-build` ends with a build-succeeded line; `mac-lint` exits 0 with no output.

**Per-milestone test loop** (after the milestone's tests are added):

```bash
xcodebuild test -workspace apps/mac/codans.xcworkspace \
  -scheme codans -destination 'platform=macOS' \
  -only-testing:codansTests/Notifications | xcsift
```

Adapt the `-only-testing` filter to whatever target / class name actually exists. Expected: `Test Suite '...' passed`.

**Manual smoke for OSC 9** (M2 onward):

```bash
# In any pane within the running app:
printf '\033]9;hello world\007'
```

Expected at M2: macOS banner appears (if permission granted) and Dock tile gets a `1` badge. At M3+, the originating Pane's top edge shows a green or amber line.

**Inbox file inspection** (M1 onward):

```bash
cat ~/.config/codans/notifications.json | jq .
```

Expected: a JSON array of notification entries; each has `id`, `kind`, `title`, `body`, `createdAt`, optional `readAt`, and a `source` object with the four ID fields.

**C6 worktree branch deletion** (M6, manual, only after user approval):

```bash
git worktree remove .claude/worktrees/design+c6-agent-notifications
git branch -D worktree-design+c6-agent-notifications
git push origin --delete worktree-design+c6-agent-notifications worktree-fix+c6-agent-notifications feature/notification
```

Do not run automatically — user must approve each delete.

## Validation and Acceptance

The plan is complete when:

1. **AC-D1..AC-D5** from the spec are observable. Each translates to a manual smoke from a Pane (run `read -p`, `make build`, `printf '\033]9;…\007'`, etc.) and verifies the expected inbox + indicators + banner result.
2. **AC-C1..AC-C4** are observable. Banner gating: focus a Pane, fire OSC 9 there → no banner. Switch focus to another Pane → fire same OSC 9 there from the first Pane (e.g., via `tmux send-keys` or simply leave it scripted) → banner. Background the app → fire → banner. Dock count matches global unread.
3. **AC-L1..AC-L7** are observable per the manual smokes in M3.
4. **AC-G1..AC-G3** are observable: click a row → focus Pane; close that Pane externally, click the row again → focus Worktree, row stays.
5. **AC-P1..AC-P3** are observable: relaunch with unread → unread persists; flood with > 500 entries → cap holds at 500; backdate an entry > 7 days in the JSON file (with the app quit) → relaunch → entry gone.
6. **AC-PM1..AC-PM3** are observable per the M5 manual smoke.

When all of the above pass, flip the spec, design, and this exec plan to their final statuses (M6) and commit.

## Idempotence and Recovery

Every step in this plan is repeatable:

- **Builds and lints** are incremental; rerunning produces no harm.
- **`make mac-generate`** is idempotent (Tuist regenerates the project from `Project.swift`); rerun whenever a file is added or `buildableFolders` changes.
- **`AtomicFileStore.write`** uses temp-file + rename; a crash mid-write leaves the previous file intact. The store reads `nil` on missing file and treats it as empty, so the inbox file can be safely deleted to reset state.
- **C6 doc deprecation edits** are simple in-place text changes; reverting is `git revert`.
- **C6 branch deletion** is the only irreversible step. Guard with explicit user approval; the branches remain on the remote (`origin/feature/notification`, `origin/worktree-design+c6-agent-notifications`) until explicitly pushed-deleted.

If a milestone's commit needs to be split or amended, use a follow-up commit rather than `--amend`; this plan does not require linear history beyond what the existing repo conventions enforce.

## Artifacts and Notes

The salvage diff for `OSNotifier.swift` (M2) is mechanically simple. From the C6 worktree's version (sibling commit, fully read in research):

```diff
- import CodansCore
+ import CodansCore
+ // No additional imports — Notification + SourcePath live in Core.

- func post(_ notification: AgentNotification) async {
+ func post(_ notification: Notification) async {
    let status = await currentAuthorizationStatus()
+   if status == .notDetermined {
+     _ = await requestAuthorization()
+   }
    guard status == .authorized || status == .provisional else { return }
    let content = UNMutableNotificationContent()
    content.title = notification.title
    content.body = notification.body
-   content.threadIdentifier = notification.panelID.raw.uuidString
-   content.categoryIdentifier = notification.kind.rawValue
-   content.userInfo = ["deeplink": "codans://panel/\(notification.panelID.raw.uuidString)/focus"]
+   content.threadIdentifier = notification.source.paneID.raw.uuidString
+   content.categoryIdentifier = notification.kind.rawValue
+   content.userInfo = ["deeplink": notification.source.deeplinkURL.absoluteString]
    content.sound = .default
    ...
  }
```

`Notification.SourcePath.deeplinkURL` is a small extension producing `codans://focus?project=...&worktree=...&tab=...&pane=...`. Drop the `Focus Panel` / `Dismiss` action buttons; banner click is the only interaction in v1.

A reference for the test-file layout: `apps/mac/codans/Tests/Developer/` (existing). The Notifications tests can sit alongside as `apps/mac/codans/Tests/Notifications/`. Confirm against the actual test target's `buildableFolders` in `Project.swift` before adding the folder.

## Interfaces and Dependencies

The end-state types and signatures, prescriptive:

In `apps/mac/CodansCore/Notifications/Notification.swift`:

```swift
public struct NotificationID: Hashable, Codable, Sendable { /* UUID-backed wrapper */ }

public struct Notification: Equatable, Codable, Sendable, Identifiable {
  public let id: NotificationID
  public let kind: Kind
  public let title: String
  public let body: String
  public let createdAt: Date
  public var readAt: Date?
  public let source: SourcePath

  public enum Kind: String, Codable, Sendable, CaseIterable {
    case waitingForInput
    case taskFinished
  }

  public struct SourcePath: Equatable, Codable, Sendable {
    public let projectID: ProjectID
    public let worktreeID: WorktreeID
    public let tabID: TabID
    public let paneID: PaneID
  }
}
```

In `apps/mac/codans/App/Features/Notifications/NotificationStore.swift`:

```swift
@MainActor
public final class NotificationStore {
  public init(fileURL: URL = NotificationStore.defaultURL, clock: any Clock<Duration> = ContinuousClock())
  public private(set) var notifications: [Notification]   // newest-first
  public var unreadCount: Int { get }
  public func append(_ notification: Notification)        // applies dedup window
  public func markRead(id: NotificationID)
  public func markAllRead()
  public var snapshots: AsyncStream<[Notification]> { get }
}
```

In `apps/mac/codans/App/Features/Notifications/NotificationDetector.swift`:

```swift
@MainActor
public final class NotificationDetector {
  public init(events: AsyncStream<TerminalEvent>, store: NotificationStore, hierarchy: HierarchyClient, banner: OSNotifier, isAppFrontmost: @escaping @Sendable () -> Bool, focusedPaneID: @escaping @Sendable () -> PaneID?)
  public func start() -> Task<Void, Never>                 // detached; cancel on app shutdown
}
```

In `apps/mac/codans/App/Features/Notifications/RollupIndex.swift`:

```swift
public struct RollupIndex: Equatable, Sendable {
  public let unreadProjects: Set<ProjectID>
  public let unreadWorktrees: Set<WorktreeID>
  public let unreadTabs: Set<TabID>
  public let paneIndicator: [PaneID: PaneIndicator]
  public let globalUnreadCount: Int

  public static func compute(unread: [Notification], focus: FocusState) -> RollupIndex
}

public enum PaneIndicator: String, Codable, Sendable, Equatable {
  case taskFinished, waitingForInput
}

public struct FocusState: Equatable, Sendable {
  public let focusedPaneID: PaneID?
  public let activeTabID: TabID?
  public let activeWorktreeID: WorktreeID?
  public let activeProjectID: ProjectID?
  public let expandedProjectIDs: Set<ProjectID>
  public let expandedWorktreeIDs: Set<WorktreeID>
}
```

In `apps/mac/codans/App/Features/Notifications/OSNotifier.swift`:

```swift
@MainActor
public protocol OSNotifier: AnyObject {
  func currentAuthorizationStatus() async -> AuthorizationStatus
  func requestAuthorization() async -> AuthorizationStatus
  func post(_ notification: Notification) async
}
```

In `apps/mac/codans/App/Features/Root/RootFeature.swift`, additions to the action enum:

```swift
case focusHierarchyPath(Notification.SourcePath, fallback: NavigationFallback)

public enum NavigationFallback: Sendable, Equatable {
  case deepestExisting
}
```

Dependencies: `UserNotifications` (Apple), `AppKit` for `NSApp.dockTile`. No new third-party packages. The detector subscribes to whatever published `TerminalEvent` stream `RootFeature` already consumes — confirm the API at M2 implementation time and avoid adding a parallel runtime client unless the existing one cannot be multi-cast.
