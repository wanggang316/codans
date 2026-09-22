import ComposableArchitecture
import Foundation

/// TCA seam between the Command Palette (a value-type reducer) and the
/// app-owned `WorkflowEngine` — an `@Observable` class kept outside TCA
/// by design (see `docs/design-docs/workflow.md` D7). Only what the
/// palette needs: which runs are cancellable, and cancelling one.
struct WorkflowClient: Sendable {
  struct RunSummary: Equatable, Sendable, Identifiable {
    var id: UUID
    var name: String
  }

  var activeRuns: @MainActor @Sendable () -> [RunSummary]
  var cancel: @MainActor @Sendable (UUID) -> Void
}

extension WorkflowClient {
  @MainActor
  static func live(engine: WorkflowEngine) -> WorkflowClient {
    WorkflowClient(
      activeRuns: { [weak engine] in
        (engine?.activeRuns ?? []).map { RunSummary(id: $0.id, name: $0.name) }
      },
      cancel: { [weak engine] runID in
        engine?.cancel(runID: runID)
      }
    )
  }
}

extension WorkflowClient: DependencyKey {
  static let liveValue = WorkflowClient(
    activeRuns: { fatalError("WorkflowClient.liveValue not configured") },
    cancel: { _ in fatalError("WorkflowClient.liveValue not configured") }
  )

  static let testValue = WorkflowClient(
    activeRuns: unimplemented("WorkflowClient.activeRuns", placeholder: []),
    cancel: unimplemented("WorkflowClient.cancel")
  )
}

extension DependencyValues {
  var workflowClient: WorkflowClient {
    get { self[WorkflowClient.self] }
    set { self[WorkflowClient.self] = newValue }
  }
}
