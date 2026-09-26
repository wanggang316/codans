import CodansCore
import Foundation
import Testing

@testable import Codans

@MainActor
struct AgentRecoveryRunnerTests {
  @MainActor
  final class Harness {
    var policy = AgentRecoveryPolicy(isEnabled: true, delaySeconds: 5, maxAttempts: 2)
    let paneID = PaneID()
    var instanceID = AgentInstanceID()
    let surfaceGeneration = UUID()
    var externalInputRevision: UInt64 = 0
    var stateRevision: UInt64 = 1
    var state: AgentState = .error(AgentFailure(reason: .transient, message: "Connection failed"))
    var inputAvailability: AgentInputAvailability = .prompt(.empty)
    var observationInstanceID: AgentInstanceID?
    var observationAge: TimeInterval = 0
    var hasObservation = true
    var identityIsValid = true
    var isSuppressed = false
    var hasResidualDraft = false
    var visible = true
    var processGroupID: Int32 = 123
    var processStartedAt = Date(timeIntervalSinceReferenceDate: 100)
    var now = Date(timeIntervalSinceReferenceDate: 1000)
    var deliveries = 0
    var offers = 0
    var beginAutomatically = true
    var deliveredInstances: [AgentInstanceID] = []
    var validateAfterSuspension: AgentRecoveryRunner.Validation?
    var beginAfterSuspension: AgentRecoveryRunner.StartAttempt?

    var isError: Bool {
      get {
        if case .error = state { return true }
        return false
      }
      set { state = newValue ? .error(AgentFailure(reason: .transient, message: "Connection failed")) : .idle }
    }

    var target: AgentRecoveryRunner.Target {
      let binding = AgentBinding(
        instanceID: instanceID, paneID: paneID, surfaceGeneration: surfaceGeneration,
        kind: .codex,
        process: AgentProcessIdentity(
          processID: processGroupID, processStartedAt: processStartedAt, processGroupID: processGroupID),
        sessionID: "session")
      let observation = AgentObservation(
        instanceID: observationInstanceID ?? instanceID, stateRevision: stateRevision,
        sequence: 1, observedAt: now.addingTimeInterval(-observationAge), state: state,
        inputAvailability: inputAvailability)
      return .init(
        binding: binding, externalInputRevision: externalInputRevision,
        directory: URL(fileURLWithPath: "/tmp"), observation: hasObservation ? observation : nil,
        identityIsValid: identityIsValid, isSuppressed: isSuppressed, hasResidualDraft: hasResidualDraft)
    }

    func runner() -> AgentRecoveryRunner {
      AgentRecoveryRunner(
        policy: { self.policy }, targets: { self.visible ? [self.target] : [] },
        deliver: { target, _, _, validate, begin in
          self.offers += 1
          self.validateAfterSuspension = validate
          self.beginAfterSuspension = begin
          if self.beginAutomatically, begin() {
            self.deliveries += 1
            self.deliveredInstances.append(target.binding.instanceID)
          }
        },
        now: { self.now })
    }

    func advance(_ seconds: TimeInterval = 5) { now.addTimeInterval(seconds) }
  }

  private func settle() async {
    for _ in 0..<10 { await Task.yield() }
  }

  @Test func waitsThenStopsAtAttemptLimitDespiteRepeatedFrames() async {
    let h = Harness()
    let runner = h.runner()
    runner.drain()
    #expect(h.deliveries == 0)
    for _ in 0..<6 {
      h.advance()
      runner.drain()
      runner.drain()
      await settle()
    }
    #expect(h.deliveries == 2)
  }

  @Test func workingDoesNotRestoreSpentBudget() async {
    let h = Harness()
    let runner = h.runner()
    runner.drain()
    h.advance()
    runner.drain()
    await settle()
    h.state = .working
    runner.drain()
    h.advance(60)
    runner.drain()
    h.isError = true
    h.stateRevision += 1
    runner.drain()
    #expect(h.deliveries == 1)
    h.advance()
    runner.drain()
    await settle()
    h.advance()
    runner.drain()
    await settle()
    #expect(h.deliveries == 2)
  }

  @Test func externalInputRequiresFreshDelay() async {
    let h = Harness()
    let runner = h.runner()
    runner.drain()
    h.advance()
    h.externalInputRevision += 1
    runner.drain()
    await settle()
    #expect(h.deliveries == 0)
    h.advance()
    runner.drain()
    await settle()
    #expect(h.deliveries == 1)
  }

  @Test func sameKindReplacementCannotInheritWaitingError() async {
    let h = Harness()
    let oldInstance = h.instanceID
    let runner = h.runner()
    runner.drain()
    h.advance()
    h.instanceID = AgentInstanceID()
    h.processGroupID = 456
    h.observationInstanceID = oldInstance
    runner.drain()
    h.advance(60)
    runner.drain()
    await settle()
    #expect(h.deliveries == 0)
    h.observationInstanceID = nil
    h.stateRevision = 1
    runner.drain()
    await settle()
    #expect(h.deliveries == 0)
    h.advance()
    runner.drain()
    await settle()
    #expect(h.deliveredInstances == [h.instanceID])
  }

  @Test func closingPaneOrChangingPolicyInvalidatesPendingDelivery() async {
    let h = Harness()
    let runner = h.runner()
    runner.drain()
    h.advance()
    runner.drain()
    h.visible = false
    await settle()
    #expect(h.deliveries == 0)
    h.visible = true
    h.policy.isEnabled = false
    runner.drain()
    h.advance(60)
    runner.drain()
    await settle()
    #expect(h.deliveries == 0)
  }

  @Test func validationRechecksBetweenPasteAndReturn() async {
    let h = Harness()
    let runner = h.runner()
    runner.drain()
    h.advance()
    runner.drain()
    await settle()
    #expect(h.validateAfterSuspension?(.beforeWrite) == true)
    h.isError = false
    h.inputAvailability = .prompt(.occupied)
    #expect(h.validateAfterSuspension?(.beforeWrite) == false)
    #expect(h.validateAfterSuspension?(.beforeSubmit) == true)
    h.externalInputRevision += 1
    #expect(h.validateAfterSuspension?(.beforeSubmit) == false)
  }

  @Test func idleComposerDuringPasteDoesNotCancelPendingReturn() async {
    let h = Harness()
    var continuation: CheckedContinuation<Void, Never>?
    var wasCancelled: Bool?
    let runner = AgentRecoveryRunner(
      policy: { h.policy }, targets: { [h.target] },
      deliver: { _, _, _, validate, begin in
        #expect(begin())
        await withCheckedContinuation { continuation = $0 }
        wasCancelled = Task.isCancelled || !validate(.beforeSubmit)
      }, now: { h.now })
    runner.drain()
    h.advance()
    runner.drain()
    await settle()
    h.isError = false
    h.inputAvailability = .prompt(.occupied)
    runner.drain()
    continuation?.resume()
    await settle()
    #expect(wasCancelled == false)
  }

  @Test func replacementForegroundProcessInvalidatesDelivery() async {
    let h = Harness()
    let runner = h.runner()
    runner.drain()
    h.advance()
    runner.drain()
    await settle()
    #expect(h.validateAfterSuspension?(.beforeSubmit) == true)
    h.processStartedAt.addTimeInterval(1)
    #expect(h.validateAfterSuspension?(.beforeSubmit) == false)
    h.processStartedAt.addTimeInterval(-1)
    h.processGroupID += 1
    #expect(h.validateAfterSuspension?(.beforeSubmit) == false)
  }

  @Test func invalidPoliciesAndNonErrorTargetsNeverDispatch() async {
    let h = Harness()
    h.policy.prompt = " "
    let runner = h.runner()
    runner.drain()
    h.advance(60)
    runner.drain()
    await settle()
    #expect(h.deliveries == 0)
    h.policy.prompt = "Retry"
    h.isError = false
    runner.drain()
    h.advance(60)
    runner.drain()
    await settle()
    #expect(h.deliveries == 0)
  }

  @Test func promptRequiresVerifiedEmptyComposer() async {
    for availability: AgentInputAvailability in [
      .unknown, .unavailable, .choice, .prompt(.unknown), .prompt(.occupied),
    ] {
      let h = Harness()
      h.inputAvailability = availability
      let runner = h.runner()
      runner.drain()
      h.advance(60)
      runner.drain()
      await settle()
      #expect(h.offers == 0)
      h.inputAvailability = .prompt(.empty)
      runner.drain()
      await settle()
      #expect(h.deliveries == 0)
      h.advance()
      runner.drain()
      await settle()
      #expect(h.deliveries == 1)
    }
  }

  @Test func scriptDoesNotRequirePromptReadiness() async {
    let h = Harness()
    h.policy.action = .script
    h.policy.script = "echo recovery"
    h.inputAvailability = .unavailable
    let runner = h.runner()
    runner.drain()
    h.advance()
    runner.drain()
    await settle()
    #expect(h.deliveries == 1)
  }

  @Test func policyChangesInvalidateTicketsWithoutReplenishingBudget() async {
    let h = Harness()
    h.policy.maxAttempts = 1
    let runner = h.runner()
    runner.drain()
    h.advance()
    runner.drain()
    await settle()
    #expect(h.deliveries == 1)
    h.policy.prompt = "Try again"
    #expect(h.validateAfterSuspension?(.beforeWrite) == false)
    runner.drain()
    h.advance(60)
    runner.drain()
    await settle()
    #expect(h.deliveries == 1)
    h.externalInputRevision += 1
    runner.drain()
    h.advance()
    runner.drain()
    await settle()
    #expect(h.deliveries == 2)
  }

  @Test func unknownOrIdentityUncertaintyDoesNotRestoreBudget() async {
    let h = Harness()
    h.policy.maxAttempts = 1
    let runner = h.runner()
    runner.drain()
    h.advance()
    runner.drain()
    await settle()
    h.identityIsValid = false
    h.state = .unknown
    runner.drain()
    h.advance(60)
    h.identityIsValid = true
    h.isError = true
    runner.drain()
    h.advance()
    runner.drain()
    await settle()
    #expect(h.deliveries == 1)
  }

  @Test func newErrorOccurrenceRequiresAFullDelay() async {
    let h = Harness()
    let runner = h.runner()
    runner.drain()
    h.advance(4)
    h.stateRevision += 1
    runner.drain()
    h.advance(1)
    runner.drain()
    await settle()
    #expect(h.deliveries == 0)
    h.advance(4)
    runner.drain()
    await settle()
    #expect(h.deliveries == 1)
    h.stateRevision += 1
    #expect(h.validateAfterSuspension?(.beforeWrite) == false)
    #expect(h.validateAfterSuspension?(.beforeSubmit) == false)
  }

  @Test(arguments: [false, true])
  func lateCompletionCannotShortenAReplacementTicketsDelay(policyChanged: Bool) async {
    let h = Harness()
    h.policy.delaySeconds = 30
    var firstCompletion: CheckedContinuation<Void, Never>?
    let runner = AgentRecoveryRunner(
      policy: { h.policy }, targets: { [h.target] },
      deliver: { _, _, _, _, begin in
        guard begin() else { return }
        h.deliveries += 1
        if h.deliveries == 1 {
          await withCheckedContinuation { firstCompletion = $0 }
        }
      }, now: { h.now })
    runner.drain()
    h.advance(30)
    runner.drain()
    await settle()
    #expect(h.deliveries == 1)
    guard let firstCompletion else {
      Issue.record("The first delivery did not reach its suspension point")
      return
    }

    // While the old action is suspended, establish a new one-hour deadline
    // through either a new rate-limit occurrence or an explicit policy edit.
    h.advance(1)
    if policyChanged {
      h.policy.delaySeconds = 3600
    } else {
      h.stateRevision += 1
      h.state = .error(AgentFailure(reason: .rateLimited, message: "Rate limited", retryAfterSeconds: 3600))
    }
    runner.drain()
    firstCompletion.resume()
    await settle()

    h.advance(30)
    runner.drain()
    await settle()
    #expect(h.deliveries == 1)
    h.advance(3569)
    runner.drain()
    await settle()
    #expect(h.deliveries == 1)
    h.advance(1)
    runner.drain()
    await settle()
    #expect(h.deliveries == 2)
  }

  @Test func staleOrAbsentObservationCannotAuthorizeRecovery() async {
    let h = Harness()
    let runner = h.runner()
    h.observationAge = 3
    runner.drain()
    h.advance(60)
    runner.drain()
    await settle()
    #expect(h.offers == 0)
    h.observationAge = 0
    h.hasObservation = false
    runner.drain()
    h.advance(60)
    runner.drain()
    await settle()
    #expect(h.offers == 0)
  }

  @Test func unstartedDeliveryDoesNotSpendBudget() async {
    let h = Harness()
    h.policy.maxAttempts = 1
    h.beginAutomatically = false
    let runner = h.runner()
    runner.drain()
    h.advance()
    runner.drain()
    await settle()
    #expect(h.offers == 1)
    #expect(h.deliveries == 0)
    h.beginAutomatically = true
    h.advance()
    runner.drain()
    await settle()
    #expect(h.deliveries == 1)
    #expect(h.beginAfterSuspension?() == false)
    h.advance()
    runner.drain()
    await settle()
    #expect(h.offers == 2)
  }

  @Test func externalInputInvalidatesTicketBeforeFirstSideEffect() async {
    let h = Harness()
    let runner = h.runner()
    runner.drain()
    h.advance()
    runner.drain()
    h.externalInputRevision += 1
    await settle()
    #expect(h.offers == 0)
    #expect(h.deliveries == 0)
  }

  @Test func suppressedOrResidualDraftTargetsNeverDispatch() async {
    let h = Harness()
    let runner = h.runner()
    h.isSuppressed = true
    runner.drain()
    h.advance(60)
    runner.drain()
    await settle()
    #expect(h.offers == 0)
    h.policy.prompt = "Retry differently"
    runner.drain()
    h.advance(60)
    runner.drain()
    await settle()
    #expect(h.offers == 0)
    h.isSuppressed = false
    h.hasResidualDraft = true
    runner.drain()
    h.advance(60)
    runner.drain()
    await settle()
    #expect(h.offers == 0)
  }

  @Test func rateLimitRetryAfterExtendsTheDelay() async {
    let h = Harness()
    h.state = .error(AgentFailure(reason: .rateLimited, message: "Rate limited", retryAfterSeconds: 30))
    let runner = h.runner()
    runner.drain()
    h.advance(29)
    runner.drain()
    await settle()
    #expect(h.deliveries == 0)
    h.advance(1)
    runner.drain()
    await settle()
    #expect(h.deliveries == 1)
  }

  @Test func scriptUsesBoundedRunnerWithFrozenContext() async throws {
    let h = Harness()
    h.policy.action = .script
    h.policy.script = "echo recovery"
    let recorder = RecordingCommandRunner()
    var starts = 0
    await AgentRecoveryRunner.runScript(
      target: h.target, policy: h.policy, attempt: 2, runner: recorder,
      validate: { _ in true },
      begin: {
        starts += 1
        return true
      })
    let calls = await recorder.calls
    let call = try #require(calls.first)
    #expect(starts == 1)
    #expect(call.executable.path == "/bin/zsh")
    #expect(call.arguments == ["-lc", "echo recovery"])
    #expect(call.cwd.path == "/tmp")
    #expect(call.timeout == .seconds(30))
    #expect(call.maxOutputBytes == 65_536)
    #expect(call.env["CODANS_AGENT_SESSION_ID"] == "session")
    #expect(call.env["CODANS_AGENT_INSTANCE_ID"] == h.instanceID.rawValue.uuidString)
    #expect(call.env["CODANS_ERROR_STATE_REVISION"] == "1")
    #expect(call.env["CODANS_RECOVERY_ATTEMPT"] == "2")
  }

  @Test func invalidatedScriptDoesNotLaunchOrConsumeAttempt() async {
    let h = Harness()
    let recorder = RecordingCommandRunner()
    var starts = 0
    await AgentRecoveryRunner.runScript(
      target: h.target, policy: h.policy, attempt: 1, runner: recorder,
      validate: { _ in false },
      begin: {
        starts += 1
        return true
      })
    #expect(await recorder.calls.isEmpty)
    #expect(starts == 0)
    await AgentRecoveryRunner.runScript(
      target: h.target, policy: h.policy, attempt: 1, runner: recorder,
      validate: { _ in true }, begin: { false })
    #expect(await recorder.calls.isEmpty)
  }
}
