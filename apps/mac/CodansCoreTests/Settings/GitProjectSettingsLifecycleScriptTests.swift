import Foundation
import Testing

@testable import CodansCore

struct GitProjectSettingsLifecycleScriptTests {
  private let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return e
  }()
  private let decoder = JSONDecoder()

  @Test
  func payloadWithoutLifecycleScriptsDecodesAsNil() throws {
    // Schema with no createScript / archiveScript / deleteScript keys.
    let payload = Data("""
      { "githubDisabled": true }
      """.utf8)
    let git = try decoder.decode(GitProjectSettings.self, from: payload)
    #expect(git.createScript == nil)
    #expect(git.archiveScript == nil)
    #expect(git.deleteScript == nil)
  }

  @Test
  func roundTripsWithEveryLifecycleScriptPopulated() throws {
    let git = GitProjectSettings(
      createScript: ScriptDefinition(command: "npm install"),
      archiveScript: ScriptDefinition(command: "git lfs prune"),
      deleteScript: ScriptDefinition(command: "./scripts/save-state.sh")
    )
    let data = try encoder.encode(git)
    let decoded = try decoder.decode(GitProjectSettings.self, from: data)
    #expect(decoded == git)
  }

  @Test
  func encoderOmitsAbsentLifecycleScripts() throws {
    let git = GitProjectSettings(
      createScript: ScriptDefinition(command: "npm install")
    )
    let data = try encoder.encode(git)
    let text = try #require(String(bytes: data, encoding: .utf8))
    #expect(text.contains("\"createScript\""))
    #expect(text.contains("\"command\":\"npm install\""))
    #expect(text.contains("archiveScript") == false)
    #expect(text.contains("deleteScript") == false)
  }

  @Test
  func encoderTreatsEmptyCommandAsAbsent() throws {
    // A non-nil ScriptDefinition with empty command must not bloat the JSON
    // with a stale UUID — it's effectively the same as nil and round-trips
    // back as nil.
    let git = GitProjectSettings(
      archiveScript: ScriptDefinition(command: "")
    )
    let data = try encoder.encode(git)
    let text = try #require(String(bytes: data, encoding: .utf8))
    #expect(text.contains("archiveScript") == false)
  }

  @Test
  func emptyLifecycleScriptsDoNotBreakIsEffectivelyEmpty() {
    var git = GitProjectSettings()
    #expect(git.isEffectivelyEmpty == true)

    git.createScript = ScriptDefinition(command: "echo hi")
    #expect(git.isEffectivelyEmpty == false)

    git.createScript = nil
    git.archiveScript = ScriptDefinition(command: "echo bye")
    #expect(git.isEffectivelyEmpty == false)

    git.archiveScript = nil
    #expect(git.isEffectivelyEmpty == true)

    // A non-nil ScriptDefinition with empty command counts as effectively
    // empty too (symmetric with the encoder's behaviour).
    git.deleteScript = ScriptDefinition(command: "")
    #expect(git.isEffectivelyEmpty == true)
  }

  @Test
  func projectSettingsCollapsesGitWithOnlyLifecycleScriptsToNonEmpty() {
    var settings = ProjectSettings(
      git: GitProjectSettings(createScript: ScriptDefinition(command: "npm install"))
    )
    settings.collapseEmptyGit()
    #expect(settings.git != nil)
    #expect(settings.isEffectivelyEmpty == false)
  }
}
