import ComposableArchitecture
import UIKit

/// A UIKit background task: extra running time after every scene went to
/// the background, so a quick app switch finds the connection still open.
nonisolated struct BackgroundTaskClient: Sendable {
  /// Begins a background task. `onExpire` runs if iOS takes the time back
  /// before `end` is called. Returns a token for `end`.
  var begin: @Sendable (_ name: String, _ onExpire: @escaping @Sendable () -> Void) async -> Int
  var end: @Sendable (_ token: Int) async -> Void
}

nonisolated extension BackgroundTaskClient: DependencyKey {
  static let liveValue = BackgroundTaskClient(
    begin: { name, onExpire in
      await MainActor.run {
        UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: onExpire).rawValue
      }
    },
    end: { token in
      await MainActor.run {
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token))
      }
    }
  )

  /// Holding a background task has no observable effect in a test; the
  /// grace timer itself runs on the injected clock.
  static let testValue = BackgroundTaskClient(begin: { _, _ in 0 }, end: { _ in })
}

nonisolated extension DependencyValues {
  var backgroundTask: BackgroundTaskClient {
    get { self[BackgroundTaskClient.self] }
    set { self[BackgroundTaskClient.self] = newValue }
  }
}
