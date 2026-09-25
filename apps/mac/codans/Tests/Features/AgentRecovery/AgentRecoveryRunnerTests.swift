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
    var generation = UUID()
    var isError = true
    var visible = true
    var processGroupID: Int32 = 123
    var processStartedAt = Date(timeIntervalSinceReferenceDate: 100)
    var now = Date(timeIntervalSinceReferenceDate: 1000)
    var deliveries = 0
    var validateAfterSuspension: AgentRecoveryRunner.Validation?

    var target: AgentRecoveryRunner.Target {
      .init(
        paneID: paneID, generation: generation, kind: .codex, sessionID: "session",
        directory: URL(fileURLWithPath: "/tmp"), isError: isError,
        processGroupID: processGroupID, processStartedAt: processStartedAt
      )
    }

    func runner() -> AgentRecoveryRunner {
      AgentRecoveryRunner(
        policy: { self.policy },
        targets: { self.visible ? [self.target] : [] },
        deliver: { _, _, _, validate in
          self.deliveries += 1
          self.validateAfterSuspension = validate
        },
        now: { self.now }
      )
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
    h.isError = false
    runner.drain()
    h.advance(60)
    runner.drain()
    h.isError = true
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

  @Test func keyboardOrRebindRequiresFreshDelay() async {
    let h = Harness()
    let runner = h.runner()
    runner.drain()
    h.advance()
    h.generation = UUID()
    runner.drain()
    await settle()
    #expect(h.deliveries == 0)
    h.advance()
    runner.drain()
    await settle()
    #expect(h.deliveries == 1)
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
    #expect(h.validateAfterSuspension?(true) == true)
    h.isError = false
    #expect(h.validateAfterSuspension?(true) == false)
    #expect(h.validateAfterSuspension?(false) == true)
    h.generation = UUID()
    #expect(h.validateAfterSuspension?(false) == false)
  }

  @Test func idleComposerDuringPasteDoesNotCancelPendingReturn() async {
    let h = Harness()
    var continuation: CheckedContinuation<Void, Never>?
    var wasCancelled: Bool?
    let runner = AgentRecoveryRunner(
      policy: { h.policy }, targets: { [h.target] },
      deliver: { _, _, _, validate in
        await withCheckedContinuation { continuation = $0 }
        wasCancelled = Task.isCancelled || !validate(false)
      },
      now: { h.now }
    )
    runner.drain()
    h.advance()
    runner.drain()
    await settle()
    h.isError = false
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
    #expect(h.validateAfterSuspension?(false) == true)
    h.processStartedAt.addTimeInterval(1)
    #expect(h.validateAfterSuspension?(false) == false)
    h.processStartedAt.addTimeInterval(-1)
    h.processGroupID += 1
    #expect(h.validateAfterSuspension?(false) == false)
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

  @Test func scriptUsesBoundedRunnerWithSessionContext() async throws {
    let h = Harness()
    h.policy.action = .script
    h.policy.script = "echo recovery"
    let recorder = RecordingCommandRunner()
    await AgentRecoveryRunner.runScript(
      target: h.target, policy: h.policy, attempt: 2, runner: recorder, validate: { _ in true }
    )
    let calls = await recorder.calls
    let call = try #require(calls.first)
    #expect(call.executable.path == "/bin/zsh")
    #expect(call.arguments == ["-lc", "echo recovery"])
    #expect(call.cwd.path == "/tmp")
    #expect(call.timeout == .seconds(30))
    #expect(call.maxOutputBytes == 65_536)
    #expect(call.env["CODANS_AGENT_SESSION_ID"] == "session")
    #expect(call.env["CODANS_RECOVERY_ATTEMPT"] == "2")
  }

  @Test func invalidatedScriptDoesNotLaunch() async {
    let h = Harness()
    let recorder = RecordingCommandRunner()
    await AgentRecoveryRunner.runScript(
      target: h.target, policy: h.policy, attempt: 1, runner: recorder, validate: { _ in false }
    )
    #expect(await recorder.calls.isEmpty)
  }
}
