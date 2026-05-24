import Foundation
import Testing

@testable import TouchCodeCore

struct SettingsCodableTests {
  @Test
  func defaultTreeRoundTrips() throws {
    let original = Settings.default
    let data = try JSONEncoder.touchCodeDefault.encode(original)
    let decoded = try JSONDecoder.touchCodeDefault.decode(Settings.self, from: data)
    #expect(decoded == original)
    #expect(decoded.version == Settings.currentVersion)
    #expect(decoded.version == 3)
  }

  /// Minimal `{"version":3}` must decode into a fully-populated default tree. Protects
  /// against future accidental removal of the `decodeIfPresent` fallbacks.
  @Test
  func minimalVersionOnlyDecodesToDefaults() throws {
    let data = Data(#"{"version":3}"#.utf8)
    let decoded = try JSONDecoder.touchCodeDefault.decode(Settings.self, from: data)
    #expect(decoded.general == .default)
    #expect(decoded.developer == .default)
    #expect(decoded.projects.isEmpty)
  }

  /// A well-formed tree that carries a parseable and an unparseable `projects` key.
  /// The good key survives; the bad one is logged and dropped; the rest of the file decodes.
  @Test
  func projectsKeyThatIsNotAUUIDIsDropped() throws {
    let uuid = UUID()
    let json = """
      {
        "version": 3,
        "projects": {
          "\(uuid.uuidString)": {},
          "not-a-uuid": {}
        }
      }
      """
    let decoded = try JSONDecoder.touchCodeDefault.decode(Settings.self, from: Data(json.utf8))
    #expect(decoded.projects.count == 1)
    #expect(decoded.projects[ProjectID(raw: uuid)] != nil)
  }

  /// Settings.init(from:) is strict and accepts only version 3; v2 is a supported input but
  /// is handled by SettingsMigration.load, not by the decoder path. v99 is unsupported.
  @Test
  func rejectsUnsupportedVersion() {
    let data = Data(#"{"version":99}"#.utf8)
    #expect(throws: Settings.DecodingIssue.unsupportedVersion(99)) {
      _ = try JSONDecoder.touchCodeDefault.decode(Settings.self, from: data)
    }
  }

  /// The Settings decoder itself rejects version 2 — the v2→v3 fold runs out-of-band
  /// inside SettingsMigration.load, which handles the typed throw and routes through a
  /// dedicated migration path.
  @Test
  func decoderItselfRejectsVersion2() {
    let data = Data(#"{"version":2}"#.utf8)
    #expect(throws: Settings.DecodingIssue.unsupportedVersion(2)) {
      _ = try JSONDecoder.touchCodeDefault.decode(Settings.self, from: data)
    }
  }

  /// `general.quitConfirmation` defaults to `.auto` and `quitAction` to `.keepRunning`
  /// so fresh installs ask only when at least one pane is live and keep daemons running
  /// otherwise — the user's stated mental model.
  @Test
  func quitSettingsDefaultsToAutoAndKeepRunning() {
    #expect(GeneralSettings.default.quitConfirmation == .auto)
    #expect(GeneralSettings.default.quitAction == .keepRunning)
    #expect(Settings.default.general.quitConfirmation == .auto)
    #expect(Settings.default.general.quitAction == .keepRunning)
  }

  /// Encoding and decoding the two orthogonal fields round-trips every combination
  /// (3 × 2 = 6) so the on-disk shape can express every supported configuration.
  @Test
  func quitSettingsRoundTripAllCombinations() throws {
    for confirmation in QuitConfirmation.allCases {
      for action in QuitAction.allCases {
        var original = Settings.default
        original.general.quitConfirmation = confirmation
        original.general.quitAction = action
        let data = try JSONEncoder.touchCodeDefault.encode(original)
        let decoded = try JSONDecoder.touchCodeDefault.decode(Settings.self, from: data)
        #expect(decoded.general.quitConfirmation == confirmation)
        #expect(decoded.general.quitAction == action)
      }
    }
  }

  /// Settings files written before either knob existed must decode to the install
  /// defaults `(.auto, .keepRunning)`.
  @Test
  func quitSettingsMissingKeysDecodeToDefaults() throws {
    let json = """
      {
        "version": 3,
        "general": {
          "appearance": "system"
        }
      }
      """
    let decoded = try JSONDecoder.touchCodeDefault.decode(Settings.self, from: Data(json.utf8))
    #expect(decoded.general.quitConfirmation == .auto)
    #expect(decoded.general.quitAction == .keepRunning)
  }

  /// Legacy `resumePanesOnLaunch: true` migrates to `(.auto, .keepRunning)` so users
  /// who opted into live-resume retain the daemons-survive-quit action with the new
  /// smart-default confirmation behaviour.
  @Test
  func legacyResumePanesOnLaunchTrueMigratesToAutoKeepRunning() throws {
    let json = """
      {
        "version": 3,
        "general": {
          "resumePanesOnLaunch": true
        }
      }
      """
    let decoded = try JSONDecoder.touchCodeDefault.decode(Settings.self, from: Data(json.utf8))
    #expect(decoded.general.quitConfirmation == .auto)
    #expect(decoded.general.quitAction == .keepRunning)
  }

  /// Legacy `resumePanesOnLaunch: false` migrates to `(.auto, .snapshot)` so users
  /// who opted out of live-resume retain the snapshot-on-quit action.
  @Test
  func legacyResumePanesOnLaunchFalseMigratesToAutoSnapshot() throws {
    let json = """
      {
        "version": 3,
        "general": {
          "resumePanesOnLaunch": false
        }
      }
      """
    let decoded = try JSONDecoder.touchCodeDefault.decode(Settings.self, from: Data(json.utf8))
    #expect(decoded.general.quitConfirmation == .auto)
    #expect(decoded.general.quitAction == .snapshot)
  }

  /// Legacy `quitStrategy: "keepRunning"` migrates to `(.never, .keepRunning)`: the prior
  /// single-Picker semantics were "do this without prompting".
  @Test
  func legacyQuitStrategyKeepRunningMigratesToNeverKeepRunning() throws {
    let json = """
      {
        "version": 3,
        "general": {
          "quitStrategy": "keepRunning"
        }
      }
      """
    let decoded = try JSONDecoder.touchCodeDefault.decode(Settings.self, from: Data(json.utf8))
    #expect(decoded.general.quitConfirmation == .never)
    #expect(decoded.general.quitAction == .keepRunning)
  }

  /// Legacy `quitStrategy: "snapshot"` migrates to `(.never, .snapshot)`.
  @Test
  func legacyQuitStrategySnapshotMigratesToNeverSnapshot() throws {
    let json = """
      {
        "version": 3,
        "general": {
          "quitStrategy": "snapshot"
        }
      }
      """
    let decoded = try JSONDecoder.touchCodeDefault.decode(Settings.self, from: Data(json.utf8))
    #expect(decoded.general.quitConfirmation == .never)
    #expect(decoded.general.quitAction == .snapshot)
  }

  /// Legacy `quitStrategy: "ask"` migrates to `(.always, .keepRunning)`: the prior
  /// semantics were "always prompt; default to keepRunning when the user confirmed".
  @Test
  func legacyQuitStrategyAskMigratesToAlwaysKeepRunning() throws {
    let json = """
      {
        "version": 3,
        "general": {
          "quitStrategy": "ask"
        }
      }
      """
    let decoded = try JSONDecoder.touchCodeDefault.decode(Settings.self, from: Data(json.utf8))
    #expect(decoded.general.quitConfirmation == .always)
    #expect(decoded.general.quitAction == .keepRunning)
  }

  /// Verifies `projects` serialises as a JSON object keyed by UUID string, not as the
  /// array-of-pairs layout JSONEncoder falls back to for non-String-keyed dictionaries. This
  /// is the on-disk invariant design §Data Storage relies on for hand-editability.
  @Test
  func projectsSerialiseAsUUIDKeyedObject() throws {
    let id = ProjectID()
    var settings = Settings.default
    // Populate with a non-empty entry so GC doesn't drop it and the encoder keeps the key.
    settings.projects[id] = ProjectSettings(defaultEditor: "vscode")
    let data = try JSONEncoder.touchCodeDefault.encode(settings)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(json.contains("\"\(id.raw.uuidString)\""), "Expected UUID-keyed projects object; got:\n\(json)")
    #expect(json.contains("\"defaultEditor\" : \"vscode\""), "Expected nested defaultEditor; got:\n\(json)")
  }
}
