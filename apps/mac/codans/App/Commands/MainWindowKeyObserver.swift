import AppKit
import SwiftUI

/// Observable that tracks whether the main codans window is the key window. Used by
/// `MainWindowCommands` to scope the Archive / Delete Worktree commands to the main window
/// (ADR 0010): they act on the selected Worktree from any focus location in that window,
/// but stay disabled while Settings, the Diff window, a sheet, or a popover is key.
///
/// Key-window changes post `NSWindow.didBecomeKeyNotification` /
/// `didResignKeyNotification`, so no event monitor is needed. Recomputes are synchronous on
/// the main thread so the new value reaches SwiftUI's `Commands` re-render — and the bridged
/// `NSMenuItem.isEnabled` — before AppKit matches the next key equivalent.
@Observable
@MainActor
final class MainWindowKeyObserver {
  private(set) var isMainWindowKey: Bool = false

  @ObservationIgnored
  private let storage = ObserverStorage()

  init() {
    storage.becomeKeyToken = NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.recompute(resigning: nil) }
    }
    storage.resignKeyToken = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      let window = note.object as? NSWindow
      MainActor.assumeIsolated { self?.recompute(resigning: window) }
    }
    // No initial recompute(): this initializer runs inside `CodansApp.init()`, before
    // `NSApplicationMain` has installed `NSApplication.shared`, so the implicitly-unwrapped
    // `NSApp` global is still nil. The default `false` is the correct launch-time answer (no
    // key window yet); `didBecomeKeyNotification` fires the first real recompute.
  }

  deinit {
    storage.teardown()
  }

  /// `resigning` is the window that posted `didResignKey`. `NSApp.keyWindow` can still
  /// return it during the notification, so it is not taken as the key window.
  private func recompute(resigning: NSWindow?) {
    var key = NSApp.keyWindow
    if let resigning, key === resigning { key = nil }
    let next = Self.isMainWindow(key)
    if next != isMainWindowKey {
      isMainWindowKey = next
    }
  }

  /// `true` when `window` is the main codans window. Settings, the Diff window, sheets
  /// (`sheetParent`), popovers and other child windows (`parent`), and panels share the
  /// app's main menu but are not the main window.
  static func isMainWindow(_ window: NSWindow?) -> Bool {
    guard let window else { return false }
    if SettingsWindowTagger.matches(window) { return false }
    if window.identifier == DiffWindowManager.windowIdentifier { return false }
    if window.parent != nil || window.sheetParent != nil { return false }
    if window is NSPanel { return false }
    return true
  }
}

/// Untyped holder for the observer tokens. Mirrors the pattern in `CommandKeyObserver` so the
/// observer's `nonisolated deinit` can tear them down without tripping Swift 6 strict
/// concurrency.
nonisolated private final class ObserverStorage: @unchecked Sendable {
  var becomeKeyToken: NSObjectProtocol?
  var resignKeyToken: NSObjectProtocol?

  init() {}

  func teardown() {
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
