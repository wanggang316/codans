import SwiftUI

/// The leading glyph of a pane card header, which shows the Pane number in its place while the
/// user holds exactly ⌘⌥ in the main window (`CommandKeyObserver.isCommandOptionHeld`). `⌘⌥N`
/// focuses Pane N, so the header shows which chord reaches which Pane, in the slot the eye
/// already reads first. The caller passes `nil` for a Pane with no number (after the ninth)
/// and for a one-Pane Tab; the glyph then stays.
///
/// Reads both observers itself, like the ⌘ hints (`ShortcutHintLabel`), so only this view
/// re-renders when a modifier changes. The main-window check keeps the numbers off while
/// ⌘⌥ is held in Settings or the Diff window, whose key events the same app monitor sees.
struct PaneNumberHint<Glyph: View>: View {
  let number: Int?
  /// The number takes the title's emphasis: primary on the focused pane, secondary elsewhere.
  let isFocused: Bool
  @ViewBuilder let glyph: () -> Glyph

  @Environment(CommandKeyObserver.self) private var commandKeyObserver: CommandKeyObserver?
  @Environment(MainWindowKeyObserver.self) private var mainWindowKey: MainWindowKeyObserver?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let isShown =
      number != nil && commandKeyObserver?.isCommandOptionHeld == true
      && mainWindowKey?.isMainWindowKey == true
    ZStack {
      if isShown, let number {
        Text(verbatim: "\(number)")
          .font(.system(size: PaneCardMetrics.headerTitleFontSize, weight: .medium))
          .monospacedDigit()
          .foregroundStyle(isFocused ? .primary : .secondary)
          .transition(.opacity)
          .accessibilityLabel("Pane \(number)")
      } else {
        glyph()
          .transition(.opacity)
      }
    }
    .animation(reduceMotion ? nil : .shortcutHint, value: isShown)
  }
}
