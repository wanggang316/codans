import Foundation
import Testing

@testable import CodansCore

struct ProjectSettingsScriptIDNormalisationTests {
  @Test
  func normalizeScriptIDsLeavesUniqueIDsAlone() {
    var settings = ProjectSettings(
      scripts: [
        ScriptDefinition(id: UUID(), name: "a", command: "echo a"),
        ScriptDefinition(id: UUID(), name: "b", command: "echo b"),
      ]
    )
    let originalIDs = settings.scripts.map(\.id)
    let replacements = settings.normalizeScriptIDs()
    #expect(replacements.isEmpty)
    #expect(settings.scripts.map(\.id) == originalIDs)
  }

  @Test
  func normalizeScriptIDsReplacesDuplicateWithFreshUUID() {
    let sharedID = UUID()
    var settings = ProjectSettings(
      scripts: [
        ScriptDefinition(id: sharedID, name: "first", command: "echo 1"),
        ScriptDefinition(id: sharedID, name: "second", command: "echo 2"),
      ]
    )
    let replacements = settings.normalizeScriptIDs()
    #expect(replacements.count == 1)
    #expect(replacements[0].old == sharedID)
    #expect(settings.scripts[0].id == sharedID)
    #expect(settings.scripts[1].id != sharedID)
    #expect(settings.scripts[1].id == replacements[0].new)
  }

  @Test
  func normalizeScriptIDsReplacesEveryDuplicateInACluster() {
    let sharedID = UUID()
    var settings = ProjectSettings(
      scripts: [
        ScriptDefinition(id: sharedID, name: "a", command: "echo a"),
        ScriptDefinition(id: sharedID, name: "b", command: "echo b"),
        ScriptDefinition(id: sharedID, name: "c", command: "echo c"),
      ]
    )
    let replacements = settings.normalizeScriptIDs()
    #expect(replacements.count == 2)
    let finalIDs = Set(settings.scripts.map(\.id))
    #expect(finalIDs.count == 3)
  }

  @Test
  func normalizeScriptIDsIsIdempotent() {
    let sharedID = UUID()
    var settings = ProjectSettings(
      scripts: [
        ScriptDefinition(id: sharedID, name: "a", command: "echo a"),
        ScriptDefinition(id: sharedID, name: "b", command: "echo b"),
      ]
    )
    _ = settings.normalizeScriptIDs()
    let secondPass = settings.normalizeScriptIDs()
    #expect(secondPass.isEmpty)
  }

  @Test
  func settingsLoadNormalisesDuplicateScriptIDs() throws {
    // End-to-end: a hand-edited settings.json with duplicate script IDs decodes
    // through Settings.init(from:) and the resulting scripts have unique ids.
    let projectID = ProjectID()
    let sharedID = UUID()
    let payload = Data(#"""
      {
        "version": 3,
        "projects": {
          "\#(projectID.raw.uuidString)": {
            "scripts": [
              { "id": "\#(sharedID.uuidString)", "kind": "run", "name": "a", "command": "echo a" },
              { "id": "\#(sharedID.uuidString)", "kind": "test", "name": "b", "command": "echo b" }
            ]
          }
        }
      }
      """#.utf8)
    let settings = try JSONDecoder().decode(Settings.self, from: payload)
    let entry = try #require(settings.projects[projectID])
    #expect(entry.scripts.count == 2)
    let ids = Set(entry.scripts.map(\.id))
    #expect(ids.count == 2)
  }
}
