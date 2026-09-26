import CodansIPC
import ComposableArchitecture
import Foundation
import Testing

@testable import CodansMobile

/// Pane detail, the text fallback for a Mac without live terminals:
/// snapshot reads while visible (one at a time, never cancelled by a newer
/// request), stale text kept on a failed read, input only for interactive
/// devices, and a permission downgrade when the Mac refuses input.
@MainActor
struct PaneDetailFeatureTests {
  @Test
  func inputIsOfferedOnlyToInteractiveDevices() {
    #expect(PaneDetailFeature.State(paneID: "A", permission: .interactive).showsInput)
    #expect(!PaneDetailFeature.State(paneID: "A", permission: .readOnly).showsInput)
  }

  @Test
  func readOnlyDeviceCannotSend() async {
    var initial = PaneDetailFeature.State(paneID: "A", permission: .readOnly)
    initial.draft = "ls"
    let store = TestStore(initialState: initial) { PaneDetailFeature() }

    await store.send(.sendTapped)
    await store.send(.keyTapped(.ctrlC))
  }

  @Test
  func visiblePaneLoadsThenPolls() async {
    let clock = TestClock()
    let reads = LockIsolated(0)
    let store = TestStore(initialState: PaneDetailFeature.State(paneID: "A", permission: .readOnly)) {
      PaneDetailFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.date.now = Fixtures.pairedAt
      $0.remoteClient.readPane = { paneID, tail in
        #expect(paneID == "A")
        #expect(tail == PaneDetailFeature.tailLines)
        let count = reads.withValue { value -> Int in
          value += 1
          return value
        }
        return "output \(count)"
      }
    }

    let task = await store.send(.task)
    await store.receive(\.refresh) { $0.isLoading = true }
    await store.receive(\.contentLoaded) {
      $0.isLoading = false
      $0.hasLoaded = true
      $0.content = "output 1"
      $0.loadedAt = Fixtures.pairedAt
    }

    await clock.advance(by: PaneDetailFeature.pollInterval)
    await store.receive(\.refresh) { $0.isLoading = true }
    await store.receive(\.contentLoaded) {
      $0.isLoading = false
      $0.content = "output 2"
    }
    await task.cancel()
  }

  @Test
  func sendTypesTheLineThenPressesEnterThenRereads() async {
    let clock = TestClock()
    let sent = LockIsolated<[String]>([])
    var initial = PaneDetailFeature.State(paneID: "A", permission: .interactive)
    initial.draft = "echo hi"
    let store = TestStore(initialState: initial) {
      PaneDetailFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.date.now = Fixtures.pairedAt
      $0.remoteClient.sendInput = { _, text in sent.withValue { $0.append("text:\(text)") } }
      $0.remoteClient.sendKey = { _, key in sent.withValue { $0.append("key:\(key.rawValue)") } }
      $0.remoteClient.readPane = { _, _ in "$ echo hi\nhi" }
    }

    await store.send(.sendTapped) {
      $0.draft = ""
      $0.isSending = true
    }
    await store.receive(\.inputDelivered) { $0.isSending = false }
    #expect(sent.value == ["text:echo hi", "key:enter"])

    await clock.advance(by: PaneDetailFeature.echoDelay)
    await store.receive(\.refresh) { $0.isLoading = true }
    await store.receive(\.contentLoaded) {
      $0.isLoading = false
      $0.hasLoaded = true
      $0.content = "$ echo hi\nhi"
      $0.loadedAt = Fixtures.pairedAt
    }
  }

  @Test
  func refusedInputDowngradesToReadOnly() async {
    let failure = RemoteFailure(.forbidden, "terminal.sendKey is not available to this device")
    let store = TestStore(initialState: PaneDetailFeature.State(paneID: "A", permission: .interactive)) {
      PaneDetailFeature()
    } withDependencies: {
      $0.remoteClient.sendKey = { _, _ in throw failure }
    }

    await store.send(.keyTapped(.escape)) { $0.isSending = true }
    await store.receive(\.inputFailed) {
      $0.isSending = false
      $0.errorMessage = failure.message
      $0.permission = .readOnly
    }
    #expect(!store.state.showsInput)
  }

  /// Change signals arrive faster than reads finish; each used to cancel
  /// the read in flight, so none ever completed.
  @Test
  func refreshDuringAReadWaitsForItInsteadOfCancellingIt() async {
    let gate = AsyncStream<Void>.makeStream()
    let reads = LockIsolated(0)
    let store = TestStore(initialState: PaneDetailFeature.State(paneID: "A", permission: .readOnly)) {
      PaneDetailFeature()
    } withDependencies: {
      $0.date.now = Fixtures.pairedAt
      $0.remoteClient.readPane = { _, _ in
        let count = reads.withValue { value -> Int in
          value += 1
          return value
        }
        if count == 1 {
          for await _ in gate.stream { break }
        }
        return "read \(count)"
      }
    }

    await store.send(.refresh) { $0.isLoading = true }
    await store.send(.paneChanged) { $0.needsRefresh = true }
    await store.send(.paneChanged)
    gate.continuation.yield()
    await store.receive(\.contentLoaded) {
      $0.hasLoaded = true
      $0.content = "read 1"
      $0.loadedAt = Fixtures.pairedAt
      $0.needsRefresh = false
    }
    await store.receive(\.contentLoaded) {
      $0.isLoading = false
      $0.content = "read 2"
    }
    #expect(reads.value == 2)
  }

  @Test
  func failedReadKeepsTheLastTextMarkedStale() async {
    let fail = LockIsolated(false)
    let store = TestStore(initialState: PaneDetailFeature.State(paneID: "A", permission: .readOnly)) {
      PaneDetailFeature()
    } withDependencies: {
      $0.date.now = Fixtures.pairedAt
      $0.remoteClient.readPane = { _, _ in
        if fail.value { throw RemoteFailure(.timeout, "Your Mac did not answer in time.") }
        return "hello"
      }
    }

    await store.send(.refresh) { $0.isLoading = true }
    await store.receive(\.contentLoaded) {
      $0.isLoading = false
      $0.hasLoaded = true
      $0.content = "hello"
      $0.loadedAt = Fixtures.pairedAt
    }
    #expect(!store.state.isStale)

    fail.setValue(true)
    await store.send(.refresh) { $0.isLoading = true }
    await store.receive(\.loadFailed) {
      $0.isLoading = false
      $0.readFailed = true
      $0.errorMessage = "Your Mac did not answer in time."
    }
    #expect(store.state.isStale)
    #expect(store.state.content == "hello")
  }
}
