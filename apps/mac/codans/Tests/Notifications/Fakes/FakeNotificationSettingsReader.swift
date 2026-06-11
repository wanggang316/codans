import Combine
import Foundation
import CodansCore

@testable import Codans

/// In-memory `NotificationSettingsReader` for unit tests. Will be consumed
/// by M2.T2's `NotificationCoordinator` test suite to drive coordinator
/// behaviour deterministically without touching SettingsStore or OSNotifier.
@MainActor
final class FakeNotificationSettingsReader: NotificationSettingsReader {
  var notifications: NotificationsSettings = .default
  var authStatus: AuthorizationStatus = .authorized
  private var handlers: [UUID: @MainActor () -> Void] = [:]

  func onChange(_ handler: @escaping @MainActor () -> Void) -> AnyCancellable {
    let id = UUID()
    handlers[id] = handler
    return AnyCancellable { [weak self] in
      Task { @MainActor [weak self] in
        self?.handlers.removeValue(forKey: id)
      }
    }
  }

  /// Test-only: fire all handlers (mirrors what real change-tracking would
  /// do when `notifications` or `authStatus` mutates).
  func fireChange() {
    for handler in handlers.values { handler() }
  }
}
