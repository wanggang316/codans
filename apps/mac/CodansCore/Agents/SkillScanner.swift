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
  public let source: AgentSkillSource
  /// The skill folder.
  public let url: URL

  public var id: String { name }

  public init(name: String, summary: String?, source: AgentSkillSource, url: URL) {
    self.name = name
    self.summary = summary
    self.source = source
    self.url = url
  }
}

/// Reads the `*/SKILL.md` files in skill directories.
public nonisolated enum SkillScanner {
  /// Resolves and scans every skill directory of `profile` launched in
  /// `projectDirectory`, off the caller's actor.
  @concurrent
  public static func scan(
    for profile: AgentProfile, projectDirectory: URL?
  ) async -> [AgentSkillEntry] {
    scanSync(SkillLocationResolver.directories(for: profile, projectDirectory: projectDirectory))
  }

  /// Scans `directories` in order, off the caller's actor. A missing
  /// directory contributes nothing. For one name the first directory wins,
  /// and the result is sorted by name.
  @concurrent
  public static func scan(_ directories: [SkillDirectory]) async -> [AgentSkillEntry] {
    scanSync(directories)
  }

  static func scanSync(_ directories: [SkillDirectory]) -> [AgentSkillEntry] {
    var seen = Set<String>()
    var entries: [AgentSkillEntry] = []
    for directory in directories {
      for entry in skills(in: directory) where seen.insert(entry.name).inserted {
        entries.append(entry)
      }
    }
    return entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  private static func skills(in directory: SkillDirectory) -> [AgentSkillEntry] {
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
        source: directory.source,
        url: folder
      )
    }
  }
}

/// `name` and `description` from the YAML frontmatter of a `SKILL.md`.
nonisolated struct SkillFrontmatter: Equatable {
  var name: String?
  var summary: String?

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
    return SkillFrontmatter(name: name, summary: summary)
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
