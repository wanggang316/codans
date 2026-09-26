import CodansCore
import Foundation
import Testing

@testable import Codans

@MainActor
struct AgentStateStoreTests {
  @Test
  func verifiedBindingStartsUnknownWithoutRecoveryEvidence() {
    let f = Fixture()
    f.bind()
    #expect(f.entry?.state == .unknown)
    #expect(f.entry?.binding == f.binding)
    #expect(f.entry?.observation == nil)
    #expect(f.entry?.recoveryEligible == false)
  }

  @Test
  func displayOnlyBindingCannotAuthorizeRecovery() {
    let f = Fixture()
    f.store.onAgentBound(f.paneID, kind: .claudeCode, sessionID: "remote-session")
    f.viewport("API Error: 503\n❯")
    #expect(f.entry?.state == .error)
    #expect(f.entry?.observation != nil)
    #expect(f.entry?.binding == nil)
    #expect(f.entry?.recoveryEligible == false)
  }

  @Test
  func prebindTextCanPopulateDisplayButNotVerifiedOwnership() {
    let f = Fixture()
    f.viewport("✢ Editing…")
    #expect(f.entry == nil)
    f.store.onAgentBound(f.paneID, kind: .claudeCode, sessionID: nil)
    #expect(f.entry?.state == .working)
    f.bind()
    #expect(f.entry?.state == .unknown)
    #expect(f.entry?.observation == nil)
  }

  @Test
  func verifiedBindingIgnoresUntaggedAndMismatchedSnapshots() {
    let f = Fixture()
    f.bind()
    f.viewport("API Error: 503\n❯")
    #expect(f.entry?.observation == nil)
    let other = f.makeBinding()
    f.snapshot("API Error: 503\n❯", binding: other)
    #expect(f.entry?.state == .unknown)
    #expect(f.entry?.observation == nil)
    f.snapshot("API Error: 503\n❯")
    #expect(f.entry?.state == .error)
    #expect(f.entry?.observation?.instanceID == f.binding.instanceID)
    #expect(f.entry?.recoveryEligible == true)
  }

  @Test
  func repeatedCapturesRefreshLivenessWithoutInventingOccurrences() {
    let f = Fixture()
    f.bind()
    f.snapshot("API Error: 503\n❯", sequence: 10)
    let before = f.entry?.observation
    let transition = f.entry?.lastTransitionAt
    f.context.now.addTimeInterval(1)
    f.snapshot("API Error: 503\n❯", sequence: 11)
    let after = f.entry?.observation
    #expect(after?.stateRevision == before?.stateRevision)
    #expect(after?.sequence == (before?.sequence ?? 0) + 1)
    #expect(after?.observedAt == f.context.now)
    #expect(f.entry?.lastTransitionAt == transition)
    f.snapshot("❯", sequence: 11)
    f.snapshot("❯", sequence: 9)
    #expect(f.entry?.observation == after)
  }

  @Test
  func identityUncertaintySuspendsRecoveryUntilFreshVerifiedCapture() {
    let f = Fixture()
    f.bind()
    f.snapshot("API Error: 503\n❯")
    let observation = f.entry?.observation
    f.store.onBindingValidityChanged(paneID: f.paneID, valid: false)
    #expect(f.entry?.recoveryEligible == false)
    #expect(f.entry?.observation == observation)
    f.context.now.addTimeInterval(1)
    f.snapshot("API Error: 503\n❯")
    #expect(f.entry?.recoveryEligible == true)
    #expect(f.entry?.observation?.stateRevision == observation?.stateRevision)
  }

  @Test
  func replacementRejectsLateResultsAndExcludesOldBanners() {
    let f = Fixture()
    f.bind()
    f.snapshot("API Error: 503\n❯")
    let old = f.binding
    let replacement = f.makeBinding(processID: 202)
    f.store.onAgentBound(replacement)
    #expect(f.entry?.state == .unknown)
    #expect(f.entry?.observation == nil)
    f.snapshot("API Error: 401\n❯", binding: old, sequence: 99)
    #expect(f.entry?.observation == nil)
    f.snapshot("API Error: 503\n❯", binding: replacement, sequence: 1)
    #expect(f.entry?.state == .idle)
    #expect(f.entry?.recoveryEligible == false)
    f.snapshot("API Error: 504\n❯", binding: replacement, sequence: 2)
    #expect(f.entry?.state == .error)
    #expect(f.entry?.recoveryEligible == true)
  }

  @Test
  func replacementFirstCaptureExcludesBannersNeverSeenInTheOldProcess() {
    let f = Fixture()
    f.bind()
    f.snapshot("❯")
    let replacement = f.makeBinding(processID: 202)
    f.store.onAgentBound(replacement)
    // The previous process paints this error after its last sampled idle frame.
    f.snapshot("API Error: 503\n❯", binding: f.binding, sequence: 99)
    #expect(f.entry?.observation == nil)
    f.snapshot("API Error: 503\n❯", binding: replacement, sequence: 5)
    #expect(f.entry?.state == .idle)
    #expect(f.entry?.recoveryEligible == false)
    let baseline = f.entry?.observation
    // An out-of-order working frame cannot establish a new interaction.
    f.snapshot("✢ Editing…", binding: replacement, sequence: 4)
    #expect(f.entry?.observation == baseline)
    f.snapshot("API Error: 503\n❯", binding: replacement, sequence: 6)
    #expect(f.entry?.recoveryEligible == false)
    #expect(f.entry?.observation?.stateRevision == baseline?.stateRevision)
    f.snapshot("API Error: 504\n❯", binding: replacement, sequence: 7)
    #expect(f.entry?.state == .error)
    #expect(f.entry?.recoveryEligible == true)
  }

  @Test
  func replacementBannerRequiresDisappearanceOrVerifiedInteractionBeforeReuse() {
    for progress in ["❯", "✢ Editing…", "Do you want to proceed? yes"] {
      let f = Fixture()
      f.bind()
      f.snapshot("❯")
      let replacement = f.makeBinding(processID: 202)
      f.store.onAgentBound(replacement)
      f.snapshot("API Error: 503", binding: replacement, sequence: 1)
      #expect(f.entry?.state == .unknown)
      #expect(f.entry?.recoveryEligible == false)
      f.snapshot(progress, binding: replacement, sequence: 2)
      f.snapshot("API Error: 503\n❯", binding: replacement, sequence: 3)
      #expect(f.entry?.state == .error)
      #expect(f.entry?.recoveryEligible == true)
    }
  }

  @Test
  func initialBindingAndSameInstanceEnrichmentDoNotAcquireReplacementBaselines() {
    let f = Fixture()
    f.bind()
    let enriched = f.makeBinding(
      instanceID: f.binding.instanceID,
      surfaceGeneration: f.binding.surfaceGeneration, sessionID: "known-session")
    f.store.onAgentBound(enriched)
    f.snapshot("API Error: 503\n❯", binding: enriched, sequence: 1)
    #expect(f.entry?.state == .error)
    #expect(f.entry?.recoveryEligible == true)
    let accepted = f.entry?.observation
    f.store.onAgentBound(enriched)
    f.snapshot("API Error: 503\n❯", binding: enriched, sequence: 2)
    #expect(f.entry?.observation?.stateRevision == accepted?.stateRevision)
    #expect(f.entry?.recoveryEligible == true)
  }

  @Test
  func sameInstanceWrongSurfaceOrProcessSnapshotIsRejected() {
    let f = Fixture()
    f.bind()
    let changedSurface = f.makeBinding(instanceID: f.binding.instanceID)
    f.snapshot("API Error: 503", binding: changedSurface)
    #expect(f.entry?.observation == nil)
    let changedProcess = f.makeBinding(
      instanceID: f.binding.instanceID,
      surfaceGeneration: f.binding.surfaceGeneration, processID: 202)
    f.snapshot("API Error: 503", binding: changedProcess)
    #expect(f.entry?.observation == nil)
  }

  @Test
  func unchangedSessionEnrichmentPreservesCancellationAndInputScope() {
    let f = Fixture()
    f.bind()
    f.snapshot("API Error: 503\n❯")
    f.store.onExternalInput(f.paneID, revision: 8)
    f.store.cancelRecovery(for: f.paneID)
    let old = f.entry?.observation
    let enriched = f.makeBinding(
      instanceID: f.binding.instanceID,
      surfaceGeneration: f.binding.surfaceGeneration, sessionID: "known-session")
    f.store.onAgentBound(enriched)
    #expect(f.entry?.externalInputRevision == 8)
    #expect(f.entry?.recoverySuppressed == true)
    #expect(f.entry?.observation == old)
    #expect(f.entry?.sessionID == "known-session")
  }

  @Test
  func acceptedIdleIsSeparateFromWorkingDisplayHoldAndFinishedAttention() {
    let f = Fixture()
    f.bind()
    f.snapshot("✢ Editing…")
    f.snapshot("❯")
    #expect(f.entry?.observation?.state == .idle)
    #expect(f.entry?.state == .working)
    f.finishHold()
    #expect(f.entry?.state == .finished)
    #expect(f.entry?.observation?.state == .idle)
    f.store.onPaneFocused(f.paneID)
    #expect(f.entry?.state == .idle)
  }

  @Test
  func unknownOrFailureDoesNotBecomeCompletion() {
    let f = Fixture()
    f.bind()
    f.snapshot("✢ Editing…")
    f.snapshot("Unrecognized provider screen")
    f.finishHold()
    #expect(f.entry?.state == .unknown)
    #expect(f.entry?.observation?.inputAvailability == .unknown)
    f.snapshot("❯")
    #expect(f.entry?.state == .idle)
    f.snapshot("API Error: 503\n❯")
    f.snapshot("❯")
    #expect(f.entry?.state == .idle)
  }

  @Test
  func staleFinishedAttentionDoesNotSurviveANewFailureOrUnknownInteraction() {
    for next in ["API Error: 503\n❯", "Unrecognized provider screen"] {
      let f = Fixture()
      f.bind()
      f.snapshot("✢ Editing…")
      f.snapshot("❯")
      f.finishHold()
      #expect(f.entry?.state == .finished)
      f.snapshot(next)
      f.snapshot("❯")
      #expect(f.entry?.state == .idle)
    }
  }

  @Test
  func focusedCompletionStaysIdleAndFocusNeverDismissesAnError() {
    let f = Fixture()
    f.context.focused = f.paneID
    f.bind()
    f.snapshot("✢ Editing…")
    f.snapshot("❯")
    f.finishHold()
    #expect(f.entry?.state == .idle)
    f.snapshot("API Error: 503\n❯")
    let observation = f.entry?.observation
    f.store.onPaneFocused(f.paneID)
    #expect(f.entry?.state == .error)
    #expect(f.entry?.observation == observation)
    #expect(f.entry?.recoveryEligible == true)
  }

  @Test
  func externalInputInvalidatesErrorAndSuppressesItsComposerRepaints() {
    let f = Fixture()
    f.bind()
    f.snapshot("API Error: 503\n❯")
    let old = f.entry?.observation
    f.store.onExternalInput(f.paneID, revision: 7)
    #expect(f.entry?.state == .unknown)
    #expect(f.entry?.observation?.stateRevision != old?.stateRevision)
    #expect(f.entry?.externalInputRevision == 7)
    #expect(f.entry?.recoveryEligible == false)
    f.snapshot("API Error: 503\n❯ typing a draft")
    #expect(f.entry?.state == .idle)
    #expect(f.entry?.observation?.inputAvailability == .prompt(.occupied))
    f.snapshot("API Error: 503\n❯")
    #expect(f.entry?.recoveryEligible == false)
    f.snapshot("✢ Editing…")
    f.snapshot("API Error: 503\n❯")
    #expect(f.entry?.recoveryEligible == true)
    #expect(f.entry?.externalInputRevision == 7)
  }

  @Test
  func cancellationSurvivesAutonomousStateChangesUntilExternalInput() {
    let f = Fixture()
    f.bind()
    f.snapshot("API Error: 503\n❯")
    f.store.cancelRecovery(for: f.paneID)
    #expect(f.entry?.state == .error)
    #expect(f.entry?.recoveryEligible == false)
    f.snapshot("✢ Editing…")
    f.snapshot("API Error: 504\n❯")
    #expect(f.entry?.recoverySuppressed == true)
    f.store.onPaneFocused(f.paneID)
    #expect(f.entry?.recoverySuppressed == true)
    f.store.onExternalInput(f.paneID, revision: 1)
    #expect(f.entry?.recoverySuppressed == false)
  }

  @Test
  func draftMarkerSurvivesArbitraryTypingAndRequiresExplicitResolution() {
    let f = Fixture()
    f.bind()
    f.snapshot("API Error: 503\n❯")
    f.store.setResidualDraft(true, for: f.paneID)
    #expect(f.entry?.recoveryEligible == false)
    f.store.onPaneKeyboardActivity(f.paneID)
    f.snapshot("API Error: 504\n❯")
    #expect(f.entry?.hasResidualDraft == true)
    #expect(f.entry?.recoveryEligible == false)
    f.store.setResidualDraft(false, for: f.paneID)
    #expect(f.entry?.recoveryEligible == true)
  }

  @Test
  func restoredBadgesAreDisplayOnlyAndGiveWayToVerifiedOwnership() {
    for state in [AgentStateStore.AgentRuntimeState.working, .blocked, .error, .finished] {
      let f = Fixture()
      f.store.seedRestored([(paneID: f.paneID, kind: .claudeCode, state: state)])
      f.store.onAgentBound(f.paneID, kind: .claudeCode, sessionID: nil)
      #expect(f.entry?.state == state)
      #expect(f.entry?.observation == nil)
      #expect(f.entry?.recoveryEligible == false)
      f.bind()
      #expect(f.entry?.state == .unknown)
      #expect(f.entry?.observation == nil)
      f.snapshot("API Error: 503\n❯")
      #expect(f.entry?.recoveryEligible == true)
    }
  }

  @Test
  func nonObservationNotificationsDoNotOverrideAcceptedFacts() {
    let f = Fixture()
    f.bind()
    f.snapshot("✢ Editing…")
    let before = f.entry?.observation
    f.store.onTerminalEvent(.paneOutput(f.paneID, Data("noise".utf8)))
    f.store.onTerminalEvent(.paneInfoChanged(f.paneID, .bellRang))
    f.store.onTerminalEvent(.paneInfoChanged(f.paneID, .desktopNotification(title: "Input needed", body: "Approve?")))
    f.store.onTerminalEvent(.paneInfoChanged(f.paneID, .title("Done")))
    #expect(f.entry?.state == .working)
    #expect(f.entry?.observation == before)
    #expect(f.store.title(for: f.paneID) == "Done")
  }

  @Test
  func teardownDropsEntriesAndObservationsCannotResurrectThem() {
    let f = Fixture()
    f.bind()
    f.snapshot("API Error: 503\n❯")
    f.store.onAgentUnbound(f.paneID)
    f.snapshot("API Error: 503\n❯")
    #expect(f.entry == nil)
    f.bind()
    f.store.onTerminalEvent(.paneCrashed(f.paneID, reason: "crashed"))
    #expect(f.entry == nil)
    f.bind()
    f.store.onTerminalEvent(.paneExited(f.paneID, code: 1, signal: nil))
    #expect(f.entry == nil)
  }

  @Test
  func membershipReconcileRemovesAbsentEntriesAndPrebindScratch() {
    let f = Fixture()
    let other = PaneID()
    f.bind()
    f.store.onTerminalEvent(.paneInfoChanged(other, .title("orphan")))
    f.store.onAgentBound(other, kind: .omp, sessionID: nil)
    f.store.reconcileMembership(livePaneIDs: [f.paneID])
    #expect(f.entry != nil)
    #expect(f.store.entries[other] == nil)
    #expect(f.store.title(for: other) == nil)
  }

  @Test
  func titleObservedBeforeBindingSurvivesAndTeardownClearsIt() {
    let f = Fixture()
    f.store.onTerminalEvent(.paneInfoChanged(f.paneID, .title("prebind")))
    f.bind()
    #expect(f.store.title(for: f.paneID) == "prebind")
    f.store.onAgentUnbound(f.paneID)
    #expect(f.store.title(for: f.paneID) == nil)
  }

  @MainActor
  final class Fixture {
    final class Context {
      var now = Date(timeIntervalSince1970: 100)
      var focused: PaneID?
    }
    let paneID = PaneID()
    let context = Context()
    let store: AgentStateStore
    let binding: AgentBinding
    private var sequence: UInt64 = 0
    var entry: AgentStateStore.AgentEntry? { store.entries[paneID] }

    init() {
      let context = self.context
      store = AgentStateStore(focusedPane: { context.focused }, now: { context.now })
      binding = AgentBinding(
        paneID: paneID, surfaceGeneration: UUID(), kind: .claudeCode,
        process: .init(processID: 101, processStartedAt: .distantPast, processGroupID: 100), sessionID: nil)
    }

    func makeBinding(
      instanceID: AgentInstanceID = .init(), surfaceGeneration: UUID = UUID(),
      processID: Int32 = 101, sessionID: String? = nil
    ) -> AgentBinding {
      AgentBinding(
        instanceID: instanceID, paneID: paneID, surfaceGeneration: surfaceGeneration,
        kind: .claudeCode, process: .init(processID: processID, processStartedAt: .distantPast, processGroupID: 100),
        sessionID: sessionID)
    }

    func bind() { store.onAgentBound(binding) }
    func viewport(_ text: String) { store.onTerminalEvent(.paneViewportChanged(paneID, text: text)) }
    func snapshot(_ text: String, binding: AgentBinding? = nil, sequence: UInt64? = nil) {
      self.sequence += 1
      store.onTerminalEvent(
        .paneAgentSnapshot(
          .init(
            binding: binding ?? self.binding,
            sequence: sequence ?? self.sequence, observedAt: context.now, text: text)))
    }
    func finishHold() {
      context.now.addTimeInterval(PaneAttentionInterpreter.agentWorkingHold + 0.1)
      store.onTerminalEvent(.paneIdle(paneID, duration: 30))
    }
  }
}
