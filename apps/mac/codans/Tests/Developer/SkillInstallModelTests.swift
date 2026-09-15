import CodansKit
import Foundation
import Testing

@testable import Codans

/// The Developer pane's "Agent skills" rows over a sandboxed bundle and
/// home: every bundled skill × every target is offered, and Install /
/// Remove flip one row without touching the others.
@MainActor
struct SkillInstallModelTests {
  @MainActor
  private struct Sandbox {
    let root: URL
    let model: SkillInstallModel
    let home: URL

    init() throws {
      root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("codans-skill-model-\(UUID().uuidString)", isDirectory: true)
      let bundled = root.appendingPathComponent("Codans.app/Contents/Resources/skills", isDirectory: true)
      home = root.appendingPathComponent("home", isDirectory: true)
      let skill = bundled.appendingPathComponent("codans-cli", isDirectory: true)
      try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
      try "# skill".write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
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
    #expect(sandbox.model.lastError?.contains("not a codans skill link") == true)
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: foreign.path, isDirectory: &isDirectory) && isDirectory.boolValue)
  }
}
