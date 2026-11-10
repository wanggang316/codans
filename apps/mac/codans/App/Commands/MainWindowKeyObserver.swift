import AppKit
import SwiftUI

/// Observable that tracks whether the main codans window is the key window. Used by
/// `MainWindowCommands` to scope the Archive / Delete Worktree commands to the main window
/// (ADR 0010): they act on the selected Worktree from any focus location in that window,
/// but stay disabled while Settings, the Diff window, a sheet, or a popover is key.
///
/// Key-window changes post `NSWindow.didBecomeKeyNotification` /
/// `didResignKeyNotification`, so no event monitor is needed. The window is taken from the
/// notification: `NSApp.keyWindow` is still `nil` while `didBecomeKey` is delivered. Updates
/// are synchronous on the main thread so the new value reaches SwiftUI's `Commands`
/// re-render — and the bridged `NSMenuItem.isEnabled` — before AppKit matches the next key
/// equivalent.
@Observable
@MainActor
final class MainWindowKeyObserver {
  private(set) var isMainWindowKey: Bool = false

  @ObservationIgnored
  private weak var keyWindow: NSWindow?

  @ObservationIgnored
  private let storage = ObserverStorage()

  init() {
    storage.becomeKeyToken = NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      let window = note.object as? NSWindow
      MainActor.assumeIsolated { self?.windowDidBecomeKey(window) }
    }
    storage.resignKeyToken = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      let window = note.object as? NSWindow
      MainActor.assumeIsolated { self?.windowDidResignKey(window) }
    }
  }

  deinit {
    storage.teardown()
  }

  func windowDidBecomeKey(_ window: NSWindow?) {
    keyWindow = window
    update(Self.isMainWindow(window))
  }

  /// Only the window recorded as key can clear the state, so a late resign of an older
  /// window does not undo a newer `didBecomeKey`.
  func windowDidResignKey(_ window: NSWindow?) {
    guard let window, window === keyWindow else { return }
    keyWindow = nil
    update(false)
  }

  private func update(_ next: Bool) {
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
    if DiffWindowManager.isDiffWindow(window) { return false }
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
