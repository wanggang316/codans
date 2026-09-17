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
    let execution = try #require(service.run(id)?.nodes["decision"]?.executions?.last)
    #expect(execution.status == "succeeded")
    #expect(execution.inputs["question"] == .string("Proceed?"))
    #expect(execution.outputs["decision"] == .string("accept"))
    #expect(execution.request == nil)
    #expect(execution.submissions.isEmpty)
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

  @Test func requestIsDurableBeforeSendingAndRecordsDispatchCompletion() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = WorkflowServiceV2(root: directory)
    let pane = PaneID()
    var inspected = false
    service.validateBinding = { _ in true }
    service.send = { _, prompt, canDispatch in
      let persisted = try #require(try WorkflowDatabaseV2(root: directory).load().first)
      let execution = try #require(persisted.nodes["review"]?.executions?.last)
      let request = try #require(execution.request)
      #expect(request.prompt == prompt)
      #expect(request.status == "sending")
      #expect(request.paneID == pane.description)
      #expect(request.sessionID == "test-session")
      #expect(request.generation == 3)
      #expect(prompt.contains(request.deliveryID.uuidString))
      #expect(execution.id == persisted.nodes["review"]?.attemptID)
      #expect(canDispatch())
      inspected = true
    }
    let id = try service.start(
      definition: WorkflowDefinitionParserV2.parse(agentSource), source: agentSource,
      title: "Recorded request", inputs: [:],
      bindings: ["reviewer": .init(source: "pick", paneID: pane, sessionID: "test-session", generation: 3)])
    await settle { service.run(id)?.nodes["review"]?.executions?.last?.request?.status == "sent" }
    #expect(inspected)
    #expect(service.run(id)?.nodes["review"]?.executions?.last?.request?.sentAt != nil)
    try service.cancel(id)
  }

  @Test func correctedSubmissionPreservesRejectedBodyAndDeduplicatesRetries() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = WorkflowServiceV2(root: directory)
    let pane = PaneID()
    service.validateBinding = { _ in true }
    service.send = { _, _, _ in }
    let id = try service.start(
      definition: WorkflowDefinitionParserV2.parse(agentSource), source: agentSource,
      title: "Corrected delivery", inputs: [:], bindings: ["reviewer": .init(source: "pick", paneID: pane)])
    await settle { service.run(id)?.nodes["review"]?.executions?.last?.request?.status == "sent" }
    let execution = try #require(service.run(id)?.nodes["review"]?.executions?.last)
    let delivery = try #require(execution.request?.deliveryID)
    for _ in 0..<2 {
      #expect(throws: (any Error).self) {
        _ = try service.deliver(
          id: id, attemptID: execution.id, deliveryID: delivery, paneID: pane.description,
          content: "Missing required heading")
      }
    }
    let rejected = try #require(service.run(id)?.nodes["review"]?.executions?.last)
    #expect(rejected.submissions.count == 1)
    #expect(rejected.submissions.first?.content == "Missing required heading")
    #expect(rejected.submissions.first?.accepted == false)
    #expect(rejected.submissions.first?.issues.isEmpty == false)
    let corrected = "# Findings\nReviewed and complete"
    _ = try service.deliver(
      id: id, attemptID: execution.id, deliveryID: delivery, paneID: pane.description, content: corrected)
    await settle { service.run(id)?.status == "succeeded" }
    _ = try service.deliver(
      id: id, attemptID: execution.id, deliveryID: delivery, paneID: pane.description, content: corrected)
    let completed = try #require(service.run(id)?.nodes["review"]?.executions?.last)
    #expect(service.run(id)?.nodes["review"]?.executions?.count == 1)
    #expect(completed.id == execution.id)
    #expect(completed.status == "succeeded")
    #expect(completed.submissions.count == 2)
    #expect(completed.submissions.last?.accepted == true)
    #expect(completed.submissions.last?.content == corrected)
    #expect(completed.outputs["result"] == .string(corrected))
    #expect(WorkflowServiceV2(root: directory).run(id)?.nodes["review"]?.executions?.last == completed)
  }

  @Test func dispatchFailureIsRecordedWithExactRequest() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = WorkflowServiceV2(root: directory)
    var sentPrompt = ""
    service.validateBinding = { _ in true }
    service.send = { _, prompt, _ in
      sentPrompt = prompt
      throw WorkflowRuntimeErrorV2.invalid("Terminal rejected dispatch")
    }
    let id = try service.start(
      definition: WorkflowDefinitionParserV2.parse(agentSource), source: agentSource,
      title: "Failed dispatch", inputs: [:], bindings: ["reviewer": .init(source: "pick", paneID: PaneID())])
    await settle { service.run(id)?.status == "failed" }
    let execution = try #require(service.run(id)?.nodes["review"]?.executions?.last)
    #expect(execution.status == "failed")
    #expect(execution.request?.status == "failed")
    #expect(execution.request?.prompt == sentPrompt)
    #expect(execution.request?.error?.contains("Terminal rejected dispatch") == true)
    #expect(execution.finishedAt != nil)
  }

  @Test func delayedSendCompletionDoesNotOverwriteAcceptedResult() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = WorkflowServiceV2(root: directory)
    let pane = PaneID()
    var continuation: CheckedContinuation<Void, Never>?
    var sendFinished = false
    var resumed = false
    service.validateBinding = { _ in true }
    service.send = { _, _, _ in
      await withCheckedContinuation { continuation = $0 }
      sendFinished = true
    }
    let id = try service.start(
      definition: WorkflowDefinitionParserV2.parse(agentSource), source: agentSource,
      title: "Early response", inputs: [:], bindings: ["reviewer": .init(source: "pick", paneID: pane)])
    await settle { continuation != nil }
    let pendingSend = try #require(continuation)
    defer { if !resumed { pendingSend.resume() } }
    let execution = try #require(service.run(id)?.nodes["review"]?.executions?.last)
    let delivery = try #require(execution.request?.deliveryID)
    _ = try service.deliver(
      id: id, attemptID: execution.id, deliveryID: delivery, paneID: pane.description,
      content: "# Findings\nArrived before dispatch returned")
    resumed = true
    pendingSend.resume()
    await settle { sendFinished && service.run(id)?.status == "succeeded" }
    #expect(sendFinished)
    let completed = try #require(service.run(id)?.nodes["review"]?.executions?.last)
    #expect(completed.status == "succeeded")
    #expect(completed.outputs["result"] == .string("# Findings\nArrived before dispatch returned"))
    #expect(completed.submissions.count == 1)
    #expect(service.run(id)?.nodes["review"]?.status == "succeeded")
  }

  @Test func cancellingSuspendedDispatchRevokesRequestAndPreservesCancellation() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = WorkflowServiceV2(root: directory)
    var continuation: CheckedContinuation<Void, Never>?
    var allowedAfterCancellation = true
    var finished = false
    service.validateBinding = { _ in true }
    service.send = { _, _, canDispatch in
      await withCheckedContinuation { continuation = $0 }
      allowedAfterCancellation = canDispatch()
      finished = true
    }
    let id = try service.start(
      definition: WorkflowDefinitionParserV2.parse(agentSource), source: agentSource,
      title: "Cancelled dispatch", inputs: [:], bindings: ["reviewer": .init(source: "pick", paneID: PaneID())])
    await settle { continuation != nil }
    let pendingSend = try #require(continuation)
    try service.cancel(id)
    pendingSend.resume()
    await settle { finished }
    #expect(!allowedAfterCancellation)
    #expect(service.run(id)?.status == "cancelled")
    #expect(service.run(id)?.nodes["review"]?.executions?.last?.status == "cancelled")
    #expect(service.run(id)?.nodes["review"]?.executions?.last?.request?.status == "cancelled")
  }

  @Test func restartInterruptsAgentRequestWithoutRedispatchOrLateDelivery() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = WorkflowServiceV2(root: directory)
    let pane = PaneID()
    var sendCount = 0
    service.validateBinding = { _ in true }
    service.send = { _, _, _ in sendCount += 1 }
    let id = try service.start(
      definition: WorkflowDefinitionParserV2.parse(agentSource), source: agentSource,
      title: "Interrupted request", inputs: [:], bindings: ["reviewer": .init(source: "pick", paneID: pane)])
    await settle { service.run(id)?.nodes["review"]?.executions?.last?.request?.status == "sent" }
    let restored = WorkflowServiceV2(root: directory)
    restored.validateBinding = { _ in true }
    restored.send = { _, _, _ in sendCount += 1 }
    let execution = try #require(restored.run(id)?.nodes["review"]?.executions?.last)
    #expect(execution.status == "interrupted")
    #expect(execution.request?.status == "sent")
    #expect(execution.request?.sentAt != nil)
    #expect(throws: (any Error).self) {
      _ = try restored.deliver(
        id: id, attemptID: execution.id, deliveryID: UUID(), paneID: pane.description,
        content: "# Findings\nLate response")
    }
    for _ in 0..<10 { await Task.yield() }
    #expect(sendCount == 1)
  }

  @Test func processArchiveContainsExactRequestAndSubmissionVersions() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = WorkflowServiceV2(root: directory)
    let pane = PaneID()
    service.validateBinding = { _ in true }
    service.send = { _, _, _ in }
    let id = try service.start(
      definition: WorkflowDefinitionParserV2.parse(agentSource), source: agentSource,
      title: "Archive", inputs: [:], bindings: ["reviewer": .init(source: "pick", paneID: pane)])
    await settle { service.run(id)?.nodes["review"]?.execution?.request?.status == "sent" }
    let execution = try #require(service.run(id)?.nodes["review"]?.execution)
    let request = try #require(execution.request)
    #expect(throws: (any Error).self) {
      _ = try service.deliver(
        id: id, attemptID: execution.id, deliveryID: request.deliveryID,
        paneID: pane.description, content: "Incomplete")
    }
    _ = try service.deliver(
      id: id, attemptID: execution.id, deliveryID: request.deliveryID,
      paneID: pane.description, content: "# Findings\nComplete")
    await settle { service.run(id)?.status == "succeeded" }
    let folder = directory.appendingPathComponent("artifacts/\(id.uuidString)")
    let nodeFolder = folder.appendingPathComponent("nodes/\(execution.id.uuidString)")
    #expect(
      try String(contentsOf: nodeFolder.appendingPathComponent("instruction.md"), encoding: .utf8) == request.prompt)
    let stored = try JSONDecoder().decode(
      WorkflowNodeExecutionV2.self,
      from: Data(contentsOf: nodeFolder.appendingPathComponent("execution.json")))
    #expect(stored == service.run(id)?.nodes["review"]?.execution)
    #expect(stored.nodeID == "review")
    for submission in stored.submissions {
      let file = nodeFolder.appendingPathComponent("submissions/\(submission.id.uuidString).json")
      #expect(try JSONDecoder().decode(WorkflowSubmissionV2.self, from: Data(contentsOf: file)) == submission)
    }
    let events = try String(contentsOf: folder.appendingPathComponent("events.jsonl"), encoding: .utf8)
    #expect(events.split(separator: "\n").count == service.run(id)?.events.count)
    // Inspection files are projections, repaired from the authoritative snapshot.
    try Data("stale".utf8).write(to: folder.appendingPathComponent("run.json"))
    let restored = WorkflowServiceV2(root: directory)
    let snapshot = try JSONDecoder().decode(
      WorkflowRunV2.self,
      from: Data(contentsOf: folder.appendingPathComponent("run.json")))
    #expect(snapshot == restored.run(id))
  }

  @Test func unavailableArchivePreventsDispatch() throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = WorkflowServiceV2(root: directory)
    try Data("blocked".utf8).write(to: directory.appendingPathComponent("artifacts"))
    var sent = false
    service.validateBinding = { _ in true }
    service.send = { _, _, _ in sent = true }
    #expect(throws: (any Error).self) {
      _ = try service.start(
        definition: WorkflowDefinitionParserV2.parse(agentSource), source: agentSource,
        title: "Unavailable archive", inputs: [:], bindings: ["reviewer": .init(source: "pick", paneID: PaneID())])
    }
    #expect(!sent)
    #expect(service.runs.isEmpty)
    #expect(!service.issues.isEmpty)
  }

  @Test func archiveFailureDoesNotRescheduleForever() async throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = WorkflowServiceV2(root: directory)
    let id = try service.start(
      definition: WorkflowDefinitionParserV2.parse(decisionSource), source: decisionSource,
      title: "Storage failure", inputs: [:], bindings: [:])
    // Block the next transition after the initial run was durably created.
    let folder = directory.appendingPathComponent("artifacts/\(id.uuidString)/nodes")
    try Data("blocked".utf8).write(to: folder)
    await settle { !service.issues.isEmpty }
    let count = service.issues.count
    #expect(count > 0)
    for _ in 0..<30 { await Task.yield() }
    #expect(service.issues.count == count)
    service.advance(id)
    for _ in 0..<30 { await Task.yield() }
    #expect(service.issues.count == count)
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
