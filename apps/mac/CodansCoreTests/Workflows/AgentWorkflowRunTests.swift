import Foundation
import Testing

@testable import CodansCore

struct AgentWorkflowRunTests {
  private let now = Date(timeIntervalSince1970: 1_000)

  private func makeRun(_ template: AgentWorkflowTemplate = .handoff) -> AgentWorkflowRun {
    AgentWorkflowRun(template: template, title: "Example", input: "Task input", now: now)
  }

  @Test
  func dependencyAndSerialClaimsRejectWithoutMutation() throws {
    var run = makeRun()
    let original = run
    #expect(throws: AgentWorkflowError.dependenciesUnsatisfied) {
      try run.claim(stepID: "receive", paneID: "receiver", now: now)
    }
    #expect(run == original)
    _ = try run.claim(stepID: "packet", paneID: "author", now: now)
    let claimed = run
    #expect(throws: AgentWorkflowError.runBusy) {
      try run.claim(stepID: "receive", paneID: "receiver", now: now)
    }
    #expect(run == claimed)
    #expect(run.readySteps.isEmpty)
  }

  @Test
  func deliveriesAreImmutableAndRetriesAreIdempotent() throws {
    var run = makeRun(.handoffSave)
    let attempt = try run.claim(stepID: "packet", paneID: "author", now: now)
    let deliveryID = UUID()
    try run.deliver(
      attemptID: attempt.id, deliveryID: deliveryID, paneID: "author", content: "Packet", now: now)
    #expect(run.status == .running)
    let export = try run.claim(stepID: "export", paneID: "author", now: now)
    try run.deliver(
      attemptID: export.id, deliveryID: UUID(), paneID: "author", content: "Export complete", now: now)
    let completed = run
    run.cancel(now: now)
    try run.deliver(
      attemptID: attempt.id, deliveryID: deliveryID, paneID: "author", content: "Packet", now: now)
    #expect(run == completed)
    #expect(run.status == .succeeded)
    #expect(throws: AgentWorkflowError.deliveryConflict) {
      try run.deliver(
        attemptID: attempt.id, deliveryID: deliveryID, paneID: "author", content: "Changed", now: now)
    }
    #expect(throws: AgentWorkflowError.deliveryConflict) {
      try run.deliver(
        attemptID: attempt.id, deliveryID: UUID(), paneID: "author", content: "Packet", now: now)
    }
    #expect(throws: AgentWorkflowError.paneMismatch) {
      try run.deliver(
        attemptID: attempt.id, deliveryID: deliveryID, paneID: "other", content: "Packet", now: now)
    }
    #expect(run == completed)
  }

  @Test
  func identityAndContentFailuresDoNotAdvance() throws {
    var run = makeRun()
    #expect(throws: AgentWorkflowError.invalidPane) {
      try run.claim(stepID: "packet", paneID: " \n", now: now)
    }
    let attempt = try run.claim(stepID: "packet", paneID: "author", now: now)
    let claimed = run
    #expect(throws: AgentWorkflowError.emptyDelivery) {
      try run.deliver(
        attemptID: attempt.id, deliveryID: UUID(), paneID: "author", content: " \n", now: now)
    }
    #expect(throws: AgentWorkflowError.unknownAttempt) {
      try run.deliver(
        attemptID: UUID(), deliveryID: UUID(), paneID: "author", content: "Packet", now: now)
    }
    #expect(run == claimed)
    run.record(type: "idle", message: "Agent appears idle.", now: now)
    #expect(run.status == .running)
    #expect(run.currentAttempt?.id == attempt.id)
  }

  @Test
  func cancellationAndRestartRevokeOutstandingWork() throws {
    for interrupt in [false, true] {
      var run = makeRun()
      let attempt = try run.claim(stepID: "packet", paneID: "author", now: now)
      if interrupt { run.interrupt(now: now) } else { run.cancel(now: now) }
      #expect(run.status == (interrupt ? .interrupted : .cancelled))
      #expect(run.attempts[0].status == .revoked)
      #expect(run.readySteps.isEmpty)
      let ended = run
      #expect(throws: AgentWorkflowError.staleAttempt) {
        try run.deliver(
          attemptID: attempt.id, deliveryID: UUID(), paneID: "author", content: "Late", now: now)
      }
      #expect(throws: AgentWorkflowError.terminalRun) {
        try run.claim(stepID: "receive", paneID: "receiver", now: now)
      }
      run.cancel(now: now)
      run.interrupt(now: now)
      #expect(run == ended)
    }
  }

  @Test(arguments: AgentWorkflowTemplate.allCases)
  func everyTemplateRequiresEveryDeliveryAndRoundTrips(template: AgentWorkflowTemplate) throws {
    var run = makeRun(template)
    for step in run.steps {
      #expect(run.status == .running)
      let attempt = try run.claim(stepID: step.id, paneID: step.id, now: now)
      let encoded = try JSONEncoder().encode(run)
      run = try JSONDecoder().decode(AgentWorkflowRun.self, from: encoded)
      #expect(run.currentAttempt == attempt)
      try run.deliver(
        attemptID: attempt.id, deliveryID: UUID(), paneID: step.id, content: "Result \(step.id)", now: now)
    }
    #expect(run.status == .succeeded)
    #expect(run.steps.allSatisfy { $0.status == .accepted })
    #expect(run.events.map(\.sequence) == Array(1...run.events.count))
    #expect(run.revision == run.events.count)
    let encoded = try JSONEncoder().encode(run)
    #expect(try JSONDecoder().decode(AgentWorkflowRun.self, from: encoded) == run)
  }

  @Test
  func receiverCannotClaimBeforeMaterialExport() throws {
    var run = makeRun(.handoff)
    let packet = try run.claim(stepID: "packet", paneID: "author", now: now)
    try run.deliver(
      attemptID: packet.id, deliveryID: UUID(), paneID: "author", content: "Packet", now: now)
    #expect(run.readySteps.map(\.id) == ["export"])
    #expect(throws: AgentWorkflowError.dependenciesUnsatisfied) {
      try run.claim(stepID: "receive", paneID: "receiver", now: now)
    }
  }

  @Test
  func committeeRequiresBothAnalysesBeforeEitherReview() throws {
    var run = makeRun(.committee)
    let attempt = try run.claim(stepID: "analysis-a", paneID: "a", now: now)
    try run.deliver(attemptID: attempt.id, deliveryID: UUID(), paneID: "a", content: "Analysis", now: now)
    #expect(run.readySteps.map(\.id) == ["analysis-b"])
    #expect(throws: AgentWorkflowError.dependenciesUnsatisfied) {
      try run.claim(stepID: "review-a", paneID: "a", now: now)
    }
    #expect(throws: AgentWorkflowError.dependenciesUnsatisfied) {
      try run.claim(stepID: "review-b", paneID: "b", now: now)
    }
  }
}
