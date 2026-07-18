import AppKit
import Foundation
import GhosttyKit
import CodansCore
import os.log

/// Single translation boundary between libghostty's C action union
/// (`ghostty_action_s`) and typed Swift intents. The decoder is split into
/// two halves:
///
///   * `decodeSurfaceAction` / `decodeAppAction` — `nonisolated`, safe to
///     call from the libghostty callback thread. Eagerly copies every
///     C-pointer-backed field (title, pwd, needle, url, notification body,
///     key-table name, cloned config handle) into owned Swift values so a
///     deferred main-thread apply never touches memory libghostty has
///     reclaimed when `action_cb` returned.
///   * `apply(_ decoded:…)` — `@MainActor`, operates only on the
///     Sendable `DecodedSurfaceAction` / `DecodedAppAction` enum and
///     performs the routing side effects (emit events, write
///     `PaneSurface.info`, trigger AppKit calls).
///
/// Two-pass so the async main-thread apply never reads the C union's
/// borrowed pointers (they dangle once `action_cb` returns), and so the
/// callback can report correct consumed-ness — decode decides it
/// synchronously.
enum GhosttyActionDecoder {

  nonisolated static let logger = Logger(
    subsystem: "com.gumpw.codans.runtime",
    category: "action"
  )
}

// MARK: - Decoded action values (Sendable, cross-thread safe)

/// Swift-owned surface action. Every pointer field from `ghostty_action_s`
/// is materialized into a Sendable Swift value before this enum is handed
/// to the main-thread applier.
enum DecodedSurfaceAction: Sendable, Equatable {
  // Bucket 1 — Tab / split intent
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

  // Bucket 2 — Window intent
  case newWindow
  case closeWindow
  case closeAllWindows
  case gotoWindow(target: GotoWindowTarget)
  case toggleFullscreen
  case toggleMaximize
  case toggleTabOverview
  case toggleVisibility
  case toggleBackgroundOpacity
  case quit
  case checkForUpdates
  case openConfig

  // Bucket 3 — Surface info
  case setTitle(String?)
  case setTabTitle(String?)
  case promptTitle(UInt32)
  case pwd(String?)
  case mouseShape(UInt32)
  case mouseVisible(Bool)
  case mouseOverLink(String?)
  case colorChange(kind: Int32, r: UInt8, g: UInt8, b: UInt8)
  case rendererHealthy(Bool)
  case cellSize(width: UInt32, height: UInt32)
  case sizeLimit(minWidth: UInt32, minHeight: UInt32, maxWidth: UInt32, maxHeight: UInt32)
  case initialSize(width: UInt32, height: UInt32)
  case resetWindowSize
  case scrollbar(total: Int, offset: Int, length: Int)
  case secureInput(UInt32)
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

  // Bucket 4 — Effectful
  case openURL(String)
  case desktopNotification(title: String, body: String)
  case ringBell
  case commandFinished(exitCode: Int32, duration: UInt64)
  case showChildExited(code: Int32)
  case undo
  case redo
  case copyTitleToClipboard

  // Bucket 5 — Config lifecycle (surface-scoped).
  // Surface-scoped `reload_config` fires per surface after
  // `ghostty_surface_set_color_scheme`; the applier pushes the current app
  // config through `ghostty_surface_update_config` so libghostty can re-resolve
  // the surface's palette against the updated conditional state.
  case reloadConfig(soft: Bool)

  // Bucket 6 — Decode failure / unsupported / unknown tag. The raw tag
  // rides along so the applier can log it without the C struct.
  case unsupported(rawTag: UInt32, reason: String)

  /// Whether the callback should report "consumed" to libghostty. Matches
  /// the value the applier will return — computed synchronously so the C
  /// return value isn't a guess.
  var consumed: Bool {
    if case .unsupported = self { return false }
    return true
  }
}

/// Swift-owned app-level action. `configChange` carries an already-cloned
/// `ghostty_config_t` whose lifetime this enum now owns — it will be freed
/// by `GhosttyRuntime.applyClonedConfig` or the `.unsupported` drop path.
enum DecodedAppAction: @unchecked Sendable {
  case configChange(cloned: ghostty_config_t)
  case reloadConfig(soft: Bool)
  case quit
  case unsupported(rawTag: UInt32, reason: String)

  var consumed: Bool {
    if case .unsupported = self { return false }
    return true
  }
}

// MARK: - Decode (C → Swift, any thread)

extension GhosttyActionDecoder {

  /// Synchronously decode a libghostty surface action into an owned Swift
  /// value. Safe to call on any thread — all pointer-backed fields are
  /// copied before return.
  nonisolated static func decodeSurfaceAction(  // swiftlint:disable:this cyclomatic_complexity function_body_length
    _ action: ghostty_action_s,
    paneID: PaneID
  ) -> DecodedSurfaceAction {
    switch action.tag {

    // Bucket 1 — Tab / split intent
    case GHOSTTY_ACTION_NEW_TAB:
      return .newTab

    case GHOSTTY_ACTION_CLOSE_TAB:
      guard let mode = decodeCloseTabMode(action.action.close_tab_mode) else {
        return .unsupported(rawTag: action.tag.rawValue, reason: "close_tab: unknown mode")
      }
      return .closeTab(mode: mode)

    case GHOSTTY_ACTION_MOVE_TAB:
      return .moveTab(offset: Int(action.action.move_tab.amount))

    case GHOSTTY_ACTION_GOTO_TAB:
      return .gotoTab(target: decodeGotoTabTarget(action.action.goto_tab))

    case GHOSTTY_ACTION_NEW_SPLIT:
      guard let dir = decodeNewSplitDirection(action.action.new_split) else {
        return .unsupported(rawTag: action.tag.rawValue, reason: "new_split: unknown direction")
      }
      return .newSplit(direction: dir)

    case GHOSTTY_ACTION_GOTO_SPLIT:
      guard let dir = decodeGotoSplitDirection(action.action.goto_split) else {
        return .unsupported(rawTag: action.tag.rawValue, reason: "goto_split: unknown direction")
      }
      return .gotoSplit(direction: dir)

    case GHOSTTY_ACTION_RESIZE_SPLIT:
      let resize = action.action.resize_split
      guard let dir = decodeResizeSplitDirection(resize.direction) else {
        return .unsupported(rawTag: action.tag.rawValue, reason: "resize_split: unknown direction")
      }
      return .resizeSplit(direction: dir, amount: Double(resize.amount))

    case GHOSTTY_ACTION_EQUALIZE_SPLITS:
      return .equalizeSplits

    case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
      return .toggleSplitZoom

    case GHOSTTY_ACTION_PRESENT_TERMINAL:
      return .presentTerminal

    case GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE:
      return .toggleCommandPalette

    // Bucket 2 — Window intent
    case GHOSTTY_ACTION_NEW_WINDOW: return .newWindow
    case GHOSTTY_ACTION_CLOSE_WINDOW: return .closeWindow
    case GHOSTTY_ACTION_CLOSE_ALL_WINDOWS: return .closeAllWindows
    case GHOSTTY_ACTION_GOTO_WINDOW:
      guard let target = decodeGotoWindowTarget(action.action.goto_window) else {
        return .unsupported(rawTag: action.tag.rawValue, reason: "goto_window: unknown target")
      }
      return .gotoWindow(target: target)
    case GHOSTTY_ACTION_TOGGLE_FULLSCREEN: return .toggleFullscreen
    case GHOSTTY_ACTION_TOGGLE_MAXIMIZE: return .toggleMaximize
    case GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW: return .toggleTabOverview
    case GHOSTTY_ACTION_TOGGLE_WINDOW_DECORATIONS:
      return .unsupported(rawTag: action.tag.rawValue, reason: "no macOS analog")
    case GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL:
      return .unsupported(rawTag: action.tag.rawValue, reason: "no codans analog")
    case GHOSTTY_ACTION_TOGGLE_VISIBILITY: return .toggleVisibility
    case GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY: return .toggleBackgroundOpacity
    case GHOSTTY_ACTION_QUIT: return .quit
    case GHOSTTY_ACTION_CHECK_FOR_UPDATES: return .checkForUpdates
    case GHOSTTY_ACTION_OPEN_CONFIG: return .openConfig

    // Bucket 3 — Surface info: title family (C strings — copy now)
    case GHOSTTY_ACTION_SET_TITLE:
      return .setTitle(String.decode(cstring: action.action.set_title.title))
    case GHOSTTY_ACTION_SET_TAB_TITLE:
      return .setTabTitle(String.decode(cstring: action.action.set_tab_title.title))
    case GHOSTTY_ACTION_PROMPT_TITLE:
      return .promptTitle(UInt32(action.action.prompt_title.rawValue))
    case GHOSTTY_ACTION_PWD:
      return .pwd(String.decode(cstring: action.action.pwd.pwd))

    // Bucket 3 — Mouse family
    case GHOSTTY_ACTION_MOUSE_SHAPE:
      return .mouseShape(UInt32(action.action.mouse_shape.rawValue))
    case GHOSTTY_ACTION_MOUSE_VISIBILITY:
      return .mouseVisible(action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE)
    case GHOSTTY_ACTION_MOUSE_OVER_LINK:
      let link = action.action.mouse_over_link
      return .mouseOverLink(String.decode(cstring: link.url, length: Int(link.len)))

    // Bucket 3 — Geometry
    case GHOSTTY_ACTION_CELL_SIZE:
      let s = action.action.cell_size
      return .cellSize(width: s.width, height: s.height)
    case GHOSTTY_ACTION_SIZE_LIMIT:
      let s = action.action.size_limit
      return .sizeLimit(
        minWidth: s.min_width, minHeight: s.min_height,
        maxWidth: s.max_width, maxHeight: s.max_height)
    case GHOSTTY_ACTION_INITIAL_SIZE:
      let s = action.action.initial_size
      return .initialSize(width: s.width, height: s.height)
    case GHOSTTY_ACTION_RESET_WINDOW_SIZE:
      return .resetWindowSize

    // Bucket 3 — Scrollbar / renderer / color
    case GHOSTTY_ACTION_SCROLLBAR:
      let s = action.action.scrollbar
      return .scrollbar(total: Int(s.total), offset: Int(s.offset), length: Int(s.len))
    case GHOSTTY_ACTION_RENDERER_HEALTH:
      return .rendererHealthy(action.action.renderer_health == GHOSTTY_RENDERER_HEALTH_HEALTHY)
    case GHOSTTY_ACTION_COLOR_CHANGE:
      let c = action.action.color_change
      return .colorChange(kind: Int32(c.kind.rawValue), r: c.r, g: c.g, b: c.b)

    // Bucket 3 — Secure input / key / readonly / timers
    case GHOSTTY_ACTION_SECURE_INPUT:
      return .secureInput(UInt32(action.action.secure_input.rawValue))
    case GHOSTTY_ACTION_KEY_SEQUENCE:
      let seq = action.action.key_sequence
      return .keySequence(active: seq.active, trigger: keyTriggerFingerprint(seq.trigger))
    case GHOSTTY_ACTION_KEY_TABLE:
      let (name, depth) = decodeKeyTable(action.action.key_table)
      return .keyTable(name: name, depth: depth)
    case GHOSTTY_ACTION_READONLY:
      return .readonly(action.action.readonly == GHOSTTY_READONLY_ON)
    case GHOSTTY_ACTION_QUIT_TIMER:
      return .quitTimer(UInt32(action.action.quit_timer.rawValue))
    case GHOSTTY_ACTION_FLOAT_WINDOW:
      return .floatWindow(action.action.float_window == GHOSTTY_FLOAT_WINDOW_ON)

    // Bucket 3 — Search
    case GHOSTTY_ACTION_START_SEARCH:
      let needle = String.decode(cstring: action.action.start_search.needle) ?? ""
      return .searchStarted(needle: needle)
    case GHOSTTY_ACTION_END_SEARCH:
      return .searchEnded
    case GHOSTTY_ACTION_SEARCH_TOTAL:
      return .searchTotal(Int(action.action.search_total.total))
    case GHOSTTY_ACTION_SEARCH_SELECTED:
      return .searchSelected(Int(action.action.search_selected.selected))

    // Bucket 3 — Progress
    case GHOSTTY_ACTION_PROGRESS_REPORT:
      let r = action.action.progress_report
      let value: Int? = r.progress == -1 ? nil : Int(r.progress)
      return .progress(state: UInt32(r.state.rawValue), value: value)

    // Bucket 4 — Effectful (C strings — copy now)
    case GHOSTTY_ACTION_OPEN_URL:
      let u = action.action.open_url
      guard let url = String.decode(cstring: u.url, length: Int(u.len)), !url.isEmpty else {
        return .unsupported(rawTag: action.tag.rawValue, reason: "open_url: empty payload")
      }
      return .openURL(url)
    case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
      let n = action.action.desktop_notification
      let title = String.decode(cstring: n.title) ?? ""
      let body = String.decode(cstring: n.body) ?? ""
      return .desktopNotification(title: title, body: body)
    case GHOSTTY_ACTION_RING_BELL:
      return .ringBell
    case GHOSTTY_ACTION_COMMAND_FINISHED:
      let f = action.action.command_finished
      return .commandFinished(exitCode: Int32(f.exit_code), duration: f.duration)
    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
      let ex = action.action.child_exited
      return .showChildExited(code: Int32(bitPattern: ex.exit_code))
    case GHOSTTY_ACTION_UNDO: return .undo
    case GHOSTTY_ACTION_REDO: return .redo
    case GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD:
      return .copyTitleToClipboard

    // Bucket 5 — Explicitly unsupported on macOS / internal to libghostty
    case GHOSTTY_ACTION_RENDER,
      GHOSTTY_ACTION_INSPECTOR,
      GHOSTTY_ACTION_SHOW_GTK_INSPECTOR,
      GHOSTTY_ACTION_RENDER_INSPECTOR,
      GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD:
      return .unsupported(rawTag: action.tag.rawValue, reason: "non-macOS / internal")

    // Config lifecycle: surface-target reload_config fires per surface after
    // `ghostty_surface_set_color_scheme` — needed for the light/dark palette
    // flip. App-target `config_change` should never arrive on a surface target
    // (programmer error).
    case GHOSTTY_ACTION_RELOAD_CONFIG:
      return .reloadConfig(soft: action.action.reload_config.soft)

    case GHOSTTY_ACTION_CONFIG_CHANGE:
      return .unsupported(rawTag: action.tag.rawValue, reason: "app-scoped on surface target")

    default:
      _ = paneID  // silence unused warning for exhaustive builds
      return .unsupported(rawTag: action.tag.rawValue, reason: "unknown tag")
    }
  }

  /// Synchronously decode an app-target action. `CONFIG_CHANGE` clones
  /// the `ghostty_config_t` handle here — on whatever thread libghostty
  /// called us — so we own it when the callback returns; the apply step
  /// only swaps pointers.
  nonisolated static func decodeAppAction(_ action: ghostty_action_s) -> DecodedAppAction {
    switch action.tag {
    case GHOSTTY_ACTION_CONFIG_CHANGE:
      guard let source = action.action.config_change.config,
        let cloned = ghostty_config_clone(source)
      else {
        return .unsupported(rawTag: action.tag.rawValue, reason: "config_clone returned nil")
      }
      return .configChange(cloned: cloned)
    case GHOSTTY_ACTION_RELOAD_CONFIG:
      return .reloadConfig(soft: action.action.reload_config.soft)
    case GHOSTTY_ACTION_QUIT:
      return .quit
    default:
      return .unsupported(rawTag: action.tag.rawValue, reason: "unknown app tag")
    }
  }
}

// MARK: - Apply (Swift-owned value → side effects, MainActor)

extension GhosttyActionDecoder {

  @MainActor
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  static func apply(
    _ decoded: DecodedSurfaceAction,
    paneID: PaneID,
    pane: PaneSurface,
    runtime: GhosttyRuntime
  ) -> Bool {
    switch decoded {

    // Bucket 1 — Tab / split intent
    case .newTab:
      return emitPaneIntent(.newTab, paneID: paneID, runtime: runtime)
    case .closeTab(let mode):
      return emitPaneIntent(.closeTab(mode: mode), paneID: paneID, runtime: runtime)
    case .moveTab(let offset):
      return emitPaneIntent(.moveTab(offset: offset), paneID: paneID, runtime: runtime)
    case .gotoTab(let target):
      return emitPaneIntent(.gotoTab(target: target), paneID: paneID, runtime: runtime)
    case .newSplit(let dir):
      return emitPaneIntent(.newSplit(direction: dir), paneID: paneID, runtime: runtime)
    case .gotoSplit(let dir):
      return emitPaneIntent(.gotoSplit(direction: dir), paneID: paneID, runtime: runtime)
    case .resizeSplit(let dir, let amount):
      return emitPaneIntent(
        .resizeSplit(direction: dir, amount: amount), paneID: paneID, runtime: runtime)
    case .equalizeSplits:
      return emitPaneIntent(.equalizeSplits, paneID: paneID, runtime: runtime)
    case .toggleSplitZoom:
      return emitPaneIntent(.toggleSplitZoom, paneID: paneID, runtime: runtime)
    case .presentTerminal:
      return emitPaneIntent(.presentTerminal, paneID: paneID, runtime: runtime)
    case .toggleCommandPalette:
      return emitPaneIntent(.toggleCommandPalette, paneID: paneID, runtime: runtime)

    // Bucket 2 — Window intent
    case .newWindow:
      return emitWindowIntent(.new(from: paneID), runtime: runtime)
    case .closeWindow:
      return emitWindowIntent(.close(from: paneID), runtime: runtime)
    case .closeAllWindows:
      return emitWindowIntent(.closeAll, runtime: runtime)
    case .gotoWindow(let target):
      return emitWindowIntent(.goto(target: target), runtime: runtime)
    case .toggleFullscreen:
      return emitWindowIntent(.toggleFullscreen(from: paneID), runtime: runtime)
    case .toggleMaximize:
      return emitWindowIntent(.toggleMaximize(from: paneID), runtime: runtime)
    case .toggleTabOverview:
      return emitWindowIntent(.toggleTabOverview(from: paneID), runtime: runtime)
    case .toggleVisibility:
      return emitWindowIntent(.toggleAppVisibility, runtime: runtime)
    case .toggleBackgroundOpacity:
      runtime.toggleBackgroundOpacity()
      logger.debug("surface action: toggle_background_opacity")
      return true
    case .quit:
      return emitWindowIntent(.quit, runtime: runtime)
    case .checkForUpdates:
      return emitWindowIntent(.checkForUpdates, runtime: runtime)
    case .openConfig:
      return emitWindowIntent(.openConfig, runtime: runtime)

    // Bucket 3 — Surface info
    case .setTitle(let title):
      return emitInfo(.title(title), pane: pane, paneID: paneID, runtime: runtime)
    case .setTabTitle(let title):
      return emitInfo(.tabTitle(title), pane: pane, paneID: paneID, runtime: runtime)
    case .promptTitle(let raw):
      return emitInfo(.promptTitle(raw), pane: pane, paneID: paneID, runtime: runtime)
    case .pwd(let pwd):
      return emitInfo(.pwd(pwd), pane: pane, paneID: paneID, runtime: runtime)
    case .mouseShape(let raw):
      return emitInfo(.mouseShape(raw), pane: pane, paneID: paneID, runtime: runtime)
    case .mouseVisible(let visible):
      return emitInfo(.mouseVisible(visible), pane: pane, paneID: paneID, runtime: runtime)
    case .mouseOverLink(let link):
      return emitInfo(.mouseOverLink(link), pane: pane, paneID: paneID, runtime: runtime)
    case .colorChange(let kind, let r, let g, let b):
      return emitInfo(
        .colorChange(kind: kind, r: r, g: g, b: b),
        pane: pane, paneID: paneID, runtime: runtime)
    case .rendererHealthy(let healthy):
      return emitInfo(.rendererHealthy(healthy), pane: pane, paneID: paneID, runtime: runtime)
    case .cellSize(let w, let h):
      return emitInfo(
        .cellSize(width: w, height: h), pane: pane, paneID: paneID, runtime: runtime)
    case .sizeLimit(let mnw, let mnh, let mxw, let mxh):
      return emitInfo(
        .sizeLimit(minWidth: mnw, minHeight: mnh, maxWidth: mxw, maxHeight: mxh),
        pane: pane, paneID: paneID, runtime: runtime)
    case .initialSize(let w, let h):
      return emitInfo(
        .initialSize(width: w, height: h), pane: pane, paneID: paneID, runtime: runtime)
    case .resetWindowSize:
      return emitInfo(.resetWindowSize, pane: pane, paneID: paneID, runtime: runtime)
    case .scrollbar(let total, let offset, let length):
      return emitInfo(
        .scrollbar(total: total, offset: offset, length: length),
        pane: pane, paneID: paneID, runtime: runtime)
    case .secureInput(let raw):
      return emitInfo(.secureInput(raw), pane: pane, paneID: paneID, runtime: runtime)
    case .keySequence(let active, let trigger):
      return emitInfo(
        .keySequence(active: active, trigger: trigger),
        pane: pane, paneID: paneID, runtime: runtime)
    case .keyTable(let name, let depth):
      return emitInfo(
        .keyTable(name: name, depth: depth),
        pane: pane, paneID: paneID, runtime: runtime)
    case .readonly(let on):
      return emitInfo(.readonly(on), pane: pane, paneID: paneID, runtime: runtime)
    case .quitTimer(let raw):
      return emitInfo(.quitTimer(raw), pane: pane, paneID: paneID, runtime: runtime)
    case .floatWindow(let floating):
      return emitInfo(.floatWindow(floating), pane: pane, paneID: paneID, runtime: runtime)
    case .searchStarted(let needle):
      return emitInfo(
        .searchStarted(needle: needle), pane: pane, paneID: paneID, runtime: runtime)
    case .searchEnded:
      return emitInfo(.searchEnded, pane: pane, paneID: paneID, runtime: runtime)
    case .searchTotal(let t):
      return emitInfo(.searchTotal(t), pane: pane, paneID: paneID, runtime: runtime)
    case .searchSelected(let s):
      return emitInfo(.searchSelected(s), pane: pane, paneID: paneID, runtime: runtime)
    case .progress(let state, let value):
      return emitInfo(
        .progress(state: state, value: value),
        pane: pane, paneID: paneID, runtime: runtime)

    // Bucket 4 — Effectful
    case .openURL(let url):
      return handleOpenURL(url)
    case .desktopNotification(let title, let body):
      return emitInfo(
        .desktopNotification(title: title, body: body),
        pane: pane, paneID: paneID, runtime: runtime)
    case .ringBell:
      return emitInfo(.bellRang, pane: pane, paneID: paneID, runtime: runtime)
    case .commandFinished(let exit, let duration):
      return emitInfo(
        .commandFinished(exitCode: exit, duration: duration),
        pane: pane, paneID: paneID, runtime: runtime)
    case .showChildExited(let code):
      pane.markExited(code: code)
      runtime.emitInfoChanged(paneID, .childExited(code: code))
      logger.debug("surface action: show_child_exited (code \(code))")
      // libghostty's `childExited` does NOT call `self.close()` on macOS: the
      // `login` wrapper breaks its runtime/exit-code detection, so every child
      // exit is classified "abnormal" and the surface parks on a blank screen
      // ("Process exited. Press any key…") until the user presses a key. Nothing
      // downstream tears the pane down on its own, so a plain `exit` leaves a
      // ghost pane and a "Close when finished" command's `<cmd>; exit` never
      // fires its close-tab / close-pane policy (paneExited is what
      // `scheduleOnFinishedAction` waits on). Drive the normal close path
      // ourselves. Deferred to the next main-actor hop so libghostty has
      // unwound out of this action dispatch before the surface is disposed;
      // re-resolving the surface keeps a concurrent close (the non-abnormal
      // path emits this action immediately before `self.close()`) from tearing
      // the pane down twice.
      Task { @MainActor in
        runtime.surface(for: paneID)?.requestClose(processAlive: false)
      }
      return true
    case .undo:
      NSApp.sendAction(#selector(UndoManager.undo), to: nil, from: nil)
      return true
    case .redo:
      NSApp.sendAction(#selector(UndoManager.redo), to: nil, from: nil)
      return true
    case .copyTitleToClipboard:
      if let title = pane.info.title, !title.isEmpty {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(title, forType: .string)
        logger.debug("surface action: copy_title_to_clipboard (\(title.count) chars)")
      } else {
        logger.debug("surface action: copy_title_to_clipboard (no title)")
      }
      return true

    // Bucket 5 — Config lifecycle
    case .reloadConfig(let soft):
      runtime.reloadSurfaceConfig(paneID: paneID, soft: soft)
      logger.debug("surface action: reload_config (soft: \(soft))")
      return true

    case .unsupported(let rawTag, let reason):
      logger.info("unsupported surface action tag=\(rawTag): \(reason)")
      return false
    }
  }

  @MainActor
  static func apply(
    _ decoded: DecodedAppAction,
    runtime: GhosttyRuntime
  ) -> Bool {
    switch decoded {
    case .configChange(let cloned):
      runtime.applyClonedConfig(cloned)
      runtime.emit(.configChanged)
      logger.debug("app action: config_change")
      return true
    case .reloadConfig(let soft):
      runtime.reloadConfig(soft: soft)
      runtime.emit(.configChanged)
      logger.debug("app action: reload_config (soft: \(soft))")
      return true
    case .quit:
      runtime.emit(.windowActionRequested(.quit))
      logger.debug("app action: quit")
      return true
    case .unsupported(let rawTag, let reason):
      logger.info("unsupported app action tag=\(rawTag): \(reason)")
      return false
    }
  }
}

// MARK: - Dispatch helpers

extension GhosttyActionDecoder {

  @MainActor
  fileprivate static func emitPaneIntent(
    _ request: PaneActionRequest,
    paneID: PaneID,
    runtime: GhosttyRuntime
  ) -> Bool {
    runtime.emit(.paneActionRequested(paneID, request))
    return true
  }

  @MainActor
  fileprivate static func emitWindowIntent(
    _ request: WindowActionRequest,
    runtime: GhosttyRuntime
  ) -> Bool {
    runtime.emit(.windowActionRequested(request))
    return true
  }

  @MainActor
  fileprivate static func emitInfo(
    _ delta: PaneInfoDelta,
    pane: PaneSurface,
    paneID: PaneID,
    runtime: GhosttyRuntime
  ) -> Bool {
    pane.apply(delta)
    runtime.emitInfoChanged(paneID, delta)
    return true
  }
}

// MARK: - C enum decoders (pure, any thread)

extension GhosttyActionDecoder {

  // Note: these six decoders are `internal static` so
  // `@testable import Codans` can reach them from
  // `GhosttyActionDecoderTests`.
  nonisolated static func decodeCloseTabMode(
    _ mode: ghostty_action_close_tab_mode_e
  ) -> CloseTabMode? {
    switch mode {
    case GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS: return .this
    case GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER: return .other
    case GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT: return .right
    default: return nil
    }
  }

  nonisolated static func decodeGotoTabTarget(
    _ tab: ghostty_action_goto_tab_e
  ) -> GotoTabTarget {
    switch tab {
    case GHOSTTY_GOTO_TAB_PREVIOUS: return .previous
    case GHOSTTY_GOTO_TAB_NEXT: return .next
    case GHOSTTY_GOTO_TAB_LAST: return .last
    default: return .index(Int(tab.rawValue))
    }
  }

  nonisolated static func decodeNewSplitDirection(
    _ dir: ghostty_action_split_direction_e
  ) -> NewSplitDirection? {
    switch dir {
    case GHOSTTY_SPLIT_DIRECTION_RIGHT: return .right
    case GHOSTTY_SPLIT_DIRECTION_LEFT: return .left
    case GHOSTTY_SPLIT_DIRECTION_UP: return .up
    case GHOSTTY_SPLIT_DIRECTION_DOWN: return .down
    default: return nil
    }
  }

  nonisolated static func decodeGotoSplitDirection(
    _ dir: ghostty_action_goto_split_e
  ) -> FocusDirection? {
    switch dir {
    case GHOSTTY_GOTO_SPLIT_PREVIOUS: return .previous
    case GHOSTTY_GOTO_SPLIT_NEXT: return .next
    case GHOSTTY_GOTO_SPLIT_UP: return .up
    case GHOSTTY_GOTO_SPLIT_DOWN: return .down
    case GHOSTTY_GOTO_SPLIT_LEFT: return .left
    case GHOSTTY_GOTO_SPLIT_RIGHT: return .right
    default: return nil
    }
  }

  nonisolated static func decodeResizeSplitDirection(
    _ dir: ghostty_action_resize_split_direction_e
  ) -> ResizeDirection? {
    switch dir {
    case GHOSTTY_RESIZE_SPLIT_UP: return .up
    case GHOSTTY_RESIZE_SPLIT_DOWN: return .down
    case GHOSTTY_RESIZE_SPLIT_LEFT: return .left
    case GHOSTTY_RESIZE_SPLIT_RIGHT: return .right
    default: return nil
    }
  }

  nonisolated static func decodeGotoWindowTarget(
    _ target: ghostty_action_goto_window_e
  ) -> GotoWindowTarget? {
    switch target {
    case GHOSTTY_GOTO_WINDOW_PREVIOUS: return .previous
    case GHOSTTY_GOTO_WINDOW_NEXT: return .next
    default: return nil
    }
  }

  /// Collapse the 3-variant key_table tag + optional name into the flat
  /// `(name, depth)` shape of `PaneInfoDelta.keyTable`. Depth mirrors the
  /// tag semantics: ACTIVATE=+1, DEACTIVATE=-1, DEACTIVATE_ALL=0 (reset).
  fileprivate nonisolated static func decodeKeyTable(
    _ table: ghostty_action_key_table_s
  ) -> (name: String?, depth: Int) {
    switch table.tag {
    case GHOSTTY_KEY_TABLE_ACTIVATE:
      let activate = table.value.activate
      let name = String.decode(cstring: activate.name, length: Int(activate.len))
      return (name, 1)
    case GHOSTTY_KEY_TABLE_DEACTIVATE:
      return (nil, -1)
    case GHOSTTY_KEY_TABLE_DEACTIVATE_ALL:
      return (nil, 0)
    default:
      return (nil, 0)
    }
  }

  /// Flatten `ghostty_input_trigger_s` into a UInt32 fingerprint. Consumers
  /// only need a change-detector today, so we hash the struct bytes rather
  /// than model every field on `PaneInfoDelta`.
  fileprivate nonisolated static func keyTriggerFingerprint(
    _ trigger: ghostty_input_trigger_s
  ) -> UInt32 {
    var hasher = Hasher()
    withUnsafeBytes(of: trigger) { buffer in
      hasher.combine(bytes: buffer)
    }
    return UInt32(truncatingIfNeeded: hasher.finalize())
  }
}

// MARK: - Effectful helpers

extension GhosttyActionDecoder {

  /// OPEN_URL: validate the scheme and hand off to LaunchServices. The
  /// decoded string has already been copied to Swift-owned memory, so this
  /// runs entirely on the Swift side.
  @MainActor
  fileprivate static func handleOpenURL(_ url: String) -> Bool {
    guard let parsed = URL(string: url), parsed.scheme?.isEmpty == false else {
      logger.info("open_url: rejected (missing scheme: \(url))")
      return false
    }
    NSWorkspace.shared.open(parsed)
    logger.debug("surface action: open_url scheme=\(parsed.scheme ?? "?")")
    return true
  }
}

// MARK: - String decoding

extension String {

  /// Copy a null-terminated C string into Swift. Returns nil if the pointer
  /// is null. The decoder uses this for every `const char*` action field so
  /// null-vs-empty is preserved downstream.
  ///
  /// `nonisolated` so the libghostty-callback-thread decode path can call
  /// these helpers — the Swift 6 default isolation in this target is
  /// `MainActor`, which would otherwise make them MainActor-isolated.
  fileprivate nonisolated static func decode(cstring: UnsafePointer<CChar>?) -> String? {
    guard let cstring else { return nil }
    return String(cString: cstring)
  }

  /// Copy a length-delimited C byte run into Swift (UTF-8). Used for fields
  /// where libghostty passes an explicit length alongside the pointer so
  /// the string may contain embedded NULs (unusual) or be non-terminated.
  fileprivate nonisolated static func decode(cstring: UnsafePointer<CChar>?, length: Int) -> String? {
    guard let cstring, length >= 0 else { return nil }
    if length == 0 { return "" }
    let buffer = UnsafeBufferPointer(start: cstring, count: length)
    return buffer.withMemoryRebound(to: UInt8.self) { bytes in
      String(bytes: bytes, encoding: .utf8)
    }
  }
}
