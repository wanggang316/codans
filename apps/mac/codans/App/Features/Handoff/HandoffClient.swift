import CodansCore
import CodansIPC
import ComposableArchitecture
import Foundation

/// TCA seam between `HandoffFeature` and the app-owned handoff machinery:
/// the request registry (one-shot authorization + completion fan-out), the
/// terminal (typing the request into the source pane), and the same
/// `HandoffHandlers` the CLI uses, for the panel's context-only fallback.
nonisolated struct HandoffClient: Sendable {
  /// The outgoing side of a handoff for a pane, or nil when the pane is not
  /// in the catalog. `agentKind == nil` means no agent is detected there.
  var source: @MainActor @Sendable (_ paneID: PaneID) -> HandoffSource?
  var register: @MainActor @Sendable (_ requestID: UUID) -> Void
  var supersede: @MainActor @Sendable (_ requestID: UUID) -> Bool
  /// Broadcast, no replay — subscribe before injecting the request.
  var completions: @MainActor @Sendable () -> AsyncStream<HandoffCompletion>
  /// Types `text` (plus Enter) through the shared input coordinator.
  /// Rejection preserves any interrupted automatic draft.
  var sendInstruction: @MainActor @Sendable (_ paneID: PaneID, _ text: String) -> SubmissionResult
  /// Runs a handoff transition in-process — the panel's fallback when the
  /// live agent cannot be asked. Same code path as the CLI verbs.
  var run: @MainActor @Sendable (_ request: IPC.HandoffRequest) async throws -> HandoffCompletion
  /// How this build spells its own CLI, resolved once at wire-up. The panel
  /// types it into the source pane, so it has to name the binary that answers
  /// on this app's socket — never the installed Release `codans`.
  var cli: String = CLIInvocation.commandName
  /// The placement the panel opens with — the last one chosen — and the hook
  /// that records a new choice. Defaults keep tests that do not care silent.
  var lastPlacement: @Sendable () -> HandoffPlacement = { .default }
  var rememberPlacement: @Sendable (HandoffPlacement) -> Void = { _ in }
  /// The advisory install probe (`AgentInstallationStore.isInstalled`), so the
  /// panel lists the same agents the toolbar offers. Everything counts as
  /// installed by default, which is also what the store answers before its
  /// first scan.
  var isInstalled: @MainActor @Sendable (AgentKind) -> Bool = { _ in true }
}

extension HandoffClient {
  @MainActor
  static func deliverInstruction(
    _ text: String,
    to paneID: PaneID,
    coordinator: PaneInputCoordinator,
    write: @MainActor (String) -> Void
  ) -> SubmissionResult {
    coordinator.performExternalInput(in: paneID, origin: .user) {
      // Preserve the existing Handoff instruction and submit convention.
      write(text + "\n")
    }
  }

  nonisolated static func instructionFailureMessage(_ result: SubmissionResult) -> String? {
    switch result {
    case .submitted: return nil
    case .rejectedDraftPresent, .interruptedWithDraft:
      return "An interrupted automatic draft remains in the pane. "
        + "Submit or clear that draft before trying again. No handoff instruction was sent."
    case .cancelledBeforeWrite:
      return "The request was cancelled before it could be sent. No handoff instruction was sent."
    case .targetChanged:
      return "The pane is no longer available for input. No handoff instruction was sent."
    }
  }

  @MainActor
  static func live(
    handlers: HandoffHandlers,
    registry: HandoffRequestRegistry,
    engine: TerminalEngine,
    cli: String,
    installation: AgentInstallationStore,
    source: @escaping @MainActor @Sendable (PaneID) -> HandoffSource?
  ) -> HandoffClient {
    HandoffClient(
      source: source,
      register: { registry.register($0) },
      supersede: { registry.supersede($0) },
      completions: { registry.completions() },
      sendInstruction: { paneID, text in
        guard let surface = engine.ghosttyRuntime?.surface(for: paneID),
          let coordinator = PaneInputCoordinator.shared
        else { return .targetChanged }
        return deliverInstruction(text, to: paneID, coordinator: coordinator) {
          surface.sendInput($0)
        }
      },
      run: { request in
        let response =
          switch request.action {
          case .save: try await handlers.save(request)
          case .to: try await handlers.to(request)
          }
        return HandoffCompletion(
          action: response.action,
          sourcePaneID: request.paneID,
          receiver: response.receiver.flatMap { AgentKind(rawValue: $0) },
          briefing: HandoffBriefingOutcome(rawValue: response.briefing) ?? .none,
          launched: response.launchedPane,
          requestID: request.requestID
        )
      },
      cli: cli,
      lastPlacement: { HandoffPlacementPersistence.load() },
      rememberPlacement: { HandoffPlacementPersistence.save($0) },
      isInstalled: { installation.isInstalled($0) }
    )
  }
}

extension HandoffClient: DependencyKey {
  static let liveValue = HandoffClient(
    source: { _ in fatalError("HandoffClient.liveValue not configured") },
    register: { _ in fatalError("HandoffClient.liveValue not configured") },
    supersede: { _ in fatalError("HandoffClient.liveValue not configured") },
    completions: { fatalError("HandoffClient.liveValue not configured") },
    sendInstruction: { _, _ in fatalError("HandoffClient.liveValue not configured") },
    run: { _ in fatalError("HandoffClient.liveValue not configured") }
  )

  static let testValue = HandoffClient(
    source: unimplemented("HandoffClient.source", placeholder: nil),
    register: unimplemented("HandoffClient.register"),
    supersede: unimplemented("HandoffClient.supersede", placeholder: false),
    completions: unimplemented("HandoffClient.completions", placeholder: AsyncStream { $0.finish() }),
    sendInstruction: unimplemented("HandoffClient.sendInstruction", placeholder: .targetChanged),
    run: unimplemented(
      "HandoffClient.run",
      placeholder: HandoffCompletion(
        action: .save, sourcePaneID: PaneID(), receiver: nil, briefing: .none,
        launched: nil, requestID: nil))
  )
}

extension DependencyValues {
  var handoffClient: HandoffClient {
    get { self[HandoffClient.self] }
    set { self[HandoffClient.self] = newValue }
  }
}
