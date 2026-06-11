import Foundation
import Testing

@testable import CodansCore

/// Editor-ID migration coverage. Exercises `Settings.garbageCollectEditors(knownIDs:)`
/// which walks both `general.defaultEditorID` and `projects[pid].defaultEditor` (v3 schema
/// absorbed per-Project editor overrides that used to live on Catalog):
///   - Reset IDs that are not in the caller-supplied registry to `nil`.
///   - Leave valid IDs untouched.
///   - Return `true` iff any field was mutated (so callers skip spurious writes).
///
/// The helper does not import the app-tier `EditorRegistry`, so `knownIDs` is passed
/// explicitly. `Catalog.garbageCollectEditors` is gone — the walk responsibility moved
/// to `Settings.garbageCollectEditors` when v3 absorbed the per-Project editor field.
struct EditorMigrationTests {
  private static let known: Set<EditorID> = ["vscode", "cursor", "zed", "finder", "editor"]

  // MARK: - Settings.garbageCollectEditors

  @Test
  func settingsGarbageCollectResetsStaleDefaultEditorID() {
    var settings = Settings()
    settings.general.defaultEditorID = "unknownCustom"

    let mutated = settings.garbageCollectEditors(knownIDs: Self.known)
    #expect(mutated == true, "Stale ID must mutate and return true")
    #expect(settings.general.defaultEditorID == nil)
  }

  @Test
  func settingsGarbageCollectKeepsValidDefaultEditorID() {
    var settings = Settings()
    settings.general.defaultEditorID = "cursor"

    let mutated = settings.garbageCollectEditors(knownIDs: Self.known)
    #expect(mutated == false, "Valid ID must not mutate and must return false")
    #expect(settings.general.defaultEditorID == "cursor")
  }

  @Test
  func settingsGarbageCollectIsNoOpWhenDefaultIsNil() {
    var settings = Settings()
    settings.general.defaultEditorID = nil

    let mutated = settings.garbageCollectEditors(knownIDs: Self.known)
    #expect(mutated == false)
    #expect(settings.general.defaultEditorID == nil)
  }

  @Test
  func settingsGarbageCollectIsIdempotent() {
    var settings = Settings()
    settings.general.defaultEditorID = "ghost-editor"

    let first = settings.garbageCollectEditors(knownIDs: Self.known)
    let second = settings.garbageCollectEditors(knownIDs: Self.known)
    #expect(first == true)
    #expect(second == false, "Second pass must be a no-op")
    #expect(settings.general.defaultEditorID == nil)
  }

  // MARK: - Settings.garbageCollectEditors on projects[pid].defaultEditor

  @Test
  func settingsGarbageCollectResetsStaleProjectDefaultEditor() {
    var settings = Settings()
    let pid = ProjectID()
    settings.projects[pid] = ProjectSettings(defaultEditor: "unknownCustom")
    let mutated = settings.garbageCollectEditors(knownIDs: Self.known)
    #expect(mutated == true)
    #expect(settings.projects[pid]?.defaultEditor == nil)
  }

  @Test
  func settingsGarbageCollectKeepsValidProjectDefaultEditor() {
    var settings = Settings()
    let pid = ProjectID()
    settings.projects[pid] = ProjectSettings(defaultEditor: "vscode")
    let mutated = settings.garbageCollectEditors(knownIDs: Self.known)
    #expect(mutated == false)
    #expect(settings.projects[pid]?.defaultEditor == "vscode")
  }

  @Test
  func settingsGarbageCollectMixedStaleAndValidNormalisesOnlyStale() {
    var settings = Settings()
    let stalePID = ProjectID()
    let validPID = ProjectID()
    settings.projects[stalePID] = ProjectSettings(defaultEditor: "ghost-editor")
    settings.projects[validPID] = ProjectSettings(defaultEditor: "cursor")
    let mutated = settings.garbageCollectEditors(knownIDs: Self.known)
    #expect(mutated == true)
    #expect(settings.projects[stalePID]?.defaultEditor == nil)
    #expect(settings.projects[validPID]?.defaultEditor == "cursor")
  }

  // MARK: - Legacy tolerance

  @Test
  func settingsDecodeToleratesLegacyCustomEditorsField() throws {
    // C8 shipped a `customEditors` array that C8a retired. Legacy files must still decode
    // cleanly (the field is ignored); there is no crash path even when the array is present
    // and non-empty.
    let legacyJSON = #"""
      {
        "version": 3,
        "general": {
          "appearance": "system",
          "defaultEditorID": "vscode",
          "customEditors": [
            { "id": "helix", "displayName": "Helix",
              "template": { "binary": "hx", "args": ["{dir}"] } }
          ]
        }
      }
      """#
    let data = Data(legacyJSON.utf8)
    let settings = try JSONDecoder().decode(Settings.self, from: data)
    #expect(settings.general.defaultEditorID == "vscode")
    // No assertion on the dropped field — the point is that decode did not throw.
  }

}
