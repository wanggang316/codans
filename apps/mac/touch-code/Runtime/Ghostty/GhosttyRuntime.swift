import AppKit
import Foundation
import GhosttyKit
import SwiftUI
import TouchCodeCore

/// Process-global libghostty façade. Owns one `ghostty_app_t` and the runtime
/// config whose callbacks route via a user-data pointer back to a weak
/// reference to `self`. Surface-scoped callbacks (`close_surface_cb`) use a
/// separate per-surface userdata (the `PaneSurface` pointer) so the
/// callback can route directly to the owning pane without a registry
/// lookup on the hot path.
@MainActor
final class GhosttyRuntime {
  struct Info {
    let version: String
    let buildMode: String
  }

  /// Strong handle bridging the C callback userdata pointer back to an
  /// instance-isolated dispatcher. Lives behind an Unmanaged retain until
  /// deinit releases it on the next main-queue turn.
  final class CallbackDispatcher {
    weak var runtime: GhosttyRuntime?

    /// App-level: libghostty wants us to tick it soon.
    var onWakeup: (@MainActor () -> Void)?
    /// App-level: libghostty action; return true if consumed.
    var onAction: (@MainActor (ghostty_app_t, ghostty_target_s, ghostty_action_s) -> Bool)?
  }

  static var info: Info {
    _ = GhosttyBootstrap.initialize
    let raw = ghostty_info()
    let version =
      (NSString(
        bytes: raw.version,
        length: Int(raw.version_len),
        encoding: NSUTF8StringEncoding
      ) as String?) ?? "unknown"

    let mode: String =
      switch raw.build_mode {
      case GHOSTTY_BUILD_MODE_DEBUG: "Debug"
      case GHOSTTY_BUILD_MODE_RELEASE_SAFE: "ReleaseSafe"
      case GHOSTTY_BUILD_MODE_RELEASE_FAST: "ReleaseFast"
      case GHOSTTY_BUILD_MODE_RELEASE_SMALL: "ReleaseSmall"
      default: "Unknown"
      }
    return Info(version: version, buildMode: mode)
  }

  private(set) var app: ghostty_app_t?
  private var config: ghostty_config_t?
  let dispatcher = CallbackDispatcher()
  private var appFocusObservers: [NSObjectProtocol] = []

  /// Back-reference to the engine whose event stream surfaces action decoder
  /// emits (`paneInfoChanged`, `paneActionRequested`, etc.). Weak to
  /// avoid a retain cycle with `TerminalEngine.ghosttyRuntime`; the engine
  /// outlives the runtime in every supported configuration, so a dangling
  /// reference is a bug elsewhere.
  weak var terminalEngine: TerminalEngine?

  /// Last resolved color scheme applied via `setColorScheme(_:)`. Newly registered
  /// surfaces adopt this on registration so a pane opened mid-session starts in the
  /// correct palette without waiting for the next toggle.
  private var lastColorScheme: ghostty_color_scheme_e?

  /// Retained observer token for `.ghosttyRuntimeReloadRequested`. Removed in deinit so
  /// the closure can't race a freed runtime after the app shuts down.
  private var reloadObserver: NSObjectProtocol?

  /// Process-global weak reference used by C callback shims that hop through
  /// DispatchQueue.main.async — the original dispatcher userdata may point
  /// to freed memory by the time the async block runs, so we go through the
  /// MainActor-isolated static instead. Only one GhosttyRuntime exists per
  /// process; init/deinit set and clear this.
  nonisolated(unsafe) static weak var shared: GhosttyRuntime?

  /// Registered pane surfaces by PaneID. Referenced by engine code that
  /// needs to look up a surface from a Pane (e.g. lazy surface creation on
  /// tab activation). Surface-scoped callbacks do NOT use this table on the
  /// hot path — they cast the per-surface userdata directly to `PaneSurface`.
  private var surfacesByPaneID: [PaneID: PaneSurface] = [:]

  init() throws {
    _ = GhosttyBootstrap.initialize

    guard let config = GhosttyConfigLoader.makeFreshConfig() else {
      throw GhosttyError.configInitFailed
    }
    self.config = config

    dispatcher.runtime = self
    // libghostty signals "I have work pending; please call ghostty_app_tick
    // soon" via wakeup_cb. Without a real handler the action queue, new-
    // surface shell fork, keybind dispatch, and mouse state all stall.
    // The wakeup shim hops to main; tick on the MainActor here.
    dispatcher.onWakeup = { [weak self] in
      self?.tick()
    }
    let userdata = Unmanaged.passRetained(dispatcher).toOpaque()
    var runtimeConfig = ghostty_runtime_config_s(
      userdata: userdata,
      supports_selection_clipboard: true,
      wakeup_cb: Self.wakeupCallback,
      action_cb: Self.actionCallback,
      read_clipboard_cb: Self.readClipboardCallback,
      confirm_read_clipboard_cb: Self.confirmReadClipboardCallback,
      write_clipboard_cb: Self.writeClipboardCallback,
      close_surface_cb: Self.closeSurfaceCallback
    )

    guard let app = ghostty_app_new(&runtimeConfig, config) else {
      Unmanaged<CallbackDispatcher>.fromOpaque(userdata).release()
      throw GhosttyError.appInitFailed(reason: "ghostty_app_new returned nil")
    }
    self.app = app
    Self.shared = self

    // App-level focus notifications. libghostty gates some global behavior
    // (e.g. bell, bracketed-paste toasts) on app focus; without these the
    // runtime thinks the app is always backgrounded.
    let center = NotificationCenter.default
    appFocusObservers.append(
      center.addObserver(
        forName: NSApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let app = self?.app else { return }
          ghostty_app_set_focus(app, true)
        }
      }
    )
    appFocusObservers.append(
      center.addObserver(
        forName: NSApplication.didResignActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let app = self?.app else { return }
          ghostty_app_set_focus(app, false)
        }
      }
    )
    // Initialise to the current state so a runtime created after the app has
    // already activated doesn't start out "unfocused".
    ghostty_app_set_focus(app, NSApp.isActive)

    // Subscribe to config-file writes from `GhosttyConfigFile.apply`; we re-parse from
    // disk and push the new config into libghostty. Using a weak capture avoids a
    // retain cycle through the default NotificationCenter.
    self.reloadObserver = center.addObserver(
      forName: .ghosttyRuntimeReloadRequested,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.reloadAppConfig()
      }
    }
  }

  isolated deinit {
    let center = NotificationCenter.default
    if let reloadObserver {
      center.removeObserver(reloadObserver)
    }
    for observer in appFocusObservers {
      center.removeObserver(observer)
    }
    appFocusObservers.removeAll()

    for (_, pane) in surfacesByPaneID {
      pane.close()
    }
    surfacesByPaneID.removeAll()

    if let app {
      ghostty_app_free(app)
    }
    if let config {
      ghostty_config_free(config)
    }
    let handle = Unmanaged.passUnretained(dispatcher).toOpaque()
    DispatchQueue.main.async {
      Unmanaged<CallbackDispatcher>.fromOpaque(handle).release()
    }
  }

  // MARK: - Surface registry

  func register(pane: PaneSurface) {
    surfacesByPaneID[pane.paneID] = pane
    // A surface registered mid-session inherits the most recently applied scheme so
    // the palette matches the app's current appearance from its first frame.
    if let lastColorScheme {
      pane.applyColorScheme(lastColorScheme)
    }
  }

  func unregister(paneID: PaneID) {
    surfacesByPaneID.removeValue(forKey: paneID)
  }

  func surface(for paneID: PaneID) -> PaneSurface? {
    surfacesByPaneID[paneID]
  }

  /// Force-clear libghostty focus on every surface except `target`. Called
  /// by `TerminalEngine.focusSurfaceView` before `makeFirstResponder` so
  /// surfaces left stale by AppKit's focus machinery (e.g. briefly-detached
  /// views that never received `resignFirstResponder`) stop rendering a
  /// blinking cursor. `ghostty_surface_set_focus(false)` is idempotent, so
  /// it's safe to call on surfaces that are already unfocused.
  func defocusAllSurfaces(except target: PaneID?) {
    for (pid, pane) in surfacesByPaneID where pid != target {
      pane.setFocus(false)
    }
  }

  func tick() {
    guard let app else { return }
    ghostty_app_tick(app)
  }

  // MARK: - Appearance

  /// Applies a color scheme signal to libghostty — tells Ghostty which of its two
  /// configured palettes (light / dark) to render. Cheap, in-memory, synchronous.
  /// Invoked on every app appearance change (user picker toggle, OS dark-mode flip).
  /// Distinct from `reloadAppConfig()`: no file I/O, no config re-parse.
  func setColorScheme(_ scheme: SwiftUI.ColorScheme) {
    guard let app else { return }
    let ghosttyScheme: ghostty_color_scheme_e =
      scheme == .dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
    lastColorScheme = ghosttyScheme
    ghostty_app_set_color_scheme(app, ghosttyScheme)
    for pane in surfacesByPaneID.values {
      pane.applyColorScheme(ghosttyScheme)
    }
    applyBackgroundColorToWindows()
  }

  /// Current ghostty theme background color (from the `background` config
  /// key, which libghostty resolves against the active light/dark theme).
  /// Falls back to `NSColor.windowBackgroundColor` when the config can't be
  /// read — e.g. before `bringUp()` finishes, or in tests with no runtime.
  ///
  /// Used by `applyBackgroundColorToWindows` to stain the NSWindow
  /// background so the translucent sidebar material (blended `withinWindow`
  /// against pixels underneath) reads as the terminal's theme tone rather
  /// than the system window color. Matches supacode's approach.
  func backgroundColor() -> NSColor {
    guard let config else { return .windowBackgroundColor }
    var color = ghostty_config_color_s()
    let key = "background"
    let keyLen = UInt(key.lengthOfBytes(using: .utf8))
    guard ghostty_config_get(config, &color, key, keyLen) else {
      return .windowBackgroundColor
    }
    return NSColor(ghostty: color)
  }

  /// Mirror of ghostty's `Ghostty.Config.unfocusedSplitOpacity`. Reads the
  /// `unfocused-split-opacity` config key (default 0.85 — surface visibility,
  /// not overlay opacity) and returns the inverted overlay opacity used to
  /// dim unfocused split panes. Falls back to 0.15 when the runtime hasn't
  /// loaded a config yet.
  func unfocusedSplitOpacity() -> Double {
    guard let config else { return 0.15 }
    var opacity: Double = 0.85
    let key = "unfocused-split-opacity"
    let keyLen = UInt(key.lengthOfBytes(using: .utf8))
    _ = ghostty_config_get(config, &opacity, key, keyLen)
    return 1 - opacity
  }

  /// Same as `unfocusedSplitFill()` but accepts the SwiftUI environment
  /// color-scheme so call-sites in views establish a body-tracking dependency.
  /// The parameter does not affect computation — libghostty's `background`
  /// key already resolves against the active palette on color-scheme flip;
  /// this overload exists purely so SwiftUI re-renders the dim overlay when
  /// the user toggles Appearance.
  func unfocusedSplitFill(_ scheme: SwiftUI.ColorScheme) -> NSColor {
    _ = scheme
    return unfocusedSplitFill()
  }

  /// Mirror of ghostty's `Ghostty.Config.unfocusedSplitFill`. Reads
  /// `unfocused-split-fill`; if unset, falls back to the terminal `background`
  /// color so the dim overlay tints the surface with its own theme color
  /// (not pure black).
  func unfocusedSplitFill() -> NSColor {
    guard let config else { return .windowBackgroundColor }
    var color = ghostty_config_color_s()
    let fillKey = "unfocused-split-fill"
    let fillKeyLen = UInt(fillKey.lengthOfBytes(using: .utf8))
    if !ghostty_config_get(config, &color, fillKey, fillKeyLen) {
      let bgKey = "background"
      let bgKeyLen = UInt(bgKey.lengthOfBytes(using: .utf8))
      guard ghostty_config_get(config, &color, bgKey, bgKeyLen) else {
        return .windowBackgroundColor
      }
    }
    return NSColor(ghostty: color)
  }

  /// Push the current ghostty theme background to every NSWindow in the app.
  /// Called on color-scheme changes (from `setColorScheme`) and, through
  /// `WindowAppearanceSetter`, on appearance-preference toggles. Idempotent.
  private func applyBackgroundColorToWindows() {
    let color = backgroundColor()
    for window in NSApp.windows {
      // Settings window opts out of the Ghostty terminal-background stain;
      // restore the stock `.windowBackgroundColor` so the pane keeps the
      // standard macOS Settings tone across scheme flips.
      if SettingsWindowTagger.matches(window) {
        window.backgroundColor = .windowBackgroundColor
        continue
      }
      window.backgroundColor = color
    }
  }

  /// Triggered by `.ghosttyRuntimeReloadRequested`, which `GhosttyConfigFile.apply`
  /// posts after writing the managed region of the user's Ghostty config. Delegates
  /// to `reloadConfig(soft:)`, the shared primitive used by the action-decoder path
  /// — keeping one implementation of the "rebuild from disk" behaviour.
  func reloadAppConfig() {
    reloadConfig(soft: false)
  }

  // MARK: - C callback shims

  private static let wakeupCallback: (@convention(c) (UnsafeMutableRawPointer?) -> Void) = { userdata in
    guard let userdata else { return }
    let dispatcher = Unmanaged<CallbackDispatcher>.fromOpaque(userdata).takeUnretainedValue()
    DispatchQueue.main.async {
      dispatcher.onWakeup?()
    }
  }

  private static let actionCallback: (@convention(c) (ghostty_app_t?, ghostty_target_s, ghostty_action_s) -> Bool) = {
    _, target, action in
    // libghostty may invoke action_cb on a non-main thread. We must decode
    // the payload *here*, synchronously — several action tags
    // (SET_TITLE / PWD / MOUSE_OVER_LINK / START_SEARCH / OPEN_URL /
    // DESKTOP_NOTIFICATION / KEY_TABLE / CONFIG_CHANGE) carry C pointers
    // borrowed from libghostty for the duration of the callback; if we
    // defer the read to a later main-queue hop those pointers are dangling.
    //
    // Decode converts everything to owned Swift values (copied Strings +
    // a cloned `ghostty_config_t` for CONFIG_CHANGE) and reports the
    // "consumed" verdict synchronously, so the C return value always
    // matches what the applier will do — no more false-return-but-
    // applied races.
    if ProcessInfo.processInfo.environment["TOUCH_CODE_DISABLE_ACTION_ROUTING"] == "1" {
      return false
    }

    let targetTag = target.tag
    let surface: ghostty_surface_t? = targetTag == GHOSTTY_TARGET_SURFACE ? target.target.surface : nil
    // PaneID is only meaningful for surface-scoped actions. We need it to
    // emit paneActionRequested / windowActionRequested from the right
    // pane, and it must be resolved here while userdata is valid.
    let paneID: PaneID? = surface.flatMap { GhosttyRuntime.paneIDBytes(fromSurface: $0) }

    GhosttyActionDecoder.logger.debug(
      "action_cb fired: targetTag=\(targetTag.rawValue, privacy: .public) tag=\(action.tag.rawValue, privacy: .public)"
    )

    switch targetTag {
    case GHOSTTY_TARGET_APP:
      let decoded = GhosttyActionDecoder.decodeAppAction(action)
      let consumed = decoded.consumed
      if Thread.isMainThread {
        return MainActor.assumeIsolated {
          _ = GhosttyRuntime.shared?.applyAppAction(decoded)
          return consumed
        }
      }
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          _ = GhosttyRuntime.shared?.applyAppAction(decoded)
        }
      }
      return consumed

    case GHOSTTY_TARGET_SURFACE:
      guard let paneID else { return false }
      let decoded = GhosttyActionDecoder.decodeSurfaceAction(action, paneID: paneID)
      let consumed = decoded.consumed
      if Thread.isMainThread {
        return MainActor.assumeIsolated {
          _ = GhosttyRuntime.shared?.applySurfaceAction(decoded, paneID: paneID)
          return consumed
        }
      }
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          _ = GhosttyRuntime.shared?.applySurfaceAction(decoded, paneID: paneID)
        }
      }
      return consumed

    default:
      return false
    }
  }

  // MARK: - Action apply (MainActor — consumes decoded Swift values)

  @MainActor
  fileprivate func applyAppAction(_ decoded: DecodedAppAction) -> Bool {
    GhosttyActionDecoder.apply(decoded, runtime: self)
  }

  @MainActor
  fileprivate func applySurfaceAction(_ decoded: DecodedSurfaceAction, paneID: PaneID) -> Bool {
    guard let pane = surfacesByPaneID[paneID] else { return false }
    return GhosttyActionDecoder.apply(decoded, paneID: paneID, pane: pane, runtime: self)
  }

  /// Copy the PaneID uuid bytes out of libghostty-stored userdata. Same
  /// pattern as `closeSurfaceCallback` — UAF-safe because userdata points
  /// to a 16-byte allocation owned by `PaneSurface` for the surface's
  /// lifetime; we only read the bytes, never the owning Swift object.
  /// `nonisolated` so the C callback thunk can resolve the PaneID on
  /// whatever thread libghostty invokes us (the read is a pure byte copy).
  nonisolated static func paneIDBytes(fromSurface surface: ghostty_surface_t) -> PaneID? {
    guard let raw = ghostty_surface_userdata(surface) else { return nil }
    return paneID(fromRawUserdata: raw)
  }

  /// Read 16 uuid_t bytes from a raw userdata pointer. Used by clipboard
  /// and close callbacks that receive surface-userdata directly.
  nonisolated static func paneID(fromRawUserdata raw: UnsafeMutableRawPointer) -> PaneID {
    var bytes = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    withUnsafeMutableBytes(of: &bytes) { dst in
      _ = dst.baseAddress.map { base in
        base.copyMemory(from: raw, byteCount: MemoryLayout<uuid_t>.size)
      }
    }
    return PaneID(raw: UUID(uuid: bytes))
  }

  // MARK: - Clipboard callbacks

  /// Map ghostty's clipboard enum to the AppKit pasteboard. We route
  /// SELECTION to a dedicated named pasteboard the way mitchellh/ghostty
  /// does so OSC52 "selection" writes don't clobber the user's general
  /// clipboard.
  @MainActor static func pasteboard(for clipboard: ghostty_clipboard_e) -> NSPasteboard? {
    switch clipboard {
    case GHOSTTY_CLIPBOARD_STANDARD:
      return NSPasteboard.general
    case GHOSTTY_CLIPBOARD_SELECTION:
      return ghosttySelectionPasteboard
    default:
      return nil
    }
  }

  // Named selection pasteboard so SELECTION writes don't clobber the
  // user's general clipboard. `@MainActor` keeps concurrency happy — all
  // our clipboard code hops through MainActor before touching it.
  @MainActor private static let ghosttySelectionPasteboard: NSPasteboard = {
    NSPasteboard(name: .init("com.mitchellh.ghostty.selection"))
  }()

  /// Read clipboard on libghostty's behalf. Must return synchronously;
  /// if not on the main thread we hop via `DispatchQueue.main.sync`.
  /// The reported `state` pointer is opaque — must be handed back to
  /// `ghostty_surface_complete_clipboard_request` unchanged.
  private static let readClipboardCallback:
    (@convention(c) (UnsafeMutableRawPointer?, ghostty_clipboard_e, UnsafeMutableRawPointer?) -> Bool) = {
      userdata, location, state in
      guard let userdata else { return false }
      let paneID = paneID(fromRawUserdata: userdata)
      let stateBits = state.map { UInt(bitPattern: $0) }
      let complete: @MainActor () -> Bool = {
        guard let pane = GhosttyRuntime.shared?.surface(for: paneID) else { return false }
        guard let pb = pasteboard(for: location),
          let text = pb.string(forType: .string)
        else { return false }
        let stateBack = stateBits.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
        pane.completeClipboardRequest(text: text, state: stateBack, confirmed: false)
        return true
      }
      if Thread.isMainThread {
        return MainActor.assumeIsolated { complete() }
      }
      return DispatchQueue.main.sync {
        MainActor.assumeIsolated { complete() }
      }
    }

  /// Follow-up for the OSC52 paste-confirmation flow. Ghostty calls this
  /// once the user (via our UI, eventually) has approved an inbound paste;
  /// today we simply forward the provided string to the surface. The
  /// confirmation dialog itself is deferred — we trust the OSC52 sender
  /// by default.
  private static let confirmReadClipboardCallback:
    (
      @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?, ghostty_clipboard_request_e
      ) -> Void
    ) = {
      userdata, cString, state, _ in
      guard let userdata, let cString else { return }
      let value = String(cString: cString)
      let paneID = paneID(fromRawUserdata: userdata)
      let stateBits = state.map { UInt(bitPattern: $0) }
      let complete: @MainActor () -> Void = {
        guard let pane = GhosttyRuntime.shared?.surface(for: paneID) else { return }
        let stateBack = stateBits.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
        pane.completeClipboardRequest(text: value, state: stateBack, confirmed: true)
      }
      if Thread.isMainThread {
        MainActor.assumeIsolated { complete() }
      } else {
        DispatchQueue.main.async {
          MainActor.assumeIsolated { complete() }
        }
      }
    }

  /// Write `content` (array of {mime, data}) to the requested pasteboard.
  /// Called when the user invokes `copy_to_clipboard` via keybind or menu.
  private static let writeClipboardCallback:
    (
      @convention(c) (
        UnsafeMutableRawPointer?, ghostty_clipboard_e, UnsafePointer<ghostty_clipboard_content_s>?, Int, Bool
      ) -> Void
    ) = {
      _, location, content, len, _ in
      guard let content, len > 0 else { return }
      // Copy items out of borrowed pointers into Swift strings before the
      // main-queue hop — the pointers are valid only for the callback.
      let items: [(mime: String, data: String)] = (0..<len).compactMap { i in
        let entry = content.advanced(by: i).pointee
        guard let mimePtr = entry.mime, let dataPtr = entry.data else { return nil }
        return (String(cString: mimePtr), String(cString: dataPtr))
      }
      guard !items.isEmpty else { return }
      let write: @MainActor () -> Void = {
        guard let pb = pasteboard(for: location) else { return }
        let types: [NSPasteboard.PasteboardType] = items.map { item in
          item.mime == "text/plain" ? .string : NSPasteboard.PasteboardType(item.mime)
        }
        pb.declareTypes(types, owner: nil)
        for (item, type) in zip(items, types) {
          pb.setString(item.data, forType: type)
        }
      }
      if Thread.isMainThread {
        MainActor.assumeIsolated { write() }
      } else {
        DispatchQueue.main.async {
          MainActor.assumeIsolated { write() }
        }
      }
    }

  // MARK: - Event emission

  /// Lift a decoded event onto the engine's `TerminalEvent` stream.
  /// No-op if the engine hasn't been wired yet (engine-less headless tests).
  @MainActor
  func emit(_ event: TerminalEvent) {
    terminalEngine?.emit(event)
  }

  /// Convenience for the info-delta family, which always travels as
  /// `paneInfoChanged(paneID, delta)`.
  @MainActor
  func emitInfoChanged(_ paneID: PaneID, _ delta: PaneInfoDelta) {
    emit(.paneInfoChanged(paneID, delta))
  }

  // MARK: - Config mutation

  /// Atomically replace the current `ghostty_config_t` with the cloned
  /// handle libghostty hands us via `CONFIG_CHANGE`. The old handle is
  /// freed after replacement; live surfaces keep rendering against their
  /// existing snapshots until ghostty re-applies.
  @MainActor
  func applyClonedConfig(_ cloned: ghostty_config_t) {
    let old = config
    config = cloned
    if let old { ghostty_config_free(old) }
  }

  /// Respond to libghostty's app-scoped `reload_config` action. Triggered by:
  ///   * `ghostty_app_set_color_scheme` — light/dark flip; libghostty has
  ///     already updated its app-level conditional state and needs us to push
  ///     a fresh config back so surfaces can re-resolve their palette.
  ///   * `.ghosttyRuntimeReloadRequested` — the Settings → Terminal pane wrote
  ///     a new `~/.config/ghostty/config` and wants the live runtime to adopt it.
  ///
  /// `soft=true` means the on-disk config hasn't changed (only the conditional
  /// state); we clone our in-memory handle and push it back so libghostty can
  /// re-run `changeConditionalState`. `soft=false` means reload from disk.
  ///
  /// Either way we call `ghostty_app_update_config`, which is the piece
  /// touch-code used to omit: without it libghostty never receives the new
  /// config and surfaces stay on the old palette even though our local
  /// `self.config` was swapped. libghostty copies what it needs synchronously,
  /// so the clone can be freed immediately after the call. A subsequent
  /// `config_change` action fires back with the "applied" config (post
  /// conditional-state resolution) and `applyClonedConfig` catches it to swap
  /// `self.config` on our side.
  @MainActor
  func reloadConfig(soft: Bool) {
    guard let app else { return }
    let pushed: ghostty_config_t?
    if soft, let current = config {
      pushed = ghostty_config_clone(current)
    } else {
      pushed = GhosttyConfigLoader.makeFreshConfig()
    }
    guard let handle = pushed else { return }
    ghostty_app_update_config(app, handle)
    ghostty_config_free(handle)
  }

  /// Respond to libghostty's surface-scoped `reload_config` action. Fires
  /// per-surface after `ghostty_surface_set_color_scheme` — the surface's own
  /// conditional state is now stale-from-libghostty's-view and needs the
  /// current app config re-applied so `Surface.updateConfig` can run
  /// `changeConditionalState` with the NEW per-surface state. No-op if the
  /// PaneID no longer maps to a live surface (racey unregister).
  @MainActor
  func reloadSurfaceConfig(paneID: PaneID, soft: Bool) {
    guard let pane = surfacesByPaneID[paneID] else { return }
    pane.reloadConfig(soft: soft, appConfig: config)
  }

  /// Placeholder for `GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY`. Lands when
  /// the appearance layer owns an opacity override; logged for now so the
  /// keybind is observable.
  @MainActor
  func toggleBackgroundOpacity() {
    // Intentionally empty — opacity is a setting surface (DeveloperSettings
    // or appearance override) that this runtime does not yet own.
  }

  /// close_surface_cb receives the SURFACE's userdata, which we set at
  /// creation to the raw bytes of the owning `PaneID.raw.uuid`. We avoid
  /// casting to a `PaneSurface` pointer because the callback hops through
  /// `DispatchQueue.main.async`: if the engine drops the PaneSurface on
  /// the main thread between the C call and the async block, the opaque
  /// pointer would reference freed memory.
  ///
  /// PaneID lookup via the runtime registry is UAF-safe — the registry
  /// maps a PaneID (value type) to a live PaneSurface, and if the pane
  /// was already unregistered the lookup returns nil and we no-op.
  private static let closeSurfaceCallback: (@convention(c) (UnsafeMutableRawPointer?, Bool) -> Void) = {
    userdata, processAlive in
    guard let userdata else { return }
    // Copy the UUID bytes out of the userdata payload now, before hopping
    // to main — the memory may be freed if the PaneSurface is dropped.
    var uuidBytes = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    withUnsafeMutableBytes(of: &uuidBytes) { dst in
      _ = dst.baseAddress.map { base in
        base.copyMemory(from: userdata, byteCount: MemoryLayout<uuid_t>.size)
      }
    }
    let paneID = PaneID(raw: UUID(uuid: uuidBytes))
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        guard let pane = GhosttyRuntime.shared?.surface(for: paneID) else { return }
        pane.requestClose(processAlive: processAlive)
      }
    }
  }
}

enum GhosttyError: Error, Equatable, Sendable, CustomStringConvertible {
  case configInitFailed
  case appInitFailed(reason: String)
  /// `retryable == true` means the caller can re-attempt after a short
  /// backoff (HAN-82: `ghostty_surface_new` is observed to fail
  /// transiently — the original throw site bubbled up an opaque
  /// `surfaceInitFailed` so external scripts had no way to decide
  /// retry vs. fail-hard).
  case surfaceInitFailed(reason: String, retryable: Bool)

  var description: String {
    switch self {
    case .configInitFailed:
      return "ghostty config init failed"
    case .appInitFailed(let reason):
      return "ghostty app init failed: \(reason)"
    case .surfaceInitFailed(let reason, let retryable):
      let tail = retryable ? " (retryable)" : ""
      return "surface init failed\(tail): \(reason)"
    }
  }
}

extension Notification.Name {
  /// Posted by `GhosttyConfigFile.apply` after writing the managed region of
  /// `~/.config/ghostty/config`. `GhosttyRuntime` listens and re-parses the config so
  /// running surfaces pick up the new theme / font without an app restart.
  static let ghosttyRuntimeReloadRequested = Notification.Name("ghosttyRuntimeReloadRequested")
}

extension NSColor {
  fileprivate convenience init(ghostty: ghostty_config_color_s) {
    self.init(
      red: Double(ghostty.r) / 255,
      green: Double(ghostty.g) / 255,
      blue: Double(ghostty.b) / 255,
      alpha: 1
    )
  }
}
