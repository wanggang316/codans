import CodansCore
import CodansIPC
import Foundation
import Testing

@testable import Codans

@MainActor struct WorkflowServiceV2Tests {
  private func root() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("workflow-v2-\(UUID())")
  }

  private func settle(_ predicate: @MainActor () -> Bool) async {
    for _ in 0..<1000 {
      if predicate() { return }
      await Task.yield()
    }
  }

  private let decisionSource = """
    schema: codans.workflow/v1
    id: test.decision
    name: Decision
    inputs: {}
    roles: {}
    nodes:
      decision:
        uses: codans/human.decide@v1
        with:
          question: {value: Proceed?}
          options: {value: [accept, reject]}
          evidence: {value: Test evidence}
    outputs:
      result: {ref: nodes.decision.outputs.decision}
    """

  @Test func humanDecisionPersistsAndRestoresWithoutResources() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = WorkflowServiceV2(root: directory)
    let definition = try WorkflowDefinitionParserV2.parse(decisionSource)
    let id = try service.start(
      definition: definition, source: decisionSource, title: "Test", inputs: [:], bindings: [:])
    await settle { service.run(id)?.status == "waiting" }
    #expect(service.run(id)?.nodes["decision"]?.inputs["question"] == .string("Proceed?"))
    #expect(throws: (any Error).self) {
      try service.decide(id: id, nodeID: "decision", decision: "other", reason: "Invalid")
    }
    try service.decide(id: id, nodeID: "decision", decision: "accept", reason: "Evidence accepted")
    await settle { service.run(id)?.status == "succeeded" }
    #expect(service.run(id)?.outputs["result"] == .string("accept"))
    let restored = WorkflowServiceV2(root: directory)
    #expect(restored.run(id) == service.run(id))
  }

  @Test func historyScopesMatchOriginAndParticipants() throws {
    let sourcePane = PaneID(raw: UUID())
    let receiverPane = PaneID(raw: UUID())
    let worktree = WorktreeID(raw: UUID())
    var run = WorkflowRunV2(
      title: "Scoped", source: decisionSource,
      definition: try WorkflowDefinitionParserV2.parse(decisionSource), inputs: [:], bindings: [:],
      origin: .init(worktreeID: worktree, paneID: sourcePane), nodes: [:])
    #expect(run.matches(.pane, paneID: sourcePane, worktreeID: nil))
    #expect(!run.matches(.pane, paneID: receiverPane, worktreeID: worktree))
    #expect(run.matches(.worktree, paneID: nil, worktreeID: worktree))
    #expect(!run.matches(.worktree, paneID: sourcePane, worktreeID: WorktreeID(raw: UUID())))
    #expect(!run.matches(.pane, paneID: nil, worktreeID: nil))
    #expect(run.matches(.all, paneID: nil, worktreeID: nil))
    run.bindings["receiver"] = .init(source: "launch", worktreeID: worktree, paneID: receiverPane)
    #expect(run.matches(.pane, paneID: receiverPane, worktreeID: nil))
    run.origin = nil
    #expect(!run.matches(.pane, paneID: sourcePane, worktreeID: nil))
    #expect(run.matches(.worktree, paneID: nil, worktreeID: worktree))
  }

  @Test func inspectionSnapshotContainsFrozenSourceAndCurrentRun() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = WorkflowServiceV2(root: directory)
    let origin = WorkflowRunOriginV2(worktreeID: WorktreeID(raw: UUID()), paneID: PaneID(raw: UUID()))
    let id = try service.start(
      definition: WorkflowDefinitionParserV2.parse(decisionSource), source: decisionSource,
      title: "Inspect", inputs: [:], bindings: [:], origin: origin)
    await settle { service.run(id)?.status == "waiting" }
    let folder = try service.inspectionDirectory(for: id)
    #expect(try String(contentsOf: folder.appendingPathComponent("workflow.yaml"), encoding: .utf8) == decisionSource)
    let snapshot = try JSONDecoder().decode(
      WorkflowRunV2.self, from: Data(contentsOf: folder.appendingPathComponent("run.json")))
    #expect(snapshot == service.run(id))
    try service.decide(id: id, nodeID: "decision", decision: "accept", reason: "Reviewed")
    await settle { service.run(id)?.status == "succeeded" }
    _ = try service.inspectionDirectory(for: id)
    let updated = try JSONDecoder().decode(
      WorkflowRunV2.self, from: Data(contentsOf: folder.appendingPathComponent("run.json")))
    #expect(updated.status == "succeeded")
    #expect(WorkflowServiceV2(root: directory).run(id)?.origin == origin)
  }

  @Test func restartInterruptsAndNeverResubmitsWaitingWork() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = WorkflowServiceV2(root: directory)
    let definition = try WorkflowDefinitionParserV2.parse(decisionSource)
    let id = try service.start(
      definition: definition, source: decisionSource, title: "Test", inputs: [:], bindings: [:])
    await settle { service.run(id)?.status == "waiting" }
    let restored = WorkflowServiceV2(root: directory)
    #expect(restored.run(id)?.status == "interrupted")
    #expect(restored.run(id)?.events.last?.type == "interrupted")
    #expect(throws: (any Error).self) {
      try restored.decide(id: id, nodeID: "decision", decision: "accept", reason: "Late")
    }
  }

  private let agentSource = """
    schema: codans.workflow/v1
    id: test.agent
    name: Agent
    inputs: {}
    roles:
      reviewer: {label: Reviewer, source: pick}
    nodes:
      review:
        uses: codans/agent.request@v1
        role: reviewer
        with:
          instruction: {value: Review the proposal.}
        expect:
          format: markdown
          sections: [Findings]
    outputs:
      report: {ref: nodes.review.outputs.result}
    """

  @Test func deliveryValidatesPaneGenerationContractAndCancellation() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = WorkflowServiceV2(root: directory)
    let pane = PaneID()
    var live = true
    var sent = ""
    service.validateBinding = { _ in live }
    service.send = { _, prompt, guardAction in if guardAction() { sent = prompt } }
    let definition = try WorkflowDefinitionParserV2.parse(agentSource)
    let id = try service.start(
      definition: definition, source: agentSource, title: "Test", inputs: [:],
      bindings: ["reviewer": .init(source: "pick", paneID: pane)])
    await settle { !sent.isEmpty }
    #expect(sent.contains("workflow deliver \(id.uuidString)"))
    let attempt = try #require(service.run(id)?.nodes["review"]?.attemptID)
    #expect(throws: (any Error).self) {
      _ = try service.claim(id: id, nodeID: "review", paneID: UUID().uuidString)
    }
    _ = try service.claim(id: id, nodeID: "review", paneID: pane.description)
    #expect(throws: (any Error).self) {
      _ = try service.deliver(
        id: id, attemptID: attempt, deliveryID: UUID(), paneID: pane.description,
        content: "Missing heading")
    }
    #expect(service.run(id)?.nodes["review"]?.status == "running")
    #expect(service.run(id)?.events.last?.type == "delivery_rejected")
    live = false
    #expect(throws: (any Error).self) {
      _ = try service.deliver(
        id: id, attemptID: attempt, deliveryID: UUID(), paneID: pane.description,
        content: "# Findings\nDone")
    }
    live = true
    try service.cancel(id)
    #expect(throws: (any Error).self) {
      _ = try service.deliver(
        id: id, attemptID: attempt, deliveryID: UUID(), paneID: pane.description,
        content: "# Findings\nDone")
    }
  }

  @Test func acceptedDeliveryCompletesAndRetainsAttempt() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = WorkflowServiceV2(root: directory)
    let pane = PaneID()
    var submitted = false
    service.validateBinding = { _ in true }
    service.send = { _, _, _ in submitted = true }
    let definition = try WorkflowDefinitionParserV2.parse(agentSource)
    let id = try service.start(
      definition: definition, source: agentSource, title: "Test", inputs: [:],
      bindings: ["reviewer": .init(source: "pick", paneID: pane)])
    await settle { submitted }
    let attempt = try #require(service.run(id)?.nodes["review"]?.attemptID)
    let delivery = UUID()
    _ = try service.deliver(
      id: id, attemptID: attempt, deliveryID: delivery, paneID: pane.description,
      content: "# Findings\nChecked")
    await settle { service.run(id)?.status == "succeeded" }
    #expect(service.run(id)?.outputs["report"] == .string("# Findings\nChecked"))
    #expect(service.run(id)?.nodes["review"]?.attemptID == attempt)
    _ = try service.deliver(
      id: id, attemptID: attempt, deliveryID: delivery, paneID: pane.description,
      content: "# Findings\nChecked")
    #expect(throws: (any Error).self) {
      _ = try service.deliver(
        id: id, attemptID: attempt, deliveryID: delivery,
        paneID: pane.description, content: "# Findings\nChanged")
    }
  }

  @Test func activeEndpointCannotBeAssignedToAnotherRun() throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = WorkflowServiceV2(root: directory)
    let pane = PaneID()
    service.validateBinding = { _ in true }
    service.send = { _, _, _ in }
    let definition = try WorkflowDefinitionParserV2.parse(agentSource)
    let bindings: [String: WorkflowBindingV2] = ["reviewer": .init(source: "pick", paneID: pane)]
    let id = try service.start(
      definition: definition, source: agentSource, title: "First", inputs: [:], bindings: bindings)
    #expect(throws: (any Error).self) {
      _ = try service.start(
        definition: definition, source: agentSource, title: "Second", inputs: [:],
        bindings: bindings)
    }
    try service.cancel(id)
    _ = try service.start(
      definition: definition, source: agentSource, title: "Third", inputs: [:], bindings: bindings)
  }

  @Test func unavailableStorageRejectsStartBeforeDispatch() throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("not a directory".utf8).write(to: directory)
    let service = WorkflowServiceV2(root: directory)
    let definition = try WorkflowDefinitionParserV2.parse(decisionSource)
    #expect(!service.issues.isEmpty)
    #expect(throws: (any Error).self) {
      _ = try service.start(
        definition: definition, source: decisionSource, title: "Test", inputs: [:], bindings: [:])
    }
    #expect(service.runs.isEmpty)
  }

  @Test func immutablePacketAndWrongAcknowledgementFailNativeNode() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = """
      schema: codans.workflow/v1
      id: test.packet
      name: Packet
      inputs: {}
      roles: {}
      nodes:
        packet:
          uses: codans/handoff.packet.create@v1
          with:
            briefing: {value: Complete briefing}
        verify:
          uses: codans/handoff.ack.verify@v1
          needs: [packet]
          with:
            packet: {ref: nodes.packet.outputs.packet}
            acknowledgement:
              value:
                packetId: wrong
                packetDigest: wrong
                understanding: Understood
                nextAction: Review
                blockers: []
      outputs:
        packet: {ref: nodes.packet.outputs.packet}
      """
    let service = WorkflowServiceV2(root: directory)
    let definition = try WorkflowDefinitionParserV2.parse(source)
    let id = try service.start(
      definition: definition, source: source, title: "Packet", inputs: [:], bindings: [:])
    await settle { service.run(id)?.status == "failed" }
    let packet = try #require(service.run(id)?.nodes["packet"]?.outputs["packet"]?.v2Object)
    #expect(packet["content"] == .string("Complete briefing"))
    let path = try #require(packet["contentRef"]?.v2String)
    #expect(try String(contentsOfFile: path, encoding: .utf8) == "Complete briefing")
    #expect(service.run(id)?.nodes["verify"]?.status == "failed")
  }
}
