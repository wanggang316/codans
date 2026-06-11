---
title: "Ghostty Action Routing — Full-Surface Dispatch for All libghostty Actions"
status: Draft
author: Gump
date: 2026-04-22
---

# Design Doc: Ghostty Action Routing

## Context and Scope

libghostty exposes every user-configurable keybinding as an **action**: when
the user presses a bound key, libghostty invokes the runtime-config
`action_cb(app, target, action)` instead of applying the binding itself.
The host decides whether to consume each action (return `true`) or let
Ghostty fall back to its default (almost always a no-op — libghostty has
no UI of its own for these).

Today, codans's `action_cb` is a hardcoded stub that always returns
`false`:

```swift
// GhosttyRuntime.swift:148
private static let actionCallback: (@convention(c) ...) = { _, _, _ in
  // Real routing lands with the action-dispatch seam in M5.2+
  false
}
```

Result: **every** `keybind` the user configures in Ghostty silently no-ops,
every surface-emitted informational action (title / pwd / bell / mouse
shape / search state) is dropped, every app-level config hot-reload
attempt is ignored. The terminal draws and accepts input because the
*render* and *keyboard* paths bypass `action_cb` — but anything the host
is supposed to *do* in response to a ghostty event never happens.

### Scope of this design

Route **all** ghostty actions codans has a meaningful mapping for,
not an incremental subset. Rationale:

1. The decoder's shape is identical across buckets; adding 10 more cases
   after the initial 30 costs less than re-opening this doc twice.
2. Every action we don't route is a silent failure for the user — if we
   ship a 60%-covered keybinding system we will spend more time
   triaging "why doesn't X work" than we save by deferring.
3. The full action set is enumerated below; each action has a concrete
   host-side behavior or an explicit, documented no-op. No silent
   fall-throughs.

### Existing state we build on

- `GhosttyRuntime` owns a `[PaneID: PaneSurface]` registry and a
  `weak shared` static for UAF-safe callback hops
  (`GhosttyRuntime.swift:61`).
- `PaneSurface` embeds 16 bytes of `PaneID.raw.uuid` as the surface's
  libghostty userdata; `ghostty_surface_userdata()` recovers this pointer
  so surface-scoped callbacks resolve the Pane without dereferencing
  Swift-object memory (`PaneSurface.swift:57-81`).
- `TerminalEngine` is the multi-subscriber event-stream fan-out; lifecycle
  events emit via `TerminalEvent` (`TerminalEvent.swift`).
- `HierarchyManager` exposes the mutations every tab/split intent needs.
  IPC `Method.swift` already lists `hierarchyCreateTab` /
  `hierarchyActivateTab` / `hierarchySplitPane` / `hierarchyZoomPane` /
  `hierarchyUnzoomPane` / `hierarchyFocusPane` — the server-side
  wiring exists.
- The invariant "Runtime is TCA-free" is stated in `docs/architecture.md`
  §Architectural Invariants — Runtime exposes `@Observable` + AsyncStream
  seams only; TCA lives in `apps/mac/App/*`.
- `SparkleUpdates` / `UpdatesFeature` is planned (arch.md §Technology
  Choices) and hosts the "check for updates" seam.
- Settings landed with `DeveloperSettings` etc. — `OPEN_CONFIG` has a
  natural destination via `EditorClient.open(path:)`.

### Action budget

libghostty exposes ~66 action tags. This design routes 62 of them;
4 are explicitly unsupported because they are libghostty-internal or
non-macOS (`RENDER`, `INSPECTOR`, `SHOW_GTK_INSPECTOR`,
`RENDER_INSPECTOR`, `SHOW_ON_SCREEN_KEYBOARD`). Every other tag has a
concrete mapping spelled out under "Goals" below.

## Goals and Non-Goals

### Goals

Route every ghostty action codans has a meaningful mapping for,
organized into four buckets. Each case must either succeed (return
`true`), be explicitly and intentionally a no-op with a log line
(return `false`), or lift an intent onto the `TerminalEvent` stream for
a TCA feature to consume.

#### Bucket 1 — Tab / Split intent (→ `PaneActionRouterFeature` → `HierarchyClient`)

`NEW_TAB`, `CLOSE_TAB`, `MOVE_TAB`, `GOTO_TAB`, `NEW_SPLIT`, `GOTO_SPLIT`,
`RESIZE_SPLIT`, `EQUALIZE_SPLITS`, `TOGGLE_SPLIT_ZOOM`, `PRESENT_TERMINAL`,
`TOGGLE_COMMAND_PALETTE`. (11)

#### Bucket 2 — Window / App intent (→ `WindowActionRouterFeature` → `NSWindow` + app services)

`NEW_WINDOW`, `CLOSE_WINDOW`, `CLOSE_ALL_WINDOWS`, `GOTO_WINDOW`,
`TOGGLE_FULLSCREEN`, `TOGGLE_MAXIMIZE`, `TOGGLE_TAB_OVERVIEW`,
`TOGGLE_WINDOW_DECORATIONS`, `TOGGLE_QUICK_TERMINAL`, `TOGGLE_VISIBILITY`,
`TOGGLE_BACKGROUND_OPACITY`, `QUIT`, `CHECK_FOR_UPDATES`, `OPEN_CONFIG`. (14)

#### Bucket 3 — Surface info (→ `PaneSurface.SurfaceInfo` + `panelInfoChanged` event)

`SET_TITLE`, `SET_TAB_TITLE`, `PROMPT_TITLE`, `PWD`, `MOUSE_SHAPE`,
`MOUSE_VISIBILITY`, `MOUSE_OVER_LINK`, `COLOR_CHANGE`, `RENDERER_HEALTH`,
`CELL_SIZE`, `SIZE_LIMIT`, `INITIAL_SIZE`, `RESET_WINDOW_SIZE`,
`SCROLLBAR`, `SECURE_INPUT`, `KEY_SEQUENCE`, `KEY_TABLE`, `READONLY`,
`QUIT_TIMER`, `FLOAT_WINDOW`, `START_SEARCH`, `END_SEARCH`, `SEARCH_TOTAL`,
`SEARCH_SELECTED`, `PROGRESS_REPORT`. (25)

#### Bucket 4 — Effectful (→ direct side effect + event for consumers)

`OPEN_URL` (NSWorkspace.open), `DESKTOP_NOTIFICATION` (fans out to
`NotificationCoordinator`), `RING_BELL` (counter + event → Notifications /
Dock), `COMMAND_FINISHED`, `SHOW_CHILD_EXITED`, `UNDO` (`NSApp.sendAction`),
`REDO`, `COPY_TITLE_TO_CLIPBOARD`. (8)

#### Bucket 5 — App-level config (→ `GhosttyRuntime` local + event)

`CONFIG_CHANGE`, `RELOAD_CONFIG`, `SET_TITLE` when target is APP,
`SET_TAB_TITLE` when target is APP. (4 — these fire on
`GHOSTTY_TARGET_APP` instead of `GHOSTTY_TARGET_SURFACE` and touch the
runtime config object directly; kept separate in the decoder.)

### Non-Goals

- **User-configurable codans action binding table.** First version
  hardcodes 1:1 ghostty-action → codans-operation. A user-editable
  binding table (map a ghostty action to a codans method / IPC call)
  is a separate design.
- **Clipboard read/write/confirm callbacks** (`read_clipboard_cb`,
  `confirm_read_clipboard_cb`, `write_clipboard_cb`). Separate doc.
  `COPY_TITLE_TO_CLIPBOARD` in this doc uses `NSPasteboard` directly, not
  the clipboard callbacks.
- **Libghostty-internal / non-macOS actions.** Return `false` with
  `.debug` log; explicitly enumerated:
  - `RENDER` — internal render tick; host should not intercept.
  - `INSPECTOR`, `SHOW_GTK_INSPECTOR`, `RENDER_INSPECTOR` — Linux/GTK
    inspector UI we don't ship.
  - `SHOW_ON_SCREEN_KEYBOARD` — iOS-only.
- **Search overlay UI**, **secure-input visual indicator**, **scroll bar
  rendering**, **progress bar overlay**. These live in follow-up UI
  features. This design only *stores* the state on `SurfaceInfo` and
  emits `panelInfoChanged` events so a future overlay can consume them.
- **Multi-window model redesign.** The window intent bucket maps onto
  the *current* NSWindow (1:1 with a Space, per arch plan). The open
  architectural question §2 "multi-window semantics" is unblocked by
  this doc — we hand off the intent; the receiver decides policy.

## Design

### Overview

Decode in `GhosttyRuntime`, classify each action into one of 5 buckets,
dispatch accordingly. The asymmetry between buckets is deliberate:

- **Info** actions stay entirely inside Runtime — write a
  `SurfaceInfo` field, emit a delta event. No reducer involvement.
  (Why: they're per-frame chatter; routing each through TCA wastes
  Effect allocation and Equatable checks.)
- **Effectful** actions perform the side effect immediately in Runtime
  (NSWorkspace, NSPasteboard, NSApp.sendAction) and emit an
  observability event. (Why: there's nothing for a reducer to *decide* —
  "open this URL" has one correct action.)
- **Intent** actions (tab, split, window) emit a typed
  `PaneActionRequest` or `WindowActionRequest` for a feature to
  service. (Why: reducers own policy — is the worktree archived? is a
  modal up? does the user need confirmation to close a tab with a
  running process?)
- **Config** actions touch the `ghostty_config_t` handle that Runtime
  already owns — kept local.

This layering preserves the "Runtime is TCA-free" invariant while
covering every action the user can bind.

### System Context Diagram

```
                libghostty (Zig / C)
                      │
                      │  action_cb(app, target, action)
                      ▼
┌────────────────────────────────────────────────────────────┐
│ GhosttyRuntime.actionCallback (static, @convention(c))     │
│   hop to MainActor → handleAction(target, action)          │
│                                                            │
│   target == APP     → handleAppAction                      │
│   target == SURFACE → resolve PaneID via                  │
│                       ghostty_surface_userdata → 16 bytes  │
│                       → handleSurfaceAction                │
│                                                            │
│   decoder (GhosttyActionDecoder)                           │
│     ├─ INFO     → pane.info += delta; emit InfoChanged    │
│     ├─ EFFECT   → NSWorkspace/NSPasteboard/NSApp;          │
│     │            emit InfoChanged for observability        │
│     ├─ INTENT   → emit .panelActionRequested OR            │
│     │            .windowActionRequested                    │
│     ├─ CONFIG   → runtime.applyConfigChange(...)           │
│     └─ IGNORED  → log .debug; return false                 │
└────────────────────────────┬───────────────────────────────┘
                             │ TerminalEvent stream
                             ▼
┌────────────────────────────────────────────────────────────┐
│ TerminalEngine → AsyncStream<TerminalEvent>                │
└─────────┬──────────────────────┬───────────────────────────┘
          │                      │
          ▼                      ▼
 PaneActionRouterFeature  WindowActionRouterFeature
    │                            │
    ├─ HierarchyClient           ├─ WindowService (NSWindow)
    │  (createTab, splitPanel,   ├─ UpdatesClient
    │   closeTab, focus, zoom,   ├─ EditorClient (OPEN_CONFIG)
    │   resize, equalize, move)  ├─ AppLifecycleClient (QUIT)
    └─ UIClient                  └─ GhosttyRuntime (bg opacity)
       (toggleCommandPalette,
        presentTerminal)
```

### API Design

#### `GhosttyRuntime` additions

Replace the stub; keep the C thunk minimal.

```swift
private static let actionCallback: (@convention(c) (...) -> Bool) = {
  _, target, action in
  if Thread.isMainThread {
    return MainActor.assumeIsolated {
      GhosttyRuntime.shared?.handleAction(target: target, action: action) ?? false
    }
  }
  DispatchQueue.main.async {
    MainActor.assumeIsolated {
      _ = GhosttyRuntime.shared?.handleAction(target: target, action: action)
    }
  }
  return false
}

@MainActor
func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
  switch target.tag {
  case GHOSTTY_TARGET_APP:      return GhosttyActionDecoder.appAction(action, runtime: self)
  case GHOSTTY_TARGET_SURFACE:  return handleSurfaceAction(target.target.surface, action)
  default:                       return false
  }
}

private func handleSurfaceAction(
  _ surface: ghostty_surface_t?, _ action: ghostty_action_s
) -> Bool {
  guard let surface, let paneID = paneID(fromSurface: surface) else { return false }
  guard let pane = surfacesByPanelID[paneID] else { return false }
  return GhosttyActionDecoder.surfaceAction(
    action, paneID: paneID, pane: pane, runtime: self
  )
}

/// Copy the PaneID uuid bytes out of libghostty-stored userdata.
/// Same pattern as close_surface_cb — UAF-safe because userdata points
/// to a dedicated 16-byte allocation owned by PaneSurface for as long
/// as the ghostty_surface_t exists.
private func paneID(fromSurface surface: ghostty_surface_t) -> PaneID? {
  guard let raw = ghostty_surface_userdata(surface) else { return nil }
  var bytes = uuid_t(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
  withUnsafeMutableBytes(of: &bytes) { dst in
    dst.baseAddress?.copyMemory(from: raw, byteCount: MemoryLayout<uuid_t>.size)
  }
  return PaneID(raw: UUID(uuid: bytes))
}
```

#### `GhosttyActionDecoder` (new, `apps/mac/codans/Runtime/Ghostty/`)

Single module that knows the `ghostty_action_tag` + union shape.
Everyone else consumes typed Swift enums. Illustrative skeleton:

```swift
@MainActor
enum GhosttyActionDecoder {

  // MARK: - Surface actions

  static func surfaceAction(
    _ action: ghostty_action_s,
    paneID: PaneID,
    pane: PaneSurface,
    runtime: GhosttyRuntime
  ) -> Bool {
    switch action.tag {

    // Tab intent
    case GHOSTTY_ACTION_NEW_TAB:
      runtime.emit(.panelActionRequested(paneID, .newTab))
      return true
    case GHOSTTY_ACTION_CLOSE_TAB:
      runtime.emit(.panelActionRequested(paneID,
        .closeTab(mode: CloseTabMode(action.action.close_tab_mode))))
      return true
    case GHOSTTY_ACTION_MOVE_TAB:
      runtime.emit(.panelActionRequested(paneID,
        .moveTab(offset: Int(action.action.move_tab.amount))))
      return true
    case GHOSTTY_ACTION_GOTO_TAB:
      runtime.emit(.panelActionRequested(paneID,
        .gotoTab(target: GotoTabTarget(action.action.goto_tab))))
      return true

    // Split intent
    case GHOSTTY_ACTION_NEW_SPLIT:
      if let dir = NewSplitDirection.decode(action.action.new_split) {
        runtime.emit(.panelActionRequested(paneID, .newSplit(direction: dir)))
        return true
      }
      return false
    case GHOSTTY_ACTION_GOTO_SPLIT:
      if let dir = FocusDirection.decode(action.action.goto_split) {
        runtime.emit(.panelActionRequested(paneID, .gotoSplit(direction: dir)))
        return true
      }
      return false
    case GHOSTTY_ACTION_RESIZE_SPLIT:
      let resize = action.action.resize_split
      if let dir = ResizeDirection.decode(resize.direction) {
        runtime.emit(.panelActionRequested(paneID,
          .resizeSplit(direction: dir, amount: Double(resize.amount))))
        return true
      }
      return false
    case GHOSTTY_ACTION_EQUALIZE_SPLITS:
      runtime.emit(.panelActionRequested(paneID, .equalizeSplits))
      return true
    case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
      runtime.emit(.panelActionRequested(paneID, .toggleSplitZoom))
      return true
    case GHOSTTY_ACTION_PRESENT_TERMINAL:
      runtime.emit(.panelActionRequested(paneID, .presentTerminal))
      return true
    case GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE:
      runtime.emit(.panelActionRequested(paneID, .toggleCommandPalette))
      return true

    // Window intent (SURFACE-scoped because fired from inside a surface
    // but semantically targets the enclosing window)
    case GHOSTTY_ACTION_NEW_WINDOW:
      runtime.emit(.windowActionRequested(.new(from: paneID))); return true
    case GHOSTTY_ACTION_CLOSE_WINDOW:
      runtime.emit(.windowActionRequested(.close(from: paneID))); return true
    case GHOSTTY_ACTION_CLOSE_ALL_WINDOWS:
      runtime.emit(.windowActionRequested(.closeAll)); return true
    case GHOSTTY_ACTION_GOTO_WINDOW:
      runtime.emit(.windowActionRequested(
        .goto(target: GotoWindowTarget(action.action.goto_window))))
      return true
    case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
      runtime.emit(.windowActionRequested(.toggleFullscreen(from: paneID)))
      return true
    case GHOSTTY_ACTION_TOGGLE_MAXIMIZE:
      runtime.emit(.windowActionRequested(.toggleMaximize(from: paneID)))
      return true
    case GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW:
      runtime.emit(.windowActionRequested(.toggleTabOverview(from: paneID)))
      return true
    case GHOSTTY_ACTION_TOGGLE_WINDOW_DECORATIONS:
      // macOS: no per-window decoration toggle equivalent; documented
      // as intentional no-op.
      return false
    case GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL:
      // Quick-terminal is ghostty's global-hotkey HUD; codans's UX
      // does not currently offer this. Explicit no-op.
      return false
    case GHOSTTY_ACTION_TOGGLE_VISIBILITY:
      runtime.emit(.windowActionRequested(.toggleAppVisibility))
      return true
    case GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY:
      runtime.toggleBackgroundOpacity(); return true

    // App intent (surface-scoped invocation)
    case GHOSTTY_ACTION_QUIT:
      runtime.emit(.windowActionRequested(.quit)); return true
    case GHOSTTY_ACTION_CHECK_FOR_UPDATES:
      runtime.emit(.windowActionRequested(.checkForUpdates)); return true
    case GHOSTTY_ACTION_OPEN_CONFIG:
      runtime.emit(.windowActionRequested(.openConfig)); return true

    // Surface info — title family
    case GHOSTTY_ACTION_SET_TITLE:
      let title = String.decode(cstring: action.action.set_title.title)
      pane.apply(.title(title)); runtime.emitInfoChanged(paneID, .title(title))
      return true
    case GHOSTTY_ACTION_SET_TAB_TITLE:
      let title = String.decode(cstring: action.action.set_tab_title.title)
      pane.apply(.tabTitle(title)); runtime.emitInfoChanged(paneID, .tabTitle(title))
      return true
    case GHOSTTY_ACTION_PROMPT_TITLE:
      let flag = action.action.prompt_title
      pane.apply(.promptTitle(flag)); runtime.emitInfoChanged(paneID, .promptTitle(flag))
      return true
    case GHOSTTY_ACTION_PWD:
      let pwd = String.decode(cstring: action.action.pwd.pwd)
      pane.apply(.pwd(pwd)); runtime.emitInfoChanged(paneID, .pwd(pwd))
      return true

    // Surface info — mouse family
    case GHOSTTY_ACTION_MOUSE_SHAPE:
      pane.apply(.mouseShape(action.action.mouse_shape)); return true
    case GHOSTTY_ACTION_MOUSE_VISIBILITY:
      pane.apply(.mouseVisible(action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE))
      return true
    case GHOSTTY_ACTION_MOUSE_OVER_LINK:
      let link = action.action.mouse_over_link
      let str = String.decode(cstring: link.url, length: link.len)
      pane.apply(.mouseOverLink(str)); return true

    // Surface info — geometry family
    case GHOSTTY_ACTION_CELL_SIZE, GHOSTTY_ACTION_SIZE_LIMIT,
         GHOSTTY_ACTION_INITIAL_SIZE, GHOSTTY_ACTION_RESET_WINDOW_SIZE:
      applyGeometryAction(action, pane: pane, runtime: runtime, paneID: paneID)
      return true

    // Surface info — scrollbar / renderer health / color
    case GHOSTTY_ACTION_SCROLLBAR:
      let s = action.action.scrollbar
      pane.apply(.scrollbar(total: s.total, offset: s.offset, length: s.len))
      runtime.emitInfoChanged(paneID, .scrollbar(total: s.total, offset: s.offset, length: s.len))
      return true
    case GHOSTTY_ACTION_RENDERER_HEALTH:
      pane.apply(.rendererHealthy(action.action.renderer_health == GHOSTTY_RENDERER_HEALTH_HEALTHY))
      return true
    case GHOSTTY_ACTION_COLOR_CHANGE:
      let c = action.action.color_change
      pane.apply(.colorChange(kind: c.kind, r: c.r, g: c.g, b: c.b))
      return true

    // Surface info — secure input / key family / readonly / quit timer / float
    case GHOSTTY_ACTION_SECURE_INPUT:
      pane.apply(.secureInput(action.action.secure_input))
      runtime.emitInfoChanged(paneID, .secureInput(action.action.secure_input))
      return true
    case GHOSTTY_ACTION_KEY_SEQUENCE:
      let seq = action.action.key_sequence
      pane.apply(.keySequence(active: seq.active, trigger: seq.trigger))
      return true
    case GHOSTTY_ACTION_KEY_TABLE:
      pane.apply(.keyTable(decode: action.action.key_table))
      return true
    case GHOSTTY_ACTION_READONLY:
      pane.apply(.readonly(action.action.readonly)); return true
    case GHOSTTY_ACTION_QUIT_TIMER:
      pane.apply(.quitTimer(action.action.quit_timer)); return true
    case GHOSTTY_ACTION_FLOAT_WINDOW:
      pane.apply(.floatWindow(action.action.float_window)); return true

    // Search (state only; overlay UI consumes via InfoChanged)
    case GHOSTTY_ACTION_START_SEARCH:
      let needle = String.decode(cstring: action.action.start_search.needle) ?? ""
      pane.apply(.searchStarted(needle: needle))
      runtime.emitInfoChanged(paneID, .searchStarted(needle: needle))
      return true
    case GHOSTTY_ACTION_END_SEARCH:
      pane.apply(.searchEnded)
      runtime.emitInfoChanged(paneID, .searchEnded)
      return true
    case GHOSTTY_ACTION_SEARCH_TOTAL:
      pane.apply(.searchTotal(Int(action.action.search_total.total)))
      runtime.emitInfoChanged(paneID, .searchTotal(Int(action.action.search_total.total)))
      return true
    case GHOSTTY_ACTION_SEARCH_SELECTED:
      pane.apply(.searchSelected(Int(action.action.search_selected.selected)))
      runtime.emitInfoChanged(paneID, .searchSelected(Int(action.action.search_selected.selected)))
      return true

    // Progress report
    case GHOSTTY_ACTION_PROGRESS_REPORT:
      let r = action.action.progress_report
      pane.apply(.progress(state: r.state,
        value: r.progress == -1 ? nil : Int(r.progress)))
      runtime.emitInfoChanged(paneID, .progress(state: r.state,
        value: r.progress == -1 ? nil : Int(r.progress)))
      return true

    // Effectful
    case GHOSTTY_ACTION_OPEN_URL:
      return handleOpenURL(action.action.open_url)
    case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
      let n = action.action.desktop_notification
      runtime.emitInfoChanged(paneID, .desktopNotification(
        title: String.decode(cstring: n.title) ?? "",
        body: String.decode(cstring: n.body) ?? ""))
      return true
    case GHOSTTY_ACTION_RING_BELL:
      pane.apply(.bellRang); runtime.emitInfoChanged(paneID, .bellRang)
      return true
    case GHOSTTY_ACTION_COMMAND_FINISHED:
      let f = action.action.command_finished
      pane.apply(.commandFinished(exitCode: f.exit_code, duration: f.duration))
      runtime.emitInfoChanged(paneID,
        .commandFinished(exitCode: f.exit_code, duration: f.duration))
      return true
    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
      let ex = action.action.child_exited
      pane.markExited(code: ex.exit_code)
      runtime.emitInfoChanged(paneID, .childExited(code: ex.exit_code))
      return true
    case GHOSTTY_ACTION_UNDO:
      NSApp.sendAction(#selector(UndoManager.undo), to: nil, from: nil); return true
    case GHOSTTY_ACTION_REDO:
      NSApp.sendAction(#selector(UndoManager.redo), to: nil, from: nil); return true
    case GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD:
      if let title = pane.info.title, !title.isEmpty {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(title, forType: .string)
      }
      return true

    // Explicitly unsupported (logged at .debug)
    case GHOSTTY_ACTION_RENDER, GHOSTTY_ACTION_INSPECTOR,
         GHOSTTY_ACTION_SHOW_GTK_INSPECTOR, GHOSTTY_ACTION_RENDER_INSPECTOR,
         GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD:
      Logger.runtime.debug("unsupported ghostty action: \(action.tag.rawValue)")
      return false

    default:
      Logger.runtime.info("unknown ghostty action tag: \(action.tag.rawValue)")
      return false
    }
  }

  // MARK: - App-level actions (target == APP)

  static func appAction(
    _ action: ghostty_action_s, runtime: GhosttyRuntime
  ) -> Bool {
    switch action.tag {
    case GHOSTTY_ACTION_CONFIG_CHANGE:
      guard let cloned = ghostty_config_clone(action.action.config_change.config)
      else { return false }
      runtime.applyClonedConfig(cloned)
      runtime.emit(.configChanged)
      return true
    case GHOSTTY_ACTION_RELOAD_CONFIG:
      runtime.reloadConfig(soft: action.action.reload_config.soft)
      return true
    case GHOSTTY_ACTION_QUIT:
      runtime.emit(.windowActionRequested(.quit)); return true
    default:
      return false
    }
  }
}
```

Above is illustrative — the final shape lives in the prototype. The
invariants that matter: one case per action; intents `emit(.panelAction*)`
or `emit(.windowAction*)`; info cases write `pane.apply(delta)` +
`emitInfoChanged`; effects run the side effect; unsupported log + false.

#### New `TerminalEvent` cases

Add to `CodansCore/TerminalEvent.swift`:

```swift
public nonisolated enum TerminalEvent: Sendable {
  // …existing cases…
  case panelInfoChanged(PaneID, PaneInfoDelta)
  case panelActionRequested(PaneID, PaneActionRequest)
  case windowActionRequested(WindowActionRequest)
  case configChanged
}
```

#### `PaneInfoDelta`, `PaneActionRequest`, `WindowActionRequest` (Core)

In `CodansCore/Pane/`:

```swift
public enum PaneInfoDelta: Sendable, Equatable {
  case title(String?)
  case tabTitle(String?)
  case promptTitle(UInt32)
  case pwd(String?)
  case mouseShape(UInt32)
  case mouseVisible(Bool)
  case mouseOverLink(String?)
  case colorChange(kind: Int32, r: UInt8, g: UInt8, b: UInt8)
  case rendererHealthy(Bool)
  case cellSize(width: UInt32, height: UInt32)
  case sizeLimit(min: Size, max: Size)
  case initialSize(width: UInt32, height: UInt32)
  case resetWindowSize
  case scrollbar(total: Int, offset: Int, length: Int)
  case secureInput(UInt32)         // on / off / toggle
  case keySequence(active: Bool, trigger: UInt32)
  case keyTable(name: String?, depth: Int)
  case readonly(Bool)
  case quitTimer(UInt32)
  case floatWindow(Bool)
  case searchStarted(needle: String)
  case searchEnded
  case searchTotal(Int)
  case searchSelected(Int)
  case progress(state: UInt32, value: Int?)
  case bellRang
  case desktopNotification(title: String, body: String)
  case commandFinished(exitCode: Int32, duration: UInt64)
  case childExited(code: Int32)
}

public enum PaneActionRequest: Sendable, Equatable {
  case newTab
  case closeTab(mode: CloseTabMode)
  case moveTab(offset: Int)
  case gotoTab(target: GotoTabTarget)
  case newSplit(direction: NewSplitDirection)
  case gotoSplit(direction: FocusDirection)
  case resizeSplit(direction: ResizeDirection, amount: Double)
  case equalizeSplits
  case toggleSplitZoom
  case presentTerminal
  case toggleCommandPalette
}

public enum WindowActionRequest: Sendable, Equatable {
  case new(from: PaneID)
  case close(from: PaneID)
  case closeAll
  case goto(target: GotoWindowTarget)
  case toggleFullscreen(from: PaneID)
  case toggleMaximize(from: PaneID)
  case toggleTabOverview(from: PaneID)
  case toggleAppVisibility
  case quit
  case checkForUpdates
  case openConfig
}

public enum CloseTabMode: Sendable, Equatable { case this, other, right }
public enum GotoTabTarget: Sendable, Equatable {
  case previous, next, last, index(Int)
}
// NewSplitDirection / FocusDirection / ResizeDirection / GotoWindowTarget:
// typed wrappers over ghostty's C enums, decoded inside the decoder.
```

Keep ghostty's C enum types out of Core — the decoder is the translation
boundary.

#### Consumers

Two new lightweight TCA features:

**`PaneActionRouterFeature`** (`apps/mac/codans/App/Features/PaneActionRouter/`)
subscribes to `panelActionRequested`. Resolves `PaneID` →
`(SpaceID, ProjectID, WorktreeID, TabID)` via a small addition to
`HierarchyClient.addressOf(paneID:)`, then dispatches:

| Request | Action |
|---|---|
| `.newTab` | `HierarchyClient.createTab(worktreeID, projectID, spaceID, name:nil)` |
| `.closeTab(mode)` | resolve siblings by mode; `closeTab` each |
| `.moveTab(offset)` | new `HierarchyClient.moveTab` (add if missing) |
| `.gotoTab(target)` | `HierarchyClient.activateTab` after target resolution |
| `.newSplit(dir)` | `HierarchyClient.splitPanel(paneID, direction: dir.mapToSplitDirection, …)` |
| `.gotoSplit(dir)` | `HierarchyClient.focusPanel` on spatial neighbor |
| `.resizeSplit` | new `HierarchyClient.resizePanel` (M5 method exists; bind) |
| `.equalizeSplits` | new `HierarchyClient.equalizeTabSplits` (add) |
| `.toggleSplitZoom` | `HierarchyClient.zoomPanel` / `.unzoomPanel` (method exists) |
| `.presentTerminal` | `UIClient.focusTerminalInMainWindow` |
| `.toggleCommandPalette` | send root reducer `Action.commandPalette(.toggle)` |

**`WindowActionRouterFeature`** (`apps/mac/codans/App/Features/WindowActionRouter/`)
subscribes to `windowActionRequested`. Maps onto:

| Request | Action |
|---|---|
| `.new(from)` | `WindowService.openNewWindow(inheriting: paneID)` |
| `.close(from)` | `paneID → window → window.performClose` |
| `.closeAll` | `NSApp.terminate` path via `AppLifecycleClient` |
| `.goto(target)` | `WindowService.activateWindow(matching: target)` |
| `.toggleFullscreen` | `NSWindow.toggleFullScreen(nil)` |
| `.toggleMaximize` | `NSWindow.zoom(nil)` |
| `.toggleTabOverview` | `NSWindow.toggleTabOverview(nil)` (macOS 10.12+) |
| `.toggleAppVisibility` | `NSApp.hide(nil)` / `NSApp.unhide(nil)` |
| `.quit` | `AppLifecycleClient.requestQuit` (routes through quit-confirmation flow) |
| `.checkForUpdates` | `UpdatesClient.checkNow` (Sparkle) |
| `.openConfig` | `EditorClient.openFile("~/.config/ghostty/config")` via user's default editor |

`WindowService` is a new `apps/mac/codans/App/Clients/WindowService.swift`
— thin wrapper over `NSApp.keyWindow`, the app's window registry, and
the Space-to-window mapping (1:1 per current plan).

### Data Storage

New `@Observable` state on `PaneSurface`:

```swift
@MainActor
@Observable
final class SurfaceInfo {
  var title: String?
  var tabTitle: String?
  var promptTitle: UInt32 = 0
  var pwd: String?
  var mouseShape: UInt32 = 0
  var mouseVisible: Bool = true
  var mouseOverLink: String?
  var colorChange: ColorChange?
  var rendererHealthy: Bool = true
  var cellSize: (width: UInt32, height: UInt32) = (0, 0)
  var sizeLimitMin: (width: UInt32, height: UInt32) = (0, 0)
  var sizeLimitMax: (width: UInt32, height: UInt32) = (0, 0)
  var initialSize: (width: UInt32, height: UInt32) = (0, 0)
  var scrollbar: (total: Int, offset: Int, length: Int) = (0, 0, 0)
  var secureInput: UInt32 = 0
  var keySequence: (active: Bool, trigger: UInt32) = (false, 0)
  var keyTable: (name: String?, depth: Int) = (nil, 0)
  var readonly: Bool = false
  var quitTimer: UInt32 = 0
  var floatWindow: Bool = false
  var searchNeedle: String?
  var searchTotal: Int?
  var searchSelected: Int?
  var progressState: UInt32 = 0
  var progressValue: Int?
  var bellCount: Int = 0
  var lastCommandExitCode: Int32?
  var lastCommandDuration: UInt64?
}

extension PaneSurface {
  var info: SurfaceInfo { /* lazily created */ }
  func apply(_ delta: PaneInfoDelta) { /* one switch; mutate fields */ }
}
```

**Not persisted.** Ephemeral per-session; reset on app relaunch. Catalog
persistence only tracks stable hierarchy.

### Component Boundaries

| Layer | File | Responsibility |
|---|---|---|
| **Core** | `CodansCore/TerminalEvent.swift` | Add `.panelInfoChanged`, `.panelActionRequested`, `.windowActionRequested`, `.configChanged` cases |
| **Core** | `CodansCore/Pane/PaneInfoDelta.swift` (new) | Info-update enum |
| **Core** | `CodansCore/Pane/PaneActionRequest.swift` (new) | Pane intent enum + typed sub-enums |
| **Core** | `CodansCore/Pane/WindowActionRequest.swift` (new) | Window intent enum + typed sub-enums |
| **Runtime** | `Runtime/Ghostty/GhosttyRuntime.swift` | Replace action stub; add `handleAction`, `paneID(fromSurface:)`, `applyClonedConfig`, `reloadConfig`, `toggleBackgroundOpacity` |
| **Runtime** | `Runtime/Ghostty/GhosttyActionDecoder.swift` (new) | The one module that touches `ghostty_action_tag` — everything else speaks typed Swift |
| **Runtime** | `Runtime/Ghostty/PaneSurface.swift` | Add `SurfaceInfo`, `apply(_:)`, `markExited` |
| **Runtime** | `Runtime/Ghostty/SurfaceInfo.swift` (new) | `@Observable` surface state class |
| **App** | `App/Features/PaneActionRouter/*` (new) | Subscribe + dispatch `panelActionRequested` → `HierarchyClient` / `UIClient` |
| **App** | `App/Features/WindowActionRouter/*` (new) | Subscribe + dispatch `windowActionRequested` → `WindowService` / `UpdatesClient` / `AppLifecycleClient` / `EditorClient` |
| **App** | `App/Clients/HierarchyClient.swift` | Add `addressOf(paneID:)`, `moveTab`, `equalizeTabSplits`, `resizePanel` closures |
| **App** | `App/Clients/WindowService.swift` (new) | `NSWindow` / `NSApp` façade |
| **App** | `App/Clients/AppLifecycleClient.swift` (new) | `requestQuit`, `terminate` |
| **App** | `App/Clients/UpdatesClient.swift` (new or existing) | `checkNow` (Sparkle seam) |
| **App** | `App/Features/Root/RootFeature.swift` | Compose both routers; subscribe to the new event variants |
| **App** | `App/Features/TabBar/TabBarFeature.swift` | Consume `panelInfoChanged(.title/.tabTitle/.progress/.bellRang)` for live tab chrome |
| **App** | `App/Features/Notifications/` (exists) | Consume `panelInfoChanged(.desktopNotification/.bellRang)` — hooks into existing C6 `NotificationCoordinator` |

**Dependency directions preserved.** `GhosttyActionDecoder` imports Core
+ GhosttyKit, never `HierarchyClient` / features. Routers import Core +
Clients, never Runtime internals. Events flow one way.

### Threading

libghostty may invoke `action_cb` on a non-main thread. Pattern: fast
path `if Thread.isMainThread` calls synchronously under
`MainActor.assumeIsolated`; otherwise hop via `DispatchQueue.main.async`
and return `false` (the async result lands later; Ghostty's app-level
defaults are no-ops, so the async application is benign).

The Pane registry lookup inside `handleSurfaceAction` is @MainActor-
isolated, so all decoder code runs single-threaded once dispatched.

## Alternatives Considered

### Alternative A: "Fat bridge per surface"

One `GhosttySurfaceBridge` class per `PaneSurface` holding ~15 closure
callbacks and ~30 state fields; engine wires closures at surface
creation.

**Cons — rejected:**
- ~500 lines of per-surface state that duplicates `SurfaceInfo`.
- Forces Runtime to know what to do on each action (closures captured
  manager methods) — breaks "Runtime is TCA-free."
- Closure soup is harder to test than event-stream subscription.

### Alternative B: "Direct `HierarchyClient` call from Runtime"

Runtime imports `HierarchyClient`, calls it on decode. Zero event hop.

**Cons — rejected:** breaks architectural invariant; pulls TCA into
Runtime; loses reducer-owned policy (modals, confirmations,
active-worktree checks).

### Alternative C: "NSNotification for cross-reducer signaling"

Emit `NSNotification` from the C callback; features listen.

**Cons — rejected:** codans's architecture forbids inter-reducer
NSNotification (untyped payloads, no ordering guarantees, no type-safety
across modules); and there is no ordering relative to existing
lifecycle events already on `TerminalEvent`, so consumers wanting both
"title changed" and "pane exited" would have two streams to reconcile.

### Alternative D: "Implement only the high-value subset now; defer the rest"

Ship tab/split/title/pwd/bell; defer search/secure/key-table/window.

**Cons — rejected:** every unrouted binding is a silent user failure.
The incremental cost per additional action in the same decoder is one
`case` + one `SurfaceInfo` field — roughly 5 lines — so deferral buys
little complexity reduction while leaving a large set of "doesn't work
and nobody knows why" bindings. Of the ~62 routable actions the
long tail (search / secure input / key table / scrollbar) is all
plain state writes, and landing them once avoids a second pass where
someone asks "why did we stop halfway."

### Alternative E: "Keep action decoding on Features side"

Runtime emits raw `ghostty_action_s` as a Core event; features decode.

**Cons — rejected:** spreads C enum knowledge across Features;
`ghostty_action_s` is not `Sendable`/`Equatable` and the union can't
cross module boundaries cleanly; decoder duplication risk.

## Cross-Cutting Concerns

### Observability

- `os.Logger` category `com.gumpw.codans.runtime.action`. Every decoded
  action logs at `.debug` with `(paneID, tag)`. Unsupported branch logs
  at `.info` with the tag int.
- `codans system.status` gains a `ghostty.actions` section: per-tag counter
  of observed actions in the current session. Makes "agent asks why
  their keybind didn't work" diagnosable with one command.
- `GhosttyRuntime` exposes `var unhandledActionCounts: [UInt32: Int]`
  (bounded) for the status command to read. Bounded at 256 entries; LRU
  eviction.

### Testing strategy

- **Unit — decoder.** `GhosttyActionDecoderTests` constructs a
  `DecodedAction` wrapper enum (translation of `ghostty_action_s` into
  pure Swift — the **one** place C is touched) and asserts each case
  produces the expected event or side effect. The translation
  `ghostty_action_s → DecodedAction` is trivial (pointer dereferences +
  enum remap), factored into a separate fn tested against synthetic
  byte-patterns.
- **Unit — routers.** `PaneActionRouterFeatureTests` and
  `WindowActionRouterFeatureTests` dispatch each enum case, assert the
  matching client call (TCA test store with recording stubs).
- **Integration — engine.** `TerminalEngineTests` feeds synthetic
  `TerminalEvent.panelActionRequested` emits; asserts fan-out.
- **Smoke — manual.** libghostty binding end-to-end is not driveable
  from `codans`. Checklist of ~15 `keybind` configs → observed effects must
  pass on a dev build before release.
  Checklist lives in the exec plan.

### Error handling

- `ghostty_surface_userdata` nil or PaneID-not-in-registry → return
  `false`, no emit. Expected during teardown races.
- Malformed action payloads (e.g. `GOTO_TAB` with out-of-range index)
  → log `.info`, return `false`.
- Router-side failures (`HierarchyClient.splitPanel` throws because the
  worktree was archived mid-flight) → emit a toast via existing error
  surfacing; never crash, never retry.
- `CONFIG_CHANGE` cloning failure (`ghostty_config_clone` returns nil)
  → log `.error`, return `false`; runtime keeps the old config.

### Security / privacy

- `OPEN_URL` passes through `ghosttyOpenURLRequest`-style resolution
  (URL scheme check; file paths via tilde-expansion + `file://`). No
  raw shell; `NSWorkspace.open` enforces macOS's LaunchServices
  gatekeeper.
- `COPY_TITLE_TO_CLIPBOARD` only copies the title string; titles are
  already rendered to screen, no elevation of disclosure.
- `DESKTOP_NOTIFICATION` funnels through `NotificationCoordinator`,
  which already enforces user-granted permission and mute rules.

### Rollout

- Launch-arg gate `CODANS_DISABLE_ACTION_ROUTING=1` for the first
  release; hotfix escape hatch if a regression slips through manual
  smoke. Remove the gate two releases later.
- Per-bucket landing order: Info → Effect → Tab/Split intent → Window
  intent → Config. Each bucket lands as its own commit on the feature
  branch so a bisect can narrow blame to one bucket.

## Risks

| Risk | Mitigation |
|---|---|
| **Action firehose overwhelms fan-out.** Chatty TUI fires `SET_TITLE`/`PWD`/`PROGRESS_REPORT` on every prompt. | `.bufferingNewest(256)` on `TerminalEvent`. Emit `.panelInfoChanged` only when the field actually changed (memo via `apply` diff). Lifecycle events stay unbuffered. |
| **Thread-safety bug**: action callback fires non-main; userdata race with `PaneSurface` deinit. | `ghostty_surface_userdata` returns the 16-byte allocation that lives as long as the surface; decode copies bytes before any main hop. Registry access is @MainActor. |
| **Unknown action flood.** Future libghostty versions emit tags we haven't seen. | Default branch logs `.info` + bumps bounded counter; `codans system.status` surfaces top unknown tags; schedule an agent sweep to add decoder cases. |
| **Router becomes a god-reducer.** Every new action expands `PaneActionRouterFeature` until it knows everything. | Only intents go through routers. Info / effect stay in Runtime. If a new intent's servicing logic exceeds ~20 lines, extract to its own reducer composed into the router. |
| **Window intent without multi-window model.** `NEW_WINDOW` today maps to a single NSWindow app model; behavior may need to change when multi-window arch question lands. | `WindowService` is the single seam; revising multi-window touches one file. `WindowActionRouterFeature` is intentionally thin so rewrites are cheap. |
| **Double-consumption.** A future feature also subscribes to `panelActionRequested` and double-runs the mutation. | Exclusivity is documented in `architecture.md` §Architectural Invariants: `panelActionRequested` and `windowActionRequested` are consumed by their named routers only. Code review gate. |
| **Config reload clobbers live sessions.** `CONFIG_CHANGE` replacing the `ghostty_config_t` could disturb in-flight surfaces. | `ghostty_config_clone` + atomic replace in `GhosttyRuntime.applyClonedConfig`; drop the old config on the main queue after surfaces finish any in-flight config-dependent calls. |
| **Quit path races.** `QUIT` arrives while another modal is up. | Route through `AppLifecycleClient.requestQuit`, which already negotiates with quit-confirmation presenter; a raw `NSApp.terminate` is forbidden. |
| **Scope: 62 cases on one PR is large.** Landing as a single change risks merge pain + review slowness. | Per-bucket commits on a feature branch (Info / Effect / Tab-Split intent / Window intent / Config). Each bucket is self-testable; the PR is the union but bisect granularity stays high. |
