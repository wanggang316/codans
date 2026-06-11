# Design Notes: C6 M5 — InboxSidebar UI

**Status:** Deprecated (2026-04-30 — superseded by [notifications.md](notifications.md))
**Author:** Gump (with Claude)
**Date:** 2026-04-20

> **Superseded by [docs/design-docs/notifications.md](notifications.md).**
> v1 of the user-visible notification system uses a status-bar bell +
> popover, not a sidebar inbox route. Retained here for historical
> context.

**Implementation note:** 0007 M3 landed DEC-2 option (b) — leading-column
mode-swap between `HierarchySidebarView` and the C6 inbox. The sketch's
preferred option (c) trailing overlay was not adopted; this sketch now
describes the as-built choice. See [exec plan 0006 §M5 Outcomes](
../exec-plans/0006-agent-notifications.md) for the delivered files.

Advance notes on the M5 SwiftUI + TCA integration so the implementation
can land quickly once the TCA shell is available. No code yet — just
interface shapes, placement, and open decisions.

## Scope

M5 delivers the user-visible surface: a right-side slide-in sidebar listing
every `AgentNotification`, filter chips, swipe-dismiss, deeplink-on-click,
and the settings toggles for `MuteSettings`. All underlying services
(`InboxStore`, `SettingsStore`, `NotificationCoordinator`) are already
shipped and tested. M5 wires them into the 0007 TCA feature tree and
writes the SwiftUI views.

## Sidebar slot — decision deferred to 0007

This sketch originally assumed a **trailing overlay slide-in** (320pt
pane, `.transition(.move(edge: .trailing))`) cohabiting with whatever
primary sidebar + detail 0007 lands. That is a **third option** alongside
the two 707A645A outlined for the root composition:

- **(a)** Three-column `NavigationSplitView` (primary hierarchy sidebar +
  inbox as a second column + detail).
- **(b)** Root-level mode swap (toggle primary sidebar between
  `HierarchySidebar` and `InboxSidebar` depending on a mode selector).
- **(c)** *This sketch's preferred option* — trailing overlay that
  coexists with (a)/(b), triggered by the toolbar bell / ⌘⇧N and
  doesn't steal the primary sidebar slot.

Implementation preference: (c). It matches the design doc's "slide-in
sidebar" language, avoids fighting whatever primary sidebar 0007 picks,
and keeps the inbox reachable without a mode switch. Fallback if (c)
doesn't compose cleanly with 0007's window-chrome: (b) — swap in
`InboxSidebar` as the primary when the user requests it.

**Hard alignment deferred to 0007 M2/M3 landing.** Once `RootFeature`
surfaces stabilise, this sketch gets another pass and the final slot
is picked. The view + reducer interfaces below are slot-agnostic.

## What lands

Under `apps/mac/codans/Notifications/Views/`:

- `InboxSidebar.swift` — root view. 320pt pane. Entry animation TBD
  per §Sidebar slot above (overlay transition vs. primary-sidebar
  swap). Bound to a `@Bindable` `InboxViewModel`.
- `InboxRow.swift` — single-row cell. Agent avatar (32pt circle with
  first letter uppercase), title, body (1 line, truncated to the cell),
  provenance (Project · Worktree · Tab · Pane), relative `createdAt`,
  state chip (Completed / Waiting / Idle / Crashed). Hover shows
  trailing actions (Focus Pane, Dismiss). `.swipeActions` exposes
  Dismiss on trailing edge with `allowsFullSwipe: true`.
- `InboxFilter.swift` — enum `{ all, unread, waiting, completed, crashed }`
  with a projection helper `filter(_:through:)` that returns the
  subset of `NotificationInbox.notifications` matching the filter.
  Pure function; unit-testable without SwiftUI.
- `NotificationsSettingsView.swift` — Settings pane section with toggle
  rows for `enabled`, `badgeEnabled`, `surfaceIdle`, `redactBodies`.
  "Open System Settings" link shown when `authStatus == .denied`,
  deeplinks to `x-apple.systempreferences:com.apple.preference.notifications?id=<bundle-id>`.
- `NotificationPermissionSheet.swift` — the Continue / Not now / Never
  pre-prompt sheet. View model conforms to `NotificationPermissionDelegate`
  (already defined in M4a) and M5's bootstrap wiring swaps it in for
  `NullPermissionDelegate`.

## TCA integration

Assumes 0007 ships a root `AppReducer` with a composition scheme for
feature reducers. C6 contributes:

```swift
@Reducer
struct InboxFeature {
  @ObservableState
  struct State: Equatable {
    var isPresented: Bool = false
    var filter: InboxFilter = .all
    var notifications: [AgentNotification] = []
    var unreadCount: Int = 0
  }

  enum Action {
    case toggleSidebar
    case filterChanged(InboxFilter)
    case rowTapped(AgentNotification.ID)
    case rowSwipedDismiss(AgentNotification.ID)
    case muteRuleTapped(ruleID: String)
    case clearAllTapped
    case onAppear                                // kick off the subscribe effects
    case inboxUpdated(NotificationInbox)         // from InboxClient.observe()
    case unreadCountUpdated(Int)                 // from InboxClient.observeUnread()
    case deeplinkRequested(PaneID)              // delegate up to RootFeature
  }

  @Dependency(\.inboxClient) var inboxClient

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .onAppear:
        return .merge(
          .run { send in
            for await inbox in inboxClient.observe() {
              await send(.inboxUpdated(inbox))
            }
          },
          .run { send in
            for await n in inboxClient.observeUnread() {
              await send(.unreadCountUpdated(n))
            }
          }
        )

      case .toggleSidebar:
        state.isPresented.toggle()
        return .none

      case .filterChanged(let filter):
        state.filter = filter
        return .none

      case .rowTapped(let id):
        let paneID = state.notifications.first(where: { $0.id == id })?.paneID
        return .run { send in
          await inboxClient.markRead([id])
          if let paneID {
            await send(.deeplinkRequested(paneID))
          }
        }

      case .rowSwipedDismiss(let id):
        return .run { _ in await inboxClient.dismiss([id]) }

      case .muteRuleTapped(let ruleID):
        return .run { _ in await inboxClient.muteRule(ruleID) }

      case .clearAllTapped:
        return .run { _ in await inboxClient.clearAll() }

      case .inboxUpdated(let inbox):
        state.notifications = inbox.notifications.filter { $0.dismissedAt == nil }
        return .none

      case .unreadCountUpdated(let n):
        state.unreadCount = n
        return .none

      case .deeplinkRequested:
        // Consumed by RootFeature — see §Deeplink chain below.
        return .none
      }
    }
  }
}
```

`InboxClient` is a `DependencyKey` matching the existing `TerminalClient` /
`HierarchyClient` pattern (both landing via 0007):

```swift
struct InboxClient: Sendable {
  var markRead: @Sendable ([UUID]) async -> Void
  var dismiss: @Sendable ([UUID]) async -> Void
  var clearAll: @Sendable () async -> Void
  var muteRule: @Sendable (String) async -> Void
  var observe: @Sendable () -> AsyncStream<NotificationInbox>
  var observeUnread: @Sendable () -> AsyncStream<Int>
}
```

Live impl wraps `InboxStore` + `SettingsStore`. Mock impl for tests
records every call.

## Integration with existing surfaces

- Toolbar bell icon in `MainView` with a badge reading from
  `InboxFeature.State.unreadCount`. Tapping sends `.toggleSidebar`.
- ⌘⇧N keyboard shortcut bound to the same action.
- `DeeplinkRouter` (architecture §URL scheme — file path pending 0007).

### Deeplink chain

Row-tap and OS-banner click both resolve through the same
`RootFeature`-level action chain. M5 does not own the final navigation
— `InboxFeature` emits a `.deeplinkRequested(PaneID)` delegate action
and `RootFeature` decides how to surface it. The expected chain,
assuming 0007 ships `tabSelect` / `splitFocus` conventions similar to
supaterm:

```
InboxFeature.Action.rowTapped(id)
  → InboxClient.markRead([id])
  → InboxFeature.Action.deeplinkRequested(paneID)
RootFeature.Action.inbox(.deeplinkRequested(paneID))
  → HierarchyClient.resolvePanel(paneID) → (spaceID, projectID, worktreeID, tabID)
  → RootFeature.Action.hierarchy(.spaceSelect(spaceID))
  → RootFeature.Action.hierarchy(.worktreeSelect(worktreeID))
  → RootFeature.Action.hierarchy(.tabSelect(tabID))
  → RootFeature.Action.hierarchy(.splitFocus(paneID))
  → RootFeature.Action.inbox(.toggleSidebar)    // optional, close on focus
```

If `resolvePanel` returns nil (Pane was closed since the banner
fired), emit a `toast` action with copy "Pane closed; inbox entry
remains." and leave the sidebar open with the row highlighted.

External surface: OS-banner click goes through AppDelegate's
`handle(url:)` → `DeeplinkRouter` → same `RootFeature.Action.inbox
(.deeplinkRequested(paneID))` entry. One code path for row-tap and
banner-click.

## Open design decisions

1. **Relative time formatting** — `"just now"`, `"2m ago"`, `"1h ago"`,
   `"Apr 20"`. Use `RelativeDateTimeFormatter` (auto-updating every
   minute) or hand-rolled? Leaning: `RelativeDateTimeFormatter` with
   `.abbreviated` style + a `TimelineView(.periodic(after:every:))`
   wrapper so the rendered string refreshes without state churn.
2. **Swipe gesture affordance — SwiftUI `List.swipeActions` vs.
   AppKit `NSTableView` host.** SwiftUI's `List.swipeActions(edge:
   allowsFullSwipe:)` gives free trackpad swipe + keyboard + hover on
   macOS 14+, composes with `@Bindable` cleanly, and costs zero AppKit
   code. `NSTableView` via `NSViewRepresentable` would give tighter
   control (row height measurement, right-click menu) but at the cost
   of bridging the selection back through TCA. Leaning: ship `List`
   first; reach for `NSTableView` only if row-height or context-menu
   requirements become blockers during dogfood. Redundant hover-
   activated trailing "Dismiss" button stays regardless — swipe
   discovery is poor for first-time users.
3. **Empty-state copy location** — keep "No agent pings. Nice." inline
   or promote to a reusable `EmptyStatePanel` component? Leaning:
   inline until a second empty state shows up.
4. **Row identity during filter animation** — SwiftUI's `List` with
   `id: .self` or `AgentNotification.id`? Leaning: `id: .id` for
   stable transitions.

## Tests

Unit-level (no SwiftUI harness needed):
- `InboxFilterTests` — 5 filter cases × fixed 7-entry inbox,
  assert returned subsets.
- `InboxFeatureTests` — TCA `TestStore` drives every `Action`,
  asserts state transitions and effect emission.
- `NotificationPermissionViewModelTests` — the view model conforms
  to `NotificationPermissionDelegate`; a test drives
  `presentPrompt()` and asserts each decision branch.

UI-level (deferred to a later task):
- SwiftUI snapshot tests for `InboxSidebar` with each filter chip.
- Manual dogfood checklist (written, not automated): bell icon,
  ⌘⇧N shortcut, swipe-dismiss, double-click focus, settings toggles
  persist, "Open System Settings" deeplink.

## Dependencies on 0007

- `AppReducer` root composition with a `@Presents` slot for the
  `InboxFeature`.
- `DeeplinkRouter` in `apps/mac/codans/App/Features/Deeplink/`
  (architecture §URL scheme pinned the path but the file doesn't
  exist yet on main).
- Toolbar host in `MainView` (today `MainView` is a single
  `PaneHostView` — 0007 replaces with the full app shell).

## Out-of-scope for M5

- In-app toast notifications (design §Alternatives A6 — deferred post-v1).
- Rich media / attachments in rows (design §Non-Goals).
- Keyboard navigation of the inbox list — accessibility enhancement, later.
- Per-row reply UI (design §Non-Goals — replying happens by focusing
  the Pane and typing).
