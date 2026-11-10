import AppKit
import Testing

@testable import Codans

@MainActor
struct TerminalBackgroundWindowTests {
  @Test func titledWindowTakesTheTerminalBackground() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: true
    )
    #expect(window.takesTerminalBackground)
  }

  /// The shape of the panel that the system text-input machinery adds to the
  /// app for the input-source indicator beside the caret.
  @Test func borderlessPanelKeepsItsOwnBackground() {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: true
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    #expect(!panel.takesTerminalBackground)
  }
}
