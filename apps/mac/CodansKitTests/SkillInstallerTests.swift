import Foundation
import Testing

@testable import CodansKit

/// `codans skill` links bundled skills into agent skill folders; these run
/// the installer against temporary directories that stand in for the app
/// bundle and the user's home.
struct SkillInstallerTests {
  private struct Sandbox {
    let root: URL
    let bundled: URL
    let home: URL
    let installer: SkillInstaller

    init() throws {
      root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("codans-skills-\(UUID().uuidString)", isDirectory: true)
      // Mirror a real bundle layout so `looksBundled` recognises the copy.
      bundled = root.appendingPathComponent("Codans.app/Contents/Resources/skills", isDirectory: true)
      home = root.appendingPathComponent("home", isDirectory: true)
      let fm = FileManager.default
      for id in ["codans-cli", "codans-review"] {
        let dir = bundled.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try "# \(id)".write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
      }
      try fm.createDirectory(at: bundled.appendingPathComponent("not-a-skill"), withIntermediateDirectories: true)
      try fm.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
      try fm.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
      installer = SkillInstaller(bundledDirectory: bundled, homeDirectory: home)
    }

    func link(_ id: String, target: SkillInstaller.Target) -> URL {
      home.appendingPathComponent(target.homeFolder).appendingPathComponent("skills").appendingPathComponent(id)
    }
  }

  @Test
  func discoversBundledSkillsAndDetectedTargets() throws {
    let sandbox = try Sandbox()
    #expect(try sandbox.installer.bundledSkills().map(\.id) == ["codans-cli", "codans-review"])
    #expect(sandbox.installer.detectedTargets(scope: .user, projectRoot: nil) == [.claude, .codex])
  }

  @Test
  func installLinksEverySkillIntoEachTargetAndIsIdempotent() throws {
    let sandbox = try Sandbox()
    let first = try sandbox.installer.install(
      ids: [], targets: [.claude, .codex], scope: .user, projectRoot: nil, force: false)
    #expect(first.installed.count == 4)
    #expect(first.skipped.isEmpty)
    let destination = try FileManager.default.destinationOfSymbolicLink(
      atPath: sandbox.link("codans-cli", target: .claude).path(percentEncoded: false))
    #expect(destination.hasSuffix("Resources/skills/codans-cli"))

    let second = try sandbox.installer.install(
      ids: ["codans-cli"], targets: [.claude], scope: .user, projectRoot: nil, force: false)
    #expect(second.installed.isEmpty)
    #expect(second.skipped.count == 1)

    let report = try sandbox.installer.report(targets: [.claude, .agents], scope: .user, projectRoot: nil)
    let cli = try #require(report.first(where: { $0.skill.id == "codans-cli" }))
    #expect(cli.targets.map(\.status) == [.installed, .missing])
  }

  @Test
  func anotherBundlesLinkIsReplacedButAForeignDirectoryNeedsForce() throws {
    let sandbox = try Sandbox()
    let fm = FileManager.default
    let claudeSkills = sandbox.home.appendingPathComponent(".claude/skills", isDirectory: true)
    try fm.createDirectory(at: claudeSkills, withIntermediateDirectories: true)
    // An older install's copy, under a different bundle path.
    let older = sandbox.root.appendingPathComponent("Old.app/Contents/Resources/skills/codans-cli", isDirectory: true)
    try fm.createDirectory(at: older, withIntermediateDirectories: true)
    try fm.createSymbolicLink(
      at: sandbox.link("codans-cli", target: .claude), withDestinationURL: older)
    // A hand-made directory under the other skill's name.
    try fm.createDirectory(at: sandbox.link("codans-review", target: .claude), withIntermediateDirectories: true)

    let before = try sandbox.installer.report(targets: [.claude], scope: .user, projectRoot: nil)
    #expect(before.map { $0.targets[0].status } == [.otherVersion, .conflict])

    // Skills install in id order: codans-cli's stale link is replaced before
    // codans-review's directory stops the run.
    #expect(throws: SkillInstaller.Failure.self) {
      try sandbox.installer.install(ids: [], targets: [.claude], scope: .user, projectRoot: nil, force: false)
    }
    let forced = try sandbox.installer.install(
      ids: [], targets: [.claude], scope: .user, projectRoot: nil, force: true)
    #expect(forced.installed.count == 1)
    #expect(forced.skipped.count == 1)
    let after = try sandbox.installer.report(targets: [.claude], scope: .user, projectRoot: nil)
    #expect(after.map { $0.targets[0].status } == [.installed, .installed])
  }

  @Test
  func uninstallRemovesOnlyBundledLinks() throws {
    let sandbox = try Sandbox()
    _ = try sandbox.installer.install(ids: [], targets: [.claude], scope: .user, projectRoot: nil, force: false)
    let foreign = sandbox.link("codans-review", target: .claude)
    try FileManager.default.removeItem(at: foreign)
    try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)

    let removed = try sandbox.installer.uninstall(
      ids: ["codans-cli"], targets: [.claude], scope: .user, projectRoot: nil)
    #expect(removed.removed.count == 1)
    #expect(
      !FileManager.default.fileExists(atPath: sandbox.link("codans-cli", target: .claude).path(percentEncoded: false)))
    #expect(throws: SkillInstaller.Failure.self) {
      try sandbox.installer.uninstall(ids: ["codans-review"], targets: [.claude], scope: .user, projectRoot: nil)
    }
  }

  @Test
  func projectScopeLinksUnderTheRepositoryRoot() throws {
    let sandbox = try Sandbox()
    let repo = sandbox.root.appendingPathComponent("repo", isDirectory: true)
    try FileManager.default.createDirectory(
      at: repo.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    #expect(sandbox.installer.detectedTargets(scope: .project, projectRoot: repo) == [.claude])
    let report = try sandbox.installer.install(
      ids: ["codans-cli"], targets: [.claude], scope: .project, projectRoot: repo, force: false)
    #expect(report.installed == [SkillInstaller.plainPath(repo.appendingPathComponent(".claude/skills/codans-cli"))])
  }

  @Test
  func unknownSkillIdsAreRefused() throws {
    let sandbox = try Sandbox()
    #expect(throws: SkillInstaller.Failure.unknownSkill("nope")) {
      try sandbox.installer.install(ids: ["nope"], targets: [.claude], scope: .user, projectRoot: nil, force: false)
    }
  }
}
