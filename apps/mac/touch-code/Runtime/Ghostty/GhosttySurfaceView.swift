import AppKit
import Carbon.HIToolbox
import Foundation
import GhosttyKit
import OSLog
import TouchCodeCore

private let ghosttyViewLogger = Logger(
  subsystem: "com.touch-code.runtime", category: "surface-view"
)

/// Minimal host view for a ghostty_surface_t. Forwards key/mouse events and
/// frame/content-scale changes; leaves Metal rendering to ghostty's own
/// layer setup (it reaches through the `nsview` pointer passed in
/// `ghostty_platform_macos_s` and attaches a CAMetalLayer).
@MainActor
final class GhosttySurfaceView: NSView, NSTextInputClient {
  /// Time-bounded memoized value used by AX accessors. AX clients tend
  /// to call multiple attribute accessors in a burst; the cache collapses
  /// those into a single libghostty read while still picking up screen
  /// updates within `duration`. MainActor-isolated so the `fetch` closure
  /// can touch MainActor state directly — every AX entry point we own is
  /// already on the main actor.
  @MainActor
  private final class CachedValue<T> {
    private var value: T?
    private let fetch: @MainActor () -> T
    private let duration: Duration
    private var expiryTask: Task<Void, Never>?

    init(duration: Duration, fetch: @escaping @MainActor () -> T) {
      self.duration = duration
      self.fetch = fetch
    }

    isolated deinit {
      expiryTask?.cancel()
    }

    func get() -> T {
      if let value {
        return value
      }
      let fetched = fetch()
      value = fetched
      expiryTask?.cancel()
      expiryTask = Task { [weak self] in
        guard let self else { return }
        try? await ContinuousClock().sleep(for: self.duration)
        guard !Task.isCancelled else { return }
        self.value = nil
        self.expiryTask = nil
      }
      return fetched
    }
  }

  let paneID: PaneID
  private var surface: ghostty_surface_t?
  private var markedText = NSMutableAttributedString()
  private var trackingArea: NSTrackingArea?
  /// NSTextInputContext delivers composed text through insertText during an
  /// interpretKeyEvents pass. We accumulate what it delivers so the outer
  /// keyDown handler can attach it to the single ghostty_surface_key call —
  /// avoiding double-insertion of event.characters.
  private var keyTextAccumulator: [String]?
  /// Modifier-key state snapshot. flagsChanged events need to be diffed
  /// against the previous modifier set to emit the correct press/release;
  /// the raw NSEvent always reads .press for the event kind.
  private var lastModifierFlags: NSEvent.ModifierFlags = []
  /// Most recent occlusion bit pushed to libghostty. Nil before the first
  /// push — the dedupe check below treats nil as "always different" so the
  /// initial value is always sent once a surface attaches.
  private var lastOcclusion: Bool?
  /// Observer registered on the current window for `didChangeOcclusionState`.
  /// Replaced when the view moves between windows; cleared when the view
  /// is detached from any window.
  private var windowOcclusionObserver: NSObjectProtocol?
  /// Fires every time the view becomes AppKit's first responder — i.e.
  /// the user clicked into this surface or the window was reactivated
  /// with this pane focused. Wired by TerminalEngine to bridge AppKit
  /// focus into HierarchyManager's per-tab focus map; without this hook
  /// click-driven focus changes wouldn't propagate up the stack.
  var onBecomeFirstResponder: (() -> Void)?
  /// Out-of-band intent the view raises on behalf of the user — currently
  /// only the right-click menu's split items. TerminalEngine wires this to
  /// `runtime.emit(.paneActionRequested(paneID, …))` so menu-driven splits
  /// flow through the same `PaneActionRouterFeature` that handles libghostty
  /// keybinding-driven splits.
  var onPaneAction: ((PaneActionRequest) -> Void)?

  init(paneID: PaneID) {
    self.paneID = paneID
    super.init(frame: .zero)
    self.wantsLayer = true
    self.autoresizingMask = [.width, .height]
    registerForDraggedTypes(Array(Self.dropTypes))
  }

  // Explicit empty deinit so the compiler emits the standard nonisolated
  // tail rather than the implicitly-isolated path used by Swift 6 for
  // `@MainActor` classes. PaneSurface releases this view from a plain
  // (non-isolated) deinit; an isolated deinit here would hop via
  // `swift_task_deinitOnExecutorMainActorBackDeploy` and double-free a
  // TaskLocal scope along the cascade — the same crash fixed for
  // PaneSurface (2bbee60) and SurfaceInfo. AppKit handles the actual
  // teardown via NSView's dealloc; observers we add are removed when
  // the view leaves its window.
  deinit {}

  // MARK: - Drag & drop

  /// Pasteboard types accepted by drag-and-drop into the terminal. Files
  /// (Finder, common apps), URLs (Safari address bar) and plain strings
  /// all collapse onto "insert escaped text at the cursor".
  private static let dropTypes: Set<NSPasteboard.PasteboardType> = [
    .fileURL,
    .URL,
    .string,
  ]

  /// Shell metacharacters that need backslash-escaping when a dragged path
  /// is pasted into a running shell. Mirrors the set Ghostty uses for the
  /// same purpose, so dropping `~/Library/Application Support/foo.txt`
  /// turns into `~/Library/Application\ Support/foo.txt`.
  private static let shellEscapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

  private static func shellEscape(_ str: String) -> String {
    var result = str
    for char in shellEscapeCharacters {
      result = result.replacing(String(char), with: "\\\(char)")
    }
    return result
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) not supported")
  }

  func attach(surface: ghostty_surface_t) {
    self.surface = surface
    pushGeometry()
    // Surface just bound — push the current occlusion bit so libghostty's
    // render loop starts in the correct state instead of waiting for the
    // first window/visibility change.
    recomputeOcclusion()
  }

  func detachSurface() {
    self.surface = nil
    lastOcclusion = nil
  }

  func backingScaleFactor() -> Double {
    if let window { return window.backingScaleFactor }
    if let screen = NSScreen.main { return screen.backingScaleFactor }
    return 2.0
  }

  // MARK: - NSResponder

  override var acceptsFirstResponder: Bool { true }

  /// Accept clicks even when the owning window is inactive. Without this,
  /// the first click on an inactive window is swallowed by AppKit to
  /// activate the window — the terminal would only focus on the second
  /// click, which is surprising in a multi-pane layout.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted, let surface { ghostty_surface_set_focus(surface, true) }
    if accepted { onBecomeFirstResponder?() }
    if accepted { postAccessibilityFocusChanged() }
    return accepted
  }

  override func resignFirstResponder() -> Bool {
    let accepted = super.resignFirstResponder()
    if accepted, let surface { ghostty_surface_set_focus(surface, false) }
    return accepted
  }

  // MARK: - Accessibility

  /// Cached snapshot of the rendered screen contents. AX clients can call
  /// `accessibilityValue` / `accessibilityNumberOfCharacters` repeatedly
  /// during a single read; hitting libghostty for every call is wasteful
  /// and would also race with rendering. 500 ms is short enough that
  /// assistive tech still sees fresh output and long enough to collapse
  /// the bursts.
  private lazy var cachedScreenContents = CachedValue<String>(duration: .milliseconds(500)) {
    [weak self] in
    self?.readScreenContents() ?? ""
  }

  /// Tell AX framework this view is the focused text element so external
  /// readers (translators, screen readers, "look up selected text" tools)
  /// know to query `accessibilitySelectedText` on us. Without this the
  /// view advertises itself as a generic non-text NSView and AX clients
  /// skip the selected-text path entirely — the symptom reported in
  /// HAN-75.
  override func isAccessibilityElement() -> Bool {
    surface != nil
  }

  override func accessibilityRole() -> NSAccessibility.Role? {
    // Match Ghostty.app so AX clients treat the surface as editable text.
    .textArea
  }

  override func accessibilityLabel() -> String? {
    "Terminal pane"
  }

  override func accessibilityValue() -> Any? {
    cachedScreenContents.get()
  }

  override func accessibilitySelectedTextRange() -> NSRange {
    // Must reflect a real (non-zero) range when there is a selection —
    // assistive tech treats an empty range as "no selection" and skips
    // the follow-up `accessibilitySelectedText` query entirely (the
    // observable failure in HAN-75 before the fix).
    selectedRange()
  }

  override func accessibilitySelectedText() -> String? {
    guard let surface else { return nil }
    var text = ghostty_text_s()
    guard ghostty_surface_read_selection(surface, &text) else { return nil }
    defer { ghostty_surface_free_text(surface, &text) }
    guard let cString = text.text else { return nil }
    let value = String(cString: cString)
    return value.isEmpty ? nil : value
  }

  override func accessibilityNumberOfCharacters() -> Int {
    cachedScreenContents.get().count
  }

  override func accessibilityVisibleCharacterRange() -> NSRange {
    let content = cachedScreenContents.get()
    return NSRange(location: 0, length: content.count)
  }

  override func accessibilityLine(for index: Int) -> Int {
    let content = cachedScreenContents.get()
    let clampedIndex = min(max(index, 0), content.count)
    let prefix = String(content.prefix(clampedIndex))
    return max(0, prefix.components(separatedBy: .newlines).count - 1)
  }

  override func accessibilityString(for range: NSRange) -> String? {
    let content = cachedScreenContents.get()
    guard let swiftRange = Range(range, in: content) else { return nil }
    return String(content[swiftRange])
  }

  override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
    guard let plain = accessibilityString(for: range) else { return nil }
    return NSAttributedString(string: plain)
  }

  private func postAccessibilityFocusChanged() {
    guard surface != nil else { return }
    if let window {
      NSAccessibility.post(element: window, notification: .focusedUIElementChanged)
    } else {
      NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
    }
  }

  /// Pull the full screen (not scrollback) into a single string for AX
  /// readers. Mirrors `PaneSurface.readText(.screen)` but lives here so
  /// the view doesn't take a dependency on PaneSurface — keeping the AX
  /// path resilient to teardown order.
  private func readScreenContents() -> String {
    guard let surface else { return "" }
    var text = ghostty_text_s()
    let selection = ghostty_selection_s(
      top_left: ghostty_point_s(
        tag: GHOSTTY_POINT_SCREEN,
        coord: GHOSTTY_POINT_COORD_TOP_LEFT,
        x: 0,
        y: 0
      ),
      bottom_right: ghostty_point_s(
        tag: GHOSTTY_POINT_SCREEN,
        coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
        x: 0,
        y: 0
      ),
      rectangle: false
    )
    guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
    defer { ghostty_surface_free_text(surface, &text) }
    guard let cString = text.text else { return "" }
    return String(cString: cString)
  }

  // MARK: - Geometry

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    pushGeometry()
    installTrackingArea()
    rebindWindowOcclusionObserver()
    recomputeOcclusion()
  }

  override func viewDidHide() {
    super.viewDidHide()
    recomputeOcclusion()
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    recomputeOcclusion()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    guard let surface else { return }
    let scale = backingScaleFactor()
    ghostty_surface_set_content_scale(surface, scale, scale)
  }

  override func resize(withOldSuperviewSize oldSize: NSSize) {
    super.resize(withOldSuperviewSize: oldSize)
    pushGeometry()
  }

  override func layout() {
    super.layout()
    pushGeometry()
    installTrackingArea()
  }

  private func pushGeometry() {
    guard let surface else { return }
    let scale = backingScaleFactor()
    ghostty_surface_set_content_scale(surface, scale, scale)
    // ghostty_surface_set_size takes device-pixel dimensions.
    let px = convertToBacking(bounds.size)
    if px.width > 0, px.height > 0 {
      ghostty_surface_set_size(surface, UInt32(px.width), UInt32(px.height))
    }
  }

  private func installTrackingArea() {
    if let trackingArea {
      removeTrackingArea(trackingArea)
    }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.activeInActiveApp, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    self.trackingArea = area
  }

  // MARK: - Occlusion

  /// Re-subscribe `windowOcclusionObserver` to the current `window`. Called
  /// every time the view moves between windows (including detach to nil).
  /// AppKit fires `didChangeOcclusionStateNotification` when the window
  /// becomes fully covered, miniaturised, or moved to a hidden Space — and
  /// again when it returns. We forward that bit into ghostty so its render
  /// loop can pause on hidden surfaces instead of redrawing every frame.
  private func rebindWindowOcclusionObserver() {
    let center = NotificationCenter.default
    if let observer = windowOcclusionObserver {
      center.removeObserver(observer)
      windowOcclusionObserver = nil
    }
    guard let window else { return }
    windowOcclusionObserver = center.addObserver(
      forName: NSWindow.didChangeOcclusionStateNotification,
      object: window,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.recomputeOcclusion()
      }
    }
  }

  /// Compute "is this surface actually visible right now?" from window
  /// attachment, AppKit's per-view hidden chain, and the window's reported
  /// occlusion state, then push the bit to libghostty if it changed. Cheap
  /// to call repeatedly — the dedupe on `lastOcclusion` collapses no-ops.
  private func recomputeOcclusion() {
    guard let surface else { return }
    let visible =
      window != nil
      && !isHiddenOrHasHiddenAncestor
      && (window?.occlusionState.contains(.visible) ?? false)
    if lastOcclusion == visible { return }
    lastOcclusion = visible
    ghostty_surface_set_occlusion(surface, visible)
  }

  // MARK: - Keyboard

  /// Intercept key events BEFORE the main menu gets a chance. Ghostty
  /// binds Cmd+W / Cmd+T / Cmd+D / Cmd+C etc. to surface actions; without
  /// this override, AppKit dispatches these to `NSApp.mainMenu` first and
  /// File → Close Window eats Cmd+W, closing the whole app instead of
  /// the surface. We ask libghostty whether the key is a configured
  /// binding and route it into `keyDown` if so.
  ///
  /// One exception: if the app's main menu already has a matching key
  /// equivalent (touch-code's File / Touch Code / Edit menus bind ⌘O, ⌘,,
  /// ⌘P, ⌘T, ⌘W, ⌘1..9 etc. to first-class app actions), defer to that
  /// menu first. Without this hand-off the chord lands on a libghostty
  /// binding the touch-code action decoder doesn't translate (e.g. ⌘, →
  /// `OPEN_CONFIG`) and the keystroke is silently swallowed instead of
  /// opening Settings or the editor. `NSMenu.performKeyEquivalent`
  /// dispatches via the responder chain, so menu items wired to
  /// first-responder selectors (Edit > Copy → `copy:` → this surface's
  /// `copy_to_clipboard` binding) still resolve through Ghostty.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard event.type == .keyDown, let surface else { return false }
    let chars = event.charactersIgnoringModifiers ?? ""
    let isFR = window?.firstResponder === self
    ghosttyViewLogger.debug(
      "perfKE: chars=\(chars, privacy: .public) mods=\(event.modifierFlags.rawValue, privacy: .public) isFR=\(isFR, privacy: .public)"
    )
    // Only intercept when this surface is the focused responder. A
    // background surface must not eat Cmd+V intended for a text field
    // elsewhere in the window.
    guard isFR else { return false }

    if NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
      ghosttyViewLogger.debug("perfKE: menu handled chord")
      return true
    }

    var key = ghostty_input_key_s()
    key.action = GHOSTTY_ACTION_PRESS
    key.keycode = UInt32(event.keyCode)
    let eventMods = mods(from: event.modifierFlags)
    key.mods = eventMods
    let translationMods = ghostty_surface_key_translation_mods(surface, eventMods)
    key.consumed_mods = ghostty_input_mods_e(
      rawValue: translationMods.rawValue
        & ~(GHOSTTY_MODS_CTRL.rawValue | GHOSTTY_MODS_SUPER.rawValue)
    )
    key.composing = !markedText.string.isEmpty
    key.unshifted_codepoint = 0
    if let chars = event.characters(byApplyingModifiers: []),
      let codepoint = chars.unicodeScalars.first
    {
      key.unshifted_codepoint = codepoint.value
    }

    var flags = ghostty_binding_flags_e(0)
    let isBinding = (event.characters ?? "").withCString { ptr in
      key.text = ptr
      return ghostty_surface_key_is_binding(surface, key, &flags)
    }
    ghosttyViewLogger.debug(
      "perfKE is_binding=\(isBinding, privacy: .public) flags=\(flags.rawValue, privacy: .public) unshifted=\(key.unshifted_codepoint, privacy: .public)"
    )
    guard isBinding else { return false }
    keyDown(with: event)
    return true
  }

  override func keyDown(with event: NSEvent) {
    guard let surface else { return }

    // Notifications side channel: record the keystroke so the
    // command-finished detector can suppress notifications fired within
    // 1 s of real user input. Bound to keyDown only (modifier-only events
    // flow through flagsChanged, not here); programmatic input via
    // `tc pane send` and friends bypasses AppKit entirely and reaches
    // libghostty via `ghostty_surface_text`, so it can never surface as a
    // synthetic keyDown that would falsely arm the suppression window.
    PaneKeyboardActivityTracker.shared?.recordKey(in: paneID)

    // Capture marked-text state BEFORE interpretKeyEvents — IME may consume
    // the event purely to mutate composition (e.g. Backspace shrinking or
    // cancelling preedit), in which case markedText is empty afterwards even
    // though the key was never destined for the terminal. Forwarding that
    // raw keycode would delete a previously-committed character in addition
    // to the cancelled composition. Mirrors upstream Ghostty's
    // `composing: markedText.length > 0 || markedTextBefore` rule.
    let markedTextBefore = markedText.length > 0

    // Accumulate composed text from the NSTextInputContext pipeline. If the
    // user is mid-IME-composition, insertText delivers the final commit
    // here; raw characters from the NSEvent are not forwarded — doing so
    // would double-insert.
    keyTextAccumulator = []
    interpretKeyEvents([event])
    let composed = keyTextAccumulator ?? []
    keyTextAccumulator = nil

    let text = composed.joined()
    // Composed text is itself a commit, never composing. Otherwise, mark
    // the event as composing if either the new or prior preedit was active
    // — this is what suppresses the stray backspace/escape after IME ends.
    let composing = composed.isEmpty ? (markedText.length > 0 || markedTextBefore) : false
    sendKeyEvent(
      event: event,
      action: GHOSTTY_ACTION_PRESS,
      surface: surface,
      text: text,
      composing: composing
    )
  }

  override func keyUp(with event: NSEvent) {
    guard let surface else { return }
    sendKeyEvent(event: event, action: GHOSTTY_ACTION_RELEASE, surface: surface, text: "")
  }

  override func flagsChanged(with event: NSEvent) {
    guard let surface else { return }
    // NSEvent.flagsChanged always reads as a single event with the new mask.
    // Diff against the snapshot to know which modifier actually changed and
    // whether it's a press (newly set) or release (newly cleared).
    let newFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let oldFlags = lastModifierFlags
    lastModifierFlags = newFlags

    let added = newFlags.subtracting(oldFlags)
    let removed = oldFlags.subtracting(newFlags)

    if !added.isEmpty {
      sendKeyEvent(event: event, action: GHOSTTY_ACTION_PRESS, surface: surface, text: "")
    }
    if !removed.isEmpty {
      sendKeyEvent(event: event, action: GHOSTTY_ACTION_RELEASE, surface: surface, text: "")
    }
  }

  private func sendKeyEvent(
    event: NSEvent,
    action: ghostty_input_action_e,
    surface: ghostty_surface_t,
    text: String,
    composing: Bool? = nil
  ) {
    var keyEvent = ghostty_input_key_s()
    keyEvent.action = action
    keyEvent.keycode = UInt32(event.keyCode)
    let eventMods = mods(from: event.modifierFlags)
    keyEvent.mods = eventMods
    // Ask libghostty which mods it considers "translation" mods (used by
    // macOS key translation for dead keys / IME — e.g. Option for ʻéʼ).
    // Those must be reported as consumed_mods so they do NOT participate
    // in binding matching. Control and command are never translation
    // carriers on macOS, so we never mark them consumed even if reported.
    let translationMods = ghostty_surface_key_translation_mods(surface, eventMods)
    keyEvent.consumed_mods = ghostty_input_mods_e(
      rawValue: translationMods.rawValue
        & ~(GHOSTTY_MODS_CTRL.rawValue | GHOSTTY_MODS_SUPER.rawValue)
    )
    // Prefer the caller-supplied composing flag when present — keyDown
    // captures preedit state across the interpretKeyEvents boundary so a
    // Backspace that ended IME composition isn't re-encoded as a delete.
    keyEvent.composing = composing ?? !markedText.string.isEmpty
    // Unshifted Unicode scalar of the physical key (i.e. ignoring shift and
    // any other modifier translations). Ghostty matches keybindings like
    // `super+d` against this codepoint — leaving it 0 makes every letter-
    // based binding silently fail to match.
    keyEvent.unshifted_codepoint = 0
    if event.type == .keyDown || event.type == .keyUp,
      let chars = event.characters(byApplyingModifiers: []),
      let codepoint = chars.unicodeScalars.first
    {
      keyEvent.unshifted_codepoint = codepoint.value
    }

    if text.isEmpty {
      keyEvent.text = nil
      _ = ghostty_surface_key(surface, keyEvent)
      return
    }
    // Use utf8.count for the length so strings with embedded NUL aren't
    // truncated. Pass the Data buffer so ghostty reads exactly utf8.count
    // bytes regardless of terminators.
    let bytes = Array(text.utf8)
    bytes.withUnsafeBufferPointer { buffer in
      buffer.baseAddress?.withMemoryRebound(
        to: CChar.self,
        capacity: bytes.count
      ) { ptr in
        keyEvent.text = ptr
        _ = ghostty_surface_key(surface, keyEvent)
      }
    }
  }

  private func mods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var raw: UInt32 = 0
    if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
    return ghostty_input_mods_e(rawValue: raw)
  }

  // MARK: - Mouse

  override func mouseDown(with event: NSEvent) {
    // Claim focus on click. NSView does not do this automatically for
    // subclasses with custom mouseDown, so without this the surface stays
    // unfocused (no cursor, keyDown not dispatched).
    if window?.firstResponder !== self {
      window?.makeFirstResponder(self)
    }
    _ = sendMouseButton(event: event, button: GHOSTTY_MOUSE_LEFT, action: GHOSTTY_MOUSE_PRESS)
  }
  override func mouseUp(with event: NSEvent) {
    _ = sendMouseButton(event: event, button: GHOSTTY_MOUSE_LEFT, action: GHOSTTY_MOUSE_RELEASE)
  }
  override func rightMouseDown(with event: NSEvent) {
    // Offer the right-click to ghostty first (vim mouse mode, captured
    // applications, configured `super+...` bindings). If ghostty consumed
    // it, swallow the event so AppKit doesn't open the local context menu.
    // Otherwise fall through to super, which lets AppKit's default chain
    // call `menu(for:)` and present our menu.
    if sendMouseButton(event: event, button: GHOSTTY_MOUSE_RIGHT, action: GHOSTTY_MOUSE_PRESS) {
      return
    }
    super.rightMouseDown(with: event)
  }
  override func rightMouseUp(with event: NSEvent) {
    if sendMouseButton(event: event, button: GHOSTTY_MOUSE_RIGHT, action: GHOSTTY_MOUSE_RELEASE) {
      return
    }
    super.rightMouseUp(with: event)
  }
  override func otherMouseDown(with event: NSEvent) {
    _ = sendMouseButton(event: event, button: GHOSTTY_MOUSE_MIDDLE, action: GHOSTTY_MOUSE_PRESS)
  }
  override func otherMouseUp(with event: NSEvent) {
    _ = sendMouseButton(event: event, button: GHOSTTY_MOUSE_MIDDLE, action: GHOSTTY_MOUSE_RELEASE)
  }

  override func mouseDragged(with event: NSEvent) { sendMouseMoved(event) }
  override func rightMouseDragged(with event: NSEvent) { sendMouseMoved(event) }
  override func otherMouseDragged(with event: NSEvent) { sendMouseMoved(event) }
  override func mouseMoved(with event: NSEvent) { sendMouseMoved(event) }

  override func scrollWheel(with event: NSEvent) {
    guard let surface else { return }
    var modifier: ghostty_input_scroll_mods_t = 0
    if event.hasPreciseScrollingDeltas { modifier |= 1 }
    // Momentum scrolling: phase != .none means we are in a momentum tail.
    // NSEvent.momentumPhase returns .changed for the tail, .ended at stop.
    if !event.momentumPhase.isEmpty && event.momentumPhase != .stationary {
      modifier |= 2
    }
    ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, modifier)
  }

  private func sendMouseMoved(_ event: NSEvent) {
    guard let surface else { return }
    // ghostty_surface_mouse_pos expects point coordinates (not device-pixel)
    // — ghostty applies content_scale internally on render. NSView is Y-up
    // by default; libghostty is Y-down. Flip explicitly so selection and
    // hover hit the same cell the user is pointing at.
    let pos = convert(event.locationInWindow, from: nil)
    let y = bounds.height - pos.y
    ghostty_surface_mouse_pos(surface, pos.x, y, mods(from: event.modifierFlags))
  }

  /// Returns whether libghostty consumed this button event. Right-click
  /// uses the result to decide whether to fall through to AppKit's default
  /// right-click handling (which opens the context menu via `menu(for:)`);
  /// other callers ignore it.
  @discardableResult
  private func sendMouseButton(
    event: NSEvent,
    button: ghostty_input_mouse_button_e,
    action: ghostty_input_mouse_state_e
  ) -> Bool {
    guard let surface else { return false }
    let pos = convert(event.locationInWindow, from: nil)
    let y = bounds.height - pos.y
    ghostty_surface_mouse_pos(surface, pos.x, y, mods(from: event.modifierFlags))
    return ghostty_surface_mouse_button(surface, action, button, mods(from: event.modifierFlags))
  }

  // MARK: - NSDraggingDestination

  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    guard let types = sender.draggingPasteboard.types else { return [] }
    if Set(types).isDisjoint(with: Self.dropTypes) { return [] }
    return .copy
  }

  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    let pasteboard = sender.draggingPasteboard
    let content: String?
    if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
      !urls.isEmpty
    {
      // File URLs (Finder, most editors). Drop the `file://` scheme and
      // shell-escape every path so a single drop of multiple files becomes
      // a space-separated list ready to be edited or executed.
      content = urls.map { url in
        url.isFileURL ? Self.shellEscape(url.path) : url.absoluteString
      }.joined(separator: " ")
    } else if let url = pasteboard.string(forType: .URL) {
      content = Self.shellEscape(url)
    } else if let str = pasteboard.string(forType: .string) {
      content = str
    } else {
      content = nil
    }
    guard let content, !content.isEmpty else { return false }
    // Route through insertText so drag-insert reuses the same forwarding
    // path as IME commits — keyTextAccumulator is nil here, so it lands
    // directly on `ghostty_surface_text`.
    insertText(content, replacementRange: NSRange(location: 0, length: 0))
    return true
  }

  // MARK: - Context menu

  override func menu(for event: NSEvent) -> NSMenu? {
    // Only build a menu for the actual right-click. Trackpad two-finger
    // taps reach here as `.rightMouseDown` too — same path.
    guard event.type == .rightMouseDown else { return nil }
    guard let surface, !ghostty_surface_mouse_captured(surface) else { return nil }

    let menu = NSMenu()
    if ghostty_surface_has_selection(surface) {
      menu.addItem(NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: ""))
    }
    menu.addItem(NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: ""))
    menu.addItem(.separator())
    menu.addItem(menuItem("Split Right", #selector(splitRight(_:)), symbol: "rectangle.righthalf.inset.filled"))
    menu.addItem(menuItem("Split Down", #selector(splitDown(_:)), symbol: "rectangle.bottomhalf.inset.filled"))
    menu.addItem(menuItem("Split Left", #selector(splitLeft(_:)), symbol: "rectangle.leadinghalf.inset.filled"))
    menu.addItem(menuItem("Split Up", #selector(splitUp(_:)), symbol: "rectangle.tophalf.inset.filled"))
    menu.addItem(.separator())
    menu.addItem(menuItem("Reset Terminal", #selector(resetTerminal(_:)), symbol: "arrow.trianglehead.2.clockwise"))
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Copy Pane ID", action: #selector(copyPaneID(_:)), keyEquivalent: ""))
    return menu
  }

  private func menuItem(_ title: String, _ action: Selector, symbol: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    return item
  }

  /// Route a binding action string (the same syntax used in Ghostty's
  /// keybindings config) through libghostty so menu items reuse the
  /// surface's own copy / paste / reset implementations rather than
  /// hand-rolling NSPasteboard logic that would diverge over time.
  private func performBindingAction(_ action: String) {
    guard let surface else { return }
    action.withCString { ptr in
      _ = ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
    }
  }

  @IBAction func copy(_ sender: Any?) { performBindingAction("copy_to_clipboard") }
  @IBAction func paste(_ sender: Any?) { performBindingAction("paste_from_clipboard") }
  @IBAction func resetTerminal(_ sender: Any?) { performBindingAction("reset") }
  @IBAction func copyPaneID(_ sender: Any?) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(paneID.description, forType: .string)
  }
  @IBAction func splitRight(_ sender: Any?) { onPaneAction?(.newSplit(direction: .right)) }
  @IBAction func splitLeft(_ sender: Any?) { onPaneAction?(.newSplit(direction: .left)) }
  @IBAction func splitDown(_ sender: Any?) { onPaneAction?(.newSplit(direction: .down)) }
  @IBAction func splitUp(_ sender: Any?) { onPaneAction?(.newSplit(direction: .up)) }

  // MARK: - NSTextInputClient

  func insertText(_ string: Any, replacementRange: NSRange) {
    let text: String = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
    guard !text.isEmpty else { return }
    // Inside a keyDown's interpretKeyEvents pass, accumulate into the
    // keyTextAccumulator so keyDown attaches it to the single key event.
    // Outside that pass (e.g. drag-insert), route directly to the surface.
    if keyTextAccumulator != nil {
      keyTextAccumulator?.append(text)
    } else if let surface {
      // Clear any in-flight preedit and commit the text.
      forwardPreedit("", to: surface)
      forwardText(text, to: surface)
    }
    markedText = NSMutableAttributedString()
    if let surface {
      // Ensure preedit is cleared on the ghostty side too.
      forwardPreedit("", to: surface)
    }
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    let attr: NSAttributedString
    if let s = string as? NSAttributedString {
      attr = s
    } else if let s = string as? String {
      attr = NSAttributedString(string: s)
    } else {
      return
    }
    markedText = NSMutableAttributedString(attributedString: attr)
    // Forward preedit so IME composition is visible in the terminal rather
    // than appearing only after commit.
    if let surface {
      forwardPreedit(attr.string, to: surface)
    }
  }

  func unmarkText() {
    markedText = NSMutableAttributedString()
    if let surface {
      forwardPreedit("", to: surface)
    }
  }

  func selectedRange() -> NSRange {
    // Bridges NSTextInputClient (IME caret) and the AX selected-text-range
    // accessor onto libghostty's current selection. Returning a real offset
    // when text is selected is required by AX consumers (translators,
    // dictionaries) to decide that a selection exists before they query
    // `accessibilitySelectedText`.
    guard let surface else { return NSRange() }
    var text = ghostty_text_s()
    guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
    defer { ghostty_surface_free_text(surface, &text) }
    return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
  }
  func markedRange() -> NSRange {
    markedText.length == 0 ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedText.length)
  }
  func hasMarkedText() -> Bool { markedText.length > 0 }
  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    // libghostty reports the caret's rect in view-points with a top-left
    // origin and y at the bottom edge of the cursor cell. AppKit views
    // are bottom-left origin, so flip y against the view height; once
    // flipped, that y is the rect's own bottom edge. Falling back to
    // .zero keeps IME functional (candidate panel anchors to the screen
    // origin) before a surface attaches.
    guard let surface, let window else { return .zero }
    var x: Double = 0
    var y: Double = 0
    var width: Double = 0
    var height: Double = 0
    ghostty_surface_ime_point(surface, &x, &y, &width, &height)
    let viewRect = NSRect(
      x: x,
      y: bounds.height - y,
      width: max(width, 0),
      height: max(height, 1)
    )
    let winRect = convert(viewRect, to: nil)
    return window.convertToScreen(winRect)
  }
  func characterIndex(for point: NSPoint) -> Int { 0 }
  override func doCommand(by selector: Selector) {
    // Let default NSResponder chain handle it; ghostty already received the
    // raw key event in keyDown.
  }

  // MARK: - Forwarding helpers

  private func forwardText(_ text: String, to surface: ghostty_surface_t) {
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

  private func forwardPreedit(_ text: String, to surface: ghostty_surface_t) {
    let bytes = Array(text.utf8)
    if bytes.isEmpty {
      ghostty_surface_preedit(surface, nil, 0)
      return
    }
    bytes.withUnsafeBufferPointer { buffer in
      buffer.baseAddress?.withMemoryRebound(
        to: CChar.self,
        capacity: bytes.count
      ) { ptr in
        ghostty_surface_preedit(surface, ptr, UInt(bytes.count))
      }
    }
  }
}

// MARK: - Services menu (selected-text read-out)

/// Third-party text utilities (translators, dictionaries, "lookup-on-hover"
/// tools) read the focused responder's selection through the macOS
/// services system, not through Accessibility. The flow is:
///   1. system calls `validRequestor(forSendType:returnType:)` to find a
///      responder that can serve `sendType` (and optionally accept
///      `returnType`),
///   2. on a match it calls `writeSelection(to:types:)` to harvest the
///      data into a pasteboard.
/// Without these hooks the selection in a pane is invisible to that whole
/// class of tools — the HAN-75 symptom. Only the read-out side is wired
/// here (`returnType == nil`); inbound services (sending text back into
/// the pane) are out of scope for HAN-75 and intentionally fall through
/// to `super`.
extension GhosttySurfaceView: NSServicesMenuRequestor {
  override func validRequestor(
    forSendType sendType: NSPasteboard.PasteboardType?,
    returnType: NSPasteboard.PasteboardType?
  ) -> Any? {
    let sendable: [NSPasteboard.PasteboardType] = [
      .string,
      .init("public.utf8-plain-text"),
    ]
    if returnType == nil,
      let sendType,
      sendable.contains(sendType),
      let surface,
      ghostty_surface_has_selection(surface)
    {
      return self
    }
    return super.validRequestor(forSendType: sendType, returnType: returnType)
  }

  func writeSelection(
    to pboard: NSPasteboard,
    types: [NSPasteboard.PasteboardType]
  ) -> Bool {
    guard let surface else { return false }
    var text = ghostty_text_s()
    guard ghostty_surface_read_selection(surface, &text) else { return false }
    defer { ghostty_surface_free_text(surface, &text) }
    guard let cString = text.text else { return false }
    pboard.declareTypes([.string], owner: nil)
    pboard.setString(String(cString: cString), forType: .string)
    return true
  }
}
