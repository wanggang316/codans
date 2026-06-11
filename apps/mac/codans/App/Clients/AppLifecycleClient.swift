import AppKit
import ComposableArchitecture
import Foundation

/// TCA bridge over the app-termination path. The `WindowActionRouterFeature`
/// dispatches `.quit` (user-initiated) through `requestQuit` and
/// `.closeAll` through `terminate`; keeping the two seams distinct lets a
/// future quit-confirmation presenter interpose on `requestQuit` without
/// the hard `terminate` callers (e.g. an IPC `system.shutdown` handler)
/// accidentally going through that flow.
///
/// `NSApp.terminate(_:)` routes through `NSApplicationDelegate`'s
/// `applicationShouldTerminate(_:)`; `AppDelegate` in `CodansApp.swift`
/// does not override that, so both closures terminate immediately. The
/// two-closure shape is forward-compatible with a future override that
/// distinguishes user-initiated from caller-initiated quits.
nonisolated struct AppLifecycleClient: Sendable {
  /// User-initiated quit. Today calls `NSApp.terminate(nil)` directly —
  /// no confirmation surface; if one is reintroduced it should hook in
  /// here, leaving `terminate` as the unconditional escape hatch.
  var requestQuit: @MainActor @Sendable () -> Void
  /// Unconditional terminate. Use only after a confirmation path has
  /// already run, or when the caller is non-user-facing.
  var terminate: @MainActor @Sendable () -> Void
}

extension AppLifecycleClient: DependencyKey {
  static let liveValue = AppLifecycleClient(
    requestQuit: {
      NSApp.terminate(nil)
    },
    terminate: {
      NSApp.terminate(nil)
    }
  )

  static let testValue = AppLifecycleClient(
    requestQuit: unimplemented("AppLifecycleClient.requestQuit"),
    terminate: unimplemented("AppLifecycleClient.terminate")
  )
}

extension DependencyValues {
  var appLifecycleClient: AppLifecycleClient {
    get { self[AppLifecycleClient.self] }
    set { self[AppLifecycleClient.self] = newValue }
  }
}
