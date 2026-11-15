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
/// **Hold of ⌘⌥.** `isCommandOptionHeld` follows the same rules for a hold of exactly ⌘ and ⌥
/// (in either order). It drives the Pane number overlay of the split viewport. A held ⌘⌥ is a
/// chord for the ⌘ hold, so the ⌘ hints stay hidden while the Pane numbers show.
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
  ///
  /// Hand-rolled instead of a stored property: Observation notifies before a stored property
  /// changes, and a hint that re-renders inside that notification (a view in a geometry
  /// reader or a lazy stack, when another reader lays the window out synchronously) reads
  /// the old state. It then keeps it until the next change, so it shows while ⌘ is up and hides
  /// while ⌘ is held. `setHeld(_:for:)` stores the state first and notifies after.
  var isCommandHeld: Bool {
    access(keyPath: \.isCommandHeld)
    return commandHold.isShown
  }

  /// `true` once exactly ⌘ and ⌥ have been held for `pressActivationDelay`. Same storage and
  /// notification rules as `isCommandHeld`.
  var isCommandOptionHeld: Bool {
    access(keyPath: \.isCommandOptionHeld)
    return commandOptionHold.isShown
  }

  @ObservationIgnored
  private let commandHold = ModifierHold(modifiers: .command)

  @ObservationIgnored
  private let commandOptionHold = ModifierHold(modifiers: [.command, .option])

  @ObservationIgnored
  private let storage = MonitorStorage()

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
        for hold in [self.commandHold, self.commandOptionHold] {
          if event.type == .flagsChanged {
            hold.gesture.modifiersChanged(event.modifierFlags)
          } else {
            hold.gesture.keyPressed()
          }
        }
        self.applyGestures()
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
        self.commandHold.gesture.reset()
        self.commandOptionHold.gesture.reset()
        self.applyGestures()
      }
    }
  }

  // A pending activation task holds the observer weakly and ends without effect once the
  // observer is gone, so the nonisolated deinit does not cancel it.
  deinit {
    storage.teardown()
  }

  private func applyGestures() {
    apply(commandHold, keyPath: \.isCommandHeld)
    apply(commandOptionHold, keyPath: \.isCommandOptionHeld)
  }

  /// Arms the delayed promotion when a hold starts; hides the hints when it ends.
  private func apply(_ hold: ModifierHold, keyPath: KeyPath<CommandKeyObserver, Bool>) {
    if hold.gesture.isHolding {
      // Already shown or pending: a repeated flagsChanged does not restart the delay.
      guard !hold.isShown, hold.activationTask == nil else { return }
      let delay = pressActivationDelay
      hold.activationTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled, let self else { return }
        hold.activationTask = nil
        self.setHeld(true, for: hold, keyPath: keyPath)
      }
    } else {
      hold.activationTask?.cancel()
      hold.activationTask = nil
      setHeld(false, for: hold, keyPath: keyPath)
    }
  }

  func setCommandHeld(_ held: Bool) {
    setHeld(held, for: commandHold, keyPath: \.isCommandHeld)
  }

  func setCommandOptionHeld(_ held: Bool) {
    setHeld(held, for: commandOptionHold, keyPath: \.isCommandOptionHeld)
  }

  /// Every hint keyed on this flag inserts or removes itself in the same transaction, so
  /// one animation here drives all of their transitions (`ShortcutHintLabel`).
  private func setHeld(
    _ held: Bool, for hold: ModifierHold, keyPath: KeyPath<CommandKeyObserver, Bool>
  ) {
    guard held != hold.isShown else { return }
    hold.isShown = held
    let animation: Animation? =
      NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .shortcutHint
    withAnimation(animation) {
      // Notify only after the store, so a reader in the notification sees the new state.
      withMutation(keyPath: keyPath) {}
    }
  }
}

/// The state of one hold gesture: the gesture phase, whether its hints show, and the pending
/// delayed promotion.
@MainActor
private final class ModifierHold {
  var gesture: CommandHoldGesture
  var isShown = false
  var activationTask: Task<Void, Never>?

  init(modifiers: NSEvent.ModifierFlags) {
    gesture = CommandHoldGesture(modifiers: modifiers)
  }
}

/// Tells a hold of exactly `modifiers` (⌘ alone by default) from a chord. Pressing part of
/// `modifiers` is the start of a hold; the press is a hold once exactly `modifiers` are down,
/// and stays one until any other key or modifier joins it. After that it stays a chord until
/// the modifiers drop back to part of `modifiers`.
struct CommandHoldGesture {
  private enum Phase {
    case idle
    case holding
    case chord
  }

  private static let tracked: NSEvent.ModifierFlags = [.command, .shift, .option, .control, .function]

  let modifiers: NSEvent.ModifierFlags
  private var phase = Phase.idle

  init(modifiers: NSEvent.ModifierFlags = .command) {
    self.modifiers = modifiers
  }

  var isHolding: Bool { phase == .holding }

  mutating func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
    let down = flags.intersection(Self.tracked)
    if down != modifiers, modifiers.isSuperset(of: down) {
      phase = .idle
    } else if down != modifiers {
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
