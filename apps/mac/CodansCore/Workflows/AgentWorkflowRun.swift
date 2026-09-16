import Foundation

public nonisolated struct AgentWorkflowAttempt: Codable, Equatable, Sendable, Identifiable {
  public enum Status: String, Codable, Sendable {
    case active
    case accepted
    case revoked
  }

  public let id: UUID
  public let stepID: String
  public let paneID: String
  public internal(set) var status: Status
  public let createdAt: Date
  public internal(set) var deliveryID: UUID?
  public internal(set) var content: String?
  public internal(set) var deliveredAt: Date?
}

public nonisolated struct AgentWorkflowEvent: Codable, Equatable, Sendable {
  public enum EventType: String, Codable, Sendable {
    case created
    case claimed
    case delivered
    case succeeded
    case cancelled
    case interrupted
  }

  public let sequence: Int
  public let type: String
  public let message: String
  public let date: Date
}

public nonisolated enum AgentWorkflowError: Error, Equatable, Sendable, LocalizedError {
  case terminalRun
  case unknownStep
  case stepUnavailable
  case dependenciesUnsatisfied
  case runBusy
  case invalidPane
  case unknownAttempt
  case paneMismatch
  case staleAttempt
  case emptyDelivery
  case deliveryConflict

  public var errorDescription: String? {
    switch self {
    case .terminalRun: "This workflow run has ended."
    case .unknownStep: "The workflow step does not exist."
    case .stepUnavailable: "The workflow step has already been claimed or revoked."
    case .dependenciesUnsatisfied: "The step's dependencies have not been accepted."
    case .runBusy: "Another step is active; this workflow executes serially."
    case .invalidPane: "A nonempty pane identity is required."
    case .unknownAttempt: "The workflow attempt does not exist."
    case .paneMismatch: "This attempt belongs to a different pane."
    case .staleAttempt: "The attempt is no longer accepting a delivery."
    case .emptyDelivery: "A delivery must contain non-whitespace content."
    case .deliveryConflict: "The delivery identity or accepted content conflicts with an existing delivery."
    }
  }
}

/// Pure, bounded-template execution state. Callers persist a changed copy before publishing or acknowledging it.
/// There is no automatic terminal observation, retry, dynamic plan editing, or replay in this first kernel.
public nonisolated struct AgentWorkflowRun: Codable, Equatable, Sendable, Identifiable {
  public enum Status: String, Codable, Sendable {
    case running
    case succeeded
    case cancelled
    case interrupted

    public var isTerminal: Bool { self != .running }
  }

  public let id: UUID
  public let template: AgentWorkflowTemplate
  public let title: String
  public let input: String
  public private(set) var status: Status
  public private(set) var steps: [AgentWorkflowStep]
  public private(set) var attempts: [AgentWorkflowAttempt]
  public private(set) var events: [AgentWorkflowEvent]
  public private(set) var revision: Int
  public let createdAt: Date
  public private(set) var updatedAt: Date

  public init(
    id: UUID = UUID(), template: AgentWorkflowTemplate, title: String, input: String, now: Date = Date()
  ) {
    self.id = id
    self.template = template
    self.title = title
    self.input = input
    status = .running
    steps = template.steps
    attempts = []
    events = [.init(sequence: 1, type: "created", message: "Workflow created.", date: now)]
    revision = 1
    createdAt = now
    updatedAt = now
  }

  public var currentAttempt: AgentWorkflowAttempt? { attempts.first { $0.status == .active } }

  public var readySteps: [AgentWorkflowStep] {
    guard status == .running, currentAttempt == nil else { return [] }
    let accepted = Set(steps.filter { $0.status == .accepted }.map(\.id))
    return steps.filter { $0.status == .pending && Set($0.dependencies).isSubset(of: accepted) }
  }

  @discardableResult
  public mutating func claim(stepID: String, paneID: String, now: Date) throws -> AgentWorkflowAttempt {
    guard status == .running else { throw AgentWorkflowError.terminalRun }
    guard !paneID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AgentWorkflowError.invalidPane
    }
    guard let index = steps.firstIndex(where: { $0.id == stepID }) else {
      throw AgentWorkflowError.unknownStep
    }
    guard currentAttempt == nil else { throw AgentWorkflowError.runBusy }
    guard steps[index].status == .pending else { throw AgentWorkflowError.stepUnavailable }
    guard readySteps.contains(where: { $0.id == stepID }) else {
      throw AgentWorkflowError.dependenciesUnsatisfied
    }
    let attempt = AgentWorkflowAttempt(
      id: UUID(), stepID: stepID, paneID: paneID, status: .active, createdAt: now)
    steps[index].status = .active
    attempts.append(attempt)
    record(.claimed, message: "Step '\(stepID)' claimed by pane '\(paneID)'.", now: now)
    return attempt
  }

  public mutating func deliver(
    attemptID: UUID, deliveryID: UUID, paneID: String, content: String, now: Date
  ) throws {
    guard let index = attempts.firstIndex(where: { $0.id == attemptID }) else {
      throw AgentWorkflowError.unknownAttempt
    }
    guard attempts[index].paneID == paneID else { throw AgentWorkflowError.paneMismatch }
    // A lost acknowledgement can be retried even after the final delivery completed the run.
    if let previous = attempts.first(where: { $0.deliveryID == deliveryID }) {
      guard previous.id == attemptID, previous.content == content else {
        throw AgentWorkflowError.deliveryConflict
      }
      return
    }
    guard attempts[index].status != .accepted else { throw AgentWorkflowError.deliveryConflict }
    guard status == .running, attempts[index].status == .active else {
      throw AgentWorkflowError.staleAttempt
    }
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AgentWorkflowError.emptyDelivery
    }
    guard let stepIndex = steps.firstIndex(where: { $0.id == attempts[index].stepID }) else {
      throw AgentWorkflowError.unknownStep
    }
    attempts[index].status = .accepted
    attempts[index].deliveryID = deliveryID
    attempts[index].content = content
    attempts[index].deliveredAt = now
    steps[stepIndex].status = .accepted
    record(.delivered, message: "Step '\(steps[stepIndex].id)' delivery accepted.", now: now)
    if steps.allSatisfy({ $0.status == .accepted }) {
      status = .succeeded
      record(.succeeded, message: "All workflow steps accepted.", now: now)
    }
  }

  public mutating func cancel(now: Date) {
    end(.cancelled, event: .cancelled, now: now)
  }

  public mutating func interrupt(now: Date) {
    end(.interrupted, event: .interrupted, now: now)
  }

  private mutating func end(_ status: Status, event: AgentWorkflowEvent.EventType, now: Date) {
    guard self.status == .running else { return }
    self.status = status
    for index in attempts.indices where attempts[index].status == .active {
      attempts[index].status = .revoked
    }
    for index in steps.indices where steps[index].status != .accepted {
      steps[index].status = .revoked
    }
    record(event, message: "Workflow \(status.rawValue); external work may still be running.", now: now)
  }

  private mutating func record(_ type: AgentWorkflowEvent.EventType, message: String, now: Date) {
    record(type: type.rawValue, message: message, now: now)
  }

  /// Records an observation without changing execution state or inferring completion.
  public mutating func record(type: String, message: String, now: Date) {
    revision += 1
    updatedAt = now
    events.append(.init(sequence: events.count + 1, type: type, message: message, date: now))
  }
}
