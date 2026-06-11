import Foundation

/// Display-only description of a key chord, rendered as a trailing label on
/// a palette row. Not a `SwiftUI.KeyEquivalent` — the row only paints these
/// characters as a hint; the actual binding, if any, is owned by the menu
/// command or ghostty keybind that sources the action.
struct KeyEquivalentDescriptor: Equatable {
  let keys: [String]

  init(_ keys: [String]) { self.keys = keys }

  /// Convenience factory for a single-modifier + letter chord, e.g.
  /// `.command("G", shift: true)` → `["⌘", "⇧", "G"]`.
  static func command(_ letter: String, shift: Bool = false, option: Bool = false) -> Self {
    var parts: [String] = ["⌘"]
    if shift { parts.append("⇧") }
    if option { parts.append("⌥") }
    parts.append(letter.uppercased())
    return .init(parts)
  }
}
