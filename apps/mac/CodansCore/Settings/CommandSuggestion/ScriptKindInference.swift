import Foundation

/// Maps a manifest entry name to the `ScriptKind` whose icon and tint fit it.
/// Only the kind's visual identity rides on this — a wrong guess costs a
/// different icon, never a different behaviour.
public nonisolated enum ScriptKindInference {
  /// Matches the entry's leading segment, so `test:unit`, `lint-fix` and
  /// `build.release` classify by `test` / `lint` / `build`.
  public static func kind(forEntryName name: String) -> ScriptKind {
    let lowered = name.lowercased()
    let head =
      lowered
      .split(whereSeparator: { ":-_./ ".contains($0) })
      .first
      .map(String.init) ?? lowered
    switch head {
    case "dev", "start", "serve", "run", "watch", "preview":
      return .run
    case "test", "tests", "e2e", "spec", "check":
      return .test
    case "lint", "clippy", "vet", "typecheck", "tsc":
      return .lint
    case "format", "fmt", "prettier":
      return .format
    case "deploy", "release", "publish", "ship":
      return .deploy
    default:
      return .custom
    }
  }
}

/// Shell-safe rendering of an entry name appended to a runner command.
nonisolated enum CommandSuggestionToken {
  /// Bare when every character is shell-inert (the overwhelmingly common
  /// `build`, `test:unit`, `@scope/x`), POSIX-quoted otherwise.
  static func render(_ name: String) -> String {
    let safe = CharacterSet(charactersIn:
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:/@+=,%")
    let isSafe = !name.isEmpty && name.unicodeScalars.allSatisfy(safe.contains)
    return isSafe ? name : ShellQuoting.quoted(name)
  }
}
