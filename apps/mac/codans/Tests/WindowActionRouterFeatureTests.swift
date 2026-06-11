import ComposableArchitecture
import Foundation
import Testing
import CodansCore

@testable import Codans

/// TestStore coverage for every `WindowActionRequest` arm of
/// `WindowActionRouterFeature`. The reducer is a pure fan-out over
/// `WindowService`, `AppLifecycleClient`, and `UpdatesClient`, so each test
/// stubs the relevant closure and asserts the matching call.
///
/// `.openConfig` hits `NSWorkspace.shared.open(_:)` directly — there's no
/// observable seam to stub, so the assertion is limited to "send does not
/// crash and does not route into any client under test". Recorded as a
/// deliberate simplification (see Decision Log note in milestone report).
@MainActor
struct WindowActionRouterFeatureTests {
  // MARK: - new / close / closeAll

  @Test
  func newCallsOpenNewWindowWithSourcePane() async {
    let paneID = PaneID()
    let recorded = LockIsolated<PaneID?>(nil)
    let store = TestStore(initialState: WindowActionRouterFeature.State()) {
      WindowActionRouterFeature()
    } withDependencies: {
      $0.windowService = WindowService.testValue
      $0.windowService.openNewWindow = { recorded.setValue($0) }
      $0.appLifecycleClient = AppLifecycleClient.testValue
      $0.updatesClient = UpdatesClient.testValue
    }

    await store.send(.requested(.new(from: paneID)))
    #expect(recorded.value == paneID)
  }

  @Test
  func closeCallsCloseWindowWithSourcePane() async {
    let paneID = PaneID()
    let recorded = LockIsolated<PaneID?>(nil)
    let store = TestStore(initialState: WindowActionRouterFeature.State()) {
      WindowActionRouterFeature()
    } withDependencies: {
      $0.windowService = WindowService.testValue
      $0.windowService.closeWindow = { recorded.setValue($0) }
      $0.appLifecycleClient = AppLifecycleClient.testValue
      $0.updatesClient = UpdatesClient.testValue
    }

    await store.send(.requested(.close(from: paneID)))
    #expect(recorded.value == paneID)
  }

  @Test
  func closeAllCallsAppLifecycleTerminate() async {
    let terminated = LockIsolated(false)
    let quitRequested = LockIsolated(false)
    let store = TestStore(initialState: WindowActionRouterFeature.State()) {
      WindowActionRouterFeature()
    } withDependencies: {
      $0.windowService = WindowService.testValue
      $0.appLifecycleClient = AppLifecycleClient.testValue
      $0.appLifecycleClient.terminate = { terminated.setValue(true) }
      $0.appLifecycleClient.requestQuit = { quitRequested.setValue(true) }
      $0.updatesClient = UpdatesClient.testValue
    }

    await store.send(.requested(.closeAll))
    #expect(terminated.value == true)
    // closeAll must NOT route through requestQuit — the two seams are
    // kept distinct so future confirmation dialogs can interpose on
    // requestQuit without catching IPC-originated terminates.
    #expect(quitRequested.value == false)
  }

  // MARK: - goto

  @Test
  func gotoCallsActivateWindowWithTarget() async {
    let recorded = LockIsolated<GotoWindowTarget?>(nil)
    let store = TestStore(initialState: WindowActionRouterFeature.State()) {
      WindowActionRouterFeature()
    } withDependencies: {
      $0.windowService = WindowService.testValue
      $0.windowService.activateWindow = { recorded.setValue($0) }
      $0.appLifecycleClient = AppLifecycleClient.testValue
      $0.updatesClient = UpdatesClient.testValue
    }

    await store.send(.requested(.goto(target: .previous)))
    #expect(recorded.value == .previous)
  }

  // MARK: - toggle* family

  @Test
  func toggleFullscreenCallsWindowServiceToggleFullscreen() async {
    let paneID = PaneID()
    let recorded = LockIsolated<PaneID?>(nil)
    let store = TestStore(initialState: WindowActionRouterFeature.State()) {
      WindowActionRouterFeature()
    } withDependencies: {
      $0.windowService = WindowService.testValue
      $0.windowService.toggleFullscreen = { recorded.setValue($0) }
      $0.appLifecycleClient = AppLifecycleClient.testValue
      $0.updatesClient = UpdatesClient.testValue
    }

    await store.send(.requested(.toggleFullscreen(from: paneID)))
    #expect(recorded.value == paneID)
  }

  @Test
  func toggleMaximizeCallsWindowServiceToggleMaximize() async {
    let paneID = PaneID()
    let recorded = LockIsolated<PaneID?>(nil)
    let store = TestStore(initialState: WindowActionRouterFeature.State()) {
      WindowActionRouterFeature()
    } withDependencies: {
      $0.windowService = WindowService.testValue
      $0.windowService.toggleMaximize = { recorded.setValue($0) }
      $0.appLifecycleClient = AppLifecycleClient.testValue
      $0.updatesClient = UpdatesClient.testValue
    }

    await store.send(.requested(.toggleMaximize(from: paneID)))
    #expect(recorded.value == paneID)
  }

  @Test
  func toggleTabOverviewCallsWindowServiceToggleTabOverview() async {
    let paneID = PaneID()
    let recorded = LockIsolated<PaneID?>(nil)
    let store = TestStore(initialState: WindowActionRouterFeature.State()) {
      WindowActionRouterFeature()
    } withDependencies: {
      $0.windowService = WindowService.testValue
      $0.windowService.toggleTabOverview = { recorded.setValue($0) }
      $0.appLifecycleClient = AppLifecycleClient.testValue
      $0.updatesClient = UpdatesClient.testValue
    }

    await store.send(.requested(.toggleTabOverview(from: paneID)))
    #expect(recorded.value == paneID)
  }

  @Test
  func toggleAppVisibilityCallsWindowServiceToggleAppVisibility() async {
    let called = LockIsolated(0)
    let store = TestStore(initialState: WindowActionRouterFeature.State()) {
      WindowActionRouterFeature()
    } withDependencies: {
      $0.windowService = WindowService.testValue
      $0.windowService.toggleAppVisibility = { called.withValue { $0 += 1 } }
      $0.appLifecycleClient = AppLifecycleClient.testValue
      $0.updatesClient = UpdatesClient.testValue
    }

    await store.send(.requested(.toggleAppVisibility))
    #expect(called.value == 1)
  }

  // MARK: - quit

  @Test
  func quitCallsAppLifecycleRequestQuit() async {
    let quitRequested = LockIsolated(false)
    let terminated = LockIsolated(false)
    let store = TestStore(initialState: WindowActionRouterFeature.State()) {
      WindowActionRouterFeature()
    } withDependencies: {
      $0.windowService = WindowService.testValue
      $0.appLifecycleClient = AppLifecycleClient.testValue
      $0.appLifecycleClient.requestQuit = { quitRequested.setValue(true) }
      $0.appLifecycleClient.terminate = { terminated.setValue(true) }
      $0.updatesClient = UpdatesClient.testValue
    }

    await store.send(.requested(.quit))
    #expect(quitRequested.value == true)
    // Symmetric to closeAll: quit must NOT hit the hard terminate seam.
    #expect(terminated.value == false)
  }

  // MARK: - checkForUpdates

  @Test
  func checkForUpdatesCallsUpdatesClientCheckNow() async {
    let called = LockIsolated(0)
    let store = TestStore(initialState: WindowActionRouterFeature.State()) {
      WindowActionRouterFeature()
    } withDependencies: {
      $0.windowService = WindowService.testValue
      $0.appLifecycleClient = AppLifecycleClient.testValue
      $0.updatesClient = UpdatesClient.testValue
      $0.updatesClient.checkNow = { called.withValue { $0 += 1 } }
    }

    await store.send(.requested(.checkForUpdates))
    #expect(called.value == 1)
  }

  // MARK: - openConfig (no observable seam — smoke-test only)

  /// `openConfig` hands off to `NSWorkspace.shared.open(_:)` and logs if the
  /// call returns `false`. There is no injected client to intercept, so the
  /// assertion is limited to "reducer runs without crashing and does not
  /// touch the other clients". This is a deliberate simplification recorded
  /// in the Decision Log.
  @Test
  func openConfigDoesNotRouteThroughOtherClients() async {
    let windowCalls = LockIsolated(0)
    let lifecycleCalls = LockIsolated(0)
    let updatesCalls = LockIsolated(0)
    let store = TestStore(initialState: WindowActionRouterFeature.State()) {
      WindowActionRouterFeature()
    } withDependencies: {
      $0.windowService = WindowService.testValue
      $0.windowService.openNewWindow = { _ in windowCalls.withValue { $0 += 1 } }
      $0.windowService.closeWindow = { _ in windowCalls.withValue { $0 += 1 } }
      $0.windowService.activateWindow = { _ in windowCalls.withValue { $0 += 1 } }
      $0.windowService.toggleFullscreen = { _ in windowCalls.withValue { $0 += 1 } }
      $0.windowService.toggleMaximize = { _ in windowCalls.withValue { $0 += 1 } }
      $0.windowService.toggleTabOverview = { _ in windowCalls.withValue { $0 += 1 } }
      $0.windowService.toggleAppVisibility = { windowCalls.withValue { $0 += 1 } }
      $0.appLifecycleClient = AppLifecycleClient.testValue
      $0.appLifecycleClient.requestQuit = { lifecycleCalls.withValue { $0 += 1 } }
      $0.appLifecycleClient.terminate = { lifecycleCalls.withValue { $0 += 1 } }
      $0.updatesClient = UpdatesClient.testValue
      $0.updatesClient.checkNow = { updatesCalls.withValue { $0 += 1 } }
    }

    await store.send(.requested(.openConfig))
    #expect(windowCalls.value == 0)
    #expect(lifecycleCalls.value == 0)
    #expect(updatesCalls.value == 0)
  }
}
