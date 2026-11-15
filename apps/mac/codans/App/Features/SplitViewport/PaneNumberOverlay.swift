import SwiftUI

/// The Pane number of one Pane, drawn over its center while the user holds exactly ⌘⌥ in the
/// main window (`CommandKeyObserver.isCommandOptionHeld`). `⌘⌥N` focuses Pane N, so the
/// overlay shows which chord reaches which Pane. The caller passes `nil` for a Pane with no
/// number (after the ninth) and for a one-Pane Tab.
///
/// Reads both observers itself, like the ⌘ hints (`ShortcutHintLabel`), so only this view
/// re-renders when a modifier changes. The main-window check keeps the numbers off while
/// ⌘⌥ is held in Settings or the Diff window, whose key events the same app monitor sees.
struct PaneNumberOverlay: View {
  let number: Int?
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
          .font(.system(size: 44, weight: .semibold, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.primary)
          .frame(minWidth: 76, minHeight: 76)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
              .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
          }
          .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
          .transition(.opacity)
          .accessibilityLabel("Pane \(number)")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .allowsHitTesting(false)
    .animation(reduceMotion ? nil : .shortcutHint, value: isShown)
  }
}
