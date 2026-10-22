import Foundation
import Testing

@testable import CodansCore

struct CloseTabConfirmationTests {
  @Test(arguments: [
    (CloseTabConfirmation.busy, true, true),
    (.busy, false, false),
    (.always, true, true),
    (.always, false, true),
    (.never, true, false),
    (.never, false, false),
  ])
  func promptsPerSettingAndBusyState(setting: CloseTabConfirmation, anyBusy: Bool, expected: Bool) {
    #expect(setting.shouldPrompt(anyBusy: anyBusy) == expected)
  }

  @Test
  func defaultsToBusy() {
    #expect(GeneralSettings.default.closeTabConfirmation == .busy)
  }

  @Test
  func roundTripsEveryCase() throws {
    for value in CloseTabConfirmation.allCases {
      var original = GeneralSettings()
      original.closeTabConfirmation = value
      let data = try JSONEncoder().encode(original)
      let decoded = try JSONDecoder().decode(GeneralSettings.self, from: data)
      #expect(decoded.closeTabConfirmation == value)
    }
  }

  @Test
  func absentOrUnknownValueDecodesToBusy() throws {
    let absent = try JSONDecoder().decode(GeneralSettings.self, from: Data("{}".utf8))
    #expect(absent.closeTabConfirmation == .busy)
    let unknown = try JSONDecoder().decode(
      GeneralSettings.self, from: Data(#"{"closeTabConfirmation":"sometimes"}"#.utf8))
    #expect(unknown.closeTabConfirmation == .busy)
  }
}
