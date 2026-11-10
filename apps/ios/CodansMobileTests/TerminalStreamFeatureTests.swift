import CodansIPC
import ComposableArchitecture
import Foundation
import Testing

@testable import CodansMobile

/// The live terminal reducer: frames applied per epoch, resync after a
/// reconnect, and input batched, never replayed.
@MainActor
struct TerminalStreamFeatureTests {
  private static let instance = UUID(uuidString: "00000000-0000-0000-0000-00000000AAAA")!
  nonisolated private static let locator = PaneLocator(projectID: "P", worktreeID: "W", tabID: "T", paneID: "A")

  private func makeState(
    screen: TerminalScreenModel, isConnected: Bool = true, permission: IPC.RemotePermission = .interactive
  ) -> TerminalStreamFeature.State {
    TerminalStreamFeature.State(
      paneID: "A", permission: permission, isConnected: isConnected, screen: screen, instance: Self.instance)
  }

  private func frame(_ seq: Int, epoch: Int, _ payload: IPC.TerminalStreamPayload) -> IPC.TerminalStreamFrame {
    IPC.TerminalStreamFrame(seq: seq, epoch: epoch, payload: payload)
  }

  /// A live state as after a first reset, for the input tests.
  private func liveState(screen: TerminalScreenModel) -> TerminalStreamFeature.State {
    var state = makeState(screen: screen)
    state.phase = .live
    state.grid = .init(cols: 80, rows: 24)
    state.epoch = 1
    state.isAttached = true
    return state
  }

  @Test
  func appliesFramesOfTheCurrentEpochOnly() async {
    let screen = TerminalScreenModel(isRecording: true)
    let (frames, continuation) = AsyncThrowingStream<IPC.TerminalStreamFrame, Error>.makeStream()
    let store = TestStore(initialState: makeState(screen: screen)) {
      TerminalStreamFeature()
    } withDependencies: {
      $0.remoteClient.attachStream = { paneID, _, _ in
        #expect(paneID == "A")
        return frames
      }
    }

    await store.send(.task) { $0.isAttached = true }

    continuation.yield(frame(1, epoch: 1, .reset(cols: 80, rows: 24, fidelity: .exact)))
    await store.receive(\.frameReceived) {
      $0.epoch = 1
      $0.grid = .init(cols: 80, rows: 24)
      $0.phase = .live
    }
    continuation.yield(frame(2, epoch: 1, .output(Data("hello".utf8))))
    await store.receive(\.frameReceived)
    // A frame from an older epoch arrives late: dropped.
    continuation.yield(frame(3, epoch: 0, .output(Data("stale".utf8))))
    await store.receive(\.frameReceived)
    continuation.yield(frame(4, epoch: 1, .resized(cols: 100, rows: 30)))
    await store.receive(\.frameReceived) { $0.grid = .init(cols: 100, rows: 30) }
    continuation.yield(frame(5, epoch: 1, .heartbeat))
    await store.receive(\.frameReceived)
    continuation.yield(frame(6, epoch: 1, .unknown(kind: "future")))
    await store.receive(\.frameReceived)
    continuation.yield(frame(7, epoch: 1, .exited(reason: "exit 0", exitCode: 0)))
    await store.receive(\.frameReceived) { $0.phase = .exited(reason: "exit 0") }
    continuation.finish()
    await store.receive(\.streamEnded) { $0.isAttached = false }

    #expect(
      screen.commands == [
        .reset(cols: 80, rows: 24),
        .feed(Data("hello".utf8)),
        .resize(cols: 100, rows: 30),
      ])
  }

  @Test
  func framesBeforeTheFirstResetAreDropped() async {
    let screen = TerminalScreenModel(isRecording: true)
    let store = TestStore(initialState: makeState(screen: screen)) { TerminalStreamFeature() }

    await store.send(.frameReceived(frame(1, epoch: 1, .output(Data("x".utf8)))))
    await store.send(.frameReceived(frame(2, epoch: 1, .resized(cols: 90, rows: 20))))
    #expect(screen.commands.isEmpty)
  }

  @Test
  func reconnectKeepsTheScreenDimmedThenResyncs() async {
    let screen = TerminalScreenModel(isRecording: true)
    let attaches = LockIsolated(0)
    let store = TestStore(initialState: liveState(screen: screen)) {
      TerminalStreamFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.remoteClient.attachStream = { _, _, _ in
        attaches.withValue { $0 += 1 }
        return AsyncThrowingStream { continuation in
          continuation.yield(
            IPC.TerminalStreamFrame(seq: 1, epoch: 2, payload: .reset(cols: 80, rows: 24, fidelity: .exact)))
          continuation.yield(IPC.TerminalStreamFrame(seq: 2, epoch: 2, payload: .output(Data("again".utf8))))
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.textTyped("x"))
    await store.send(.connectionChanged(false)) {
      $0.isConnected = false
      $0.isAttached = false
      $0.phase = .reconnecting
      $0.outbox = []
      $0.isFlushScheduled = false
    }
    #expect(store.state.isStale)
    #expect(store.state.inputDisabledReason != nil)
    // Keys typed while offline go nowhere.
    await store.send(.textTyped("y"))
    #expect(store.state.outbox.isEmpty)

    await store.send(.connectionChanged(true)) {
      $0.isConnected = true
      $0.isAttached = true
    }
    await store.receive(\.frameReceived) {
      $0.epoch = 2
      $0.phase = .live
    }
    await store.receive(\.frameReceived)
    #expect(attaches.value == 1)
    #expect(!store.state.isStale)
    #expect(screen.commands == [.reset(cols: 80, rows: 24), .feed(Data("again".utf8))])
  }

  @Test
  func streamEndingWhileConnectedRetriesThenFails() async {
    let clock = TestClock()
    let screen = TerminalScreenModel(isRecording: true)
    let store = TestStore(initialState: makeState(screen: screen)) {
      TerminalStreamFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.remoteClient.attachStream = { _, _, _ in throw RemoteFailure(.other, "no session") }
    }

    await store.send(.task) { $0.isAttached = true }
    for attempt in 1...TerminalStreamFeature.maxAttachRetries {
      await store.receive(\.streamEnded) {
        $0.isAttached = false
        $0.attachFailures = attempt
      }
      await clock.advance(by: TerminalStreamFeature.retryDelay(afterFailures: attempt))
      await store.receive(\.retryAttach) { $0.isAttached = true }
    }
    await store.receive(\.streamEnded) {
      $0.isAttached = false
      $0.attachFailures = TerminalStreamFeature.maxAttachRetries + 1
      $0.phase = .failed("no session")
    }
  }

  @Test
  func typedKeysShareOneBatch() async {
    let clock = TestClock()
    let sent = LockIsolated<[[IPC.TerminalInputEvent]]>([])
    let store = TestStore(initialState: liveState(screen: TerminalScreenModel(isRecording: true))) {
      TerminalStreamFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.remoteClient.sendEvents = { paneID, events in
        #expect(paneID == "A")
        sent.withValue { $0.append(events) }
        return IPC.TerminalSendEventsResult(delivered: events.count, rejected: [])
      }
    }

    await store.send(.textTyped("l")) {
      $0.outbox = [.text("l")]
      $0.isFlushScheduled = true
    }
    await store.send(.textTyped("s")) { $0.outbox = [.text("l"), .text("s")] }
    await store.send(.textTyped("\n")) { $0.outbox = [.text("l"), .text("s"), .press("Enter")] }
    await clock.advance(by: TerminalStreamFeature.flushDelay)
    await store.receive(\.flush) {
      $0.isFlushScheduled = false
      $0.outbox = []
      $0.isSending = true
    }
    await store.receive(\.sendFinished) { $0.isSending = false }
    #expect(sent.value == [[.text("l"), .text("s"), .press("Enter")]])
  }

  @Test
  func latchedCtrlTurnsTheNextCharacterIntoAChord() async {
    let clock = TestClock()
    let store = TestStore(initialState: liveState(screen: TerminalScreenModel(isRecording: true))) {
      TerminalStreamFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.date.now = Date(timeIntervalSince1970: 100)
      $0.remoteClient.sendEvents = { _, events in IPC.TerminalSendEventsResult(delivered: events.count, rejected: []) }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.modifierTapped(.ctrl))
    #expect(store.state.modifiers.ctrl == .armed)
    await store.send(.textTyped("c"))
    #expect(store.state.outbox == [.key(code: "KeyC", text: nil, mods: IPC.TerminalKeyModifiers(ctrl: true))])
    #expect(store.state.modifiers.ctrl == .off)
    await store.send(.textTyped("d"))
    #expect(store.state.outbox.last == .text("d"))
    await store.send(.keyPressed(code: "ArrowUp", mods: .none))
    #expect(store.state.outbox.last == .press("ArrowUp"))
    await clock.run()
  }

  @Test
  func composeSendsPasteSettleEnterAndRestoresTheDraftOnFailure() async {
    let clock = TestClock()
    let sent = LockIsolated<[[IPC.TerminalInputEvent]]>([])
    var initial = liveState(screen: TerminalScreenModel(isRecording: true))
    initial.composeDraft = "refactor the stream\nand test it"
    let store = TestStore(initialState: initial) {
      TerminalStreamFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.remoteClient.sendEvents = { _, events in
        sent.withValue { $0.append(events) }
        throw RemoteFailure(.other, "Your Mac did not answer in time.")
      }
    }

    await store.send(.composeSubmitted(pressEnter: true)) {
      $0.composeDraft = ""
      $0.composePending = "refactor the stream\nand test it"
      $0.outbox = [.paste("refactor the stream\nand test it"), .delay(millis: 30), .press("Enter")]
      $0.isFlushScheduled = true
    }
    await clock.advance(by: TerminalStreamFeature.flushDelay)
    await store.receive(\.flush) {
      $0.isFlushScheduled = false
      $0.outbox = []
      $0.isSending = true
    }
    await store.receive(\.sendFinished) {
      $0.isSending = false
      $0.composeDraft = "refactor the stream\nand test it"
      $0.composePending = nil
      $0.toast = "Couldn't send: Your Mac did not answer in time."
    }
    #expect(sent.value == [[.paste("refactor the stream\nand test it"), .delay(millis: 30), .press("Enter")]])
    await clock.advance(by: TerminalStreamFeature.toastDuration)
    await store.receive(\.toastExpired) { $0.toast = nil }
  }

  @Test
  func composeCanInsertWithoutEnter() {
    #expect(TerminalStreamFeature.composeEvents("ls", pressEnter: false) == [.paste("ls")])
    #expect(
      TerminalStreamFeature.composeEvents("ls", pressEnter: true)
        == [.paste("ls"), .delay(millis: 30), .press("Enter")])
  }

  @Test
  func paneNotOpenOnTheMacShowsTheNoticeUntilOpened() async {
    let clock = TestClock()
    let activated = LockIsolated<[String]>([])
    var initial = liveState(screen: TerminalScreenModel(isRecording: true))
    initial.location = Self.locator
    let store = TestStore(initialState: initial) {
      TerminalStreamFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.remoteClient.sendEvents = { _, _ in
        throw RemoteRPCFailures.unsupported
      }
      $0.remoteClient.activateTab = { tabID in activated.withValue { $0.append(tabID) } }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.keyPressed(code: "Enter", mods: .none))
    await clock.advance(by: TerminalStreamFeature.flushDelay)
    await store.receive(\.sendFinished)
    #expect(store.state.notice == .paneNotOpenOnMac)
    #expect(store.state.outbox.isEmpty)

    await store.send(.openOnMacTapped)
    await store.receive(\.managementFinished)
    #expect(activated.value == ["T"])
    #expect(store.state.notice == nil)
  }

  @Test
  func rejectedKeysShowAToast() {
    let binding = IPC.TerminalInputRejection(index: 0, reason: IPC.TerminalInputRejection.Reason.binding)
    #expect(TerminalStreamFeature.message(forRejections: [binding])?.contains("shortcut on your Mac") == true)
    #expect(TerminalStreamFeature.message(forRejections: []) == nil)
  }

  @Test
  func readOnlyDevicesSendNothing() async {
    var initial = liveState(screen: TerminalScreenModel(isRecording: true))
    initial.permission = .readOnly
    let store = TestStore(initialState: initial) { TerminalStreamFeature() }

    await store.send(.textTyped("rm -rf"))
    await store.send(.keyPressed(code: "Enter", mods: .none))
    await store.send(.modifierTapped(.ctrl))
    await store.send(.newTabTapped(cwd: nil))
  }

  @Test
  func batchesStayWithinTheCallLimits() {
    var outbox: [IPC.TerminalInputEvent] = Array(repeating: .text("a"), count: 300)
    let first = TerminalStreamFeature.takeBatch(from: &outbox)
    #expect(first.count == IPC.TerminalSendEventsRequest.maxEvents)
    #expect(outbox.count == 300 - IPC.TerminalSendEventsRequest.maxEvents)

    var delays: [IPC.TerminalInputEvent] = Array(repeating: .delay(millis: 500), count: 6)
    #expect(TerminalStreamFeature.takeBatch(from: &delays).count == 4)
    #expect(delays.count == 2)
  }

  @Test
  func splittingNavigatesToTheNewPane() async {
    var initial = liveState(screen: TerminalScreenModel(isRecording: true))
    initial.location = Self.locator
    let store = TestStore(initialState: initial) {
      TerminalStreamFeature()
    } withDependencies: {
      $0.remoteClient.splitPane = { location, direction in
        #expect(location == Self.locator)
        #expect(direction == .down)
        return "B"
      }
      $0.remoteClient.closePane = { location in #expect(location == Self.locator) }
    }

    await store.send(.splitTapped(.down)) { $0.isManaging = true }
    await store.receive(\.managementFinished) {
      $0.isManaging = false
      $0.navigation = .showPane("B")
    }
    await store.send(.navigationHandled) { $0.navigation = nil }
    await store.send(.closePaneConfirmed) { $0.isManaging = true }
    await store.receive(\.managementFinished) {
      $0.isManaging = false
      $0.navigation = .paneClosed
    }
  }

  // MARK: - Seats

  private func seatState(screen: TerminalScreenModel) -> TerminalStreamFeature.State {
    var state = makeState(screen: screen)
    state.supportsSeats = true
    return state
  }

  @Test
  func attachingWaitsForTheScreenGridAndOpensASeatThatClaimsAuto() async {
    let screen = TerminalScreenModel(isRecording: true)
    let clock = TestClock()
    let opened = LockIsolated<[(IPC.TerminalGridSize?, IPC.TerminalSizeClaim?)]>([])
    let store = TestStore(initialState: seatState(screen: screen)) {
      TerminalStreamFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.remoteClient.attachStream = { _, seat, claim in
        opened.withValue { $0.append((seat, claim)) }
        return AsyncThrowingStream { _ in }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.task) { $0.isWaitingForSeat = true }
    await store.send(.seatSizeChanged(.init(cols: 58, rows: 36))) {
      $0.seat = .init(cols: 58, rows: 36)
      $0.isWaitingForSeat = false
      $0.isAttached = true
    }
    for _ in 0..<100 where opened.value.isEmpty { await Task.yield() }
    #expect(opened.value.count == 1)
    #expect(opened.value.first?.0 == IPC.TerminalGridSize(cols: 58, rows: 36))
    #expect(opened.value.first?.1 == .auto)
    await store.skipInFlightEffects()
  }

  @Test
  func withoutAGridInTimeItAttachesAsAMirror() async {
    let screen = TerminalScreenModel(isRecording: true)
    let clock = TestClock()
    let opened = LockIsolated<[IPC.TerminalGridSize?]>([])
    let store = TestStore(initialState: seatState(screen: screen)) {
      TerminalStreamFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.remoteClient.attachStream = { _, seat, _ in
        opened.withValue { $0.append(seat) }
        return AsyncThrowingStream { _ in }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.task)
    await clock.advance(by: TerminalStreamFeature.seatWait)
    await store.receive(\.seatWaitExpired)
    for _ in 0..<100 where opened.value.isEmpty { await Task.yield() }
    #expect(opened.value == [nil])
    await store.skipInFlightEffects()
  }

  @Test
  func aGridThatArrivesAfterAMirrorOpenedReopensTheStreamWithASeat() async {
    let screen = TerminalScreenModel(isRecording: true)
    let opened = LockIsolated<[IPC.TerminalGridSize?]>([])
    var state = seatState(screen: screen)
    state.isAttached = true
    let store = TestStore(initialState: state) {
      TerminalStreamFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.remoteClient.attachStream = { _, seat, _ in
        opened.withValue { $0.append(seat) }
        return AsyncThrowingStream { _ in }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.seatSizeChanged(.init(cols: 58, rows: 36)))
    for _ in 0..<100 where opened.value.isEmpty { await Task.yield() }
    #expect(opened.value == [IPC.TerminalGridSize(cols: 58, rows: 36)])
    #expect(store.state.isAttachedWithSeat)
    await store.skipInFlightEffects()
  }

  @Test
  func keysGoThroughTheSeatAsEncodedBytes() async {
    let screen = TerminalScreenModel(isRecording: true)
    let clock = TestClock()
    let typed = LockIsolated<[Data]>([])
    var state = seatState(screen: screen)
    state.phase = .live
    state.isAttached = true
    state.seat = .init(cols: 58, rows: 36)
    let store = TestStore(initialState: state) {
      TerminalStreamFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.remoteClient.typeBytes = { _, bytes in typed.withValue { $0.append(bytes) } }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.textTyped("ls"))
    await store.send(.keyPressed(code: "ArrowUp", mods: .none))
    await store.send(.eventsRequested([.ctrl("c")]))
    await clock.advance(by: TerminalStreamFeature.flushDelay)
    await store.receive(\.sendFinished)
    #expect(typed.value == [Data("ls\u{1B}[A\u{03}".utf8)])
  }

  @Test
  func aMacWithoutASeatGetsTheSameKeysTheOldWay() async {
    let screen = TerminalScreenModel(isRecording: true)
    let clock = TestClock()
    let sent = LockIsolated<[[IPC.TerminalInputEvent]]>([])
    var state = seatState(screen: screen)
    state.phase = .live
    state.isAttached = true
    let store = TestStore(initialState: state) {
      TerminalStreamFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.remoteClient.typeBytes = { _, _ in throw RemoteFailure(.unsupported, "no terminal seat") }
      $0.remoteClient.sendEvents = { _, events in
        sent.withValue { $0.append(events) }
        return IPC.TerminalSendEventsResult(delivered: events.count, rejected: [])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.textTyped("x"))
    await clock.advance(by: TerminalStreamFeature.flushDelay)
    await store.receive(\.seatInputFailed)
    await store.receive(\.flush)
    await store.receive(\.sendFinished)
    #expect(store.state.isSeatUnavailable)
    #expect(sent.value == [[.text("x")]])
  }

  @Test
  func aNewGridSettlesBeforeTheSeatResizesAndFitAndGiveBackReachTheMac() async {
    let screen = TerminalScreenModel(isRecording: true)
    let clock = TestClock()
    let calls = LockIsolated<[String]>([])
    var state = seatState(screen: screen)
    state.phase = .live
    state.isAttached = true
    state.isAttachedWithSeat = true
    state.seat = .init(cols: 58, rows: 36)
    let store = TestStore(initialState: state) {
      TerminalStreamFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.remoteClient.setSeatSize = { _, size in calls.withValue { $0.append("size \(size.cols)x\(size.rows)") } }
      $0.remoteClient.claimSize = { _, claim in calls.withValue { $0.append(claim ? "claim" : "release") } }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.seatSizeChanged(.init(cols: 58, rows: 20)))
    await store.send(.seatSizeChanged(.init(cols: 58, rows: 36)))
    await clock.advance(by: TerminalStreamFeature.seatSizeSettle)
    await store.receive(\.seatSizeSettled)
    await store.send(.fitToDeviceTapped)
    await store.send(.giveSizeBackTapped)
    for _ in 0..<100 where calls.value.count < 3 { await Task.yield() }
    #expect(calls.value == ["size 58x36", "claim", "release"])
    #expect(!store.state.isFittedToDevice)
    await store.send(.frameReceived(frame(1, epoch: 1, .reset(cols: 58, rows: 36, fidelity: .exact))))
    #expect(store.state.isFittedToDevice)
  }

  @Test
  func leavingTheAppGivesAFittedPaneBackAndOnlyThen() async {
    let screen = TerminalScreenModel(isRecording: true)
    let calls = LockIsolated<[String]>([])
    var state = seatState(screen: screen)
    state.phase = .live
    state.isAttached = true
    state.isAttachedWithSeat = true
    state.seat = .init(cols: 58, rows: 36)
    state.grid = .init(cols: 135, rows: 53)
    let store = TestStore(initialState: state) {
      TerminalStreamFeature()
    } withDependencies: {
      $0.remoteClient.claimSize = { _, claim in calls.withValue { $0.append(claim ? "claim" : "release") } }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    // At the Mac's size: nothing to give back.
    await store.send(.movedToBackground)
    await store.send(.frameReceived(frame(1, epoch: 1, .reset(cols: 58, rows: 36, fidelity: .exact))))
    await store.send(.movedToBackground)
    await store.receive(\.giveSizeBackTapped)
    for _ in 0..<100 where calls.value.isEmpty { await Task.yield() }
    #expect(calls.value == ["release"])
  }
}

/// Errors as the remote stack throws them.
enum RemoteRPCFailures {
  static let unsupported = RemoteFailure(.unsupported, "pane not open on the Mac")
}
