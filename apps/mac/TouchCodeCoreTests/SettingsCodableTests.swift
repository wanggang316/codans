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

  /// `general.resumePanesOnLaunch` defaults to `true` so unconfigured users land on the
  /// M2 live-resume tier; the M3 snapshot-quit path only engages when the user opts out.
  @Test
  func resumePanesOnLaunchDefaultsToTrue() {
    #expect(GeneralSettings.default.resumePanesOnLaunch == true)
    #expect(Settings.default.general.resumePanesOnLaunch == true)
  }

  /// Encoding and decoding the field round-trips both states.
  @Test
  func resumePanesOnLaunchRoundTrips() throws {
    for value in [true, false] {
      var original = Settings.default
      original.general.resumePanesOnLaunch = value
      let data = try JSONEncoder.touchCodeDefault.encode(original)
      let decoded = try JSONDecoder.touchCodeDefault.decode(Settings.self, from: data)
      #expect(decoded.general.resumePanesOnLaunch == value)
    }
  }

  /// Settings files written before this field existed must decode with `resumePanesOnLaunch`
  /// defaulted to `true` — the M3 toggle is opt-out, not opt-in.
  @Test
  func resumePanesOnLaunchMissingKeyDecodesToTrue() throws {
    let json = """
      {
        "version": 3,
        "general": {
          "appearance": "system"
        }
      }
      """
    let decoded = try JSONDecoder.touchCodeDefault.decode(Settings.self, from: Data(json.utf8))
    #expect(decoded.general.resumePanesOnLaunch == true)
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
