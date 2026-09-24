import Foundation

/// Public recipes of a justfile → `just <recipe>`.
///
/// Recipes are column-0 `name params…:` lines. Settings, aliases, imports and
/// assignments (`x := …`) are skipped, as are private recipes (`_name` or a
/// `[private]` attribute). A comment line directly above a recipe is its doc
/// comment — `just --list` shows it too — and becomes the detail.
public nonisolated struct JustfileParser: CommandSuggestionParser {
  public let source = CommandSuggestionSource(id: "just", displayName: "justfile")

  static let manifests = ["justfile", "Justfile", ".justfile"]
  static let keywords: Set<String> = ["set", "alias", "export", "import", "mod", "unexport"]

  public init() {}

  public var request: ManifestRequest { ManifestRequest(contentPaths: Self.manifests) }

  public func suggestions(in snapshot: ManifestSnapshot) -> [CommandSuggestion] {
    guard let manifest = snapshot.firstContents(of: Self.manifests) else { return [] }

    var suggestions: [CommandSuggestion] = []
    var docComment: String?
    var isPrivate = false

    for rawLine in manifest.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
      let line = String(rawLine)
      guard let first = line.first, !first.isWhitespace else {
        // Blank or indented (recipe body) lines end any pending doc comment.
        docComment = nil
        isPrivate = false
        continue
      }
      if first == "#" {
        docComment = line.dropFirst().trimmingCharacters(in: .whitespaces)
        continue
      }
      if first == "[" {
        // Attributes stack above the recipe and keep the doc comment.
        if line.contains("private") { isPrivate = true }
        continue
      }
      defer {
        docComment = nil
        isPrivate = false
      }
      guard let name = Self.recipeName(in: line), !isPrivate else { continue }
      suggestions.append(
        CommandSuggestion(
          source: source,
          name: name,
          command: "just \(CommandSuggestionToken.render(name))",
          detail: docComment
        )
      )
    }
    return suggestions
  }

  /// `@build target='x': deps` → `build`; nil for non-recipe lines.
  static func recipeName(in line: String) -> String? {
    guard let colon = line.firstIndex(of: ":") else { return nil }
    let afterColon = line[line.index(after: colon)...]
    if afterColon.hasPrefix("=") { return nil }  // `x := value`
    let header = line[..<colon]
    var words = header.split(whereSeparator: \.isWhitespace)
    guard !words.isEmpty else { return nil }
    if keywords.contains(String(words[0])) { return nil }
    var name = String(words.removeFirst())
    if name.hasPrefix("@") { name.removeFirst() }
    guard let head = name.first, head.isLetter || head.isNumber,
      name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    else { return nil }
    return name
  }
}
