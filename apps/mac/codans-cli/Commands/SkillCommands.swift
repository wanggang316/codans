import ArgumentParser
import CodansCore
import CodansKit
import Foundation

/// `codans skill` — link the skills this app bundles into the folders
/// coding agents read (`~/.claude/skills`, `~/.codex/skills`,
/// `~/.agents/skills`). Local file-system work; the app need not run.
struct SkillCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "skill",
    abstract: "Install the bundled agent skills into your agents' skill folders.",
    discussion: """
      Codans ships its agent skills inside the app (Contents/Resources/skills).
      `skill install` links them into every detected agent skill folder so
      Claude Code, Codex, and other agents learn this CLI from the version
      that matches the installed app; an app update updates the skill.
      `skill list` shows the install status per target and `skill path`
      prints where a bundled skill lives.
      """,
    subcommands: [
      SkillList.self,
      SkillInstall.self,
      SkillUninstall.self,
      SkillPath.self,
    ]
  )
}

struct SkillTargetOptions: ParsableArguments {
  @Option(
    name: .long, parsing: .upToNextOption,
    help: "Target (repeatable): claude, codex, or agents. Defaults to every detected target.")
  var target: [SkillInstaller.Target] = []
  @Option(name: .long, help: "Scope: user (default) or project.")
  var scope: SkillInstaller.Scope = .user
  @Option(name: .long, help: "Repository root for --scope project. Defaults to the git root of $PWD.")
  var projectRoot: String?

  func resolvedRoot() throws -> URL? {
    guard scope == .project else { return nil }
    if let projectRoot {
      return URL(fileURLWithPath: PathResolver.absolute(projectRoot), isDirectory: true)
    }
    guard let root = SkillLocator.gitRoot(of: FileManager.default.currentDirectoryPath) else {
      throw CLIError(
        code: .userError, message: "--scope project needs a repository: $PWD is not inside a git worktree",
        hint: "pass --project-root <dir>")
    }
    return URL(fileURLWithPath: root, isDirectory: true)
  }

  func resolvedTargets(_ installer: SkillInstaller, root: URL?) throws -> [SkillInstaller.Target] {
    if !target.isEmpty { return target }
    let detected = installer.detectedTargets(scope: scope, projectRoot: root)
    guard !detected.isEmpty else {
      throw CLIError(
        code: .notFound,
        message: "no agent skill folders detected (~/.claude, ~/.codex, ~/.agents)",
        hint: "pass --target claude|codex|agents to create one")
    }
    return detected
  }
}

struct SkillList: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List the bundled skills with their install status per target."
  )

  @OptionGroup var globals: GlobalOptions
  @OptionGroup var targets: SkillTargetOptions

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let installer = try SkillLocator.installer()
      let root = try targets.resolvedRoot()
      let selected =
        targets.target.isEmpty
        ? installer.detectedTargets(scope: targets.scope, projectRoot: root) : targets.target
      let report = try installer.report(targets: selected, scope: targets.scope, projectRoot: root)
      try Renderer.emit(
        SkillListRenderable(report: report, bundled: installer.bundledDirectory), mode: globals.renderMode)
    }
  }
}

struct SkillInstall: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "install",
    abstract: "Link bundled skills into agent skill folders."
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Skill ids. Defaults to every bundled skill.")
  var skills: [String] = []
  @OptionGroup var targets: SkillTargetOptions
  @Flag(name: .long, help: "Replace a directory or foreign link that occupies the skill's name.")
  var force: Bool = false

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let installer = try SkillLocator.installer()
      let root = try targets.resolvedRoot()
      let selected = try targets.resolvedTargets(installer, root: root)
      let report = try installer.install(
        ids: skills, targets: selected, scope: targets.scope, projectRoot: root, force: force)
      try Renderer.emit(SkillChangeRenderable(report: report, verb: "installed"), mode: globals.renderMode)
    }
  }
}

struct SkillUninstall: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "uninstall",
    abstract: "Remove bundled skill links from agent skill folders."
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Skill ids. Defaults to every bundled skill.")
  var skills: [String] = []
  @OptionGroup var targets: SkillTargetOptions

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let installer = try SkillLocator.installer()
      let root = try targets.resolvedRoot()
      let selected = try targets.resolvedTargets(installer, root: root)
      let report = try installer.uninstall(ids: skills, targets: selected, scope: targets.scope, projectRoot: root)
      try Renderer.emit(SkillChangeRenderable(report: report, verb: "removed"), mode: globals.renderMode)
    }
  }
}

struct SkillPath: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "path",
    abstract: "Print the bundled directory of a skill."
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Skill id (default: codans-cli).")
  var skill: String = "codans-cli"

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let installer = try SkillLocator.installer()
      guard let found = try installer.bundledSkills().first(where: { $0.id == skill }) else {
        throw CLIError(code: .notFound, message: "unknown skill \"\(skill)\"", details: ["kind": "skill", "id": skill])
      }
      try Renderer.emitObject(["id": found.id, "path": found.path], mode: globals.renderMode) { obj in
        obj["path"] as? String ?? ""
      }
    }
  }
}

/// Finds the bundled skills for the CLI that is running: `$CODANS_SKILLS_DIR`
/// when set, else `Contents/Resources/skills` of the app this binary sits
/// in (`Contents/Resources/bin/<cli>`, through the installed symlink).
enum SkillLocator {
  static func installer() throws -> SkillInstaller {
    let directory: URL
    if let override = ProcessInfo.processInfo.environment["CODANS_SKILLS_DIR"], !override.isEmpty {
      directory = URL(fileURLWithPath: override, isDirectory: true)
    } else {
      let binary = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
      directory =
        binary
        .deletingLastPathComponent()  // bin
        .deletingLastPathComponent()  // Resources
        .appendingPathComponent("skills", isDirectory: true)
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false), isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw CLIError(
        code: .notFound,
        message: "no bundled skills at \(directory.path(percentEncoded: false))",
        hint: "run the CLI that ships inside Codans.app, or set CODANS_SKILLS_DIR")
    }
    // `$HOME` first: `homeDirectoryForCurrentUser` reads the account record,
    // so a script (or the regression harness) pointing `HOME` at a sandbox
    // would otherwise still write into the real home.
    let home =
      ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 }
      .map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? FileManager.default.homeDirectoryForCurrentUser
    return SkillInstaller(bundledDirectory: directory, homeDirectory: home)
  }

  static func gitRoot(of directory: String) -> String? {
    var url = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
    while true {
      if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path(percentEncoded: false)) {
        return url.path(percentEncoded: false)
      }
      let parent = url.deletingLastPathComponent()
      if parent.path == url.path { return nil }
      url = parent
    }
  }
}

struct SkillListRenderable: Encodable, CustomStringConvertible {
  let report: [SkillInstaller.SkillReport]
  let bundled: URL

  private struct TargetRow: Encodable {
    let target: String
    let directory: String
    let status: String
  }
  private struct SkillRow: Encodable {
    let id: String
    let path: String
    let targets: [TargetRow]
  }
  private enum Key: String, CodingKey { case skills }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    try container.encode(
      report.map { item in
        SkillRow(
          id: item.skill.id, path: item.skill.path,
          targets: item.targets.map {
            TargetRow(target: $0.target.rawValue, directory: $0.directory, status: $0.status.rawValue)
          })
      }, forKey: .skills)
  }

  var description: String {
    guard !report.isEmpty else { return "(no bundled skills at \(bundled.path(percentEncoded: false)))" }
    return report.map { item in
      let rows = item.targets.map {
        "  \($0.target.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \($0.status.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)) \($0.directory)"
      }
      return ([item.skill.id + "  " + item.skill.path] + (rows.isEmpty ? ["  (no targets detected)"] : rows))
        .joined(separator: "\n")
    }.joined(separator: "\n")
  }
}

struct SkillChangeRenderable: Encodable, CustomStringConvertible {
  let report: SkillInstaller.ChangeReport
  let verb: String

  private enum Key: String, CodingKey { case installed, removed, skipped }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    try container.encode(report.installed, forKey: .installed)
    try container.encode(report.removed, forKey: .removed)
    try container.encode(report.skipped, forKey: .skipped)
  }

  var description: String {
    var lines: [String] = []
    lines += report.installed.map { "installed \($0)" }
    lines += report.removed.map { "removed \($0)" }
    lines += report.skipped.map { "already \(verb == "installed" ? "installed" : "absent") \($0)" }
    return lines.isEmpty ? "nothing to do" : lines.joined(separator: "\n")
  }
}

extension SkillInstaller.Target: @retroactive ExpressibleByArgument {}
extension SkillInstaller.Scope: @retroactive ExpressibleByArgument {}
