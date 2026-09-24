import Foundation

/// Turns a suggestion into a Project script while holding the Commands table's
/// invariants: at most one script per predefined kind, and the built-in Run
/// (virtual until first edited) is filled in rather than duplicated.
public nonisolated enum CommandSuggestionAdoption {
  public struct Result: Equatable, Sendable {
    public var scripts: [ScriptDefinition]
    /// Script that now carries the suggestion — the row to select.
    public var scriptID: UUID
  }

  /// `true` when some script already runs exactly this command, so the menu
  /// can show it as added instead of offering a duplicate.
  public static func isAdopted(_ suggestion: CommandSuggestion, in scripts: [ScriptDefinition]) -> Bool {
    let command = normalized(suggestion.command)
    return scripts.contains { normalized($0.command) == command }
  }

  public static func adopt(_ suggestion: CommandSuggestion, into scripts: [ScriptDefinition]) -> Result {
    if suggestion.kind == .run {
      if let index = scripts.firstIndex(where: { $0.kind == .run }) {
        // An existing Run with no command is still a blank default — fill it.
        if normalized(scripts[index].command).isEmpty {
          var updated = scripts
          updated[index].command = suggestion.command
          updated[index].name = suggestion.name
          return Result(scripts: updated, scriptID: updated[index].id)
        }
      } else {
        // Run is still the virtual built-in: materialize it at the front,
        // where the table was already showing it, keeping its ⌘R default.
        var run = ScriptDefinition.builtinRun
        run.command = suggestion.command
        run.name = suggestion.name
        return Result(scripts: [run] + scripts, scriptID: run.id)
      }
    }

    let kindTaken = suggestion.kind != .custom && scripts.contains { $0.kind == suggestion.kind }
    let script = ScriptDefinition(
      kind: kindTaken ? .custom : suggestion.kind,
      name: suggestion.name,
      command: suggestion.command
    )
    return Result(scripts: scripts + [script], scriptID: script.id)
  }

  private static func normalized(_ command: String) -> String {
    command.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
