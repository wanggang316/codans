import AppKit
import SwiftUI

/// Observable that surfaces whether the `.command` modifier is currently held. Used by the
/// sidebar / tab bar / status bar to toggle hotkey hints (`⌃N`, `⌘N`, etc.) so users
/// discover the bindings without cluttering chrome in the default state.
///
/// Installs an `NSEvent` local monitor for `.flagsChanged` at init. The monitor fires on
/// the main thread, so `isCommandHeld` is mutated on the same thread SwiftUI reads from.
///
/// **Hold of ⌘ alone.** Hints widen the chrome of every button they decorate, so they show
/// only for a deliberate "hold ⌘ to discover" gesture: ⌘ held alone for
/// `pressActivationDelay`. Any other key or modifier during the press is a chord, not a
/// discovery gesture: it hides the hints and keeps them hidden until ⌘ goes up
/// (`CommandHoldGesture`). Because a chord ends the hold, the delay only has to cover the
/// pause before the second key, not the whole chord. Releases hide the hints immediately.
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
  /// `true` once ⌘ has been held alone for `pressActivationDelay`.
  private(set) var isCommandHeld: Bool = false

  @ObservationIgnored
  private var gesture = CommandHoldGesture()

  @ObservationIgnored
  private let storage = MonitorStorage()
  /// Pending "promote ⌘ to held after delay" task. Cancelled when the hold ends before the
  /// delay elapses.
  @ObservationIgnored
  private var activationTask: Task<Void, Never>?

  /// Hold threshold before hints render. Long enough to pass the pause between ⌘-down and
  /// the second key of a chord, short enough that discovery does not feel slow.
  /// Configurable per-instance for tests.
  let pressActivationDelay: Duration

  init(pressActivationDelay: Duration = .milliseconds(500)) {
    self.pressActivationDelay = pressActivationDelay
    // Local monitors run on the main thread, in event order.
    storage.monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) {
      [weak self] event in
      MainActor.assumeIsolated {
        guard let self else { return }
        if event.type == .flagsChanged {
          self.gesture.modifiersChanged(event.modifierFlags)
        } else {
          self.gesture.keyPressed()
        }
        self.applyGesture()
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
        guard let self else { return }
        self.gesture.reset()
        self.applyGesture()
      }
    }
  }

  deinit {
    activationTask?.cancel()
    storage.teardown()
  }

  /// Arms the delayed promotion when a hold starts; hides the hints when it ends.
  private func applyGesture() {
    if gesture.isHolding {
      // Already shown or pending: a repeated flagsChanged does not restart the delay.
      guard !isCommandHeld, activationTask == nil else { return }
      let delay = pressActivationDelay
      activationTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled, let self else { return }
        self.activationTask = nil
        self.setCommandHeld(true)
      }
    } else {
      activationTask?.cancel()
      activationTask = nil
      if isCommandHeld {
        setCommandHeld(false)
      }
    }
  }

  /// Every hint keyed on this flag inserts or removes itself in the same transaction, so
  /// one animation here drives all of their transitions (`ShortcutHintLabel`).
  private func setCommandHeld(_ held: Bool) {
    let animation: Animation? =
      NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .shortcutHint
    withAnimation(animation) {
      isCommandHeld = held
    }
  }
}

/// Tells a hold of ⌘ alone from a chord. A press of ⌘ is a hold until any other key or
/// modifier joins it; after that it stays a chord until ⌘ goes up.
struct CommandHoldGesture {
  private enum Phase {
    case idle
    case holding
    case chord
  }

  private var phase = Phase.idle

  var isHolding: Bool { phase == .holding }

  mutating func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
    let modifiers = flags.intersection([.command, .shift, .option, .control, .function])
    if !modifiers.contains(.command) {
      phase = .idle
    } else if modifiers != .command {
      phase = .chord
    } else if phase == .idle {
      phase = .holding
    }
  }

  mutating func keyPressed() {
    if phase == .holding {
      phase = .chord
    }
  }

  mutating func reset() {
    phase = .idle
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
