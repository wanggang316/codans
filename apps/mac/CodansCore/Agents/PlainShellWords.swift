import Foundation

/// Reads a profile's extra arguments, a raw shell fragment that the launch
/// command appends as it is. The shell, not codans, turns the fragment into
/// arguments, and every shell construct (quotes, escapes, expansions,
/// operators, a word that starts with `=` or `~`) can change what reaches
/// the agent. codans does not read shell syntax: it reads a fragment only
/// when the whole of it is plain words (ADR 0010).
nonisolated enum PlainShellWords {
  /// The words of `fragment`, or `nil` when any part of it is not a plain
  /// word. A blank fragment has no words.
  static func split(_ fragment: String) -> [String]? {
    let words = fragment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    guard fragment.allSatisfy(isPlainCharacter), words.allSatisfy(isPlainWord) else { return nil }
    return words
  }

  /// A character the shell keeps as it is inside a word, or a blank between
  /// words. `=` and `~` are plain only inside a word (`isPlainWord`).
  private static func isPlainCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == " " || character == "\t"
      || "/._-+,@:%=~".contains(character)
  }

  /// A word the shell passes as it is: zsh expands a leading `=` to a
  /// command path, and a leading `~` is a home directory. The one leading
  /// `~` codans reads is `~/`, expanded by the caller.
  private static func isPlainWord(_ word: String) -> Bool {
    if word.hasPrefix("=") { return false }
    if word.hasPrefix("~") { return word.hasPrefix("~/") }
    return true
  }
}
