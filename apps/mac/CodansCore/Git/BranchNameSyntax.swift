import Foundation

/// The parts of `git check-ref-format --branch` a form can apply while the
/// user types, without a subprocess per keystroke. Deliberately a subset: a
/// name that passes here still goes through git before anything is created,
/// so a false negative costs a round trip and a false positive is impossible.
public nonisolated enum BranchNameSyntax {
  public enum Problem: Equatable, Sendable {
    case empty
    case whitespace
    case controlCharacter
    /// `..`, `@{`, `~`, `^`, `:`, `?`, `*`, `[`, `\`.
    case forbiddenSequence(String)
    /// Leading `-`, leading or trailing `/` or `.`, a component starting
    /// with `.`, or a trailing `.lock`.
    case badEdge(String)
  }

  /// Nil when nothing obviously wrong is found.
  public static func quickCheck(_ name: String) -> Problem? {
    if name.isEmpty { return .empty }
    if name.contains(where: \.isWhitespace) { return .whitespace }
    if name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
      return .controlCharacter
    }
    for sequence in ["..", "@{", "~", "^", ":", "?", "*", "[", "\\"] where name.contains(sequence) {
      return .forbiddenSequence(sequence)
    }
    if name.hasPrefix("-") { return .badEdge("-") }
    if name.hasPrefix("/") || name.hasSuffix("/") { return .badEdge("/") }
    if name.hasPrefix(".") || name.hasSuffix(".") { return .badEdge(".") }
    if name.hasSuffix(".lock") { return .badEdge(".lock") }
    if name.contains("//") { return .badEdge("//") }
    if name.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
      $0.hasPrefix(".") || $0.hasSuffix(".lock")
    }) {
      return .badEdge(".")
    }
    if name == "@" { return .forbiddenSequence("@") }
    return nil
  }

  public static func isPlausible(_ name: String) -> Bool {
    quickCheck(name) == nil
  }
}
