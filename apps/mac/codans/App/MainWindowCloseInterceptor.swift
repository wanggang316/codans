import AppKit
import Carbon.HIToolbox
import SwiftUI

/// `NSWindowDelegate` proxy for the single main window that redirects the ⌘W
/// chord away from AppKit's standard `File ▸ Close`.
///
/// ⌘W is claimed by the AppKit-synthesised `File ▸ Close` menu item. SwiftUI
/// can neither remove nor outrank it (and its mere presence dedups the same
/// chord off our own `Tab ▸ Close Tab`), so ⌘W ran `performClose:` on the one
/// main window — and because `applicationShouldTerminateAfterLastWindowClosed`
/// returns false, the process then lingered windowless, looking "quit" though
/// it was never killed. We cannot stop `File ▸ Close` from firing, but every
/// close path (⌘W, the red button, a `File ▸ Close` menu click, a programmatic
/// `performClose:`) is funnelled through `windowShouldClose:` first — so we
/// veto there.
///
/// ⌘W is distinguished from the other paths via `NSApp.currentEvent`: when the
/// close originates from the chord, the current event is the ⌘W key-down;
/// the red close button / menu click carry a mouse event and so still close
/// the window normally. Every other delegate callback is forwarded untouched
/// to SwiftUI's own window delegate so scene/restoration behaviour is intact.
@MainActor
final class MainWindowCloseInterceptor: NSObject, NSWindowDelegate {
  /// SwiftUI's original delegate. `NSWindow.delegate` is weak, so SwiftUI keeps
  /// owning this; we only borrow it to forward. `nonisolated(unsafe)` because
  /// the `responds(to:)` / `forwardingTarget(for:)` overrides are nonisolated
  /// on `NSObject` — all access is main-thread (AppKit delegate dispatch).
  nonisolated(unsafe) private weak var forwardTo: NSWindowDelegate?
  private let onCloseChord: () -> Void

  init(forwardTo: NSWindowDelegate?, onCloseChord: @escaping () -> Void) {
    self.forwardTo = forwardTo
    self.onCloseChord = onCloseChord
    super.init()
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if let event = NSApp.currentEvent,
      event.type == .keyDown,
      event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
      event.keyCode == UInt16(kVK_ANSI_W)
    {
      onCloseChord()
      return false
    }
    return forwardTo?.windowShouldClose?(sender) ?? true
  }

  nonisolated override func responds(to aSelector: Selector!) -> Bool {
    super.responds(to: aSelector) || (forwardTo?.responds(to: aSelector) ?? false)
  }

  nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
    super.responds(to: aSelector) ? nil : forwardTo
  }
}

/// Zero-size host that wraps the enclosing window's delegate with
/// `MainWindowCloseInterceptor`. Drop once into the main scene's content tree
/// (mirrors `SettingsWindowTag`); no visual output. `onCloseChord` should
/// dispatch `RootFeature.closeActiveTabForCurrentWorktree`.
struct MainWindowCloseRedirector: NSViewRepresentable {
  let onCloseChord: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(onCloseChord: onCloseChord) }

  func makeNSView(context: Context) -> InstallerView {
    let view = InstallerView()
    view.onResolveWindow = { [coordinator = context.coordinator] window in
      coordinator.install(on: window)
    }
    return view
  }

  func updateNSView(_ nsView: InstallerView, context: Context) {
    // Re-assert in case a scene rebuild swapped the window delegate.
    nsView.onResolveWindow?(nsView.window)
  }

  @MainActor
  final class Coordinator {
    private let onCloseChord: () -> Void
    private var interceptor: MainWindowCloseInterceptor?

    init(onCloseChord: @escaping () -> Void) { self.onCloseChord = onCloseChord }

    func install(on window: NSWindow?) {
      guard let window else { return }
      if let interceptor, window.delegate === interceptor { return }
      let proxy = MainWindowCloseInterceptor(
        forwardTo: window.delegate, onCloseChord: onCloseChord
      )
      window.delegate = proxy
      interceptor = proxy  // strong-hold; `NSWindow.delegate` is weak
    }
  }

  final class InstallerView: NSView {
    var onResolveWindow: ((NSWindow?) -> Void)?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      onResolveWindow?(window)
    }
  }
}
