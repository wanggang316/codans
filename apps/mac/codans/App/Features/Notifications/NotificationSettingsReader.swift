import Combine
import Foundation
import Observation
import CodansCore

/// Read-only surface that the future `NotificationCoordinator` (M2.T2) binds
/// against: the current `NotificationsSettings` snapshot plus the cached
/// `AuthorizationStatus`, together with a single `onChange` fan-out that
/// fires whenever either input shifts.
///
/// Splitting the surface from `SettingsStore` keeps the coordinator testable
/// against a hand-rolled fake (`FakeNotificationSettingsReader`) without
/// having to stand up a live settings file or `UNUserNotificationCenter`.
@MainActor
protocol NotificationSettingsReader: AnyObject {
  var notifications: NotificationsSettings { get }
  var authStatus: AuthorizationStatus { get }
  /// Fires whenever `notifications` or `authStatus` changes. Returns a
  /// `Cancellable`-shaped token whose cancellation or deallocation
  /// removes the handler.
  func onChange(_ handler: @escaping @MainActor () -> Void) -> AnyCancellable
}

/// Production adapter: `notifications` reads through to `SettingsStore`
/// every call (the store is `@Observable`, so a `withObservationTracking`
/// re-arm gives us change notifications); `authStatus` is cached because
/// `OSNotifier.currentAuthorizationStatus()` is `async` and the coordinator
/// needs sync reads on its hot path. The bringup site (M2.T2) is expected
/// to invoke `refresh()` at app start and on `applicationDidBecomeActive`.
@MainActor
final class SettingsStoreReaderAdapter: NotificationSettingsReader {
  private let settingsStore: SettingsStore
  private let osNotifier: OSNotifier
  private(set) var authStatus: AuthorizationStatus = .notDetermined
  private var handlers: [UUID: @MainActor () -> Void] = [:]

  init(settingsStore: SettingsStore, osNotifier: OSNotifier) {
    self.settingsStore = settingsStore
    self.osNotifier = osNotifier
    // `init` does NOT await `osNotifier.currentAuthorizationStatus()` — the
    // call is async and we cannot block synchronous construction. The
    // cached value starts at `.notDetermined`; M2.T2's bringup site fires
    // `refresh()` at app start and on `applicationDidBecomeActive`.
    subscribeNext()
  }

  var notifications: NotificationsSettings {
    settingsStore.settings.notifications
  }

  func onChange(_ handler: @escaping @MainActor () -> Void) -> AnyCancellable {
    let id = UUID()
    handlers[id] = handler
    return AnyCancellable { [weak self] in
      Task { @MainActor [weak self] in
        self?.handlers.removeValue(forKey: id)
      }
    }
  }

  /// Re-reads `await osNotifier.currentAuthorizationStatus()` and updates
  /// the cached value, firing any registered `onChange` handlers if the
  /// value changed. M2.T2's bringup site wires this to fire on
  /// `applicationDidBecomeActive` and at app start.
  func refresh() async {
    let next = await osNotifier.currentAuthorizationStatus()
    guard next != authStatus else { return }
    authStatus = next
    fireHandlers()
  }

  // MARK: - Internals

  /// Arms a `withObservationTracking` registration that fires once when any
  /// observed property of `settingsStore.settings.notifications` mutates,
  /// then re-arms itself on the MainActor. Matches the re-arming pattern
  /// used by `RollupIndexProvider` / `HierarchyClient`. The closure is
  /// `[weak self]` because the adapter is `@MainActor final class` and
  /// must not retain itself through the Observation token.
  private func subscribeNext() {
    // Order is fire-then-rearm rather than `RollupIndexProvider`'s
    // rearm-first pattern. This adapter only fans out — it does not derive
    // any cached state from `notifications` — so a mutation landing in the
    // fire-to-rearm gap means at most one missed `onChange` tick;
    // handlers re-reading `notifications` still see the settled value.
    // The derived-state correctness argument that motivates rearm-first
    // in `RollupIndexProvider` (its `recompute` must observe the final
    // settled snapshot) does not apply here.
    withObservationTracking {
      _ = settingsStore.settings.notifications
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.fireHandlers()
        self.subscribeNext()
      }
    }
  }

  private func fireHandlers() {
    for handler in handlers.values {
      handler()
    }
  }
}
