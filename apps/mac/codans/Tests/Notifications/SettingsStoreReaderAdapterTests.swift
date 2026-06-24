import Foundation
import Testing
import CodansCore

@testable import Codans

/// Plumbing-only tests for `SettingsStoreReaderAdapter`. Here we only
/// verify the read-through, observation fan-out, cancellation, and the
/// async `refresh()` cache.
@MainActor
struct SettingsStoreReaderAdapterTests {
  private func makeStore() -> (SettingsStore, URL) {
    let url = FileManager.default.temporaryDirectory.appending(
      component: "settings-reader-adapter-\(UUID().uuidString).json"
    )
    return (SettingsStore(fileURL: url), url)
  }

  /// Yields the MainActor a few times so a `withObservationTracking`
  /// `onChange` (which schedules a `Task { @MainActor in ... }`) has a
  /// chance to fire before we assert. One yield is usually enough; the
  /// loop is cheap insurance against scheduler jitter.
  private func awaitObservationFlush() async {
    for _ in 0..<5 { await Task.yield() }
  }

  @Test
  func readsThroughToSettingsStoreNotifications() throws {
    let (store, url) = makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    let adapter = SettingsStoreReaderAdapter(settingsStore: store, osNotifier: notifier)

    #expect(adapter.notifications == store.settings.notifications)

    store.mutateNotifications { $0.inAppEnabled = false }

    #expect(adapter.notifications.inAppEnabled == false)
    #expect(adapter.notifications == store.settings.notifications)
  }

  @Test
  func onChangeFiresOnSettingsStoreMutation() async throws {
    let (store, url) = makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    let adapter = SettingsStoreReaderAdapter(settingsStore: store, osNotifier: notifier)

    var counter = 0
    let token = adapter.onChange { counter += 1 }

    store.mutateNotifications { $0.systemEnabled = false }
    await awaitObservationFlush()

    #expect(counter == 1)
    _ = token  // keep the cancellable alive until the assertion
  }

  @Test
  func onChangeHandlerRemovedOnCancel() async throws {
    let (store, url) = makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    let adapter = SettingsStoreReaderAdapter(settingsStore: store, osNotifier: notifier)

    var counter = 0
    let token = adapter.onChange { counter += 1 }
    token.cancel()
    // Cancellation removal is dispatched via a MainActor Task; give it a
    // turn before mutating so the handler is gone by the time observation
    // would fire.
    await awaitObservationFlush()

    store.mutateNotifications { $0.dockBadgeEnabled = false }
    await awaitObservationFlush()

    #expect(counter == 0)
  }

  @Test
  func authStatusCachedAndRefreshPicksUpChanges() async throws {
    let (store, url) = makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    notifier.status = .notDetermined
    let adapter = SettingsStoreReaderAdapter(settingsStore: store, osNotifier: notifier)

    #expect(adapter.authStatus == .notDetermined)

    var counter = 0
    let token = adapter.onChange { counter += 1 }

    notifier.status = .authorized
    await adapter.refresh()

    #expect(adapter.authStatus == .authorized)
    #expect(counter == 1)
    _ = token
  }

  @Test
  func multipleHandlersAllFireOnMutation() async throws {
    let (store, url) = makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    let adapter = SettingsStoreReaderAdapter(settingsStore: store, osNotifier: notifier)

    var counterA = 0
    var counterB = 0
    let tokenA = adapter.onChange { counterA += 1 }
    let tokenB = adapter.onChange { counterB += 1 }

    store.mutateNotifications { $0.soundEnabled = false }
    await awaitObservationFlush()

    #expect(counterA == 1)
    #expect(counterB == 1)
    _ = (tokenA, tokenB)
  }
}
