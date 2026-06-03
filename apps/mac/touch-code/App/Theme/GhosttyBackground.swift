import AppKit
import SwiftUI

/// A solid fill that tracks the active Ghostty terminal `background` color —
/// the same tone `WindowAppearanceSetter` stains each `NSWindow.backgroundColor`
/// with so the translucent sidebar + toolbar chrome read as the terminal
/// palette rather than the neutral system window color.
///
/// Detail-pane placeholders (empty-project, empty-terminal, worktree-loading)
/// fill with this instead of `Color(nsColor: .windowBackgroundColor)`. Without
/// it the body paints the neutral system tone while the chrome around it shows
/// the Ghostty stain, so the first-launch / no-terminal states read as a white
/// body framed by gray chrome. `NavigationSplitView` fills the window opaquely,
/// so the window-level stain has nothing to bleed through — the body has to
/// paint the color explicitly.
///
/// Reactivity mirrors `GhosttyChromeTintModifier`: re-resolves on the
/// post-swap `.ghosttyRuntimeConfigApplied` signal (theme reload / OS dark-mode
/// flip) and on SwiftUI `colorScheme` changes, so the body and the chrome band
/// repaint together.
struct GhosttyBackground: View {
  @Environment(\.colorScheme) private var colorScheme
  @State private var nsColor: NSColor = .windowBackgroundColor

  var body: some View {
    Color(nsColor: nsColor)
      .onAppear { refresh() }
      .onChange(of: colorScheme) { _, _ in refresh() }
      .onReceive(NotificationCenter.default.publisher(for: .ghosttyRuntimeConfigApplied)) { _ in
        refresh()
      }
  }

  private func refresh() {
    nsColor = GhosttyRuntime.shared?.backgroundColor() ?? .windowBackgroundColor
  }
}
