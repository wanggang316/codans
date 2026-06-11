import AppKit

/// `NSPanel` subclass for the Master Terminal. Override defaults so the
/// panel can become key (and therefore receive keystrokes / give focus to
/// the embedded Ghostty surface in M3) without becoming the application's
/// "main" window — main status would push it into the standard window
/// list and Cmd-Tab order, which is not what we want for a quick-summon
/// surface.
final class MasterTerminalWindow: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}
