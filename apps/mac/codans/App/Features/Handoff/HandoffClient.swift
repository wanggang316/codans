import CodansCore
import ComposableArchitecture
import Foundation

/// The chooser resolves a source and starts a persisted built-in workflow.
nonisolated struct HandoffClient: Sendable {
  var source: @MainActor @Sendable (_ paneID: PaneID) -> HandoffSource?
  var startWorkflow:
    @MainActor @Sendable (PaneID, HandoffFeature.Order, HandoffPlacement, AgentProfile?) throws ->
      UUID
  var lastPlacement: @Sendable () -> HandoffPlacement = { .default }
  var rememberPlacement: @Sendable (HandoffPlacement) -> Void = { _ in }
  var isInstalled: @MainActor @Sendable (AgentKind) -> Bool = { _ in true }
}

extension HandoffClient {
  @MainActor
  static func live(
    installation: AgentInstallationStore,
    startWorkflow:
      @escaping @MainActor @Sendable (
        PaneID, HandoffFeature.Order, HandoffPlacement, AgentProfile?
      ) throws -> UUID,
    source: @escaping @MainActor @Sendable (PaneID) -> HandoffSource?
  ) -> HandoffClient {
    HandoffClient(
      source: source,
      startWorkflow: startWorkflow,
      lastPlacement: { HandoffPlacementPersistence.load() },
      rememberPlacement: { HandoffPlacementPersistence.save($0) },
      isInstalled: { installation.isInstalled($0) }
    )
  }
}

extension HandoffClient: DependencyKey {
  static let liveValue = HandoffClient(
    source: { _ in fatalError("HandoffClient.liveValue not configured") },
    startWorkflow: { _, _, _, _ in fatalError("HandoffClient.liveValue not configured") }
  )

  static let testValue = HandoffClient(
    source: unimplemented("HandoffClient.source", placeholder: nil),
    startWorkflow: unimplemented("HandoffClient.startWorkflow", placeholder: UUID())
  )
}

extension DependencyValues {
  var handoffClient: HandoffClient {
    get { self[HandoffClient.self] }
    set { self[HandoffClient.self] = newValue }
  }
}
