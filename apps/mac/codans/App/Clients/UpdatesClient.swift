import ComposableArchitecture
import Foundation
import Sparkle
import CodansCore
import os.log

/// TCA seam for the Updates feature. Wraps Sparkle's
/// `SPUStandardUpdaterController` so feature code can apply persisted
/// preferences and trigger a manual check without importing Sparkle. The
/// controller itself lives in `UpdatesEnvironment` so the Settings pane
/// shares a single instance instead of standing up a parallel one.
///
/// `applyPreferences` is the single sync point from `SettingsStore` to
/// Sparkle: invoked once on app bringup with the persisted values, and
/// again on every settings change so the running Sparkle instance stays
/// aligned with `settings.json`.
nonisolated struct UpdatesClient: Sendable {
  /// Push the persisted Updates preferences to the live `SPUUpdater`.
  /// `triggerBackgroundCheck` is `true` only on the very first call after
  /// launch (or after the user enables auto-checks while the app is
  /// running) so flipping the channel does not spam the appcast endpoint
  /// with redundant probes.
  var applyPreferences:
    @MainActor @Sendable (
      _ channel: UpdateChannel,
      _ interval: UpdateCheckInterval,
      _ automaticallyChecks: Bool,
      _ automaticallyDownloads: Bool,
      _ triggerBackgroundCheck: Bool
    ) -> Void
  /// Manual "Check for Updates…" action — surfaces Sparkle's modal flow
  /// regardless of the auto-check setting.
  var checkNow: @MainActor @Sendable () -> Void
}

extension UpdatesClient: DependencyKey {
  private static let logger = Logger(subsystem: "com.gumpw.codans.ui", category: "updates")

  static let liveValue = UpdatesClient(
    applyPreferences: { channel, interval, automaticallyChecks, automaticallyDownloads, triggerBackgroundCheck in
      let updater = UpdatesEnvironment.updater
      UpdatesEnvironment.delegate.setChannel(channel)
      updater.automaticallyChecksForUpdates = automaticallyChecks
      updater.automaticallyDownloadsUpdates = automaticallyDownloads
      updater.updateCheckInterval = interval.seconds
      logger.info(
        "applyPreferences: channel=\(channel.rawValue, privacy: .public) interval=\(interval.hours)h checks=\(automaticallyChecks) downloads=\(automaticallyDownloads) bgCheck=\(triggerBackgroundCheck)"
      )
      if triggerBackgroundCheck, automaticallyChecks {
        updater.checkForUpdatesInBackground()
      }
    },
    checkNow: {
      logger.info("checkForUpdates triggered")
      UpdatesEnvironment.updater.checkForUpdates()
    }
  )

  static let testValue = UpdatesClient(
    applyPreferences: unimplemented("UpdatesClient.applyPreferences"),
    checkNow: unimplemented("UpdatesClient.checkNow")
  )
}

extension DependencyValues {
  var updatesClient: UpdatesClient {
    get { self[UpdatesClient.self] }
    set { self[UpdatesClient.self] = newValue }
  }
}
