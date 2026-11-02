import AppKit
import CodansCore
import SwiftUI

/// A chord and the action it runs, for `localHotkeys(_:)`.
struct LocalHotkey {
  let binding: ShortcutBinding
  let action: () -> Void
}

extension View {
  /// Runs the action of the first hotkey that matches a key press in this view's window,
  /// while this view is mounted, and swallows that key press.
  ///
  /// Use it for a chord without ⌘ or ⌃ (e.g. `⌥1`). AppKit offers only ⌘ and ⌃ chords as
  /// key equivalents before it sends `keyDown` to the first responder, so a SwiftUI
  /// `.keyboardShortcut` with ⌥ alone never fires while a terminal pane has focus: the
  /// surface takes the press as text input. A local monitor sees the press first.
  ///
  /// A press goes through untouched while a text field or text view has focus, so the
  /// chords stay available for typing there.
  func localHotkeys(_ hotkeys: [LocalHotkey]) -> some View {
    background(LocalHotkeyProbe(hotkeys: hotkeys))
  }
}

private struct LocalHotkeyProbe: NSViewRepresentable {
  let hotkeys: [LocalHotkey]

  func makeNSView(context: Context) -> LocalHotkeyProbeView {
    LocalHotkeyProbeView()
  }

  func updateNSView(_ nsView: LocalHotkeyProbeView, context: Context) {
    nsView.hotkeys = hotkeys
  }

  static func dismantleNSView(_ nsView: LocalHotkeyProbeView, coordinator: ()) {
    nsView.uninstall()
  }
}

@MainActor
final class LocalHotkeyProbeView: NSView {
  var hotkeys: [LocalHotkey] = []
  private let storage = HotkeyMonitorStorage()

  deinit {
    storage.teardown()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { uninstall() } else { install() }
  }

  func uninstall() {
    storage.teardown()
  }

  private func install() {
    guard storage.monitor == nil else { return }
    storage.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      // Local monitors run on the main thread; see `ClickOutsideProbeView`.
      guard let self else { return event }
      return self.handle(event)
    }
  }

  /// Returns the event to let it through, or `nil` to swallow it.
  private func handle(_ event: NSEvent) -> NSEvent? {
    guard let window, event.window === window, !(window.firstResponder is NSText) else {
      return event
    }
    let modifiers = ModifierMask(eventFlags: event.modifierFlags)
    guard
      let hotkey = hotkeys.first(where: {
        $0.binding.matches(keyCode: event.keyCode, modifiers: modifiers)
      })
    else { return event }
    hotkey.action()
    return nil
  }
}

/// Holds the monitor token outside the view's own storage so the nonisolated `deinit` can
/// remove it under Swift 6 (same shape as `ClickOutsideProbeView`'s storage). Installed and
/// removed only on the main thread.
nonisolated private final class HotkeyMonitorStorage: @unchecked Sendable {
  var monitor: Any?

  init() {}

  func teardown() {
    guard let monitor else { return }
    NSEvent.removeMonitor(monitor)
    self.monitor = nil
  }
}
