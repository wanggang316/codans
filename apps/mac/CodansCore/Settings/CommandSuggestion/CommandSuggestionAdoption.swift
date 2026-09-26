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
    adoptedScript(for: suggestion, in: scripts) != nil
  }

  public static func adopt(_ suggestion: CommandSuggestion, into scripts: [ScriptDefinition]) -> Result {
    if suggestion.kind == .run {
      if let index = scripts.firstIndex(where: { $0.kind == .run }) {
        // An existing Run with no command is still a blank default — fill it.
        if normalized(scripts[index].command).isEmpty {
          var updated = scripts
          updated[index].command = suggestion.command
          updated[index].name = suggestion.name
          // Keep an icon the user already chose for the blank Run.
          if let icon = iconOverride(for: suggestion, kind: .run) {
            updated[index].systemImage = icon
          }
          return Result(scripts: updated, scriptID: updated[index].id)
        }
      } else {
        // Run is still the virtual built-in: materialize it at the front,
        // where the table was already showing it, keeping its ⌘R default.
        var run = ScriptDefinition.builtinRun
        run.command = suggestion.command
        run.name = suggestion.name
        run.systemImage = iconOverride(for: suggestion, kind: .run)
        return Result(scripts: [run] + scripts, scriptID: run.id)
      }
    }

    let kindTaken = suggestion.kind != .custom && scripts.contains { $0.kind == suggestion.kind }
    let kind = kindTaken ? .custom : suggestion.kind
    let script = ScriptDefinition(
      kind: kind,
      name: suggestion.name,
      command: suggestion.command,
      systemImage: iconOverride(for: suggestion, kind: kind)
    )
    return Result(scripts: scripts + [script], scriptID: script.id)
  }

  /// Global commands have no kind taxonomy (no built-in Run, no one-per-kind
  /// rule): a suggestion is appended as a Custom command that keeps its icon.
  public static func adoptGlobal(_ suggestion: CommandSuggestion, into scripts: [ScriptDefinition]) -> Result {
    let script = ScriptDefinition(
      kind: .custom,
      name: suggestion.name,
      command: suggestion.command,
      systemImage: suggestion.icon.flatMap { $0 == .symbol(ScriptKind.custom.defaultSystemImage) ? nil : $0.storedValue }
    )
    return Result(scripts: scripts + [script], scriptID: script.id)
  }

  /// The saved script that already runs this suggestion's command, if any.
  public static func adoptedScript(for suggestion: CommandSuggestion, in scripts: [ScriptDefinition])
    -> ScriptDefinition?
  {
    let command = normalized(suggestion.command)
    return scripts.first { normalized($0.command) == command }
  }

  /// An unsaved script for running a suggestion directly. Its id is derived
  /// from the suggestion's id, so running the same entry again reuses the
  /// pane the previous run opened, exactly like a saved script does.
  public static func transientScript(for suggestion: CommandSuggestion) -> ScriptDefinition {
    ScriptDefinition(
      id: stableID(for: "command-suggestion:" + suggestion.id),
      kind: suggestion.kind,
      name: suggestion.name,
      command: suggestion.command,
      systemImage: suggestion.icon?.storedValue
    )
  }

  /// FNV-1a over the key with two seeds → 128 bits, stamped as a v5-style
  /// UUID. Deterministic across launches; collisions need two suggestion ids
  /// hashing alike, which only costs a shared run pane.
  static func stableID(for key: String) -> UUID {
    func fnv(_ seed: UInt64) -> UInt64 {
      var hash = seed
      for byte in key.utf8 {
        hash ^= UInt64(byte)
        hash &*= 0x100_0000_01b3
      }
      return hash
    }
    var bytes = [UInt8](repeating: 0, count: 16)
    withUnsafeBytes(of: fnv(0xcbf2_9ce4_8422_2325).bigEndian) { bytes.replaceSubrange(0..<8, with: $0) }
    withUnsafeBytes(of: fnv(0x84_2222_325c_bf29).bigEndian) { bytes.replaceSubrange(8..<16, with: $0) }
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }

  /// The mapped icon as a stored override — nil when there is none or it is
  /// what the script's kind shows anyway, keeping `settings.json` minimal.
  private static func iconOverride(for suggestion: CommandSuggestion, kind: ScriptKind) -> String? {
    guard let icon = suggestion.icon, icon != .symbol(kind.defaultSystemImage) else { return nil }
    return icon.storedValue
  }

  private static func normalized(_ command: String) -> String {
    command.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
