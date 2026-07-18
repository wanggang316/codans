import AppKit
import ComposableArchitecture
import Foundation
import CodansCore
import os.log

/// Façade over `NSApp` / `NSWindow` that the window-intent router consumes.
/// Keeps AppKit out of reducers so TestStore can stub each closure
/// independently. The live surface is intentionally thin — every closure
/// maps 1:1 onto a single AppKit call (or a small cluster of them) so the
/// router never has to touch `NSApp` directly.
///
/// `openNewWindow` / `closeWindow` currently lack a clean API in the single-
/// `WindowGroup` scene used by `CodansApp`: SwiftUI's `OpenWindowAction`
/// is only reachable from a `View`'s environment, and the app has no
/// per-pane window registry yet. The live closures log at `.info` and
/// no-op; the routing surface is ready to upgrade once a multi-window
/// model lands. Hardening is deliberately deferred — wiring the type
/// contract first lets the decoder + router land without blocking on the
/// multi-window architectural decision.
nonisolated struct WindowService: Sendable {
  var openNewWindow: @MainActor @Sendable (_ inheriting: PaneID) -> Void
  var closeWindow: @MainActor @Sendable (_ from: PaneID) -> Void
  var activateWindow: @MainActor @Sendable (_ target: GotoWindowTarget) -> Void
  var toggleFullscreen: @MainActor @Sendable (_ from: PaneID) -> Void
  var toggleMaximize: @MainActor @Sendable (_ from: PaneID) -> Void
  var toggleTabOverview: @MainActor @Sendable (_ from: PaneID) -> Void
  var toggleAppVisibility: @MainActor @Sendable () -> Void
  var keyWindow: @MainActor @Sendable () -> NSWindow?
}

extension WindowService: DependencyKey {
  private static let logger = Logger(subsystem: "com.gumpw.codans.ui", category: "window")

  /// Returns only `NSApp.windows` with a non-nil `windowController` and a
  /// non-zero `windowNumber` — filters out the hidden Settings scene stub
  /// that SwiftUI keeps around once the Settings window has been shown,
  /// plus the transient panes AppKit creates for menus. Sorting by
  /// `orderedIndex` makes `previous/next/last` stable across runs.
  @MainActor
  private static func visibleAppWindows() -> [NSWindow] {
    NSApp.windows
      .filter { $0.isVisible && $0.canBecomeKey }
      .sorted { $0.orderedIndex < $1.orderedIndex }
  }

  static let liveValue = WindowService(
    openNewWindow: { paneID in
      // CodansApp today uses a single `WindowGroup` without a per-pane
      // window registry. `NSDocumentController.newDocument(_:)` would route
      // through `File → New`, but there's no document type registered.
      // Until a multi-window model lands, log and no-op.
      logger.info(
        "openNewWindow(from: \(String(describing: paneID), privacy: .public)) requested — multi-window not yet implemented"
      )
    },
    closeWindow: { paneID in
      // Without a PaneID → NSWindow registry we fall back to the key
      // window. This is the right behavior for the common case (user
      // pressed a bound key inside the focused window) even though it
      // ignores `paneID`; once the registry exists we resolve precisely.
      guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
        logger.info(
          "closeWindow(from: \(String(describing: paneID), privacy: .public)) — no key/main window"
        )
        return
      }
      window.performClose(nil)
    },
    activateWindow: { target in
      let windows = visibleAppWindows()
      guard !windows.isEmpty else { return }
      let currentIndex = windows.firstIndex(where: { $0.isKeyWindow }) ?? 0
      let picked: NSWindow?
      switch target {
      case .previous:
        picked = windows[(currentIndex - 1 + windows.count) % windows.count]
      case .next:
        picked = windows[(currentIndex + 1) % windows.count]
      case .last:
        picked = windows.last
      case .index(let idx):
        picked = windows.indices.contains(idx) ? windows[idx] : nil
      }
      picked?.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    },
    toggleFullscreen: { _ in
      NSApp.keyWindow?.toggleFullScreen(nil)
    },
    toggleMaximize: { _ in
      NSApp.keyWindow?.zoom(nil)
    },
    toggleTabOverview: { _ in
      if #available(macOS 10.12, *) {
        NSApp.keyWindow?.toggleTabOverview(nil)
      }
    },
    toggleAppVisibility: {
      if NSApp.isHidden {
        NSApp.unhide(nil)
      } else {
        NSApp.hide(nil)
      }
    },
    keyWindow: { NSApp.keyWindow }
  )

  static let testValue = WindowService(
    openNewWindow: unimplemented("WindowService.openNewWindow"),
    closeWindow: unimplemented("WindowService.closeWindow"),
    activateWindow: unimplemented("WindowService.activateWindow"),
    toggleFullscreen: unimplemented("WindowService.toggleFullscreen"),
    toggleMaximize: unimplemented("WindowService.toggleMaximize"),
    toggleTabOverview: unimplemented("WindowService.toggleTabOverview"),
    toggleAppVisibility: unimplemented("WindowService.toggleAppVisibility"),
    keyWindow: unimplemented("WindowService.keyWindow", placeholder: nil)
  )
}

extension DependencyValues {
  var windowService: WindowService {
    get { self[WindowService.self] }
    set { self[WindowService.self] = newValue }
  }
}
