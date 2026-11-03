import Foundation
import Testing

@testable import CodansCore

/// Verifies the GitHub-integration surface that now lives under
/// `ProjectSettings.git: GitProjectSettings?` (v3 schema):
///   - backward compatibility: an empty `{}` still decodes to an `isEffectivelyEmpty` entry
///   - additive fields flip `isEffectivelyEmpty` to false when set
///   - settings.json round-trips with the per-Project `git` overrides populated
///   - global defaults on `GeneralSettings` encode + decode cleanly
struct GitHubSettingsIntegrationTests {
  // MARK: - GitProjectSettings backward compatibility

  @Test
  func emptyObjectStillDecodesToEffectivelyEmpty() throws {
    let decoded = try JSONDecoder().decode(GitProjectSettings.self, from: Data("{}".utf8))
    #expect(decoded.defaultMergeStrategy == nil)
    #expect(decoded.postMergeAction == nil)
    #expect(decoded.githubDisabled == false)
    #expect(decoded.isEffectivelyEmpty == true)
  }

  @Test
  func emptyInstanceEncodesToEmptyObject() throws {
    let encoded = try JSONEncoder().encode(GitProjectSettings())
    let roundTripped = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    #expect(roundTripped?.isEmpty == true, "empty entry must round-trip as {} to match pre-integration files")
  }

  // MARK: - Each GitHub-only field flips isEffectivelyEmpty

  @Test
  func defaultMergeStrategyFlipsEffectivelyEmpty() {
    let settings = GitProjectSettings(defaultMergeStrategy: .squash)
    #expect(settings.isEffectivelyEmpty == false)
  }

  @Test
  func postMergeActionFlipsEffectivelyEmpty() {
    let settings = GitProjectSettings(postMergeAction: .archive)
    #expect(settings.isEffectivelyEmpty == false)
  }

  @Test
  func githubDisabledFlipsEffectivelyEmpty() {
    let settings = GitProjectSettings(githubDisabled: true)
    #expect(settings.isEffectivelyEmpty == false)
  }

  // MARK: - GitProjectSettings round-trip with all fields

  @Test
  func gitProjectSettingsRoundTripAllFields() throws {
    let original = GitProjectSettings(
      defaultMergeStrategy: .rebase,
      postMergeAction: .delete,
      githubDisabled: true
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(GitProjectSettings.self, from: data)
    #expect(decoded == original)
  }

  @Test
  func githubDisabledFalseIsOmittedFromEncoding() throws {
    let settings = GitProjectSettings(defaultMergeStrategy: .squash, githubDisabled: false)
    let data = try JSONEncoder().encode(settings)
    let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(dict?["defaultMergeStrategy"] as? String == "squash")
    #expect(dict?["githubDisabled"] == nil, "false should be omitted to match the empty-default pattern")
  }

  // MARK: - GeneralSettings backward compatibility + round-trip

  @Test
  func generalSettingsDecodesFromPreIntegrationFile() throws {
    let json = #"{"appearance":"system"}"#
    let decoded = try JSONDecoder().decode(GeneralSettings.self, from: Data(json.utf8))
    #expect(decoded.defaultMergeStrategy == nil)
    #expect(decoded.postMergeAction == nil)
  }

  @Test
  func generalSettingsRoundTripWithGitHubFields() throws {
    let original = GeneralSettings(
      appearance: .dark,
      defaultEditorID: nil,
      defaultMergeStrategy: .squash,
      postMergeAction: .archive
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(GeneralSettings.self, from: data)
    #expect(decoded == original)
    #expect(decoded.defaultMergeStrategy == .squash)
    #expect(decoded.postMergeAction == .archive)
  }

  // MARK: - Full settings tree round-trip with per-Project git overrides

  @Test
  func settingsTreeRoundTripWithGitHubFields() throws {
    let projectID = ProjectID(raw: UUID())
    var settings = Settings(
      general: GeneralSettings(
        defaultMergeStrategy: .squash,
        postMergeAction: .ask
      )
    )
    settings.projects[projectID] = ProjectSettings(
      git: GitProjectSettings(
        defaultMergeStrategy: .rebase,
        postMergeAction: .archive,
        githubDisabled: false
      )
    )
    let data = try JSONEncoder.touchCodeDefault.encode(settings)
    let decoded = try JSONDecoder.touchCodeDefault.decode(Settings.self, from: data)
    #expect(decoded == settings)
    #expect(decoded.general.defaultMergeStrategy == .squash)
    #expect(decoded.projects[projectID]?.git?.defaultMergeStrategy == .rebase)
  }
}
