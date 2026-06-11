import AppKit
import SwiftUI

/// Observable that surfaces whether the `.command` modifier is currently held. Used by the
/// sidebar / tab bar / status bar to toggle hotkey hints (`⌃N`, `⌘N`, etc.) so users
/// discover the bindings without cluttering chrome in the default state.
///
/// Installs an `NSEvent` local monitor for `.flagsChanged` at init. The monitor fires on
/// the main thread, so `isCommandHeld` is mutated on the same thread SwiftUI reads from.
///
/// **Press-debounce.** Hints widen the chrome of every button they decorate (chord text
/// laid out inline with the label), so toggling them on every transient ⌘ tap — quick
/// chord triggers, finger glances, modifier-only chord prefixes — produces a lot of
/// distracting layout churn. We delay flipping `isCommandHeld → true` by
/// `pressActivationDelay` (default 1 s): only a sustained "hold ⌘ to discover" gesture
/// lights up the hints. The delay is one-way; releases flip back to `false` immediately
/// so a chord that fires and briefly grabs focus doesn't leave hints lingering after the
/// user has let go.
///
/// **Active-state coupling.** When a chord like ⌘O fires a menu action that opens an
/// external editor, the OS hands focus to that editor. Any `flagsChanged` event that fires
/// for the ⌘ release while another app is frontmost is delivered to *that* app, not ours,
/// so the local monitor never sees it and `isCommandHeld` would stay stuck at `true` even
/// after the user has long since let the modifier go. We additionally listen for
/// `NSApplication.didResignActive` and clear the flag whenever codans goes to the
/// background — `flagsChanged` resumes delivering once the user re-presses ⌘ inside our
/// window, restoring the hint live.
///
/// The monitor + observer tokens live in a private `@unchecked Sendable` box so the
/// observer's nonisolated `deinit` can tear them down without tripping Swift 6 strict
/// concurrency.
@Observable
@MainActor
final class CommandKeyObserver {
  /// `true` once the `.command` modifier has been continuously held for `pressActivationDelay`.
  private(set) var isCommandHeld: Bool = false

  @ObservationIgnored
  private let storage = MonitorStorage()
  /// Pending "promote ⌘ to held after delay" task. Cancelled if the user releases ⌘
  /// before the delay elapses, or if the app loses focus.
  @ObservationIgnored
  private var activationTask: Task<Void, Never>?

  /// Sustained-hold threshold before hints render. Tuned long (1 s) deliberately:
  /// shorter values still flickered every ⌘+key chord because the ⌘ key sits depressed
  /// during the natural pause between modifier-down and the second key. 1 s is past the
  /// average chord duration, so only a clear "hold ⌘ to discover bindings" gesture lights
  /// up the hint chrome. Configurable per-instance for tests.
  let pressActivationDelay: Duration

  init(pressActivationDelay: Duration = .seconds(1)) {
    self.pressActivationDelay = pressActivationDelay
    storage.monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      let down = event.modifierFlags.contains(.command)
      Task { @MainActor in
        self?.handleCommandFlag(down: down)
      }
      return event
    }
    storage.resignToken = NotificationCenter.default.addObserver(
      forName: NSApplication.didResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      // App lost focus: a chord that fires an external app (⌘O → editor, ⌘⇧G → browser)
      // releases its modifier in *that* app, so `flagsChanged` never reaches us. Clear
      // the held flag now so the hint chrome doesn't get stuck on.
      MainActor.assumeIsolated {
        self?.handleCommandFlag(down: false)
      }
    }
  }

  deinit {
    activationTask?.cancel()
    storage.teardown()
  }

  /// Routes a raw `.command`-down boolean through the press-debounce. Down transitions
  /// schedule a delayed promotion to `isCommandHeld == true`; up transitions cancel any
  /// pending promotion and flip the flag false synchronously.
  private func handleCommandFlag(down: Bool) {
    if down {
      // Already held (e.g. flagsChanged fired again with command still set) — no need
      // to re-arm. The earlier task either already promoted or is still pending.
      guard !isCommandHeld else { return }
      activationTask?.cancel()
      let delay = pressActivationDelay
      activationTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled else { return }
        self?.isCommandHeld = true
      }
    } else {
      activationTask?.cancel()
      activationTask = nil
      if isCommandHeld {
        isCommandHeld = false
      }
    }
  }
}

/// Untyped holder for the `NSEvent` monitor + observer tokens. `@unchecked Sendable` is
/// safe here: the tokens are written exactly once (by `CommandKeyObserver.init`) and read
/// at teardown, so there is no concurrent access. Wrapping the `Any?` slots inside a
/// dedicated class also keeps the non-Sendable properties out of the observer's own
/// storage, which the Swift 6 deinit checker requires.
nonisolated private final class MonitorStorage: @unchecked Sendable {
  var monitor: Any?
  var resignToken: NSObjectProtocol?

  init() {}

  func teardown() {
    if let monitor = monitor {
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }
    if let resignToken {
      NotificationCenter.default.removeObserver(resignToken)
      self.resignToken = nil
    }
  }
}
