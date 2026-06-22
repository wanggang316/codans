import AppKit
import SwiftUI

/// Hosts a zero-size `NSView` whose `viewDidMoveToWindow` opts the enclosing
/// window out of the macOS **Window** menu's auto-populated window list. AppKit
/// adds every titled `NSWindow` to that list itself (`addWindowsItem`); SwiftUI's
/// `CommandGroup(replacing: .windowList)` only governs the window *commands*
/// group and does not suppress those AppKit-owned title entries. Setting
/// `isExcludedFromWindowsMenu` (and dropping any entry already added) removes
/// them. Place once inside each scene's content tree — no visual output.
struct ExcludeFromWindowsMenu: NSViewRepresentable {
  func makeNSView(context: Context) -> ExcludingView { ExcludingView() }
  func updateNSView(_ nsView: ExcludingView, context: Context) {}

  final class ExcludingView: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else { return }
      // Prevent future re-adds, then strip the entry AppKit may have already
      // inserted for this window.
      window.isExcludedFromWindowsMenu = true
      NSApp.removeWindowsItem(window)
    }
  }
}
