import SwiftUI
import TouchCodeCore

/// Terminal-region placeholder shown when a Worktree is selected but the
/// active Tab is nil — i.e. the user closed the last Tab, or restored a
/// snapshot whose tabs were pruned. Surfaces the `.newTab` chord inline so
/// the hint stays correct even after the user rebinds it; resolves against
/// the shortcut registry and falls back to the schema default before the
/// registry has finished loading.
struct EmptyTerminalPaneView: View {
  let message: String

  @Environment(\.resolvedShortcuts) private var resolvedShortcuts

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "apple.terminal.on.rectangle")
        .font(.title)
        .imageScale(.large)
        .accessibilityHidden(true)
        .foregroundStyle(.secondary)
      VStack(spacing: 4) {
        Text(message)
          .font(.title3)
        hint
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  @ViewBuilder
  private var hint: some View {
    if let chord = newTabChord {
      Text("Press \(Text(chord).monospaced()) or click \(Text("+").bold()) to open a new terminal.")
    } else {
      Text("Click \(Text("+").bold()) to open a new terminal.")
    }
  }

  /// Resolves the `.newTab` chord from the registry, falling back to the schema default when
  /// the env-injected map is missing the entry (rare — only before `ShortcutsStore` loads).
  /// Returns `nil` only when the user has explicitly disabled the binding.
  private var newTabChord: String? {
    if let resolved = resolvedShortcuts[.newTab], resolved.isEnabled, let binding = resolved.binding {
      return ShortcutDisplay.chord(for: binding)
    }
    if let fallback = ShortcutSchema.app.entry(for: .newTab)?.defaultBinding {
      return ShortcutDisplay.chord(for: fallback)
    }
    return nil
  }
}

#Preview {
  EmptyTerminalPaneView(message: "No terminals open")
    .frame(width: 600, height: 400)
}
