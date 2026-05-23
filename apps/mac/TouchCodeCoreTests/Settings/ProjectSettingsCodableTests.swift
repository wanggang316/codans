import Foundation
import Testing

@testable import TouchCodeCore

struct ProjectSettingsCodableTests {
  private let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return e
  }()
  private let decoder = JSONDecoder()

  // MARK: - ProjectSettings

  @Test
  func emptyProjectSettingsEncodesAsEmptyObject() throws {
    let settings = ProjectSettings()
    let data = try encoder.encode(settings)
    let text = try #require(String(bytes: data, encoding: .utf8))
    #expect(text == "{}")
  }

  @Test
  func emptyProjectSettingsIsEffectivelyEmpty() {
    #expect(ProjectSettings().isEffectivelyEmpty == true)
  }

  @Test
  func populatedTopLevelRoundTrips() throws {
    let settings = ProjectSettings(
      defaultEditor: "vscode",
      worktreesDirectory: "/tmp/wt",
      envVars: ["FOO": "bar"],
      scripts: [ScriptDefinition(name: "run", command: "make run")],
      git: nil
    )
    let data = try encoder.encode(settings)
    let decoded = try decoder.decode(ProjectSettings.self, from: data)
    #expect(decoded == settings)
  }

  @Test
  func populatedGitRoundTrips() throws {
    let settings = ProjectSettings(
      git: GitProjectSettings(
        defaultMergeStrategy: .squash,
        postMergeAction: .archive,
        githubDisabled: true
      )
    )
    let data = try encoder.encode(settings)
    let decoded = try decoder.decode(ProjectSettings.self, from: data)
    #expect(decoded == settings)
  }

  @Test
  func collapseEmptyGitClearsEffectivelyEmptyChild() {
    var settings = ProjectSettings(git: GitProjectSettings())
    #expect(settings.git != nil)
    settings.collapseEmptyGit()
    #expect(settings.git == nil)
    #expect(settings.isEffectivelyEmpty == true)
  }

  @Test
  func collapseEmptyGitKeepsNonEmptyChild() {
    var settings = ProjectSettings(git: GitProjectSettings(githubDisabled: true))
    settings.collapseEmptyGit()
    #expect(settings.git != nil)
    #expect(settings.isEffectivelyEmpty == false)
  }

  @Test
  func encoderOmitsEmptyCollectionsAndEmptyGit() throws {
    // An otherwise-empty ProjectSettings that carries an empty
    // GitProjectSettings should still encode as `{}` — the encoder
    // skips an `isEffectivelyEmpty` git subtree rather than emitting
    // `"git": {}`.
    let settings = ProjectSettings(git: GitProjectSettings())
    let data = try encoder.encode(settings)
    let text = try #require(String(bytes: data, encoding: .utf8))
    #expect(text == "{}")
  }

  // MARK: - GitProjectSettings

  @Test
  func emptyGitEncodesAsEmptyObject() throws {
    let git = GitProjectSettings()
    let data = try encoder.encode(git)
    let text = try #require(String(bytes: data, encoding: .utf8))
    #expect(text == "{}")
    #expect(git.isEffectivelyEmpty == true)
  }

  @Test
  func gitWithGithubDisabledIsNotEmpty() {
    let git = GitProjectSettings(githubDisabled: true)
    #expect(git.isEffectivelyEmpty == false)
  }

  @Test
  func gitDefaultFalseGithubDisabledOmitted() throws {
    // `githubDisabled: false` is the common case and must not appear on
    // disk — matches the existing RepositorySettings encoding contract.
    let git = GitProjectSettings(
      defaultMergeStrategy: .squash,
      githubDisabled: false
    )
    let data = try encoder.encode(git)
    let text = try #require(String(bytes: data, encoding: .utf8))
    #expect(text.contains("githubDisabled") == false)
    #expect(text.contains("squash") == true)
  }
}
