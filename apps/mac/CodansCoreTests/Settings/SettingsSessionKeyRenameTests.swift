import Foundation
import Testing

@testable import CodansCore

/// Session-scoped settings keys follow the Tab vocabulary:
/// `notifications.mute.mutedPaneIDs` → `mutedContentIDs` and the
/// `ScriptOnFinished` token `closePane` → `closeTab`. A v3 file written
/// with the former names loads through `SettingsMigration` with every value
/// kept, and the next save writes only the new names.
struct SettingsSessionKeyRenameTests {
  @Test
  func formerSessionKeysLoadOnceAndSaveUnderTheNewNames() throws {
    let harness = RenameHarness()
    defer { harness.cleanup() }

    let mutedContent = UUID()
    let projectUUID = UUID()
    let scriptUUID = UUID()
    let json = """
      {
        "version": 3,
        "notifications": {
          "mute": {
            "mutedRuleIDs": ["git.dirty"],
            "mutedPaneIDs": [{"raw": "\(mutedContent.uuidString)"}]
          }
        },
        "projects": {
          "\(projectUUID.uuidString)": {
            "scripts": [
              {
                "id": "\(scriptUUID.uuidString)",
                "command": "make test",
                "target": "split",
                "direction": "down",
                "onFinished": "closePane"
              }
            ]
          }
        }
      }
      """
    try Data(json.utf8).write(to: harness.fileURL)

    let outcome = try SettingsMigration.load(from: harness.fileURL, clock: harness.clock)
    guard case .v3(let settings) = outcome else {
      Issue.record("Expected .v3, got \(outcome)")
      return
    }
    #expect(settings.notifications.mute.mutedContentIDs == [ContentID(raw: mutedContent)])
    #expect(settings.notifications.mute.mutedRuleIDs == ["git.dirty"])
    let script = try #require(settings.projects[ProjectID(raw: projectUUID)]?.scripts.first)
    #expect(script.onFinished == .closeTab)
    #expect(script.resolvedOnFinished == .closeTab)

    try AtomicFileStore.write(settings, to: harness.fileURL)
    let written = try String(contentsOf: harness.fileURL, encoding: .utf8)
    #expect(written.contains("mutedContentIDs"))
    #expect(!written.contains("mutedPaneIDs"))
    #expect(written.contains("closeTab"))
    #expect(!written.contains("closePane"))

    let reloaded = try SettingsMigration.load(from: harness.fileURL, clock: harness.clock)
    guard case .v3(let readBack) = reloaded else {
      Issue.record("Expected .v3 on reload, got \(reloaded)")
      return
    }
    #expect(readBack == settings)
  }

  /// When both spellings are present the new key wins: it is the one the
  /// app wrote last.
  @Test
  func newMuteKeyWinsOverTheFormerOne() throws {
    let current = UUID()
    let json = """
      {
        "mutedContentIDs": [{"raw": "\(current.uuidString)"}],
        "mutedPaneIDs": [{"raw": "\(UUID().uuidString)"}]
      }
      """
    let mute = try JSONDecoder().decode(MuteSettings.self, from: Data(json.utf8))
    #expect(mute.mutedContentIDs == [ContentID(raw: current)])
  }
}

private final class RenameHarness {
  let directory: URL
  var fileURL: URL { directory.appendingPathComponent("settings.json", isDirectory: false) }
  let clock: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_777_190_400) }

  init() {
    self.directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SettingsSessionKeyRenameTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: directory)
  }
}
