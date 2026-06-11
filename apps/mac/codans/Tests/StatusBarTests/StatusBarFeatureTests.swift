import ComposableArchitecture
import Foundation
import Testing
import CodansCore

@testable import Codans

/// TestStore coverage for StatusBarFeature. All timing uses TestClock so
/// the 3 s / 8 s auto-clear windows are exercised deterministically.
@MainActor
struct StatusBarFeatureTests {
  @Test
  func pushSuccessAutoClearsAfterThreeSeconds() async {
    let clock = TestClock()
    let store = TestStore(initialState: StatusBarFeature.State()) {
      StatusBarFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }
    await store.send(.push(.success("Opened in Xcode"))) {
      $0.toast = .success("Opened in Xcode")
      $0.sequence = 1
    }
    await clock.advance(by: StatusBarFeature.successDuration)
    await store.receive(.cleared(sequence: 1)) {
      $0.toast = nil
    }
  }

  @Test
  func pushWarningAutoClearsAfterEightSeconds() async {
    let clock = TestClock()
    let store = TestStore(initialState: StatusBarFeature.State()) {
      StatusBarFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }
    await store.send(.push(.warning("Push rejected"))) {
      $0.toast = .warning("Push rejected")
      $0.sequence = 1
    }
    await clock.advance(by: StatusBarFeature.warningDuration)
    await store.receive(.cleared(sequence: 1)) {
      $0.toast = nil
    }
  }

  @Test
  func pushInProgressNeverAutoClears() async {
    let clock = TestClock()
    let store = TestStore(initialState: StatusBarFeature.State()) {
      StatusBarFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }
    await store.send(.push(.inProgress("Running tests"))) {
      $0.toast = .inProgress("Running tests")
      $0.sequence = 1
    }
    // Advance well beyond both success + warning windows; no `.cleared`
    // should arrive. TestStore asserts unhandled effects on `finish`.
    await clock.advance(by: .seconds(60))
    await store.finish()
  }

  @Test
  func newPushCancelsPendingTimer() async {
    let clock = TestClock()
    let store = TestStore(initialState: StatusBarFeature.State()) {
      StatusBarFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }
    await store.send(.push(.success("First"))) {
      $0.toast = .success("First")
      $0.sequence = 1
    }
    await clock.advance(by: .seconds(1))
    await store.send(.push(.success("Second"))) {
      $0.toast = .success("Second")
      $0.sequence = 2
    }
    // Pending timer for seq 1 is cancelled by `cancelInFlight`. Advancing
    // the full success window from push #2 should fire exactly one
    // `.cleared(sequence: 2)` — never `.cleared(sequence: 1)`.
    await clock.advance(by: StatusBarFeature.successDuration)
    await store.receive(.cleared(sequence: 2)) {
      $0.toast = nil
    }
  }

  @Test
  func staleClearedIsIgnored() async {
    let clock = TestClock()
    let store = TestStore(initialState: StatusBarFeature.State()) {
      StatusBarFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }
    await store.send(.push(.success("Current"))) {
      $0.toast = .success("Current")
      $0.sequence = 1
    }
    // A leaked prior-generation `.cleared` must be swallowed without
    // touching state. Sequence mismatch guards the race where
    // `clock.sleep` resumes past its cancellation point.
    await store.send(.cleared(sequence: 0))
    await clock.advance(by: StatusBarFeature.successDuration)
    await store.receive(.cleared(sequence: 1)) {
      $0.toast = nil
    }
  }

  @Test
  func dismissedClearsImmediatelyAndCancelsTimer() async {
    let clock = TestClock()
    let store = TestStore(initialState: StatusBarFeature.State()) {
      StatusBarFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }
    await store.send(.push(.warning("Heads up"))) {
      $0.toast = .warning("Heads up")
      $0.sequence = 1
    }
    await store.send(.dismissed) {
      $0.toast = nil
    }
    // Timer was cancelled; advancing past the warning window must not
    // dispatch `.cleared`.
    await clock.advance(by: StatusBarFeature.warningDuration + .seconds(2))
    await store.finish()
  }

  @Test
  func inProgressThenSuccessSwapsAndSchedulesAutoClear() async {
    let clock = TestClock()
    let store = TestStore(initialState: StatusBarFeature.State()) {
      StatusBarFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }
    await store.send(.push(.inProgress("Merging"))) {
      $0.toast = .inProgress("Merging")
      $0.sequence = 1
    }
    await store.send(.push(.success("PR merged"))) {
      $0.toast = .success("PR merged")
      $0.sequence = 2
    }
    await clock.advance(by: StatusBarFeature.successDuration)
    await store.receive(.cleared(sequence: 2)) {
      $0.toast = nil
    }
  }
}
