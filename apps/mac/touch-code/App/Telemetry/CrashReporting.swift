import Foundation
import Sentry
import TouchCodeCore
import os.log

/// One-shot bootstrap for the Sentry SDK. Called from `TouchCodeApp.init()`
/// so the SDK's Mach-exception + signal handlers install before SwiftUI
/// starts rendering anything that could crash. Behaviour is fully gated:
///
/// * `#if DEBUG` builds never call `SentrySDK.start`, period.
/// * Release builds skip start when `settings.general.crashReportsEnabled`
///   is `false` or `SentryDSN` (read from Info.plist) is missing/empty.
/// * The release name is pinned to `touch-code@<CFBundleShortVersionString>`
///   so the upload-symbols step in `release.sh` can attach dSYMs to the
///   right release for symbolication.
///
/// The actual SDK call surface is small enough that wrapping it in a
/// dedicated namespace pays off mainly for testability: `Configuration`
/// + `isEnabled` are pure functions exercised by unit tests, and the
/// `#if !DEBUG`-gated `bootstrap` is the only function with side
/// effects.
@MainActor
enum CrashReporting {
  /// Inputs needed to start the SDK. Constructed from `Info.plist` so the
  /// DSN flows through `Configurations/Secrets.xcconfig` rather than being
  /// hard-coded in source.
  struct Configuration: Equatable {
    let dsn: String
    let releaseName: String?

    init?(infoDictionary: [String: Any]) {
      guard
        let raw = infoDictionary["SentryDSN"] as? String
      else { return nil }
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      self.dsn = trimmed
      if let version = infoDictionary["CFBundleShortVersionString"] as? String,
        !version.isEmpty
      {
        self.releaseName = "touch-code@\(version)"
      } else {
        self.releaseName = nil
      }
    }
  }

  private static let logger = Logger(subsystem: "com.touch-code.telemetry", category: "crash-reporting")

  /// Pure decision: should the SDK be started given current settings and
  /// build flavour? Split out from `bootstrap` so tests can cover every
  /// combination of inputs without touching the global SDK state.
  static func isEnabled(settings: Settings, isDebugBuild: Bool) -> Bool {
    settings.general.crashReportsEnabled && !isDebugBuild
  }

  /// Start the SDK once. Idempotent — calling twice in the same process
  /// is a no-op past the first invocation (the SDK itself short-circuits
  /// re-init), but the canonical contract is a single call from
  /// `TouchCodeApp.init()`.
  static func bootstrap(settings: Settings, infoDictionary: [String: Any]) {
    #if DEBUG
      return
    #else
      guard isEnabled(settings: settings, isDebugBuild: false) else {
        logger.debug("crash reporting disabled by user setting")
        return
      }
      guard let configuration = Configuration(infoDictionary: infoDictionary) else {
        logger.debug("crash reporting skipped — no DSN baked into this build")
        return
      }
      SentrySDK.start { options in
        options.dsn = configuration.dsn
        options.releaseName = configuration.releaseName
        options.environment = "production"
        // Keep below any plausible free-tier ceiling. Crash + error
        // capture itself is independent of this knob.
        options.tracesSampleRate = 0.05
        // Disabled in v1 — main-thread hang detection on macOS reports
        // a lot of system-induced false positives. Re-evaluate after
        // the baseline is quiet.
        options.enableAppHangTracking = false
        options.sendDefaultPii = false
        options.beforeSend = SystemHangFilter.filter
      }
      SentrySDK.setUser(.init(userId: InstallIdentifier.current))
      logger.info("crash reporting started for \(configuration.releaseName ?? "unknown-release", privacy: .public)")
    #endif
  }

  /// Loads settings from disk specifically for bootstrap, without going
  /// through `SettingsStore` (which is only constructed later in
  /// `AppState.bringUp()`). Failures degrade to `.default` so the
  /// bootstrap never blocks app launch — a malformed settings file
  /// simply means we treat the user as opted-in (the default) on this
  /// launch and `SettingsStore` will surface the migration error
  /// through its own logging shortly after.
  static func loadSettingsForBootstrap() -> Settings {
    let url = Settings.defaultURL()
    guard let data = try? Data(contentsOf: url) else { return .default }
    return (try? JSONDecoder().decode(Settings.self, from: data)) ?? .default
  }
}
