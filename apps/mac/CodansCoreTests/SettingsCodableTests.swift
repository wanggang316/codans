import Foundation
import Testing

@testable import CodansCore

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

/// `WorktreeSettings.autoSwitchToNewWorktree` is a GLOBAL Bool that defaults to `true`
/// and is omitted from the encoded JSON when at its default — so a fresh `settings.json`
/// carries no key (absent == ON). The key is written ONLY when the user turns it off.
struct WorktreeAutoSwitchCodableTests {
  private func encodedJSON(_ worktree: WorktreeSettings) throws -> String {
    let data = try JSONEncoder.touchCodeDefault.encode(worktree)
    return try #require(String(data: data, encoding: .utf8))
  }

  /// Default value is `true`, and at the default the key is ABSENT from the encoded JSON.
  @Test
  func defaultIsOnAndKeyOmittedWhenDefault() throws {
    let worktree = WorktreeSettings.default
    #expect(worktree.autoSwitchToNewWorktree == true)
    let json = try encodedJSON(worktree)
    #expect(
      !json.contains("autoSwitchToNewWorktree"),
      "Expected key omitted at default; got:\n\(json)"
    )
  }

  /// `false` round-trips and writes the key.
  @Test
  func falseRoundTripsAndWritesKey() throws {
    var worktree = WorktreeSettings.default
    worktree.autoSwitchToNewWorktree = false
    let json = try encodedJSON(worktree)
    #expect(
      json.contains("\"autoSwitchToNewWorktree\" : false"),
      "Expected key written when false; got:\n\(json)"
    )
    let data = try JSONEncoder.touchCodeDefault.encode(worktree)
    let decoded = try JSONDecoder.touchCodeDefault.decode(WorktreeSettings.self, from: data)
    #expect(decoded.autoSwitchToNewWorktree == false)
  }

  /// A JSON missing the key decodes to `true` (absent == ON).
  @Test
  func missingKeyDecodesToOn() throws {
    let data = Data(#"{}"#.utf8)
    let decoded = try JSONDecoder.touchCodeDefault.decode(WorktreeSettings.self, from: data)
    #expect(decoded.autoSwitchToNewWorktree == true)
  }

  /// Toggling `false` → `true` re-omits the key — no residue from the earlier off-state.
  @Test
  func togglingBackOnReOmitsKey() throws {
    var worktree = WorktreeSettings.default
    worktree.autoSwitchToNewWorktree = false
    worktree.autoSwitchToNewWorktree = true
    let json = try encodedJSON(worktree)
    #expect(
      !json.contains("autoSwitchToNewWorktree"),
      "Expected key re-omitted after toggling back on; got:\n\(json)"
    )
  }
}

/// `WorktreeSettings.branchConflictResolution` — lenient-decoded enum that falls back to
/// `.rename` for absent, unknown, or mis-cased raw values without throwing.
///
/// The lenient decode path reads a raw `String` and maps it through `init(rawValue:)` so
/// a future unknown value cannot corrupt the entire `WorktreeSettings` decode.
struct BranchConflictResolutionCodableTests {
  private let decoder = JSONDecoder.touchCodeDefault
  private let encoder = JSONEncoder.touchCodeDefault

  /// Decode a `WorktreeSettings` from a plain `[String: Any]` dict so tests are
  /// agnostic to the encoding shape of unrelated keys.
  private func decode(from dict: [String: Any]) throws -> WorktreeSettings {
    let data = try JSONSerialization.data(withJSONObject: dict)
    return try decoder.decode(WorktreeSettings.self, from: data)
  }

  private func encodedDict(_ worktree: WorktreeSettings) throws -> [String: Any] {
    let data = try encoder.encode(worktree)
    return try #require(
      try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
  }

  // MARK: Round-trip

  /// `.reuse` survives encode → decode.
  @Test
  func reuseRoundTrips() throws {
    var worktree = WorktreeSettings.default
    worktree.branchConflictResolution = .reuse
    let data = try encoder.encode(worktree)
    let decoded = try decoder.decode(WorktreeSettings.self, from: data)
    #expect(decoded.branchConflictResolution == .reuse)
  }

  /// `.recreate` survives encode → decode.
  @Test
  func recreateRoundTrips() throws {
    var worktree = WorktreeSettings.default
    worktree.branchConflictResolution = .recreate
    let data = try encoder.encode(worktree)
    let decoded = try decoder.decode(WorktreeSettings.self, from: data)
    #expect(decoded.branchConflictResolution == .recreate)
  }

  // MARK: Absent key

  /// A `settings.json` that has no `branchConflictResolution` key decodes to `.rename`.
  @Test
  func missingKeyDecodesToRename() throws {
    let result = try decode(from: [:])
    #expect(result.branchConflictResolution == .rename)
  }

  // MARK: Omit-when-default

  /// Encoding `.rename` omits the key entirely so the settings file stays minimal.
  @Test
  func renameIsOmittedFromEncoding() throws {
    let worktree = WorktreeSettings.default  // branchConflictResolution == .rename
    let dict = try encodedDict(worktree)
    #expect(
      dict["branchConflictResolution"] == nil,
      "Expected key absent for default .rename; got:\n\(dict)"
    )
  }

  // MARK: Lenient decode — unknown raw value

  /// An unknown raw value (`"destroy"`) decodes to `.rename` WITHOUT throwing, and a
  /// sibling key present in the same dict is preserved after the decode.
  @Test
  func unknownRawValueDecodesToRenameWithoutThrowing() throws {
    let result = try decode(from: [
      "branchConflictResolution": "destroy",
      "fetchRemoteOnCreate": false,
    ])
    #expect(result.branchConflictResolution == .rename, "Expected .rename fallback for unknown raw value")
    // The sibling key must survive — the decode must not have thrown and been caught externally.
    #expect(result.fetchRemoteOnCreate == false, "Expected sibling key preserved after lenient decode")
  }

  // MARK: Lenient decode — mis-cased value

  /// A mis-cased value (`"Reuse"`) decodes to `.rename` without throwing because the raw
  /// value match is case-sensitive and `"Reuse"` != `"reuse"`.
  @Test
  func misCasedValueDecodesToRenameWithoutThrowing() throws {
    let result = try decode(from: ["branchConflictResolution": "Reuse"])
    #expect(result.branchConflictResolution == .rename, "Expected .rename fallback for mis-cased raw value")
  }
}
