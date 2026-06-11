import AppKit
import Foundation

/// The single macOS Launch Services / NSWorkspace seam used by `EditorService`. All production
/// launches and bundle-ID resolutions go through this protocol; tests inject a recording
/// double to verify `(appURL, urls, configuration.arguments, configuration.createsNewApplicationInstance)`
/// tuples without ever touching `NSWorkspace`.
///
/// This is the only place `NSWorkspace` is imported outside test code (see design doc
/// §Component Boundaries).
protocol AppLauncher: Sendable {
  /// Resolves a bundle identifier to a `.app` URL via Launch Services, or `nil` if no
  /// matching bundle is registered on the current system. Matches
  /// `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` semantics.
  func urlForApplication(bundleIdentifier: String) -> URL?

  /// Launches the application at `appURL` with the given `urls` and configuration. Wraps
  /// `NSWorkspace.shared.open(_:withApplicationAt:configuration:completionHandler:)`.
  ///
  /// The live implementation bridges the completion-handler API into Swift concurrency via
  /// `withCheckedThrowingContinuation`; the continuation resumes exactly once (Risk R6 in the
  /// design doc). On error, throws the underlying `NSError`.
  func open(
    urls: [URL],
    withApplicationAt appURL: URL,
    configuration: NSWorkspace.OpenConfiguration
  ) async throws

  /// Launches the application at `appURL` with no URL arguments, forwarding
  /// `configuration.arguments` to the freshly-launched process. Wraps
  /// `NSWorkspace.shared.openApplication(at:configuration:completionHandler:)`.
  ///
  /// `.applicationWithArguments` (JetBrains IDEs) routes through here: `open(urls:…)` with
  /// an empty URL list is undefined and does not deliver `configuration.arguments` to the
  /// target app. Using this API instead guarantees `arguments` reach the launched process's
  /// `main(argc:argv:)`.
  func openApplication(
    at appURL: URL,
    configuration: NSWorkspace.OpenConfiguration
  ) async throws
}

/// Production `AppLauncher`. Thin facade over `NSWorkspace.shared` — no caching (Launch
/// Services already caches) and no business logic.
struct LiveAppLauncher: AppLauncher {
  func urlForApplication(bundleIdentifier: String) -> URL? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
  }

  func open(
    urls: [URL],
    withApplicationAt appURL: URL,
    configuration: NSWorkspace.OpenConfiguration
  ) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      NSWorkspace.shared.open(
        urls,
        withApplicationAt: appURL,
        configuration: configuration
      ) { _, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  func openApplication(
    at appURL: URL,
    configuration: NSWorkspace.OpenConfiguration
  ) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      NSWorkspace.shared.openApplication(
        at: appURL,
        configuration: configuration
      ) { _, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }
}
