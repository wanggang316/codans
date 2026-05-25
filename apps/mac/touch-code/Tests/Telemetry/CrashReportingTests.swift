import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// Pure-function coverage for `CrashReporting`: the `Configuration` Info.plist
/// parser and the `isEnabled` gate. The side-effecting `bootstrap` is left
/// out because it touches the global Sentry SDK state — its decision branches
/// are exercised here through `isEnabled` + `Configuration` independently.
@MainActor
struct CrashReportingTests {
  @Test func configurationParsesTrimmedDSNAndVersion() {
    let parsed = CrashReporting.Configuration(infoDictionary: [
      "SentryDSN": "  https://abc@o123.ingest.sentry.io/456  ",
      "CFBundleShortVersionString": "0.4.0",
    ])
    #expect(parsed?.dsn == "https://abc@o123.ingest.sentry.io/456")
    #expect(parsed?.releaseName == "touch-code@0.4.0")
  }

  @Test func configurationReturnsNilForMissingDSN() {
    #expect(CrashReporting.Configuration(infoDictionary: [:]) == nil)
  }

  @Test func configurationReturnsNilForEmptyDSN() {
    #expect(CrashReporting.Configuration(infoDictionary: ["SentryDSN": ""]) == nil)
    #expect(CrashReporting.Configuration(infoDictionary: ["SentryDSN": "   \n"]) == nil)
  }

  @Test func configurationOmitsReleaseNameWhenVersionMissing() {
    let parsed = CrashReporting.Configuration(infoDictionary: [
      "SentryDSN": "https://abc@o123.ingest.sentry.io/456"
    ])
    #expect(parsed?.releaseName == nil)
  }

  @Test func isEnabledRequiresUserOptIn() {
    var settings = Settings.default
    settings.general.crashReportsEnabled = false
    #expect(CrashReporting.isEnabled(settings: settings, isDebugBuild: false) == false)
  }

  @Test func isEnabledFalseInDebugBuilds() {
    var settings = Settings.default
    settings.general.crashReportsEnabled = true
    #expect(CrashReporting.isEnabled(settings: settings, isDebugBuild: true) == false)
  }

  @Test func isEnabledTrueOnReleaseWithOptIn() {
    var settings = Settings.default
    settings.general.crashReportsEnabled = true
    #expect(CrashReporting.isEnabled(settings: settings, isDebugBuild: false) == true)
  }
}
