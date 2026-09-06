import AppKit
import SwiftUI

/// Collapses a pane-local overlay when the user clicks anywhere outside it,
/// or presses Escape.
///
/// A transparent SwiftUI backdrop — the pattern the Command Palette uses —
/// cannot do this job over a terminal: the pane's ghostty surface is an
/// AppKit view hosted by `PaneHostView`, so a click that lands on the
/// terminal is dispatched by AppKit and never reaches SwiftUI's hit testing.
/// A local event monitor sees the mouse-down before dispatch, which works no
/// matter which view would have received it.
///
/// The probe view is installed as the card's *background*, so its bounds are
/// the card's bounds and "inside" is an exact geometric test rather than
/// coordinate-space arithmetic. It never takes part in hit testing, so the
/// card's own buttons stay clickable.
extension View {
  /// - Parameters:
  ///   - isPresented: monitor only while true.
  ///   - onDismiss: invoked on an outside click or Escape, on the main actor.
  func dismissOnClickOutside(isPresented: Bool, onDismiss: @escaping () -> Void) -> some View {
    background(ClickOutsideProbe(isActive: isPresented, onDismiss: onDismiss))
  }
}

private struct ClickOutsideProbe: NSViewRepresentable {
  let isActive: Bool
  let onDismiss: () -> Void

  func makeNSView(context: Context) -> ClickOutsideProbeView {
    ClickOutsideProbeView()
  }

  func updateNSView(_ nsView: ClickOutsideProbeView, context: Context) {
    nsView.onDismiss = onDismiss
    nsView.isActive = isActive
  }

  static func dismantleNSView(_ nsView: ClickOutsideProbeView, coordinator: ()) {
    nsView.isActive = false
  }
}

@MainActor
final class ClickOutsideProbeView: NSView {
  var onDismiss: () -> Void = {}

  var isActive: Bool = false {
    didSet {
      guard isActive != oldValue else { return }
      if isActive { install() } else { remove() }
    }
  }

  private let storage = MonitorStorage()

  /// Escape's virtual key code. Spelled here rather than inline so the
  /// comparison below reads as intent.
  private static let escapeKeyCode: UInt16 = 53

  deinit {
    // Belt and braces: `dismantleNSView` already deactivates the probe, but
    // a monitor that outlives its view would keep swallowing clicks.
    storage.teardown()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    // Purely a geometry probe. Staying out of hit testing keeps the card's
    // buttons — and, when collapsed, the terminal underneath — clickable.
    nil
  }

  private func install() {
    guard storage.monitor == nil else { return }
    storage.monitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
    ) { [weak self] event in
      // Local monitors are delivered on the main thread, and the closure
      // inherits this view's main-actor isolation — so `handle` is called
      // directly rather than hopped onto the actor, which would require the
      // non-`Sendable` `NSEvent` to cross an isolation boundary.
      guard let self else { return event }
      return self.handle(event)
    }
  }

  private func remove() {
    storage.teardown()
  }

  /// Returns the event to let it through, or `nil` to swallow it.
  private func handle(_ event: NSEvent) -> NSEvent? {
    guard isActive else { return event }

    if event.type == .keyDown {
      guard event.keyCode == Self.escapeKeyCode, event.window === window else { return event }
      onDismiss()
      return nil
    }

    // A click in another window collapses this overlay but still belongs to
    // that window — never swallow it.
    guard let window, event.window === window else {
      onDismiss()
      return event
    }
    let point = convert(event.locationInWindow, from: nil)
    guard !bounds.contains(point) else { return event }
    // Swallowed on purpose: the click that dismisses a menu should not also
    // land in the terminal underneath and move the cursor.
    onDismiss()
    return nil
  }
}

/// Holds the monitor token outside the view's own storage. Swift 6's deinit
/// checker refuses to touch a non-`Sendable` `Any?` stored on a main-actor
/// type from a nonisolated deinit; boxing it here is the same shape
/// `CommandKeyObserver` uses for the identical problem. Installed and torn
/// down only on the main thread, so there is no concurrent access.
nonisolated private final class MonitorStorage: @unchecked Sendable {
  var monitor: Any?

  init() {}

  func teardown() {
    guard let monitor else { return }
    NSEvent.removeMonitor(monitor)
    self.monitor = nil
  }
}
