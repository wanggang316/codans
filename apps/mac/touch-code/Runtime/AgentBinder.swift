import Foundation
import OSLog
import TouchCodeCore

private let binderLogger = Logger(
  subsystem: "com.touch-code.activeagents", category: "binder"
)

/// Identifies which coding agent is running in each pane and persists
/// that decision via `HierarchyClient.setPaneAgentKind`.
///
/// Foreground job snapshots are the authoritative signal: they follow the
/// PTY foreground process group, so an agent started after an idle shell is
/// still identified and an exited agent clears on the next snapshot. Title
/// and desktop-notification strings remain weak fallbacks for environments
/// where a process snapshot is temporarily unavailable; they can fill an
/// empty binding but never overwrite one.
@MainActor
final class AgentBinder {
  enum Trigger: Equatable {
    case paneCreated
    case titleChanged
    case desktopNotification(title: String, body: String)
    case promptReturned
    case foregroundJobChanged(ForegroundJob)
  }

  private let client: HierarchyClient
  private let currentAgentKind: @MainActor (PaneID) -> AgentKind?
  private let paneInitialCommand: @MainActor (PaneID) -> String?
  private let paneTitle: @MainActor (PaneID) -> String?
  /// Optional T6 hook: fired immediately AFTER `setPaneAgentKind` lands
  /// a non-nil binding. AppState wires this to `AgentRegistry.onAgentBound`
  /// so the ActiveAgents UI learns about the new agent without a separate
  /// observation pass. Default no-op keeps existing tests / callers
  /// untouched.
  private let agentBoundHandler: @MainActor (PaneID, AgentKind, String?) -> Void
  /// Companion of `agentBoundHandler` — fires on `unbind(_:)` and on any
  /// path that writes a nil binding through `setPaneAgentKind`. AppState
  /// wires this to `AgentRegistry.onAgentUnbound`.
  private let agentUnboundHandler: @MainActor (PaneID) -> Void

  init(
    client: HierarchyClient,
    currentAgentKind: @escaping @MainActor (PaneID) -> AgentKind?,
    paneInitialCommand: @escaping @MainActor (PaneID) -> String?,
    paneTitle: @escaping @MainActor (PaneID) -> String?,
    agentBoundHandler: @escaping @MainActor (PaneID, AgentKind, String?) -> Void = { _, _, _ in },
    agentUnboundHandler: @escaping @MainActor (PaneID) -> Void = { _ in }
  ) {
    self.client = client
    self.currentAgentKind = currentAgentKind
    self.paneInitialCommand = paneInitialCommand
    self.paneTitle = paneTitle
    self.agentBoundHandler = agentBoundHandler
    self.agentUnboundHandler = agentUnboundHandler
  }

  /// Re-run classification for this pane in response to the given trigger
  /// and write only when the result differs from the current binding.
  /// See the type-level doc comment for the full sticky-rule contract.
  func consider(paneID: PaneID, trigger: Trigger) {
    let existing = currentAgentKind(paneID)

    switch trigger {
    case .paneCreated:
      break

    case .titleChanged, .desktopNotification:
      guard existing == nil else {
        binderLogger.debug(
          "consider trigger=\(String(describing: trigger), privacy: .public) pane already bound, skipping"
        )
        return
      }
      guard let classified = classifyFallback(trigger: trigger, paneID: paneID) else { return }
      writeIfChanged(
        paneID: paneID, existing: existing, next: classified,
        reason: triggerLogTag(trigger)
      )

    case .promptReturned:
      guard existing == nil,
        let classified = classifyFallback(trigger: trigger, paneID: paneID)
      else { return }
      writeIfChanged(
        paneID: paneID, existing: existing, next: classified, reason: "promptReturned"
      )

    case .foregroundJobChanged(let job):
      let classified = AgentKindPatterns.classify(foregroundJob: job)
      guard classified != existing else { return }
      writeIfChanged(
        paneID: paneID,
        existing: existing,
        next: classified,
        reason: "foregroundJobChanged"
      )
    }
  }

  private func classifyFallback(trigger: Trigger, paneID: PaneID) -> AgentKind? {
    let notificationTitle: String? = {
      if case .desktopNotification(let notifTitle, _) = trigger { return notifTitle }
      return nil
    }()

    return AgentKindPatterns.classify(
      initialCommand: paneInitialCommand(paneID),
      title: paneTitle(paneID),
      notificationTitle: notificationTitle
    )
  }

  /// Pane teardown: clear the agent binding. Always calls the writer; the
  /// underlying writer is idempotent so a never-bound pane costs only a
  /// snapshot read.
  func unbind(_ paneID: PaneID) {
    client.setPaneAgentKind(paneID, nil)
    agentUnboundHandler(paneID)
  }

  // MARK: - Helpers

  private func writeIfChanged(
    paneID: PaneID,
    existing: AgentKind?,
    next: AgentKind?,
    reason: String
  ) {
    guard existing != next else {
      binderLogger.debug(
        "no-op classify reason=\(reason, privacy: .public)"
      )
      return
    }
    if existing == nil {
      binderLogger.info(
        "bind reason=\(reason, privacy: .public) kind=\(next?.rawValue ?? "nil", privacy: .public)"
      )
    } else {
      binderLogger.info(
        "rebind reason=\(reason, privacy: .public) \(existing?.rawValue ?? "nil", privacy: .public) → \(next?.rawValue ?? "nil", privacy: .public)"
      )
    }
    client.setPaneAgentKind(paneID, next)
    // T6 hook — fire AFTER the writer so the registry observes the same
    // kind that just landed in the catalog. Session-id is not modelled
    // here yet (always nil); when `setPaneAgentSessionID` callers wake
    // up, plumb a third channel down through this hook.
    if let kind = next {
      agentBoundHandler(paneID, kind, nil)
    } else {
      agentUnboundHandler(paneID)
    }
  }

  private func triggerLogTag(_ trigger: Trigger) -> String {
    switch trigger {
    case .paneCreated: return "paneCreated"
    case .titleChanged: return "titleChanged"
    case .desktopNotification: return "desktopNotification"
    case .promptReturned: return "promptReturned"
    case .foregroundJobChanged: return "foregroundJobChanged"
    }
  }
}
