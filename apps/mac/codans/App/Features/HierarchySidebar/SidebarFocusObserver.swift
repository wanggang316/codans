import AppKit
import SwiftUI

/// Observable that tracks whether the sidebar (the only `NSTableView` inside the main window)
/// currently holds first-responder. Used by `MainWindowCommands` to gate destructive
/// worktree chords (`⌘⌫` / `⌘⇧⌫`) so they only fire while the user is on the sidebar — when
/// focus is in a Ghostty terminal pane the menu item is disabled and the chord falls through
/// to the terminal (where `⌘⌫` is the standard "delete to start of line" binding).
///
/// **Update strategy.** First-responder has no public KVO / notification, so we recompute on
/// every signal that *could* have moved focus: window key changes, mouse up, key down, and
/// flags changed. Recomputes are synchronous on the main thread so the freshly mutated
/// `isSidebarFocused` reaches SwiftUI's `Commands` re-render — and the bridged
/// `NSMenuItem.isEnabled` — before AppKit's chord matcher inspects the menu on the next
/// `.keyDown` event with the chord modifier.
///
/// **Sidebar identification.** The main window contains exactly one `NSTableView` (the
/// `NavigationSplitView` sidebar's `List(selection:)`); other tables in the app live in
/// Settings (its own window) or in modal sheets (which present as separate child windows
/// and are filtered out via `window.parent != nil` and `SettingsWindowTagger.matches`).
@Observable
@MainActor
final class SidebarFocusObserver {
  private(set) var isSidebarFocused: Bool = false

  @ObservationIgnored
  private let storage = MonitorStorage()

  init() {
    storage.eventMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseUp, .rightMouseUp, .keyDown, .flagsChanged]
    ) { [weak self] event in
      MainActor.assumeIsolated { self?.recompute() }
      return event
    }
    storage.becomeKeyToken = NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.recompute() }
    }
    storage.resignKeyToken = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.recompute() }
    }
    // No initial recompute(): this initializer runs inside `CodansApp.init()` —
    // i.e. before `NSApplicationMain` has installed `NSApplication.shared`, so the
    // implicitly-unwrapped `NSApp` global is still nil and `evaluate()`'s first
    // line traps. The default `false` is the correct launch-time answer (no key
    // window yet); `didBecomeKeyNotification` will fire the first real recompute
    // once the main window comes up.
  }

  deinit {
    storage.teardown()
  }

  private func recompute() {
    let next = Self.evaluate()
    if next != isSidebarFocused {
      isSidebarFocused = next
    }
  }

  private static func evaluate() -> Bool {
    guard let window = NSApp.keyWindow else { return false }
    // Settings is its own scene; sheets / popovers come up as child windows. Both share the
    // app's main menu but are not the codans workspace, so destructive worktree chords
    // should never fire from them.
    if SettingsWindowTagger.matches(window) { return false }
    if window.parent != nil { return false }
    var responder: NSResponder? = window.firstResponder
    while let cur = responder {
      if cur is NSTableView { return true }
      responder = cur.nextResponder
    }
    return false
  }
}

/// Untyped holder for the `NSEvent` monitor + observer tokens. Mirrors the pattern in
/// `CommandKeyObserver` so the observer's `nonisolated deinit` can tear them down without
/// tripping Swift 6 strict concurrency.
nonisolated private final class MonitorStorage: @unchecked Sendable {
  var eventMonitor: Any?
  var becomeKeyToken: NSObjectProtocol?
  var resignKeyToken: NSObjectProtocol?

  init() {}

  func teardown() {
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }
    if let becomeKeyToken {
      NotificationCenter.default.removeObserver(becomeKeyToken)
      self.becomeKeyToken = nil
    }
    if let resignKeyToken {
      NotificationCenter.default.removeObserver(resignKeyToken)
      self.resignKeyToken = nil
    }
  }
}
