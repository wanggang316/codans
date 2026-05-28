import AppKit
import TouchCodeCore

/// AppKit chord-capture surface driven by `HotkeyRecorderPopover`. Renders the current
/// binding (or a placeholder) as a focusable cell; while focused, intercepts `keyDown`
/// events through a local `NSEvent` monitor so chord candidates do not also fire the
/// matching menu items.
///
/// Validation rules applied before forwarding to the host:
///
/// - At least one of `⌘` / `⌥` / `⌃` must be present. Bare `⇧` + a printable key is
///   rejected because it would shadow ordinary typing.
/// - The keyCode must not be a modifier-only event (rare but possible — pressing `⌘`
///   with nothing else produces a keyDown with keyCode == 55 on some hardware paths).
final class HotkeyRecorderNSView: NSView {
  enum RejectionReason: Equatable, Sendable, Error {
    case missingPrimaryModifier
    case modifierOnly
  }

  /// Fired when a valid chord is captured.
  var onCapture: ((ShortcutBinding) -> Void)?
  /// Fired when a keyDown is rejected by validation. The host typically shows a
  /// transient inline message and re-enables the field.
  var onReject: ((RejectionReason) -> Void)?
  /// Fired when the user cancels via Esc or by clicking out.
  var onCancel: (() -> Void)?
  /// Fired on every flagsChanged event while recording. The popover-style host uses this
  /// to render Raycast-style live keycap previews of the modifier(s) currently held down
  /// before any non-modifier key produces a chord. Omit on inline hosts that don't want
  /// the live preview.
  var onModifiersChanged: ((ModifierMask) -> Void)?

  /// Pure validator — extracted so unit tests can exercise it without a running RunLoop.
  static func validate(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Result<ShortcutBinding, RejectionReason> {
    if Self.isModifierKeyCode(keyCode) {
      return .failure(.modifierOnly)
    }
    let mask = ModifierMask(eventFlags: flags)
    let primary: ModifierMask = [.command, .option, .control]
    if mask.intersection(primary).isEmpty {
      return .failure(.missingPrimaryModifier)
    }
    return .success(ShortcutBinding(keyCode: keyCode, modifiers: mask, isEnabled: true))
  }

  override var acceptsFirstResponder: Bool { isRecording }

  private(set) var isRecording: Bool = false
  private var localMonitor: Any?

  // MARK: - Lifecycle

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    wantsLayer = true
  }

  deinit {
    teardownMonitor()
  }

  // MARK: - Recording control

  func beginRecording() {
    guard !isRecording else { return }
    isRecording = true
    window?.makeFirstResponder(self)
    teardownMonitor()
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
      guard let self else { return event }
      switch event.type {
      case .flagsChanged:
        // flagsChanged is informational — surface the current modifier mask via the
        // optional callback, but do NOT swallow the event so cmd-tab and other
        // higher-level system handlers still see it.
        self.onModifiersChanged?(ModifierMask(eventFlags: event.modifierFlags))
        return event
      default:
        // Swallow the keyDown so the chord candidate does not also fire the matching
        // menu item or text-input target while recording.
        self.handle(event)
        return nil
      }
    }
  }

  func endRecording() {
    guard isRecording else { return }
    isRecording = false
    teardownMonitor()
    onCancel?()
    window?.makeFirstResponder(nil)
  }

  // MARK: - Event handling

  override func keyDown(with event: NSEvent) {
    handle(event)
  }

  override func flagsChanged(with event: NSEvent) {
    onModifiersChanged?(ModifierMask(eventFlags: event.modifierFlags))
  }

  private func handle(_ event: NSEvent) {
    guard isRecording else { return }
    if event.keyCode == kVK_Escape_compat {
      endRecording()
      return
    }
    let result = Self.validate(keyCode: event.keyCode, flags: event.modifierFlags)
    switch result {
    case .success(let binding):
      isRecording = false
      teardownMonitor()
      onCapture?(binding)
    case .failure(let reason):
      onReject?(reason)
    }
  }

  private func teardownMonitor() {
    if let monitor = localMonitor {
      NSEvent.removeMonitor(monitor)
      localMonitor = nil
    }
  }

  // MARK: - Helpers

  /// Pure modifier keyCodes that should never produce a binding. Spelled out as
  /// numeric literals so the validator stays Carbon-import-free at the call site;
  /// values match `Carbon.HIToolbox.kVK_Shift / Control / Option / Command` etc.
  private static let modifierKeyCodes: Set<UInt16> = [
    0x37,  // command
    0x36,  // right command
    0x38,  // shift
    0x3C,  // right shift
    0x3A,  // option
    0x3D,  // right option
    0x3B,  // control
    0x3E,  // right control
    0x39,  // capslock
    0x3F,  // function
  ]

  static func isModifierKeyCode(_ keyCode: UInt16) -> Bool {
    modifierKeyCodes.contains(keyCode)
  }
}

private let kVK_Escape_compat: UInt16 = 0x35  // matches Carbon.HIToolbox.kVK_Escape

extension ModifierMask {
  /// Convenience for translating an `NSEvent.ModifierFlags` value into the storage-layer
  /// mask. Caps-lock and other ancillary bits are masked away.
  init(eventFlags: NSEvent.ModifierFlags) {
    var mask: ModifierMask = []
    if eventFlags.contains(.command) { mask.insert(.command) }
    if eventFlags.contains(.option) { mask.insert(.option) }
    if eventFlags.contains(.control) { mask.insert(.control) }
    if eventFlags.contains(.shift) { mask.insert(.shift) }
    self = mask
  }
}
