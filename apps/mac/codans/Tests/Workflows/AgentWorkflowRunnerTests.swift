import CodansCore
import Foundation
import Testing

@testable import Codans

@MainActor
struct AgentWorkflowRunnerTests {
  private final class Launcher {
    var specs: [AgentLaunchSpec] = []
    var panes: [PaneID] = []
    var shouldFail = false
    var shouldSuspend = false
    var continuation: CheckedContinuation<Void, Never>?
    var sentPrompts: [String] = []

    func launch(_ spec: AgentLaunchSpec) async throws -> AgentLaunchOutcome {
      specs.append(spec)
      if shouldFail { throw CocoaError(.fileNoSuchFile) }
      if shouldSuspend {
        await withCheckedContinuation { continuation = $0 }
      }
      let pane = PaneID()
      panes.append(pane)
      return AgentLaunchOutcome(profile: spec.profile, command: "agent", tabID: TabID(), paneID: pane)
    }
  }

  private final class ClaimClock {
    var duration: Duration?
    var continuation: CheckedContinuation<Void, Never>?

    func sleep(_ duration: Duration) async {
      self.duration = duration
      await withCheckedContinuation { continuation = $0 }
    }

    func expire() {
      continuation?.resume()
      continuation = nil
    }
  }

  private func makeRunner(store: AgentWorkflowStore, launcher: Launcher) -> AgentWorkflowRunner {
    AgentWorkflowRunner(
      store: store, launch: { try await launcher.launch($0) },
      sendPrompt: { _, _, prompt, isLive in
        guard isLive() else { return false }
        launcher.sentPrompts.append(prompt)
        return true
      }, cli: "env CODANS_SOCKET_PATH='/tmp/workflow socket' '/tmp/codans app/codans'")
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-runner-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func settle(until condition: @MainActor () -> Bool) async {
    for _ in 0..<200 {
      if condition() { return }
      await Task.yield()
    }
    #expect(condition(), "Runner did not reach the expected state")
  }

  @Test
  func claimDeadlineRaisesAttentionWithoutRetryAndAllowsLateClaim() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentWorkflowStore(root: root)
    let launcher = Launcher()
    let clock = ClaimClock()
    let runner = AgentWorkflowRunner(
      store: store, launch: { try await launcher.launch($0) },
      sendPrompt: { _, _, _, _ in true }, cli: "codans", sleep: { await clock.sleep($0) })
    store.didChange = { [weak runner] in runner?.advance($0) }
    let id = try runner.start(
      template: .advisor, title: "Advice", input: "Question", projectID: ProjectID(),
      worktreeID: WorktreeID(), primary: AgentProfile(kind: .claudeCode), secondary: nil)
    await settle { clock.continuation != nil }
    #expect(clock.duration == .seconds(600))
    clock.expire()
    await settle { store.records[id]?.execution?.dispatches["advice"]?.status == .attention }
    #expect(launcher.specs.count == 1)
    let pane = try #require(launcher.panes.first).raw.uuidString
    let attempt = try store.claim(id, stepID: "advice", paneID: pane)
    _ = try store.deliver(id, attemptID: attempt.id, deliveryID: UUID(), paneID: pane, content: "Late advice")
    #expect(try store.status(id).readySteps.map(\.id) == ["disposition"])
    #expect(launcher.specs.count == 1)
  }

  @Test
  func claimDeadlineDoesNotRaiseAttentionAfterClaimOrCancel() async throws {
    for cancel in [false, true] {
      let root = try temporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let store = AgentWorkflowStore(root: root)
      let launcher = Launcher()
      let clock = ClaimClock()
      let runner = AgentWorkflowRunner(
        store: store, launch: { try await launcher.launch($0) },
        sendPrompt: { _, _, _, _ in true }, cli: "codans", sleep: { await clock.sleep($0) })
      store.didChange = { [weak runner] in runner?.advance($0) }
      let id = try runner.start(
        template: .advisor, title: "Advice", input: "Question", projectID: ProjectID(),
        worktreeID: WorktreeID(), primary: AgentProfile(kind: .claudeCode), secondary: nil)
      await settle { clock.continuation != nil }
      if cancel {
        _ = try store.cancel(id)
      } else {
        let pane = try #require(launcher.panes.first).raw.uuidString
        _ = try store.claim(id, stepID: "advice", paneID: pane)
      }
      let before = try store.status(id)
      clock.expire()
      for _ in 0..<10 { await Task.yield() }
      #expect(try store.status(id) == before)
      #expect(launcher.specs.count == 1)
    }
  }

  @Test
  func advisorLaunchesOnceAndLeavesDispositionForTheUser() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentWorkflowStore(root: root)
    let launcher = Launcher()
    let runner = makeRunner(store: store, launcher: launcher)
    let project = ProjectID()
    let worktree = WorktreeID()
    let profile = AgentProfile(kind: .claudeCode)
    let id = try runner.start(
      template: .advisor, title: "Advice", input: "Evaluate this design", projectID: project,
      worktreeID: worktree, primary: profile, secondary: nil)
    runner.advance(id)
    await settle { store.records[id]?.execution?.dispatches["advice"]?.status == .submitted }
    #expect(launcher.specs.count == 1)
    let spec = try #require(launcher.specs.first)
    #expect(spec.target == .newTab)
    #expect(!spec.focus)
    #expect(spec.prompt?.contains("workflow claim \(id.uuidString) --step advice --pane current --json") == true)
    #expect(spec.prompt?.contains("workflow deliver \(id.uuidString)") == true)
    #expect(
      spec.prompt?.contains("env CODANS_SOCKET_PATH='/tmp/workflow socket' '/tmp/codans app/codans' workflow claim")
        == true)
    let pane = try #require(launcher.panes.first)
    let attempt = try store.claim(id, stepID: "advice", paneID: pane.raw.uuidString)
    _ = try store.deliver(
      id, attemptID: attempt.id, deliveryID: UUID(), paneID: pane.raw.uuidString, content: "Recommendation")
    runner.advance(id)
    _ = try runner.start(
      id: id, template: .advisor, title: "Advice", input: "Evaluate this design", projectID: project,
      worktreeID: worktree, primary: profile, secondary: nil)
    await Task.yield()
    #expect(launcher.specs.count == 1)
    #expect(try store.status(id).readySteps.map(\.id) == ["disposition"])
    #expect(try store.status(id).status == .running)
  }

  @Test
  func committeeDispatchesSeriallyWithIndependentAnalysisAndBoundedReviewContext() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentWorkflowStore(root: root)
    let launcher = Launcher()
    let runner = makeRunner(store: store, launcher: launcher)
    let primary = AgentProfile(kind: .claudeCode, name: "A")
    let secondary = AgentProfile(kind: .claudeCode, name: "B")
    let id = try runner.start(
      template: .committee, title: "Review", input: "Compare designs", projectID: ProjectID(),
      worktreeID: WorktreeID(), primary: primary, secondary: secondary)
    let steps = ["analysis-a", "analysis-b", "review-a", "review-b", "synthesis"]
    for (index, step) in steps.enumerated() {
      runner.advance(id)
      await settle { store.records[id]?.execution?.dispatches[step]?.status == .submitted }
      #expect(launcher.specs.count == index + 1)
      let spec = launcher.specs[index]
      #expect(spec.profile.id == (["analysis-b", "review-b"].contains(step) ? secondary.id : primary.id))
      let prompt = try #require(spec.prompt)
      if step.hasPrefix("analysis-") {
        #expect(!prompt.contains("REPORT-analysis-"))
      } else {
        #expect(prompt.contains("REPORT-analysis-a"))
        #expect(prompt.contains("REPORT-analysis-b"))
      }
      if step.hasPrefix("review-") { #expect(!prompt.contains("REPORT-review-")) }
      if step == "synthesis" {
        #expect(prompt.contains("REPORT-review-a"))
        #expect(prompt.contains("REPORT-review-b"))
      }
      let pane = launcher.panes[index].raw.uuidString
      let attempt = try store.claim(id, stepID: step, paneID: pane)
      _ = try store.deliver(
        id, attemptID: attempt.id, deliveryID: UUID(), paneID: pane, content: "REPORT-\(step)")
      runner.advance(id)
    }
    #expect(try store.status(id).status == .succeeded)
    #expect(launcher.specs.count == 5)
  }

  @Test
  func cancellationDuringLaunchPreventsFallbackAndLaterDispatch() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentWorkflowStore(root: root)
    let launcher = Launcher()
    launcher.shouldSuspend = true
    let runner = makeRunner(store: store, launcher: launcher)
    let fallbackKind = try #require(
      AgentKind.allCases.first { !AgentCatalog.descriptor(for: $0).supportsInitialPrompt })
    let id = try runner.start(
      template: .advisor, title: "Advice", input: "Question", projectID: ProjectID(),
      worktreeID: WorktreeID(), primary: AgentProfile(kind: fallbackKind), secondary: nil)
    await settle { launcher.continuation != nil }
    _ = try store.cancel(id)
    launcher.continuation?.resume()
    launcher.continuation = nil
    await settle { !launcher.panes.isEmpty }
    runner.advance(id)
    await Task.yield()
    #expect(launcher.sentPrompts.isEmpty)
    #expect(launcher.specs.count == 1)
    #expect(try store.status(id).status == .cancelled)
  }

  @Test
  func manualResultDuringLaunchPreventsStalePromptInjection() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentWorkflowStore(root: root)
    let launcher = Launcher()
    launcher.shouldSuspend = true
    let runner = makeRunner(store: store, launcher: launcher)
    let fallbackKind = try #require(
      AgentKind.allCases.first { !AgentCatalog.descriptor(for: $0).supportsInitialPrompt })
    let id = try runner.start(
      template: .advisor, title: "Advice", input: "Question", projectID: ProjectID(),
      worktreeID: WorktreeID(), primary: AgentProfile(kind: fallbackKind), secondary: nil)
    await settle { launcher.continuation != nil }
    try store.recordResult(id: id, stepID: "advice", content: "User supplied advice")
    launcher.continuation?.resume()
    launcher.continuation = nil
    await settle { !launcher.panes.isEmpty }
    await Task.yield()
    #expect(launcher.sentPrompts.isEmpty)
    #expect(launcher.specs.count == 1)
    #expect(try store.status(id).readySteps.map(\.id) == ["disposition"])
    #expect(store.records[id]?.execution?.dispatches["advice"]?.paneID == nil)
  }

  @Test
  func dispatchIntentWriteFailureLaunchesNothing() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var writes = 0
    let store = AgentWorkflowStore(
      root: root,
      write: { record, url in
        writes += 1
        if writes == 3 { throw CocoaError(.fileWriteOutOfSpace) }
        try AtomicFileStore.write(record, to: url)
      })
    let launcher = Launcher()
    let runner = makeRunner(store: store, launcher: launcher)
    let id = try runner.start(
      template: .advisor, title: "Advice", input: "Question", projectID: ProjectID(),
      worktreeID: WorktreeID(), primary: AgentProfile(kind: .claudeCode), secondary: nil)
    await settle { !store.issues.isEmpty }
    runner.advance(id)
    await Task.yield()
    #expect(launcher.specs.isEmpty)
    #expect(launcher.sentPrompts.isEmpty)
    #expect(!store.canDispatch(id))
    #expect(store.records[id]?.execution?.dispatches.isEmpty == true)
  }

  @Test
  func uncertainLaunchFailureIsRecordedAndNeverAutomaticallyRetried() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentWorkflowStore(root: root)
    let launcher = Launcher()
    launcher.shouldFail = true
    let runner = makeRunner(store: store, launcher: launcher)
    let id = try runner.start(
      template: .advisor, title: "Advice", input: "Question", projectID: ProjectID(),
      worktreeID: WorktreeID(), primary: AgentProfile(kind: .claudeCode), secondary: nil)
    await settle { store.records[id]?.execution?.dispatches["advice"]?.status == .attention }
    runner.advance(id)
    await Task.yield()
    #expect(launcher.specs.count == 1)
    #expect(try store.status(id).status == .running)
    #expect(store.records[id]?.execution?.dispatches["advice"]?.message?.isEmpty == false)
  }
}
