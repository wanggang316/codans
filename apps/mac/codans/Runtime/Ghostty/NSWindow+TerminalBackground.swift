import AppKit

extension NSWindow {
  /// Whether the terminal theme background applies to this window.
  ///
  /// `NSApp.windows` also holds windows that AppKit and system services add to
  /// the process: menus, tooltips, and the transparent panel that shows the
  /// input-source indicator beside the caret. Those windows draw their own
  /// content on a clear background; an opaque background color turns the
  /// indicator panel into a solid box over the terminal. None of them can
  /// become key, and every window the app shows as chrome can.
  var takesTerminalBackground: Bool { canBecomeKey }
}
