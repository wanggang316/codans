import Foundation
import Yams

/// One Agent Skill the completion list offers.
public nonisolated struct AgentSkillEntry: Equatable, Sendable, Hashable, Identifiable {
  /// The name the agent calls the skill by, `<plugin>:<skill>` for a
  /// plugin skill.
  public let name: String
  /// First line of the frontmatter `description`, or `nil` when the
  /// frontmatter has none or cannot be read.
  public let summary: String?
  /// The whole frontmatter `description`, trimmed, or `nil` when there is
  /// none. Shown beside the completion list.
  public let details: String?
  public let source: AgentSkillSource
  /// The skill folder.
  public let url: URL
  /// The frontmatter sets `disable-model-invocation: true`: the model may
  /// not call the skill, so only a call the agent itself expands runs it.
  /// `false` when the frontmatter cannot be read.
  public let disablesModelInvocation: Bool

  public var id: String { name }

  public init(
    name: String, summary: String?, details: String? = nil, source: AgentSkillSource, url: URL,
    disablesModelInvocation: Bool = false
  ) {
    self.name = name
    self.summary = summary
    self.details = details
    self.source = source
    self.url = url
    self.disablesModelInvocation = disablesModelInvocation
  }
}

/// Reads the `*/SKILL.md` files in skill directories.
public nonisolated enum SkillScanner {
  /// Scans `directories` off the caller's actor. A missing directory
  /// contributes nothing. For one name the source that comes first in
  /// `precedence` wins, then the earlier directory; a source not in
  /// `precedence` comes last. The result is sorted by name.
  @concurrent
  public static func scan(
    _ directories: [SkillDirectory], precedence: [AgentSkillSource] = []
  ) async -> [AgentSkillEntry] {
    scanSync(directories, precedence: precedence)
  }

  static func scanSync(
    _ directories: [SkillDirectory], precedence: [AgentSkillSource] = []
  ) -> [AgentSkillEntry] {
    let rank = { (source: AgentSkillSource) in precedence.firstIndex(of: source) ?? precedence.count }
    let ordered = directories.enumerated()
      .sorted { (rank($0.element.source), $0.offset) < (rank($1.element.source), $1.offset) }
      .map(\.element)
    var seen = Set<String>()
    var entries: [AgentSkillEntry] = []
    for directory in ordered {
      for entry in skills(in: directory) where seen.insert(entry.name).inserted {
        entries.append(entry)
      }
    }
    return entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  private static func skills(
    in directory: SkillDirectory
  ) -> [AgentSkillEntry] {
    let fileManager = FileManager.default
    // Skill folders are often symlinks into a skill source tree, so the
    // listing resolves each child rather than trusting its own type.
    let folders: [URL]
    switch directory.layout {
    case .skill: folders = [directory.url]
    case .skillFolders:
      guard
        let children = try? fileManager.contentsOfDirectory(
          at: directory.url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
      else { return [] }
      folders = children
    }
    return folders.compactMap { folder in
      let file = folder.appending(path: "SKILL.md", directoryHint: .notDirectory)
      guard let data = fileManager.contents(atPath: file.path(percentEncoded: false)) else {
        return nil
      }
      let folderName = folder.lastPathComponent
      let frontmatter = String(data: data, encoding: .utf8).flatMap(SkillFrontmatter.parse)
      let name = frontmatter?.name ?? folderName
      return AgentSkillEntry(
        name: directory.namespace.map { "\($0):\(name)" } ?? name,
        summary: frontmatter?.summary,
        details: frontmatter?.details,
        source: directory.source,
        url: folder,
        disablesModelInvocation: frontmatter?.disablesModelInvocation ?? false
      )
    }
  }
}

/// `name`, `description`, and `disable-model-invocation` from the YAML
/// frontmatter of a `SKILL.md`.
nonisolated struct SkillFrontmatter: Equatable {
  var name: String?
  var summary: String?
  var details: String?
  var disablesModelInvocation = false

  /// `nil` when the file has no frontmatter block or the block is not a
  /// YAML mapping. Then the skill is listed by its folder name alone.
  static func parse(_ text: String) -> SkillFrontmatter? {
    guard let yaml = block(in: text),
      let composed = try? Yams.compose(yaml: yaml),
      let mapping = composed.mapping
    else { return nil }
    let name = mapping["name"]?.string.map(trimmed).flatMap(nonEmpty)
    let summary = mapping["description"]?.string.flatMap { description in
      description.split(whereSeparator: { $0.isNewline }).lazy.map(trimmed).first { !$0.isEmpty }
    }
    let details = mapping["description"]?.string
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap(nonEmpty)
    let disablesModelInvocation = mapping["disable-model-invocation"]?.bool ?? false
    return SkillFrontmatter(
      name: name, summary: summary, details: details,
      disablesModelInvocation: disablesModelInvocation)
  }

  /// The text between a leading `---` line and the next `---` line.
  private static func block(in text: String) -> String? {
    var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)[...]
    guard lines.first.map(trimmed) == "---" else { return nil }
    lines = lines.dropFirst()
    guard let end = lines.firstIndex(where: { trimmed($0) == "---" }) else { return nil }
    return lines[..<end].joined(separator: "\n")
  }

  private static func trimmed<S: StringProtocol>(_ value: S) -> String {
    value.trimmingCharacters(in: .whitespaces)
  }

  private static func nonEmpty(_ value: String) -> String? {
    value.isEmpty ? nil : value
  }
}
