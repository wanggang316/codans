import CodansCore
import Foundation
import Testing

@testable import Codans

@MainActor
struct PaneInputCoordinatorTests {
  @Test func recoveryWritesDoNotInvalidateTheirOwnLease() async {
    let paneID = PaneID()
    let coordinator = PaneInputCoordinator(pauseBeforeSubmit: { await Task.yield() })
    var writes: [String] = []
    var attempts = 0
    var externalInputs = 0
    coordinator.onExternalInput = { _, _ in externalInputs += 1 }
    let result = await coordinator.submitCommand(
      in: paneID, origin: .recovery(operationID: UUID()),
      willPaste: {
        attempts += 1
        return true
      },
      paste: { writes.append("paste") }, submit: { writes.append("return") }
    )
    #expect(result == .submitted)
    #expect(writes == ["paste", "return"])
    #expect(attempts == 1)
    #expect(externalInputs == 0)
    #expect(coordinator.revision(for: paneID) == 0)
    #expect(!coordinator.hasResidualDraft(in: paneID))
  }

  @Test func nativeInputBetweenPasteAndReturnLeavesDraftAndCancelsReturn() async {
    let paneID = PaneID()
    let gate = Gate()
    let coordinator = PaneInputCoordinator(pauseBeforeSubmit: { await gate.pause() })
    var writes: [String] = []
    let task = Task { @MainActor in
      await coordinator.submitCommand(
        in: paneID, origin: .recovery(operationID: UUID()),
        paste: { writes.append("paste") }, submit: { writes.append("return") }
      )
    }
    await gate.waitForPause()
    #expect(!coordinator.canSubmitProgrammaticInput(in: paneID))
    coordinator.beforeNativeInput(in: paneID)
    writes.append("native")
    #expect(coordinator.hasResidualDraft(in: paneID))
    gate.resume()
    #expect(await task.value == .interruptedWithDraft)
    #expect(writes == ["paste", "native"])
  }

  @Test func cliInputRevokesPendingReturnBeforeRejectingUnsafeAppend() async {
    let paneID = PaneID()
    let gate = Gate()
    let coordinator = PaneInputCoordinator(pauseBeforeSubmit: { await gate.pause() })
    var writes: [String] = []
    let task = Task { @MainActor in
      await coordinator.submitCommand(
        in: paneID, origin: .recovery(operationID: UUID()),
        paste: { writes.append("paste") }, submit: { writes.append("return") }
      )
    }
    await gate.waitForPause()
    let result = coordinator.performExternalInput(in: paneID, origin: .cli) {
      writes.append("cli")
    }
    #expect(result == .rejectedDraftPresent)
    #expect(coordinator.revision(for: paneID) == 1)
    gate.resume()
    #expect(await task.value == .interruptedWithDraft)
    #expect(writes == ["paste"])
  }

  @Test func queuedSubmissionReservesSynchronouslyBeforeItsTaskStarts() async {
    let paneID = PaneID()
    let coordinator = PaneInputCoordinator(pauseBeforeSubmit: { await Task.yield() })
    var writes: [String] = []
    let first = coordinator.reserve(in: paneID, origin: .recovery(operationID: UUID()))
    guard case .reserved(let recoveryLease) = first else {
      Issue.record("Missing lease")
      return
    }
    let next = coordinator.reserve(in: paneID, origin: .commandQueue)
    guard case .reserved(let externalLease) = next else {
      Issue.record("Missing external lease")
      return
    }
    #expect(!coordinator.isValid(recoveryLease))
    #expect(coordinator.revision(for: paneID) == 1)
    let result = await coordinator.submitCommand(
      recoveryLease, paste: { writes.append("paste") }, submit: { writes.append("return") }
    )
    #expect(result == .cancelledBeforeWrite)
    #expect(writes.isEmpty)
    #expect(coordinator.isValid(externalLease))
    #expect(coordinator.canSubmitProgrammaticInput(in: paneID))
  }

  @Test func invalidTargetBeforePasteHasNoSideEffectsOrSpentAttempt() async {
    let paneID = PaneID()
    let coordinator = PaneInputCoordinator()
    var effects = 0
    let result = await coordinator.submitCommand(
      in: paneID, origin: .recovery(operationID: UUID()),
      validateBeforePaste: { false },
      willPaste: {
        effects += 1
        return true
      },
      paste: { effects += 1 }, submit: { effects += 1 }
    )
    #expect(result == .targetChanged)
    #expect(effects == 0)
    #expect(!coordinator.hasResidualDraft(in: paneID))
  }

  @Test func replacementDuringDelayPreventsReturn() async {
    let paneID = PaneID()
    let coordinator = PaneInputCoordinator(pauseBeforeSubmit: { await Task.yield() })
    var writes: [String] = []
    let result = await coordinator.submitCommand(
      in: paneID, origin: .recovery(operationID: UUID()),
      validateBeforeSubmit: { false },
      paste: { writes.append("paste") }, submit: { writes.append("return") }
    )
    #expect(result == .interruptedWithDraft)
    #expect(writes == ["paste"])
    #expect(coordinator.hasResidualDraft(in: paneID))
  }

  @Test func cancellationAfterPastePreservesResidualDraft() async {
    let paneID = PaneID()
    let gate = Gate()
    let coordinator = PaneInputCoordinator(pauseBeforeSubmit: { await gate.pause() })
    var returns = 0
    let task = Task { @MainActor in
      await coordinator.submitCommand(
        in: paneID, origin: .recovery(operationID: UUID()),
        paste: {}, submit: { returns += 1 }
      )
    }
    await gate.waitForPause()
    task.cancel()
    gate.resume()
    #expect(await task.value == .interruptedWithDraft)
    #expect(returns == 0)
    #expect(coordinator.hasResidualDraft(in: paneID))
  }

  @Test func lateCompletionCannotRecreateDraftAfterPaneRemoval() async {
    let paneID = PaneID()
    let gate = Gate()
    let coordinator = PaneInputCoordinator(pauseBeforeSubmit: { await gate.pause() })
    var returns = 0
    let task = Task { @MainActor in
      await coordinator.submitCommand(
        in: paneID, origin: .recovery(operationID: UUID()),
        paste: {}, submit: { returns += 1 }
      )
    }
    await gate.waitForPause()
    coordinator.removePane(paneID)
    gate.resume()
    #expect(await task.value == .interruptedWithDraft)
    #expect(!coordinator.hasResidualDraft(in: paneID))
    #expect(returns == 0)
  }

  @Test func residualDraftSurvivesTypingUntilExplicitResolution() async {
    let paneID = PaneID()
    let coordinator = PaneInputCoordinator(pauseBeforeSubmit: { await Task.yield() })
    var markerChanges: [Bool] = []
    coordinator.onResidualDraftChanged = { _, exists in markerChanges.append(exists) }
    _ = await coordinator.submitCommand(
      in: paneID, origin: .recovery(operationID: UUID()),
      validateBeforeSubmit: { false }, paste: {}, submit: {}
    )
    coordinator.beforeNativeInput(in: paneID)
    #expect(coordinator.hasResidualDraft(in: paneID))
    let blocked = coordinator.reserve(in: paneID, origin: .commandQueue)
    guard case .rejected(.rejectedDraftPresent) = blocked else {
      Issue.record("A new command must not append to the interrupted draft")
      return
    }
    #expect(!coordinator.canSubmitProgrammaticInput(in: paneID))
    coordinator.resolveResidualDraft(in: paneID)
    #expect(coordinator.canSubmitProgrammaticInput(in: paneID))
    var didWrite = false
    #expect(coordinator.performExternalInput(in: paneID, origin: .cli) { didWrite = true } == .submitted)
    #expect(didWrite)
    #expect(markerChanges == [true, false])
  }

  @Test func inputHookInvalidatesLeaseBeforeObserverOrWriterRuns() {
    let paneID = PaneID()
    let coordinator = PaneInputCoordinator()
    guard case .reserved(let lease) = coordinator.reserve(in: paneID, origin: .recovery(operationID: UUID())) else {
      Issue.record("Missing lease")
      return
    }
    var events: [String] = []
    coordinator.onExternalInput = { pane, revision in
      #expect(pane == paneID)
      #expect(revision == 1)
      #expect(!coordinator.isValid(lease))
      events.append("observer")
    }
    let result = coordinator.performExternalInput(in: paneID, origin: .cli) {
      #expect(!coordinator.isValid(lease))
      events.append("writer")
    }
    #expect(result == .submitted)
    #expect(events == ["observer", "writer"])
  }

  @Test func externalInputOnlyRevokesItsOwnPane() {
    let coordinator = PaneInputCoordinator()
    let first = PaneID()
    let second = PaneID()
    guard case .reserved(let lease) = coordinator.reserve(in: second, origin: .recovery(operationID: UUID())) else {
      Issue.record("Missing lease")
      return
    }
    coordinator.beforeNativeInput(in: first)
    #expect(coordinator.isValid(lease))
    #expect(coordinator.revision(for: first) == 1)
    #expect(coordinator.revision(for: second) == 0)
  }

  @Test func aSecondRecoveryCannotStealAnActiveLease() {
    let coordinator = PaneInputCoordinator()
    let paneID = PaneID()
    guard case .reserved(let lease) = coordinator.reserve(in: paneID, origin: .recovery(operationID: UUID())) else {
      Issue.record("Missing lease")
      return
    }
    let result = coordinator.reserve(in: paneID, origin: .recovery(operationID: UUID()))
    guard case .rejected(.targetChanged) = result else {
      Issue.record("Only one submission can own the pane")
      return
    }
    #expect(coordinator.isValid(lease))
  }

  @Test func staleFinishCannotReleaseAReplacementLease() {
    let coordinator = PaneInputCoordinator()
    let paneID = PaneID()
    guard case .reserved(let old) = coordinator.reserve(in: paneID, origin: .recovery(operationID: UUID())) else {
      Issue.record("Missing old lease")
      return
    }
    coordinator.invalidate(in: paneID)
    guard case .reserved(let current) = coordinator.reserve(in: paneID, origin: .recovery(operationID: UUID())) else {
      Issue.record("Missing current lease")
      return
    }
    coordinator.finish(old)
    #expect(coordinator.isValid(current))
  }

  @Test func declinedAttemptDoesNotPasteOrLeaveResidualDraft() async {
    let paneID = PaneID()
    let coordinator = PaneInputCoordinator()
    var writes = 0
    let result = await coordinator.submitCommand(
      in: paneID, origin: .recovery(operationID: UUID()), willPaste: { false },
      paste: { writes += 1 }, submit: { writes += 1 })
    #expect(result == .cancelledBeforeWrite)
    #expect(writes == 0)
    #expect(!coordinator.hasResidualDraft(in: paneID))
    #expect(coordinator.canSubmitProgrammaticInput(in: paneID))
  }

  @Test func staleEmptyFrameDoesNotResolveAnUnrenderedPaste() async {
    let paneID = PaneID()
    let coordinator = PaneInputCoordinator(pauseBeforeSubmit: { await Task.yield() })
    _ = await coordinator.submitCommand(
      in: paneID, origin: .recovery(operationID: UUID()),
      validateBeforeSubmit: { false }, paste: {}, submit: {})
    coordinator.observePrompt(.empty, in: paneID)
    coordinator.observePrompt(.unknown, in: paneID)
    coordinator.observePrompt(.empty, in: paneID)
    #expect(coordinator.hasResidualDraft(in: paneID))
    #expect(!coordinator.canSubmitProgrammaticInput(in: paneID))
    coordinator.observePrompt(.occupied, in: paneID)
    coordinator.observePrompt(.unknown, in: paneID)
    #expect(coordinator.hasResidualDraft(in: paneID))
    coordinator.observePrompt(.empty, in: paneID)
    #expect(!coordinator.hasResidualDraft(in: paneID))
  }

  @Test func occupiedFrameBeforeInterruptionCannotResolveALaterDraft() async {
    let paneID = PaneID()
    let coordinator = PaneInputCoordinator(pauseBeforeSubmit: { await Task.yield() })
    coordinator.observePrompt(.occupied, in: paneID)
    _ = await coordinator.submitCommand(
      in: paneID, origin: .recovery(operationID: UUID()),
      validateBeforeSubmit: { false }, paste: {}, submit: {})
    coordinator.observePrompt(.empty, in: paneID)
    #expect(coordinator.hasResidualDraft(in: paneID))
    coordinator.resolveResidualDraft(in: paneID)
    #expect(!coordinator.hasResidualDraft(in: paneID))
  }

  @Test func aNewResidualDraftRequiresItsOwnVisibleTransition() async {
    let paneID = PaneID()
    let coordinator = PaneInputCoordinator(pauseBeforeSubmit: { await Task.yield() })
    for _ in 0..<2 {
      _ = await coordinator.submitCommand(
        in: paneID, origin: .recovery(operationID: UUID()),
        validateBeforeSubmit: { false }, paste: {}, submit: {})
      coordinator.observePrompt(.empty, in: paneID)
      #expect(coordinator.hasResidualDraft(in: paneID))
      coordinator.observePrompt(.occupied, in: paneID)
      coordinator.resolveResidualDraft(in: paneID)
    }
  }

  @Test func teardownForgetsResidualVisibility() async {
    let paneID = PaneID()
    let coordinator = PaneInputCoordinator(pauseBeforeSubmit: { await Task.yield() })
    _ = await coordinator.submitCommand(
      in: paneID, origin: .recovery(operationID: UUID()),
      validateBeforeSubmit: { false }, paste: {}, submit: {})
    coordinator.observePrompt(.occupied, in: paneID)
    coordinator.removePane(paneID)
    _ = await coordinator.submitCommand(
      in: paneID, origin: .recovery(operationID: UUID()),
      validateBeforeSubmit: { false }, paste: {}, submit: {})
    coordinator.observePrompt(.empty, in: paneID)
    #expect(coordinator.hasResidualDraft(in: paneID))
  }

  @Test func membershipRetiresPendingAndRevisionOnlyPanesWhilePreservingLiveLease() {
    let coordinator = PaneInputCoordinator()
    let pendingPane = PaneID()
    let revisionOnlyPane = PaneID()
    let livePane = PaneID()
    coordinator.beforeNativeInput(in: revisionOnlyPane)
    coordinator.beforeNativeInput(in: livePane)
    guard case .reserved(let pending) = coordinator.reserve(in: pendingPane, origin: .recovery(operationID: UUID())),
      case .reserved(let live) = coordinator.reserve(in: livePane, origin: .recovery(operationID: UUID()))
    else {
      Issue.record("Missing test leases")
      return
    }
    coordinator.reconcileMembership(livePaneIDs: [livePane])
    #expect(!coordinator.isValid(pending))
    #expect(coordinator.isValid(live))
    #expect(coordinator.revision(for: revisionOnlyPane) == 0)
    #expect(coordinator.revision(for: livePane) == 1)
  }

  @Test func membershipRetiresPastedOperationWithoutAStaleReturnOrDraft() async {
    let paneID = PaneID()
    let gate = Gate()
    let coordinator = PaneInputCoordinator(pauseBeforeSubmit: { await gate.pause() })
    var returns = 0
    let task = Task { @MainActor in
      await coordinator.submitCommand(
        in: paneID, origin: .recovery(operationID: UUID()),
        paste: {}, submit: { returns += 1 })
    }
    await gate.waitForPause()
    coordinator.reconcileMembership(livePaneIDs: [])
    gate.resume()
    #expect(await task.value == .interruptedWithDraft)
    #expect(returns == 0)
    #expect(!coordinator.hasResidualDraft(in: paneID))
    #expect(coordinator.canSubmitProgrammaticInput(in: paneID))
  }

  @Test func membershipRemovesResidualDraftAndItsVisibilityThroughTheNormalCallback() async {
    let paneID = PaneID()
    let coordinator = PaneInputCoordinator(pauseBeforeSubmit: { await Task.yield() })
    _ = await coordinator.submitCommand(
      in: paneID, origin: .recovery(operationID: UUID()),
      validateBeforeSubmit: { false }, paste: {}, submit: {})
    coordinator.observePrompt(.occupied, in: paneID)
    var changes: [Bool] = []
    coordinator.onResidualDraftChanged = { _, exists in changes.append(exists) }
    coordinator.reconcileMembership(livePaneIDs: [])
    #expect(changes == [false])
    #expect(!coordinator.hasResidualDraft(in: paneID))
    _ = await coordinator.submitCommand(
      in: paneID, origin: .recovery(operationID: UUID()),
      validateBeforeSubmit: { false }, paste: {}, submit: {})
    coordinator.observePrompt(.empty, in: paneID)
    #expect(coordinator.hasResidualDraft(in: paneID))
  }

  @Test func externalInputRevokesSubmissionDuringItsCustomEchoWait() async {
    let paneID = PaneID()
    let gate = Gate()
    var defaultWaits = 0
    let coordinator = PaneInputCoordinator(pauseBeforeSubmit: {
      defaultWaits += 1
      await Task.yield()
    })
    var writes: [String] = []
    let task = Task { @MainActor in
      await coordinator.submitCommand(
        in: paneID, origin: .user,
        waitBeforeSubmit: { await gate.pause() },
        paste: { writes.append("paste") }, submit: { writes.append("return") })
    }
    await gate.waitForPause()
    coordinator.beforeNativeInput(in: paneID)
    gate.resume()
    #expect(await task.value == .interruptedWithDraft)
    #expect(writes == ["paste"])
    #expect(defaultWaits == 0)
    #expect(coordinator.hasResidualDraft(in: paneID))
  }

  @MainActor
  private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    func pause() async {
      await withCheckedContinuation { continuation in
        self.continuation = continuation
        let pending = observers
        observers.removeAll()
        for observer in pending { observer.resume() }
      }
    }

    func waitForPause() async {
      if continuation != nil { return }
      await withCheckedContinuation { observers.append($0) }
    }

    func resume() {
      continuation?.resume()
      continuation = nil
    }
  }
}
