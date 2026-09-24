import Foundation

/// go-task `Taskfile.yml` → `task <name>`.
///
/// Reads only the keys one indentation level under the top-level `tasks:`
/// mapping — enough YAML to list tasks without a YAML dependency. Each task's
/// `desc:` (a plain one-line scalar) becomes the detail; tasks marked
/// `internal: true` are hidden, as `task --list` does.
public nonisolated struct TaskfileParser: CommandSuggestionParser {
  public let source = CommandSuggestionSource(id: "task", displayName: "Taskfile")

  static let manifests = ["Taskfile.yml", "Taskfile.yaml", "taskfile.yml", "taskfile.yaml"]

  public init() {}

  public var request: ManifestRequest { ManifestRequest(contentPaths: Self.manifests) }

  public func suggestions(in snapshot: ManifestSnapshot) -> [CommandSuggestion] {
    guard let manifest = snapshot.firstContents(of: Self.manifests) else { return [] }

    struct Entry {
      var name: String
      var desc: String?
      var isInternal = false
    }
    var entries: [Entry] = []
    var inTasks = false
    var taskIndent: Int?

    for rawLine in manifest.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
      let line = String(rawLine)
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
      let indent = line.prefix(while: { $0 == " " }).count

      if indent == 0 {
        inTasks = trimmed == "tasks:"
        taskIndent = nil
        continue
      }
      guard inTasks, let (key, value) = Self.mappingEntry(trimmed) else { continue }

      if taskIndent == nil { taskIndent = indent }
      if indent == taskIndent {
        entries.append(Entry(name: key))
      } else if indent > (taskIndent ?? 0), !entries.isEmpty {
        switch key {
        case "desc" where entries[entries.count - 1].desc == nil:
          entries[entries.count - 1].desc = Self.unquoted(value)
        case "internal":
          entries[entries.count - 1].isInternal = value == "true"
        default:
          break
        }
      }
    }

    return entries.filter { !$0.isInternal }.map { entry in
      CommandSuggestion(
        source: source,
        name: entry.name,
        command: "task \(CommandSuggestionToken.render(entry.name))",
        detail: entry.desc
      )
    }
  }

  /// `key: value` / `'lint:fix':` → (key, value). A quoted key may itself hold
  /// colons, so its separator is searched after the closing quote. List items
  /// are not mapping keys.
  static func mappingEntry(_ trimmed: String) -> (String, String)? {
    guard let first = trimmed.first, first != "-" else { return nil }
    var searchStart = trimmed.startIndex
    if first == "\"" || first == "'" {
      guard let close = trimmed.dropFirst().firstIndex(of: first) else { return nil }
      searchStart = trimmed.index(after: close)
    }
    guard let colon = trimmed[searchStart...].firstIndex(of: ":") else { return nil }
    let key = unquoted(String(trimmed[..<colon]))
    guard !key.isEmpty, !key.contains(" ") else { return nil }
    let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    return (key, value)
  }

  static func unquoted(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard trimmed.count >= 2, let first = trimmed.first, first == trimmed.last, first == "\"" || first == "'"
    else { return trimmed }
    return String(trimmed.dropFirst().dropLast())
  }
}
