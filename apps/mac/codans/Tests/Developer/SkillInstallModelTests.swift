import CodansKit
import Foundation
import Testing

@testable import Codans

/// The Developer pane's per-skill sections over a sandboxed bundle and
/// home: every bundled skill × every target is offered, grouped by skill,
/// and Install / Remove flip one row without touching the others.
@MainActor
struct SkillInstallModelTests {
  @MainActor
  private struct Sandbox {
    let root: URL
    let model: SkillInstallModel
    let home: URL
    let bundled: URL

    init(skillIDs: [String] = ["codans-cli"]) throws {
      root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("codans-skill-model-\(UUID().uuidString)", isDirectory: true)
      bundled = root.appendingPathComponent("Codans.app/Contents/Resources/skills", isDirectory: true)
      home = root.appendingPathComponent("home", isDirectory: true)
      for id in skillIDs {
        let skill = bundled.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "# skill".write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
      }
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
      model = SkillInstallModel(installer: SkillInstaller(bundledDirectory: bundled, homeDirectory: home))
    }
  }

  @Test
  func offersEveryTargetEvenWithoutAnAgentFolder() throws {
    let sandbox = try Sandbox()
    sandbox.model.refresh()
    #expect(sandbox.model.rows.map(\.target) == [.claude, .codex, .agents])
    #expect(sandbox.model.rows.allSatisfy { $0.status == .missing })
    #expect(sandbox.model.rows[0].directory.hasSuffix("/home/.claude/skills"))
  }

  @Test
  func installAndRemoveFlipOneRow() throws {
    let sandbox = try Sandbox()
    sandbox.model.refresh()
    let codex = try #require(sandbox.model.rows.first(where: { $0.target == .codex }))

    sandbox.model.install(codex)
    #expect(sandbox.model.rows.map(\.status) == [.missing, .installed, .missing])
    #expect(sandbox.model.lastError == nil)
    let link = sandbox.home.appendingPathComponent(".codex/skills/codans-cli").path
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link)) != nil)

    sandbox.model.uninstall(try #require(sandbox.model.rows.first(where: { $0.target == .codex })))
    #expect(sandbox.model.rows.allSatisfy { $0.status == .missing })
    #expect(!FileManager.default.fileExists(atPath: link))
  }

  @Test
  func aForeignDirectoryIsReportedNotReplaced() throws {
    let sandbox = try Sandbox()
    let foreign = sandbox.home.appendingPathComponent(".claude/skills/codans-cli", isDirectory: true)
    try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
    sandbox.model.refresh()
    let claude = try #require(sandbox.model.rows.first(where: { $0.target == .claude }))
    #expect(claude.status == .conflict)

    sandbox.model.install(claude)
    #expect(sandbox.model.lastError?.skillID == "codans-cli")
    #expect(sandbox.model.lastError?.message.contains("not a codans skill link") == true)
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: foreign.path, isDirectory: &isDirectory) && isDirectory.boolValue)
  }

  @Test
  func groupsRowsBySkillInIDOrder() throws {
    let sandbox = try Sandbox(skillIDs: ["codans-workflow", "codans-cli"])
    sandbox.model.refresh()
    #expect(sandbox.model.groups.map(\.id) == ["codans-cli", "codans-workflow"])
    for group in sandbox.model.groups {
      #expect(group.rows.map(\.target) == [.claude, .codex, .agents])
      #expect(group.rows.allSatisfy { $0.skill == group.skill })
      #expect(group.description != nil)
    }
  }

  @Test
  func installInOneGroupLeavesTheOtherUnchanged() throws {
    let sandbox = try Sandbox(skillIDs: ["codans-cli", "codans-workflow"])
    sandbox.model.refresh()
    let workflowClaude = try #require(sandbox.model.groups[1].rows.first(where: { $0.target == .claude }))

    sandbox.model.install(workflowClaude)
    #expect(sandbox.model.groups[0].rows.map(\.status) == [.missing, .missing, .missing])
    #expect(sandbox.model.groups[1].rows.map(\.status) == [.installed, .missing, .missing])
  }

  @Test
  func revealURLIsEachSkillsOwnBundledFolder() throws {
    let sandbox = try Sandbox(skillIDs: ["codans-cli", "codans-workflow"])
    sandbox.model.refresh()
    let paths = sandbox.model.groups.map { $0.bundledFolder.standardizedFileURL.path }
    #expect(
      paths
        == ["codans-cli", "codans-workflow"].map {
          sandbox.bundled.appendingPathComponent($0, isDirectory: true).standardizedFileURL.path
        })
  }

  @Test
  func aSkillWithoutADescriptionStillHasItsRows() throws {
    let sandbox = try Sandbox(skillIDs: ["zz-unknown"])
    sandbox.model.refresh()
    let group = try #require(sandbox.model.groups.first)
    #expect(group.id == "zz-unknown")
    #expect(group.description == nil)
    #expect(group.rows.count == 3)
  }

  @Test
  func anEmptyBundleHasNoGroups() throws {
    let sandbox = try Sandbox(skillIDs: [])
    sandbox.model.refresh()
    #expect(sandbox.model.groups.isEmpty)
  }
}
