import Foundation

/// Built-in serial workflows. Completion describes this run, not the user's business task.
public nonisolated enum AgentWorkflowTemplate: String, Codable, CaseIterable, Sendable {
  case handoff
  case handoffSave = "handoff-save"
  case advisor
  case committee

  public var title: String {
    switch self {
    case .handoff: "Handoff"
    case .handoffSave: "Save handoff"
    case .advisor: "Advisor"
    case .committee: "Committee"
    }
  }

  public var steps: [AgentWorkflowStep] {
    switch self {
    case .handoffSave:
      [
        .init(id: "packet", title: "Prepare handoff packet", dependencies: []),
        .init(id: "export", title: "Export handoff materials", dependencies: ["packet"]),
      ]
    case .handoff:
      [
        .init(id: "packet", title: "Prepare handoff packet", dependencies: []),
        .init(id: "export", title: "Export handoff materials", dependencies: ["packet"]),
        .init(id: "receive", title: "Acknowledge handoff packet", dependencies: ["export"]),
      ]
    case .advisor:
      [
        .init(id: "advice", title: "Provide advice", dependencies: []),
        .init(id: "disposition", title: "Record disposition", dependencies: ["advice"]),
      ]
    case .committee:
      [
        .init(id: "analysis-a", title: "Independent analysis A", dependencies: []),
        .init(id: "analysis-b", title: "Independent analysis B", dependencies: []),
        .init(id: "review-a", title: "Cross-review A", dependencies: ["analysis-a", "analysis-b"]),
        .init(id: "review-b", title: "Cross-review B", dependencies: ["analysis-a", "analysis-b"]),
        .init(id: "synthesis", title: "Synthesize findings", dependencies: ["review-a", "review-b"]),
      ]
    }
  }
}

public nonisolated struct AgentWorkflowStep: Codable, Equatable, Sendable, Identifiable {
  public enum Status: String, Codable, Sendable {
    case pending
    case active
    case accepted
    case revoked
  }

  public let id: String
  public let title: String
  public let dependencies: [String]
  public internal(set) var status: Status = .pending

  public init(id: String, title: String, dependencies: [String]) {
    self.id = id
    self.title = title
    self.dependencies = dependencies
  }
}
