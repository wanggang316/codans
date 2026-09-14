import Foundation

/// Links the skills an app bundle ships (`Contents/Resources/skills/<id>`)
/// into the folders coding agents read skills from, so an agent always
/// sees the skill version that matches the installed app. Pure file-system
/// work: no socket, no running app.
public struct SkillInstaller {
  /// Where an agent looks for skills. `user` scope is the agent's home
  /// folder; `project` scope is the same folder name under a repository.
  public enum Target: String, CaseIterable, Sendable {
    case claude
    case codex
    case agents

    /// The agent-owned directory the skills folder lives under.
    public var homeFolder: String {
      switch self {
      case .claude: return ".claude"
      case .codex: return ".codex"
      case .agents: return ".agents"
      }
    }
  }

  public enum Scope: String, CaseIterable, Sendable {
    case user
    case project
  }

  public enum Status: String, Codable, Sendable {
    /// Linked to this bundle's copy.
    case installed
    case missing
    /// A link to another app's copy (an older install, a development build).
    case otherVersion = "other-version"
    /// Something that is not a link to any bundled skill occupies the name.
    case conflict
  }

  public struct BundledSkill: Equatable, Sendable {
    public let id: String
    public let path: String
  }

  public struct TargetStatus: Equatable, Sendable {
    public let target: Target
    public let directory: String
    public let status: Status
  }

  public struct SkillReport: Equatable, Sendable {
    public let skill: BundledSkill
    public let targets: [TargetStatus]
  }

  public struct ChangeReport: Equatable, Sendable {
    public var installed: [String] = []
    public var removed: [String] = []
    public var skipped: [String] = []
    public init() {}
  }

  public enum Failure: Error, Equatable, CustomStringConvertible {
    case noBundledSkills(String)
    case unknownSkill(String)
    case conflict(path: String)
    case notOurs(path: String)

    public var description: String {
      switch self {
      case .noBundledSkills(let path): return "no bundled skills at \(path)"
      case .unknownSkill(let id): return "unknown skill \"\(id)\""
      case .conflict(let path): return "\(path) exists and is not a codans skill link; remove it or pass --force"
      case .notOurs(let path): return "\(path) is not a link to a codans skill; leaving it alone"
      }
    }
  }

  public let bundledDirectory: URL
  private let homeDirectory: URL
  private let fileManager: FileManager

  public init(bundledDirectory: URL, homeDirectory: URL, fileManager: FileManager = .default) {
    self.bundledDirectory = bundledDirectory
    self.homeDirectory = homeDirectory
    self.fileManager = fileManager
  }

  // MARK: - Discovery

  /// Every `<id>/SKILL.md` under the bundled directory, sorted by id.
  public func bundledSkills() throws -> [BundledSkill] {
    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: bundledDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else {
      throw Failure.noBundledSkills(bundledDirectory.path(percentEncoded: false))
    }
    return
      entries
      .filter { fileManager.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path(percentEncoded: false)) }
      .map { BundledSkill(id: $0.lastPathComponent, path: Self.plainPath($0)) }
      .sorted { $0.id < $1.id }
  }

  /// The skills folder for a target: `~/.claude/skills` for user scope,
  /// `<root>/.claude/skills` for project scope.
  public func skillsDirectory(for target: Target, scope: Scope, projectRoot: URL?) -> URL {
    let base = scope == .project ? (projectRoot ?? homeDirectory) : homeDirectory
    return base.appendingPathComponent(target.homeFolder, isDirectory: true)
      .appendingPathComponent("skills", isDirectory: true)
  }

  /// A file-system path without a trailing slash, so links, reports, and
  /// comparisons all spell a directory the same way.
  static func plainPath(_ url: URL) -> String {
    let path = url.standardizedFileURL.path(percentEncoded: false)
    return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
  }

  /// Targets whose agent folder (`~/.claude`, …) exists — the agents the
  /// user actually has.
  public func detectedTargets(scope: Scope, projectRoot: URL?) -> [Target] {
    Target.allCases.filter { target in
      let base = scope == .project ? (projectRoot ?? homeDirectory) : homeDirectory
      var isDirectory: ObjCBool = false
      let folder = base.appendingPathComponent(target.homeFolder).path(percentEncoded: false)
      return fileManager.fileExists(atPath: folder, isDirectory: &isDirectory) && isDirectory.boolValue
    }
  }

  public func status(of skill: BundledSkill, in directory: URL) -> Status {
    let path = Self.plainPath(directory.appendingPathComponent(skill.id))
    guard let attributes = try? fileManager.attributesOfItem(atPath: path) else { return .missing }
    guard attributes[.type] as? FileAttributeType == .typeSymbolicLink,
      let destination = try? fileManager.destinationOfSymbolicLink(atPath: path)
    else { return .conflict }
    let resolved = URL(fileURLWithPath: destination, relativeTo: directory).standardizedFileURL
    if Self.sameLocation(resolved, URL(fileURLWithPath: skill.path)) { return .installed }
    return Self.looksBundled(resolved) ? .otherVersion : .conflict
  }

  public func report(targets: [Target], scope: Scope, projectRoot: URL?) throws -> [SkillReport] {
    try bundledSkills().map { skill in
      SkillReport(
        skill: skill,
        targets: targets.map { target in
          let directory = skillsDirectory(for: target, scope: scope, projectRoot: projectRoot)
          return TargetStatus(
            target: target, directory: Self.plainPath(directory),
            status: status(of: skill, in: directory))
        })
    }
  }

  // MARK: - Changes

  /// Links `ids` (every bundled skill when empty) into each target. An
  /// existing link to another bundle is replaced; anything else in the way
  /// is a conflict unless `force`.
  public func install(ids: [String], targets: [Target], scope: Scope, projectRoot: URL?, force: Bool) throws
    -> ChangeReport
  {
    var report = ChangeReport()
    for skill in try selectedSkills(ids) {
      for target in targets {
        let directory = skillsDirectory(for: target, scope: scope, projectRoot: projectRoot)
        let linkPath = Self.plainPath(directory.appendingPathComponent(skill.id))
        switch status(of: skill, in: directory) {
        case .installed:
          report.skipped.append(linkPath)
          continue
        case .otherVersion:
          try fileManager.removeItem(atPath: linkPath)
        case .conflict:
          guard force else { throw Failure.conflict(path: linkPath) }
          try fileManager.removeItem(atPath: linkPath)
        case .missing:
          break
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: linkPath, withDestinationPath: skill.path)
        report.installed.append(linkPath)
      }
    }
    return report
  }

  /// Removes links that point at a bundled skill (this app's or another
  /// install's); a name occupied by anything else is left alone.
  public func uninstall(ids: [String], targets: [Target], scope: Scope, projectRoot: URL?) throws -> ChangeReport {
    var report = ChangeReport()
    for skill in try selectedSkills(ids) {
      for target in targets {
        let directory = skillsDirectory(for: target, scope: scope, projectRoot: projectRoot)
        let linkPath = Self.plainPath(directory.appendingPathComponent(skill.id))
        switch status(of: skill, in: directory) {
        case .installed, .otherVersion:
          try fileManager.removeItem(atPath: linkPath)
          report.removed.append(linkPath)
        case .missing:
          report.skipped.append(linkPath)
        case .conflict:
          throw Failure.notOurs(path: linkPath)
        }
      }
    }
    return report
  }

  private func selectedSkills(_ ids: [String]) throws -> [BundledSkill] {
    let all = try bundledSkills()
    guard !ids.isEmpty else { return all }
    return try ids.map { id in
      guard let skill = all.first(where: { $0.id == id }) else { throw Failure.unknownSkill(id) }
      return skill
    }
  }

  /// A link into any app bundle's `Resources/skills` — another install's
  /// copy rather than a foreign directory.
  static func looksBundled(_ url: URL) -> Bool {
    url.pathComponents.contains("skills") && url.pathComponents.contains("Resources")
  }

  private static func sameLocation(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
      == rhs.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
  }
}
