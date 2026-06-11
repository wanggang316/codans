import Foundation
import Testing

@testable import CodansCore

struct NotificationsSettingsCodableTests {
  private let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return e
  }()
  private let decoder = JSONDecoder()

  // MARK: - NotificationsSettings round-trips

  @Test
  func defaultRoundTrip() throws {
    let original = NotificationsSettings.default
    let data = try encoder.encode(original)
    let decoded = try decoder.decode(NotificationsSettings.self, from: data)
    #expect(decoded == original)
  }

  @Test
  func customValueRoundTrip() throws {
    let custom = NotificationsSettings(
      inAppEnabled: false,
      systemEnabled: false,
      soundEnabled: false,
      dockBadgeEnabled: false,
      moveNotifiedWorktreeToTop: false,
      commandFinishedEnabled: false,
      commandFinishedThresholdSec: 42,
      mute: MuteSettings(
        mutedRuleIDs: ["rule.a", "rule.b"],
        mutedPaneIDs: [PaneID(raw: UUID()), PaneID(raw: UUID())]
      )
    )
    let data = try encoder.encode(custom)
    let decoded = try decoder.decode(NotificationsSettings.self, from: data)
    #expect(decoded == custom)
  }

  @Test
  func muteSettingsRoundTrip() throws {
    let paneA = PaneID(raw: UUID())
    let paneB = PaneID(raw: UUID())
    let mute = MuteSettings(
      mutedRuleIDs: ["timeout.long", "git.dirty"],
      mutedPaneIDs: [paneA, paneB]
    )
    let data = try encoder.encode(mute)
    let decoded = try decoder.decode(MuteSettings.self, from: data)
    #expect(decoded == mute)
    #expect(decoded.mutedPaneIDs.contains(paneA))
    #expect(decoded.mutedPaneIDs.contains(paneB))
  }

  // MARK: - Decode with missing fields

  /// A v1.0-shaped settings.json that omits the entire `notifications` key must decode to
  /// a Settings tree whose `notifications` is exactly `.default`.
  @Test
  func missingSectionDecodesToDefault() throws {
    let json = #"{"version":3}"#
    let decoded = try JSONDecoder.touchCodeDefault.decode(Settings.self, from: Data(json.utf8))
    #expect(decoded.notifications == .default)
  }

  /// A NotificationsSettings JSON object that only carries `commandFinishedThresholdSec`
  /// must populate every other field from `.default`.
  @Test
  func decodeIfPresentForEveryField() throws {
    let json = #"{"commandFinishedThresholdSec":30}"#
    let decoded = try decoder.decode(NotificationsSettings.self, from: Data(json.utf8))
    #expect(decoded.commandFinishedThresholdSec == 30)
    #expect(decoded.inAppEnabled == true)
    #expect(decoded.systemEnabled == true)
    #expect(decoded.soundEnabled == true)
    #expect(decoded.dockBadgeEnabled == true)
    #expect(decoded.moveNotifiedWorktreeToTop == true)
    #expect(decoded.commandFinishedEnabled == true)
    #expect(decoded.mute == MuteSettings())
  }

  // MARK: - Threshold clamping

  /// Out-of-range threshold values arriving via raw JSON must be clamped on decode.
  /// We bypass the struct's own clamp-on-init by feeding raw JSON directly.
  @Test
  func outOfRangeThresholdClampsOnDecode() throws {
    let lowJSON = #"{"commandFinishedThresholdSec":0}"#
    let lowDecoded = try decoder.decode(NotificationsSettings.self, from: Data(lowJSON.utf8))
    #expect(lowDecoded.commandFinishedThresholdSec == 1)

    let highJSON = #"{"commandFinishedThresholdSec":10000}"#
    let highDecoded = try decoder.decode(NotificationsSettings.self, from: Data(highJSON.utf8))
    #expect(highDecoded.commandFinishedThresholdSec == 3600)

    let negativeJSON = #"{"commandFinishedThresholdSec":-50}"#
    let negativeDecoded = try decoder.decode(NotificationsSettings.self, from: Data(negativeJSON.utf8))
    #expect(negativeDecoded.commandFinishedThresholdSec == 1)
  }

  /// In-range values pass through unchanged.
  @Test
  func inRangeThresholdSurvives() throws {
    for value in [1, 10, 60, 600, 3600] {
      let json = #"{"commandFinishedThresholdSec":\#(value)}"#
      let decoded = try decoder.decode(NotificationsSettings.self, from: Data(json.utf8))
      #expect(decoded.commandFinishedThresholdSec == value)
    }
  }

  // MARK: - Settings parent integration

  /// The parent Settings document must encode + decode with the notifications section
  /// present and equal across the round-trip.
  @Test
  func settingsRoundTripIncludesNotifications() throws {
    var original = Settings.default
    original.notifications.systemEnabled = false
    original.notifications.commandFinishedThresholdSec = 90
    let data = try JSONEncoder.touchCodeDefault.encode(original)
    let decoded = try JSONDecoder.touchCodeDefault.decode(Settings.self, from: data)
    #expect(decoded.notifications == original.notifications)
  }
}
