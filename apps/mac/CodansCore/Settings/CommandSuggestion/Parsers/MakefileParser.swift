import Foundation

/// Explicit targets of the top-level Makefile → `make <target>`.
///
/// A line-level scan, not a make evaluator: it keeps rules whose target names
/// are literal words at column 0 and drops everything make treats as
/// machinery — special targets (`.PHONY`), pattern rules (`%.o`), variable
/// assignments (`CC := clang`) and recipe lines. Targets declared `.PHONY` are
/// the ones people invoke by name, so they lead; file targets follow. A
/// trailing `## text` on the rule line (the common self-documenting-Makefile
/// idiom) becomes the detail.
public nonisolated struct MakefileParser: CommandSuggestionParser {
  public let source = CommandSuggestionSource(id: "make", displayName: "Makefile")

  static let manifests = ["GNUmakefile", "makefile", "Makefile"]

  public init() {}

  public var request: ManifestRequest { ManifestRequest(contentPaths: Self.manifests) }

  public func suggestions(in snapshot: ManifestSnapshot) -> [CommandSuggestion] {
    // Same lookup order as GNU make itself.
    guard let manifest = snapshot.firstContents(of: Self.manifests) else { return [] }

    var phony = Set<String>()
    var targets: [(name: String, help: String?)] = []
    var seen = Set<String>()

    for rawLine in manifest.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
      let line = String(rawLine)
      // Recipe lines, comments and continuation bodies never start a rule.
      guard let first = line.first, first != "\t", first != " ", first != "#" else { continue }
      guard let rule = Self.parseRule(line) else { continue }
      if rule.targets == [".PHONY"] {
        phony.formUnion(rule.prerequisites)
        continue
      }
      for name in rule.targets where Self.isInvocable(name) && seen.insert(name).inserted {
        targets.append((name, rule.help))
      }
    }

    let ordered = targets.filter { phony.contains($0.name) } + targets.filter { !phony.contains($0.name) }
    return ordered.map { target in
      CommandSuggestion(
        source: source,
        name: target.name,
        command: "make \(CommandSuggestionToken.render(target.name))",
        detail: target.help
      )
    }
  }

  struct Rule: Equatable {
    var targets: [String]
    var prerequisites: [String]
    var help: String?
  }

  /// `a b: deps ## help` → targets/prerequisites/help. Returns nil for
  /// assignments (`=`, `:=`, `::=`, `?=`, `+=`, `!=`) and non-rule lines.
  static func parseRule(_ line: String) -> Rule? {
    var body = Substring(line)
    var help: String?
    if let marker = body.range(of: "##") {
      help = body[marker.upperBound...].trimmingCharacters(in: .whitespaces)
      body = body[..<marker.lowerBound]
    }
    guard let colon = body.firstIndex(of: ":") else { return nil }
    let head = body[..<colon]
    let tail = body[body.index(after: colon)...]
    // `CC := x`, `X ::= y`, `A = b: c` are assignments, not rules.
    if head.contains("=") || tail.hasPrefix("=") || tail.hasPrefix(":=") { return nil }
    let targets = head.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !targets.isEmpty else { return nil }
    // Double-colon rules (`a:: b`) and target-specific variables (`a: X = 1`)
    // still name `a`; only the prerequisite list is unreliable for them.
    let prereqText = tail.drop(while: { $0 == ":" })
    let prerequisites =
      prereqText.contains("=")
      ? [] : prereqText.split(whereSeparator: { $0.isWhitespace || $0 == ";" }).map(String.init)
    return Rule(targets: targets, prerequisites: prerequisites, help: help)
  }

  /// Literal, user-facing target names only.
  static func isInvocable(_ name: String) -> Bool {
    guard let first = name.first, first != ".", first != "_" else { return false }
    return !name.contains(where: { "%$()/\\*?".contains($0) })
  }
}
