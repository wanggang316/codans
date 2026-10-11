import CodansCore
import SwiftUI

/// Toolbar button that opens the New Agent dialog. Sits at the head of the
/// header's center group, left of the status capsule: starting an agent is
/// the most frequent action in this app, so it gets the most central spot.
///
/// Plain icon button, no menu half — the dialog is where the project, the
/// worktree, and the agent are chosen. The glyph takes a multicolor gradient
/// so the entry point reads apart from the neutral toolbar glyphs.
struct HeaderNewAgentButton: View {
  let action: () -> Void
  @Environment(\.resolvedShortcuts) private var resolvedShortcuts

  /// Warm top-left to cool bottom-right, sampled once — a static fill, not
  /// an animation, so it never animates late toolbar layout.
  private static let gradient = LinearGradient(
    colors: [.orange, .pink, .purple, .blue],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
  )

  var body: some View {
    Button(action: action) {
      Image(systemName: "plus.bubble")
        .foregroundStyle(Self.gradient)
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
    .help(help)
    .accessibilityLabel("New Agent")
  }

  /// Live chord for the `.newAgent` registry entry, so the tooltip follows a
  /// rebind or a disable.
  private var help: String {
    guard let resolved = resolvedShortcuts[.newAgent], resolved.isEnabled,
      let binding = resolved.binding
    else { return "New Agent" }
    return "New Agent (\(ShortcutDisplay.chord(for: binding)))"
  }
}
