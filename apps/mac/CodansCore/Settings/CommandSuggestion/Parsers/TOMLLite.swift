import Foundation

/// Just enough TOML for manifests' command tables: table headers, flat
/// `key = value` lines, single-line strings and inline-table fields. Not a
/// TOML parser — arrays of tables, multi-line strings and dotted keys are
/// skipped, which for command tables only ever means a missed entry.
nonisolated enum TOMLLite {
  /// Table headers in file order (`[tool.poetry.scripts]` → `tool.poetry.scripts`).
  static func tables(in text: String) -> [String] {
    lines(text).compactMap(header)
  }

  /// `key = value` lines directly under `[table]`, in file order; keys
  /// unquoted, values raw (trimmed).
  static func entries(in text: String, table: String) -> [(key: String, value: String)] {
    var current: String?
    var result: [(key: String, value: String)] = []
    for line in lines(text) {
      if let name = header(line) {
        current = name
        continue
      }
      guard current == table, let equals = line.firstIndex(of: "=") else { continue }
      guard let key = key(String(line[..<equals])) else { continue }
      result.append((key, line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)))
    }
    return result
  }

  /// `"text"` / `'text'` → text; nil for arrays, tables and multi-line strings.
  static func string(_ value: String) -> String? {
    guard value.count >= 2, let first = value.first, first == "\"" || first == "'",
      !value.hasPrefix(String(repeating: first, count: 3)),
      let close = value.dropFirst().firstIndex(of: first)
    else { return nil }
    return String(value[value.index(after: value.startIndex)..<close])
  }

  /// `{ cmd = "x", help = "y" }` → the named field's string value.
  static func inlineField(_ field: String, in value: String) -> String? {
    guard value.hasPrefix("{") else { return nil }
    for part in value.dropFirst().dropLast().split(separator: ",") {
      guard let equals = part.firstIndex(of: "=") else { continue }
      if key(String(part[..<equals])) == field {
        return string(part[part.index(after: equals)...].trimmingCharacters(in: .whitespaces))
      }
    }
    return nil
  }

  // MARK: - Lexing

  private static func lines(_ text: String) -> [String] {
    text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.hasPrefix("#") }
  }

  private static func header(_ line: String) -> String? {
    guard line.hasPrefix("["), !line.hasPrefix("[["), let close = line.firstIndex(of: "]") else { return nil }
    return line[line.index(after: line.startIndex)..<close]
      .split(separator: ".").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ".")
  }

  /// Bare or quoted key; dotted keys (`a.b = 1`) are not command names.
  private static func key(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if let quoted = string(trimmed) { return quoted }
    guard !trimmed.isEmpty, !trimmed.contains("."), !trimmed.contains(" ") else { return nil }
    return trimmed
  }
}
