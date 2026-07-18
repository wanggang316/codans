import AppKit
import SwiftUI

/// Hosts a zero-size `NSView` that keeps the enclosing window out of the macOS
/// **Window** menu's auto-populated window list (the "Codans" / "Settings"
/// title entries).
///
/// `isExcludedFromWindowsMenu` is the documented lever, but a single set in
/// `viewDidMoveToWindow` does not stick for a SwiftUI scene: SwiftUI wires the
/// window into the Window menu on a later runloop turn and re-registers it when
/// the window first becomes key, each time effectively re-adding the entry. So
/// the exclusion is re-applied defensively — on every SwiftUI update, one
/// runloop turn after the view mounts, and whenever the window becomes key —
/// and the already-inserted item is stripped with `removeWindowsItem` each time.
///
/// Place once inside each scene's content tree — no visual output.
struct ExcludeFromWindowsMenu: NSViewRepresentable {
  func makeNSView(context: Context) -> ExcludingView { ExcludingView() }
  func updateNSView(_ nsView: ExcludingView, context: Context) { nsView.reapply() }

  final class ExcludingView: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      reapply()
      if let window {
        // Re-exclude whenever this window becomes key — SwiftUI re-registers it
        // in the Window menu at that point. Target/selector (not a token-based
        // observer) so the nonisolated `deinit` can tear it down with
        // `removeObserver(self)` without touching a non-Sendable stored token.
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(
          self,
          selector: #selector(windowBecameKey),
          name: NSWindow.didBecomeKeyNotification,
          object: window
        )
      }
      // SwiftUI registers the scene's window in the menu on a later runloop
      // turn; a synchronous set here would be undone, so re-apply once the
      // current turn drains.
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated { self?.reapply() }
      }
    }

    @objc private func windowBecameKey() { reapply() }

    /// Exclude this view's window and drop any entry AppKit/SwiftUI already
    /// inserted for it. No-op until the view is in a window.
    func reapply() {
      guard let window else { return }
      window.isExcludedFromWindowsMenu = true
      NSApp.removeWindowsItem(window)
    }

    deinit {
      NotificationCenter.default.removeObserver(self)
    }
  }
}
