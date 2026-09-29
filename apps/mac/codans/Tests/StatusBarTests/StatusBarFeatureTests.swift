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
  func activityNeverAutoClears() async {
    let clock = TestClock()
    let store = TestStore(initialState: StatusBarFeature.State()) {
      StatusBarFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }
    let activity = StatusActivity(id: .init("test"), title: "Running tests")
    await store.send(.begin(activity)) {
      $0.activities = [activity]
    }
    // Advance well beyond both toast windows; nothing may end the activity
    // but its emitter. TestStore asserts unhandled effects on `finish`.
    await clock.advance(by: .seconds(60))
    await store.finish()
  }

  @Test
  func beginSameIDReplacesAndMovesToFront() async {
    let store = TestStore(initialState: StatusBarFeature.State()) {
      StatusBarFeature()
    }
    let merge = StatusActivity(id: .init("pr.merge", 1), title: "Merging PR #1")
    let handoff = StatusActivity(id: .init("handoff"), title: "Handing off")
    let retried = StatusActivity(id: .init("pr.merge", 1), title: "Merging PR #1", detail: "Retry")
    await store.send(.begin(merge)) { $0.activities = [merge] }
    await store.send(.begin(handoff)) { $0.activities = [merge, handoff] }
    #expect(store.state.primaryActivity == handoff)
    await store.send(.begin(retried)) { $0.activities = [handoff, retried] }
    #expect(store.state.primaryActivity == retried)
  }

  @Test
  func updateChangesProgressAndIgnoresEndedActivity() async {
    let store = TestStore(initialState: StatusBarFeature.State()) {
      StatusBarFeature()
    }
    let id = StatusActivityID("build")
    let activity = StatusActivity(id: id, title: "Building")
    await store.send(.begin(activity)) { $0.activities = [activity] }
    await store.send(.update(id: id, detail: nil, progress: .determinate(completed: 3, total: 8))) {
      $0.activities[id: id]?.progress = .determinate(completed: 3, total: 8)
    }
    await store.send(.end(id: id, outcome: nil)) { $0.activities = [] }
    await store.send(.update(id: id, detail: "late", progress: .indeterminate))
  }

  @Test
  func endWithOutcomeRemovesActivityAndSchedulesAutoClear() async {
    let clock = TestClock()
    let store = TestStore(initialState: StatusBarFeature.State()) {
      StatusBarFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }
    let id = StatusActivityID("pr.merge", 7)
    let activity = StatusActivity(id: id, title: "Merging PR #7")
    await store.send(.begin(activity)) { $0.activities = [activity] }
    await store.send(.end(id: id, outcome: .success("PR #7 merged"))) {
      $0.activities = []
      $0.toast = .success("PR #7 merged")
      $0.sequence = 1
    }
    await clock.advance(by: StatusBarFeature.successDuration)
    await store.receive(.cleared(sequence: 1)) {
      $0.toast = nil
    }
  }

  @Test
  func endUnknownIDStillPushesOutcome() async {
    let clock = TestClock()
    let store = TestStore(initialState: StatusBarFeature.State()) {
      StatusBarFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }
    await store.send(.end(id: .init("never-begun"), outcome: .warning("Late failure"))) {
      $0.toast = .warning("Late failure")
      $0.sequence = 1
    }
    await clock.advance(by: StatusBarFeature.warningDuration)
    await store.receive(.cleared(sequence: 1)) {
      $0.toast = nil
    }
  }
}
