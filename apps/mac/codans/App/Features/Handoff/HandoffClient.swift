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
  /// Types `text` (plus Enter) into the pane's live surface. `false` when
  /// the pane has no surface to take input.
  var sendInstruction: @MainActor @Sendable (_ paneID: PaneID, _ text: String) -> Bool
  /// Runs a handoff transition in-process — the panel's fallback when the
  /// live agent cannot be asked. Same code path as the CLI verbs.
  var run: @MainActor @Sendable (_ request: IPC.HandoffRequest) async throws -> HandoffCompletion
}

extension HandoffClient {
  @MainActor
  static func live(
    handlers: HandoffHandlers,
    registry: HandoffRequestRegistry,
    engine: TerminalEngine,
    source: @escaping @MainActor @Sendable (PaneID) -> HandoffSource?
  ) -> HandoffClient {
    HandoffClient(
      source: source,
      register: { registry.register($0) },
      supersede: { registry.supersede($0) },
      completions: { registry.completions() },
      sendInstruction: { paneID, text in
        guard let surface = engine.ghosttyRuntime?.surface(for: paneID) else { return false }
        // Same submit convention as script dispatch: the trailing newline is
        // what makes a TUI input box accept the line.
        surface.sendInput(text + "\n")
        return true
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
      }
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
    sendInstruction: unimplemented("HandoffClient.sendInstruction", placeholder: false),
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
