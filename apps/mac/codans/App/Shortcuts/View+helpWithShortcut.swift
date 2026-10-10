import SwiftUI
import CodansCore

extension View {
  /// Tooltip that appends the resolved chord for `id` after `description`,
  /// rendered in macOS-conventional glyph form. When the command has no
  /// resolved binding (or the user disabled it), falls back to plain
  /// `.help(description)`. Reads `\.resolvedShortcuts` from the
  /// environment, already injected at the main scene root.
  ///
  /// Example: `helpWithShortcut("Add Project", .addProject)` →
  /// `Add Project (⌘⇧O)`.
  func helpWithShortcut(_ description: String, _ id: CommandID) -> some View {
    modifier(HelpWithShortcutModifier(description: description, id: id))
  }
}

private struct HelpWithShortcutModifier: ViewModifier {
  let description: String
  let id: CommandID
  @Environment(\.resolvedShortcuts) private var shortcuts

  func body(content: Content) -> some View {
    content.help(tooltip)
  }

  private var tooltip: String {
    guard let resolved = shortcuts[id], resolved.isEnabled,
      let binding = resolved.binding
    else { return description }
    return "\(description) (\(ShortcutDisplay.chord(for: binding)))"
  }
}
