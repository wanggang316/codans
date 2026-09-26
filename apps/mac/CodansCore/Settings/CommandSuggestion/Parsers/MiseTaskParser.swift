import Foundation

/// mise TOML tasks → `mise run <name>`.
///
/// Both TOML spellings are recognised: a `[tasks.<name>]` table per task, and
/// inline `<name> = …` entries under a `[tasks]` table. The detail is the
/// task's `description`, falling back to a one-line `run`. File tasks
/// (`.mise/tasks/*`) are out of reach of a manifest read and not listed.
public nonisolated struct MiseTaskParser: CommandSuggestionParser {
  public let source = CommandSuggestionSource(id: "mise", displayName: "mise.toml")

  static let manifests = ["mise.toml", ".mise.toml"]

  public init() {}

  public var request: ManifestRequest { ManifestRequest(contentPaths: Self.manifests) }

  public func suggestions(in snapshot: ManifestSnapshot) -> [CommandSuggestion] {
    guard let manifest = snapshot.firstContents(of: Self.manifests) else { return [] }

    var names: [String] = []
    var details: [String: String] = [:]
    var descriptions: [String: String] = [:]
    enum Section {
      case other
      case taskList
      case task(String)
    }
    var section = Section.other

    func record(_ name: String) {
      if !names.contains(name) { names.append(name) }
    }

    for rawLine in manifest.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }

      if line.hasPrefix("[") {
        let header = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        if header == "tasks" {
          section = .taskList
        } else if header.hasPrefix("tasks."), let name = Self.key(String(header.dropFirst("tasks.".count))) {
          section = .task(name)
          record(name)
        } else {
          section = .other
        }
        continue
      }

      guard let equals = line.firstIndex(of: "="), let key = Self.key(String(line[..<equals])) else { continue }
      let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
      switch section {
      case .taskList:
        record(key)
        if let text = Self.basicString(value) {
          details[key] = text
        } else if let text = Self.inlineField("description", in: value) ?? Self.inlineField("run", in: value) {
          details[key] = text
        }
      case .task(let name):
        if key == "description", let text = Self.basicString(value) {
          descriptions[name] = text
        } else if key == "run", details[name] == nil, let text = Self.basicString(value) {
          details[name] = text
        }
      case .other:
        break
      }
    }

    return names.map { name in
      CommandSuggestion(
        source: source,
        name: name,
        command: "mise run \(CommandSuggestionToken.render(name))",
        detail: descriptions[name] ?? details[name]
      )
    }
  }

  /// Bare or quoted TOML key; dotted sub-keys (`build.env`) are not task names.
  static func key(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if let quoted = basicString(trimmed) { return quoted }
    guard !trimmed.isEmpty, !trimmed.contains("."), !trimmed.contains(" ") else { return nil }
    return trimmed
  }

  /// `"text"` / `'text'` → text; nil for arrays, tables and multi-line strings.
  static func basicString(_ value: String) -> String? {
    guard value.count >= 2, let first = value.first, first == "\"" || first == "'",
      !value.hasPrefix(String(repeating: first, count: 3)),
      let close = value.dropFirst().firstIndex(of: first)
    else { return nil }
    return String(value[value.index(after: value.startIndex)..<close])
  }

  /// `{ run = "x", description = "y" }` → the named field's string value.
  static func inlineField(_ field: String, in value: String) -> String? {
    guard value.hasPrefix("{"), let range = value.range(of: "\(field) =") ?? value.range(of: "\(field)=") else {
      return nil
    }
    return basicString(value[range.upperBound...].trimmingCharacters(in: .whitespaces))
  }
}
