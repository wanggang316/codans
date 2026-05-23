import AppKit
import Foundation
import GhosttyKit
import TouchCodeCore
import TouchCodeIPC

/// Owns one `ghostty_surface_t` and its hosting `GhosttySurfaceView`. One
/// PaneSurface corresponds to one `Pane` while alive; when the surface
/// closes (child exited, crash, explicit close) the engine disposes this
/// object and drops it from its registry.
@MainActor
final class PaneSurface {
  enum State: Equatable, Sendable {
    case initialising
    case ready
    case exited(code: Int32)
    case crashed(reason: String)
  }

  let paneID: PaneID
  /// Observable informational state populated from the `PaneInfoDelta`
  /// stream via `apply(_:)`. Reference type — `let` is intentional; the
  /// instance lives for the full PaneSurface lifetime and its fields
  /// are mutated in place so observers keep the same identity.
  let info: SurfaceInfo = SurfaceInfo()
  private(set) var state: State = .initialising
  let view: GhosttySurfaceView
  // The C-handle / unsafe-pointer storage below is read from a nonisolated
  // deinit; their non-Sendable types would otherwise reject that access.
  // `nonisolated(unsafe)` is sound here because the deinit only fires once
  // the refcount has hit zero — by that point the MainActor is the sole
  // owner and no other context can race. See `deinit` for the rationale
  // for nonisolated deinit itself.
  nonisolated(unsafe) private var surface: ghostty_surface_t?

  private let runtime: GhosttyRuntime
  nonisolated(unsafe) private let workingDirectoryCString: UnsafeMutablePointer<CChar>?
  /// Heap-allocated key/value C strings backing the env_vars array passed
  /// to libghostty. `strdup`'d in init, every entry `free`'d in deinit.
  /// Held on the instance because libghostty does NOT documented-copy the
  /// `env_vars` buffer; keeping the strings alive matches the
  /// `working_directory` lifecycle.
  nonisolated(unsafe) private let envCStrings: [(key: UnsafeMutablePointer<CChar>, value: UnsafeMutablePointer<CChar>)]
  /// Backing storage for the `ghostty_env_var_s` array. Allocated only
  /// when the env map is non-empty; a `nil` buffer means the surface
  /// config receives `env_vars = nil, env_var_count = 0`.
  nonisolated(unsafe) private let envVarsBuffer: UnsafeMutableBufferPointer<ghostty_env_var_s>?
  /// Heap-allocated uuid_t bytes passed to libghostty as the surface
  /// userdata. close_surface_cb reads these bytes to recover the owning
  /// PaneID without casting to a Swift object pointer (UAF-safe across
  /// the C→main-queue hop).
  nonisolated(unsafe) private let paneIDUserdata: UnsafeMutablePointer<UInt8>

  /// Engine-provided close callback. Runs when the libghostty surface
  /// reports close (child exited or crashed). `processAlive` is true for
  /// user-initiated close with a live child, false for child-exit triggered
  /// close.
  var onClose: (@MainActor (_ processAlive: Bool) -> Void)?

  /// Engine-provided output callback. Currently unused — surface output
  /// reaches the engine via ghostty's own rendering layer; the engine hooks
  /// this in M4 integration (deferred).
  var onOutput: (@MainActor (Data) -> Void)?

  init(
    runtime: GhosttyRuntime,
    paneID: PaneID,
    workingDirectory: String,
    env: [String: String] = [:],
    fontSize: Float32 = 13.0
  ) throws {
    guard let app = runtime.app else {
      throw GhosttyError.appInitFailed(
        reason: "libghostty app not initialized; surface request for pane \(paneID) at \(workingDirectory)"
      )
    }
    self.runtime = runtime
    self.paneID = paneID
    self.workingDirectoryCString = strdup(workingDirectory)
    self.view = GhosttySurfaceView(paneID: paneID)

    // Stable C-string ownership for env: each (key, value) is `strdup`'d,
    // referenced from a `ghostty_env_var_s` in `envVarsBuffer`, and freed
    // in `deinit`. Empty map → nil buffer → config.env_vars stays nil.
    let strdupped = Self.makeEnvCStrings(env)
    self.envCStrings = strdupped
    if strdupped.isEmpty {
      self.envVarsBuffer = nil
    } else {
      let buffer = UnsafeMutableBufferPointer<ghostty_env_var_s>.allocate(
        capacity: strdupped.count
      )
      for (index, pair) in strdupped.enumerated() {
        buffer[index] = ghostty_env_var_s(
          key: UnsafePointer(pair.key),
          value: UnsafePointer(pair.value)
        )
      }
      self.envVarsBuffer = buffer
    }

    // Allocate 16 bytes to hold the PaneID's uuid bytes as surface userdata.
    self.paneIDUserdata = UnsafeMutablePointer<UInt8>.allocate(capacity: 16)
    withUnsafeBytes(of: paneID.raw.uuid) { src in
      paneIDUserdata.update(
        from: src.bindMemory(to: UInt8.self).baseAddress!,
        count: 16
      )
    }

    var config = ghostty_surface_config_new()
    config.platform_tag = GHOSTTY_PLATFORM_MACOS
    config.platform = ghostty_platform_u(
      macos: ghostty_platform_macos_s(
        nsview: Unmanaged.passUnretained(view).toOpaque()
      )
    )
    config.scale_factor = view.backingScaleFactor()
    config.font_size = fontSize
    config.working_directory = workingDirectoryCString.map { UnsafePointer($0) }
    if let envBuffer = envVarsBuffer {
      config.env_vars = envBuffer.baseAddress
      config.env_var_count = envBuffer.count
    }
    config.context = GHOSTTY_SURFACE_CONTEXT_SPLIT
    // Per-surface userdata: opaque pointer to the 16 uuid-bytes of the
    // owning PaneID. The close_surface_cb copies these bytes into a local
    // UUID so the callback survives the C→main-queue hop even if the
    // PaneSurface object is freed in-between.
    config.userdata = UnsafeMutableRawPointer(paneIDUserdata)

    guard let surface = ghostty_surface_new(app, &config) else {
      // HAN-82: surface the diagnostic context libghostty doesn't return
      // through its nil-pointer protocol. The pane id, working
      // directory, and env-var count are the inputs callers can act on
      // (cwd missing? env too large? same surface request a moment
      // later succeeded?). `retryable: true` tags it as a transient
      // failure so the caller knows it can backoff and retry.
      throw GhosttyError.surfaceInitFailed(
        reason:
          "ghostty_surface_new returned nil for pane \(paneID) (workingDirectory=\(workingDirectory), envVarCount=\(strdupped.count))",
        retryable: true
      )
    }
    self.surface = surface
    self.view.attach(surface: surface)
    // libghostty defaults new surfaces to focused; in a multi-pane layout
    // that makes every fresh surface draw the filled blinking cursor until
    // something explicitly resigns it. Force-false here — the one pane that
    // wins first-responder will flip it back to true via becomeFirstResponder.
    ghostty_surface_set_focus(surface, false)
    self.state = .ready
  }

  // Nonisolated deinit on a MainActor class: chained `isolated deinit`s
  // along the close path (this PaneSurface released alongside its
  // PendingOutputBuffer) crash inside `swift_task_deinitOnExecutorImpl` on
  // Swift 6 — the cascading executor hops double-free a TaskLocal scope
  // and libmalloc aborts. Everything touched here is C-pointer cleanup on
  // `let` storage; the only `var` read (`surface`) is a value-type handle
  // and the object's refcount has already reached zero, so no other actor
  // can race us. Callers still call `close()` first via the close path —
  // this is a leak-prevention safety net.
  deinit {
    if let surface {
      ghostty_surface_free(surface)
    }
    if let ptr = workingDirectoryCString {
      free(UnsafeMutableRawPointer(ptr))
    }
    for pair in envCStrings {
      free(UnsafeMutableRawPointer(pair.key))
      free(UnsafeMutableRawPointer(pair.value))
    }
    if let buffer = envVarsBuffer {
      buffer.deallocate()
    }
    paneIDUserdata.deallocate()
  }

  // MARK: - Env helpers

  /// Allocate a stable `(key, value)` C-string pair for each entry in
  /// `env`. Returned pointers must be freed with `free`. Pure / nonisolated
  /// so unit tests can exercise the conversion without spinning a real
  /// `GhosttyRuntime`.
  static func makeEnvCStrings(
    _ env: [String: String]
  ) -> [(key: UnsafeMutablePointer<CChar>, value: UnsafeMutablePointer<CChar>)] {
    guard !env.isEmpty else { return [] }
    // Sort for deterministic ordering — libghostty does not require any
    // particular order, but stable iteration makes the test surface
    // predictable and avoids spurious flakiness on dictionary reorderings.
    return env.sorted(by: { $0.key < $1.key }).map { entry in
      (key: strdup(entry.key)!, value: strdup(entry.value)!)
    }
  }

  /// Explicit teardown. Idempotent. After `close()`, the surface handle is
  /// nil and all subsequent operations no-op.
  func close() {
    guard let surface else { return }
    ghostty_surface_free(surface)
    self.surface = nil
    view.detachSurface()
  }

  func setFocus(_ focused: Bool) {
    guard let surface else { return }
    ghostty_surface_set_focus(surface, focused)
  }

  /// Apply a color scheme to this surface and request a redraw. No-op after `close()`.
  /// Called by `GhosttyRuntime.setColorScheme(_:)` when the app's resolved
  /// color scheme changes (either user picker toggle or OS-level appearance flip).
  func applyColorScheme(_ scheme: ghostty_color_scheme_e) {
    guard let surface else { return }
    ghostty_surface_set_color_scheme(surface, scheme)
    ghostty_surface_refresh(surface)
  }

  /// Push a config to this specific surface. Called from the action decoder
  /// when libghostty fires a surface-target `reload_config` action (per-surface
  /// light/dark flip raised by `ghostty_surface_set_color_scheme`). libghostty
  /// copies what it needs synchronously from `ghostty_surface_update_config`
  /// — caller owns and frees the handle it passes in. The surface's own
  /// `config_conditional_state` has already been mutated before this call, so
  /// `Surface.updateConfig` will pick up the new scheme while applying the
  /// config we push here.
  func reloadConfig(soft: Bool, appConfig: ghostty_config_t?) {
    guard let surface else { return }
    let pushed: ghostty_config_t?
    if soft, let current = appConfig {
      pushed = ghostty_config_clone(current)
    } else {
      pushed = GhosttyConfigLoader.makeFreshConfig()
    }
    guard let handle = pushed else { return }
    ghostty_surface_update_config(surface, handle)
    ghostty_config_free(handle)
  }

  /// Fulfils a `read_clipboard_cb` request by forwarding the string back to
  /// libghostty. Called from `GhosttyRuntime`'s clipboard bridge on
  /// MainActor after the pasteboard is read.
  func completeClipboardRequest(
    text: String, state: UnsafeMutableRawPointer?, confirmed: Bool
  ) {
    guard let surface else { return }
    text.withCString { ptr in
      ghostty_surface_complete_clipboard_request(surface, ptr, state, confirmed)
    }
  }

  func sendInput(_ text: String) {
    guard let surface, !text.isEmpty else { return }
    var chunk = ""
    var index = text.startIndex
    while index < text.endIndex {
      let character = text[index]
      if character == "\r" || character == "\n" {
        sendTextChunk(chunk, to: surface)
        chunk.removeAll(keepingCapacity: true)
        if character == "\r" {
          let next = text.index(after: index)
          if next < text.endIndex, text[next] == "\n" {
            index = next
          }
        }
        sendEnterKey(to: surface)
      } else {
        chunk.append(character)
      }
      index = text.index(after: index)
    }
    sendTextChunk(chunk, to: surface)
  }

  enum ReadExtent {
    case viewport
    case screen
  }

  func readText(_ extent: ReadExtent) -> String? {
    guard let surface else { return nil }
    var text = ghostty_text_s()
    let tag: ghostty_point_tag_e =
      switch extent {
      case .viewport: GHOSTTY_POINT_VIEWPORT
      case .screen: GHOSTTY_POINT_SCREEN
      }
    let selection = ghostty_selection_s(
      top_left: ghostty_point_s(
        tag: tag,
        coord: GHOSTTY_POINT_COORD_TOP_LEFT,
        x: 0,
        y: 0
      ),
      bottom_right: ghostty_point_s(
        tag: tag,
        coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
        x: 0,
        y: 0
      ),
      rectangle: false
    )
    guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
    defer { ghostty_surface_free_text(surface, &text) }
    return Self.string(from: text)
  }

  func readSelection() -> String? {
    guard let surface else { return nil }
    var text = ghostty_text_s()
    guard ghostty_surface_read_selection(surface, &text) else { return nil }
    defer { ghostty_surface_free_text(surface, &text) }
    return Self.string(from: text)
  }

  /// Route through libghostty's `reset` binding action — the same path the
  /// context-menu "Reset Terminal" item uses. Clears scrollback and
  /// reinitialises the terminal state without disturbing the child PTY.
  ///
  /// The binding action mutates terminal state synchronously but does not
  /// trigger a redraw on its own; without `ghostty_surface_refresh` the
  /// rendered viewport stays stale until the next input or mouse event.
  func resetTerminal() {
    guard let surface else { return }
    let action = "reset"
    action.withCString { ptr in
      _ = ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
    }
    ghostty_surface_refresh(surface)
  }

  private func sendTextChunk(_ text: String, to surface: ghostty_surface_t) {
    guard !text.isEmpty else { return }
    // Use utf8.count, not strlen — embedded NUL in composed glyphs would
    // truncate the forwarded bytes on strlen.
    let bytes = Array(text.utf8)
    bytes.withUnsafeBufferPointer { buffer in
      buffer.baseAddress?.withMemoryRebound(
        to: CChar.self,
        capacity: bytes.count
      ) { ptr in
        ghostty_surface_text(surface, ptr, UInt(bytes.count))
      }
    }
  }

  private func sendEnterKey(to surface: ghostty_surface_t) {
    sendKeyEvent(keycode: 0x24, mods: 0, to: surface)
  }

  /// Send a named special key (Esc, arrows, function keys, common Ctrl
  /// combos). Builds a press/release pair on the same `ghostty_surface_t`
  /// path the GUI uses, so the terminal application sees the same byte
  /// sequences a physical keypress would produce.
  func sendNamedKey(_ key: IPC.TerminalNamedKey) {
    guard let surface else { return }
    let (keycode, mods) = Self.keycodeAndMods(for: key)
    sendKeyEvent(keycode: keycode, mods: mods, to: surface)
  }

  /// Forward raw bytes to the terminal by splitting them into control-byte
  /// key events (Esc, Tab, CR/LF, BS, Ctrl-X) and intervening printable
  /// chunks. This is the path `terminal.sendRawBytes` uses so callers can
  /// inject CSI sequences (`1b 5b 41` = ESC [ A = ↑) that the plain
  /// `terminal.sendInput` text path drops on the floor.
  func sendRawBytes(_ bytes: [UInt8]) {
    guard let surface else { return }
    var chunk: [UInt8] = []
    var index = 0
    while index < bytes.count {
      let byte = bytes[index]
      if Self.isControlByte(byte) {
        flushChunk(&chunk, to: surface)
        // Treat CR or CR LF as a single Enter; LF alone is also Enter.
        if byte == 0x0D {
          sendKeyEvent(keycode: 0x24, mods: 0, to: surface)
          if index + 1 < bytes.count, bytes[index + 1] == 0x0A { index += 1 }
        } else if byte == 0x0A {
          sendKeyEvent(keycode: 0x24, mods: 0, to: surface)
        } else if let (kc, mods) = Self.keyEvent(forControlByte: byte) {
          sendKeyEvent(keycode: kc, mods: mods, to: surface)
        }
      } else {
        chunk.append(byte)
      }
      index += 1
    }
    flushChunk(&chunk, to: surface)
  }

  private func flushChunk(_ chunk: inout [UInt8], to surface: ghostty_surface_t) {
    guard !chunk.isEmpty else { return }
    chunk.withUnsafeBufferPointer { buffer in
      buffer.baseAddress?.withMemoryRebound(
        to: CChar.self,
        capacity: chunk.count
      ) { ptr in
        ghostty_surface_text(surface, ptr, UInt(chunk.count))
      }
    }
    chunk.removeAll(keepingCapacity: true)
  }

  private func sendKeyEvent(keycode: UInt32, mods: UInt32, to surface: ghostty_surface_t) {
    var key = ghostty_input_key_s()
    key.action = GHOSTTY_ACTION_PRESS
    key.keycode = keycode
    key.mods = ghostty_input_mods_e(mods)
    key.consumed_mods = ghostty_input_mods_e(0)
    _ = ghostty_surface_key(surface, key)

    key.action = GHOSTTY_ACTION_RELEASE
    _ = ghostty_surface_key(surface, key)
  }

  /// Bytes < 0x20 plus DEL (0x7F) are treated as control bytes — the text
  /// input path filters most of these, so we route them through key events
  /// instead.
  private static func isControlByte(_ byte: UInt8) -> Bool {
    byte < 0x20 || byte == 0x7F
  }

  /// Mac virtual keycode + ghostty mod bitmap for one named key. The
  /// keycodes track `Ghostty.Input.Key.keyCode` in the ghostty submodule;
  /// kept inline to avoid a cross-module dependency on Ghostty's Swift
  /// helpers.
  private static func keycodeAndMods(for key: IPC.TerminalNamedKey) -> (UInt32, UInt32) {  // swiftlint:disable:this cyclomatic_complexity
    let ctrl = UInt32(GHOSTTY_MODS_CTRL.rawValue)
    switch key {
    case .escape: return (0x35, 0)
    case .up: return (0x7E, 0)
    case .down: return (0x7D, 0)
    case .left: return (0x7B, 0)
    case .right: return (0x7C, 0)
    case .tab: return (0x30, 0)
    case .enter: return (0x24, 0)
    case .backspace: return (0x33, 0)
    case .delete: return (0x75, 0)
    case .home: return (0x73, 0)
    case .end: return (0x77, 0)
    case .pgup: return (0x74, 0)
    case .pgdn: return (0x79, 0)
    case .f1: return (0x7A, 0)
    case .f2: return (0x78, 0)
    case .f3: return (0x63, 0)
    case .f4: return (0x76, 0)
    case .f5: return (0x60, 0)
    case .f6: return (0x61, 0)
    case .f7: return (0x62, 0)
    case .f8: return (0x64, 0)
    case .f9: return (0x65, 0)
    case .f10: return (0x6D, 0)
    case .f11: return (0x67, 0)
    case .f12: return (0x6F, 0)
    case .ctrlC: return (0x08, ctrl)
    case .ctrlD: return (0x02, ctrl)
    case .ctrlL: return (0x25, ctrl)
    case .ctrlZ: return (0x06, ctrl)
    }
  }

  /// Map a control byte (< 0x20 or 0x7F) to a (keycode, mods) pair so it
  /// reaches the PTY as a key event. Returns nil for control bytes we
  /// don't recognise (NUL, other rare ASCII control codes); callers drop
  /// those.
  private static func keyEvent(forControlByte byte: UInt8) -> (UInt32, UInt32)? {  // swiftlint:disable:this cyclomatic_complexity
    let ctrl = UInt32(GHOSTTY_MODS_CTRL.rawValue)
    switch byte {
    case 0x1B: return (0x35, 0)  // ESC
    case 0x09: return (0x30, 0)  // TAB
    case 0x08: return (0x33, 0)  // BS  -> backspace
    case 0x7F: return (0x33, 0)  // DEL -> backspace (matches macOS default)
    case 0x01: return (0x00, ctrl)  // Ctrl-A
    case 0x02: return (0x0B, ctrl)  // Ctrl-B
    case 0x03: return (0x08, ctrl)  // Ctrl-C
    case 0x04: return (0x02, ctrl)  // Ctrl-D
    case 0x05: return (0x0E, ctrl)  // Ctrl-E
    case 0x06: return (0x03, ctrl)  // Ctrl-F
    case 0x07: return (0x05, ctrl)  // Ctrl-G
    case 0x0B: return (0x28, ctrl)  // Ctrl-K
    case 0x0C: return (0x25, ctrl)  // Ctrl-L
    case 0x0E: return (0x2D, ctrl)  // Ctrl-N
    case 0x0F: return (0x1F, ctrl)  // Ctrl-O
    case 0x10: return (0x23, ctrl)  // Ctrl-P
    case 0x11: return (0x0C, ctrl)  // Ctrl-Q
    case 0x12: return (0x0F, ctrl)  // Ctrl-R
    case 0x13: return (0x01, ctrl)  // Ctrl-S
    case 0x14: return (0x11, ctrl)  // Ctrl-T
    case 0x15: return (0x20, ctrl)  // Ctrl-U
    case 0x16: return (0x09, ctrl)  // Ctrl-V
    case 0x17: return (0x0D, ctrl)  // Ctrl-W
    case 0x18: return (0x07, ctrl)  // Ctrl-X
    case 0x19: return (0x10, ctrl)  // Ctrl-Y
    case 0x1A: return (0x06, ctrl)  // Ctrl-Z
    default: return nil
    }
  }

  private static func string(from text: ghostty_text_s) -> String {
    guard let pointer = text.text else { return "" }
    let data = Data(bytes: pointer, count: Int(text.text_len))
    return String(data: data, encoding: .utf8) ?? String(cString: pointer)
  }

  func markExited(code: Int32) {
    state = .exited(code: code)
    info.lastChildExitCode = code
  }

  func markCrashed(reason: String) {
    state = .crashed(reason: reason)
  }

  /// Called from `GhosttyRuntime.closeSurfaceCallback` when libghostty
  /// wants to close this surface. Invokes `onClose` with the processAlive
  /// flag so the engine decides how to emit the lifecycle event — the
  /// engine distinguishes user-initiated close (`processAlive == true`)
  /// from child-exit-driven close (`processAlive == false`) and uses
  /// state transitions that were already set via markExited / markCrashed
  /// if any.
  func requestClose(processAlive: Bool) {
    onClose?(processAlive)
    close()
  }

  // MARK: - Info delta application

  /// Fold a single `PaneInfoDelta` into `info`. Exhaustive over every
  /// delta case — the compiler enforces coverage when new cases land in
  /// TouchCodeCore, which is the whole point of keeping the enum Core-side.
  ///
  /// This only mutates per-surface observable state; it does NOT emit
  /// `TerminalEvent.paneInfoChanged`. The decoder is responsible for
  /// fan-out so listeners that don't need per-field tracking can stay on
  /// the event stream.
  func apply(_ delta: PaneInfoDelta) {  // swiftlint:disable:this cyclomatic_complexity
    switch delta {
    case .title(let t):
      info.title = t
    case .tabTitle(let t):
      info.tabTitle = t
    case .promptTitle(let tag):
      info.promptTitle = tag
    case .pwd(let p):
      info.pwd = p

    case .mouseShape(let shape):
      info.mouseShape = shape
    case .mouseVisible(let visible):
      info.mouseVisible = visible
    case .mouseOverLink(let url):
      info.mouseOverLink = url

    case .colorChange(let kind, let r, let g, let b):
      info.colorChange = ColorChange(kind: kind, r: r, g: g, b: b)
    case .rendererHealthy(let healthy):
      info.rendererHealthy = healthy

    case .cellSize(let width, let height):
      info.cellWidth = width
      info.cellHeight = height
    case .sizeLimit(let minWidth, let minHeight, let maxWidth, let maxHeight):
      info.sizeLimitMinWidth = minWidth
      info.sizeLimitMinHeight = minHeight
      info.sizeLimitMaxWidth = maxWidth
      info.sizeLimitMaxHeight = maxHeight
    case .initialSize(let width, let height):
      info.initialWidth = width
      info.initialHeight = height
    case .resetWindowSize:
      // Transient intent — libghostty asks the host to restore its default
      // window size. No persistent field to update here; the decoder
      // forwards this on the event stream for the window layer to service.
      break

    case .scrollbar(let total, let offset, let length):
      info.scrollbarTotal = total
      info.scrollbarOffset = offset
      info.scrollbarLength = length

    case .secureInput(let mode):
      info.secureInput = mode
    case .keySequence(let active, let trigger):
      info.keySequenceActive = active
      info.keySequenceTrigger = trigger
    case .keyTable(let name, let depth):
      info.keyTableName = name
      info.keyTableDepth = depth
    case .readonly(let ro):
      info.readonly = ro
    case .quitTimer(let phase):
      info.quitTimer = phase
    case .floatWindow(let floating):
      info.floatWindow = floating

    case .searchStarted(let needle):
      info.searchNeedle = needle
      info.searchTotal = nil
      info.searchSelected = nil
    case .searchEnded:
      info.searchNeedle = nil
      info.searchTotal = nil
      info.searchSelected = nil
    case .searchTotal(let total):
      info.searchTotal = total
    case .searchSelected(let index):
      info.searchSelected = index

    case .progress(let state, let value):
      info.progressState = state
      info.progressValue = value

    case .bellRang:
      info.bellCount &+= 1
    case .desktopNotification(let title, let body):
      info.lastNotificationTitle = title
      info.lastNotificationBody = body
    case .commandFinished(let exitCode, let duration):
      info.lastCommandExitCode = exitCode
      info.lastCommandDuration = duration
    case .childExited(let code):
      info.lastChildExitCode = code
    }
  }
}
