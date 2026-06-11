import Foundation

/// User-selectable cadence for Sparkle's background update check. Independent of
/// `UpdateChannel`: the channel decides which appcast items match, this knob decides how
/// often we poll. Persisted in `GeneralSettings.updateCheckInterval` and pushed to
/// `SPUUpdater.updateCheckInterval` on every `UpdatesClient.applyPreferences(...)`.
public nonisolated enum UpdateCheckInterval: Int, Codable, CaseIterable, Sendable {
  case threeHours = 3
  case sixHours = 6
  case twelveHours = 12
  case oneDay = 24
  case twoDays = 48
  case threeDays = 72

  public var hours: Int { rawValue }

  public var seconds: TimeInterval { TimeInterval(rawValue) * 3600 }
}
