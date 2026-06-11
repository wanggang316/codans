import Foundation

extension IPC {
  /// Named key for `terminal.sendKey`. Lets the CLI send special keys
  /// (Esc, arrows, function keys, common Ctrl combos) that `terminal.sendInput`
  /// cannot deliver because libghostty's text-input path drops control bytes.
  ///
  /// The set covers the keys called out in HAN-46. Each value maps on the
  /// app side to a `ghostty_input_key_s` event with the corresponding Mac
  /// virtual keycode + modifiers, so terminal applications observe the
  /// same byte sequences a physical keypress would emit (CSI for arrows,
  /// 0x1B for escape, 0x09 for tab, etc.).
  public enum TerminalNamedKey: String, Codable, Sendable, CaseIterable {
    case escape
    case up
    case down
    case left
    case right
    case tab
    case enter
    case backspace
    case delete
    case home
    case end
    case pgup
    case pgdn
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    case ctrlC = "ctrl_c"
    case ctrlD = "ctrl_d"
    case ctrlL = "ctrl_l"
    case ctrlZ = "ctrl_z"
  }
}
