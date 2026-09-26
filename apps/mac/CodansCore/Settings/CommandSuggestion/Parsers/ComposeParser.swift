import Foundation

/// Docker Compose file → the stack verbs plus one `up` per service.
///
/// Only the file names `docker compose` picks up by itself are read, so every
/// command runs without `-f`. Services are the keys one level under the
/// top-level `services:` mapping — the same indentation-based YAML reading
/// the Taskfile parser uses.
public nonisolated struct ComposeParser: CommandSuggestionParser {
  public let source = CommandSuggestionSource(id: "compose", displayName: "compose.yaml")

  /// Compose's own lookup order.
  static let manifests = ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"]

  public init() {}

  public var request: ManifestRequest { ManifestRequest(contentPaths: Self.manifests) }

  public func suggestions(in snapshot: ManifestSnapshot) -> [CommandSuggestion] {
    guard let manifest = snapshot.firstContents(of: Self.manifests) else { return [] }
    let services = Self.services(in: manifest.text)
    let docker = CommandIconRef.mark(.docker)
    var suggestions = [
      CommandSuggestion(source: source, name: "up", command: "docker compose up -d", detail: "Start all services in the background"),
      CommandSuggestion(source: source, name: "down", command: "docker compose down", detail: "Stop and remove the stack's containers"),
      CommandSuggestion(
        source: source, name: "logs", command: "docker compose logs -f --tail=100", detail: "Follow the stack's logs"),
      CommandSuggestion(source: source, name: "ps", command: "docker compose ps", detail: "Containers of this stack", icon: docker),
    ]
    for service in services {
      suggestions.append(
        CommandSuggestion(
          source: source, name: service, command: "docker compose up \(CommandSuggestionToken.render(service))",
          detail: "Run the \(service) service in the foreground", kind: .run, icon: docker))
    }
    return suggestions
  }

  static func services(in text: String) -> [String] {
    var inServices = false
    var serviceIndent: Int?
    var names: [String] = []
    for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
      let line = String(rawLine)
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
      let indent = line.prefix(while: { $0 == " " }).count
      if indent == 0 {
        inServices = trimmed == "services:"
        serviceIndent = nil
        continue
      }
      guard inServices, let (key, _) = TaskfileParser.mappingEntry(trimmed) else { continue }
      if serviceIndent == nil { serviceIndent = indent }
      if indent == serviceIndent { names.append(key) }
    }
    return names
  }
}
