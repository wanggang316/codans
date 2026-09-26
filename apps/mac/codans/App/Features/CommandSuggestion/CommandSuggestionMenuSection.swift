import CodansCore
import SwiftUI

/// Menu section listing a Project's detected commands, one submenu per
/// manifest, for the Commands table's `+` menu: picking an item adopts the
/// command into the Project. (The worktree header's Run dropdown lists the
/// same commands through `RunMenuBuilder`, where a row runs and its trailing
/// accessory adds.) `subtitle(for:)` is shared by both.
struct CommandSuggestionMenuSection: View {
  let title: String
  let groups: [CommandSuggestionGroup]
  /// Scripts already in the Project; matching commands show checked.
  let scripts: [ScriptDefinition]
  let isScanning: Bool
  let onAdd: (CommandSuggestion) -> Void
  var onRefresh: (() -> Void)?

  /// AppKit wraps a long menu subtitle onto a second line; clipping the whole
  /// subtitle keeps every item one row tall.
  static let subtitleLimit = 44

  var body: some View {
    Section(title) {
      if groups.isEmpty {
        Text(isScanning ? "Scanning…" : "No commands found")
      }
      ForEach(groups) { group in
        Menu(group.source.displayName) {
          ForEach(group.suggestions) { suggestion in
            item(suggestion)
          }
        }
      }
      if let onRefresh {
        Button("Refresh", action: onRefresh)
      }
    }
  }

  /// Already-adopted commands stay listed but disabled with a checkmark, so
  /// the menu still mirrors the manifest and never offers a duplicate.
  private func item(_ suggestion: CommandSuggestion) -> some View {
    let isAdopted = CommandSuggestionAdoption.isAdopted(suggestion, in: scripts)
    return Button {
      onAdd(suggestion)
    } label: {
      // Icon + title + a second Text: the shape AppKit-backed menus render as
      // a subtitle. Wrapping the texts in a `Label` drops the subtitle.
      if isAdopted {
        Image(systemName: "checkmark")
      } else {
        ScriptTintColorPalette.menuIcon(suggestion.resolvedIcon, tint: suggestion.kind.defaultTintColor)
      }
      Text(suggestion.name)
      Text(Self.subtitle(for: suggestion))
    }
    .help(Self.subtitle(for: suggestion))
    .disabled(isAdopted)
  }

  /// The runnable command, plus what it expands to when the manifest says.
  static func subtitle(for suggestion: CommandSuggestion) -> String {
    var subtitle = suggestion.command
    if let detail = suggestion.detail, detail != suggestion.command {
      subtitle += " — " + detail.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
    return subtitle.count > subtitleLimit ? String(subtitle.prefix(subtitleLimit)) + "…" : subtitle
  }
}
