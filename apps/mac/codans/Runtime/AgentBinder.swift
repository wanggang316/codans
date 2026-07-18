import Foundation
import OSLog
import CodansCore

private let binderLogger = Logger(
  subsystem: "com.gumpw.codans.agentstate", category: "binder"
)

/// Identifies which coding agent is running in each pane and persists
/// that decision via `HierarchyClient.setPaneAgentKind`.
///
/// Foreground job snapshots are the authoritative signal: they follow the
/// PTY foreground process group, so an agent started after an idle shell is
/// still identified and an exited agent clears on the next snapshot.
@MainActor
final class AgentBinder {
  enum Trigger: Equatable {
    case foregroundJobChanged(ForegroundJob)
  }

  private struct Presence {
    static let releaseMissThreshold: UInt8 = 6

    var misses: UInt8 = 0

    mutating func shouldRelease(afterMiss classified: AgentKind?) -> Bool {
      if classified != nil {
        misses = 0
        return false
      }
      misses += 1
      if misses >= Self.releaseMissThreshold {
        misses = 0
        return true
      }
      return false
    }
  }

  private let client: HierarchyClient
  private let currentAgentKind: @MainActor (PaneID) -> AgentKind?
  /// Optional post-bind hook: fired immediately AFTER `setPaneAgentKind` lands
  /// a non-nil binding. AppState wires this to `AgentStateStore.onAgentBound`
  /// so the AgentState UI learns about the new agent without a separate
  /// observation pass. Default no-op keeps existing tests / callers
  /// untouched.
  private let agentBoundHandler: @MainActor (PaneID, AgentKind, String?, Bool) -> Void
  /// Companion of `agentBoundHandler` — fires on `unbind(_:)` and on any
  /// path that writes a nil binding through `setPaneAgentKind`. AppState
  /// wires this to `AgentStateStore.onAgentUnbound`.
  private let agentUnboundHandler: @MainActor (PaneID) -> Void
  private var presenceByPane: [PaneID: Presence] = [:]
  private var materializedBindings: Set<PaneID> = []

  init(
    client: HierarchyClient,
    currentAgentKind: @escaping @MainActor (PaneID) -> AgentKind?,
    agentBoundHandler: @escaping @MainActor (PaneID, AgentKind, String?, Bool) -> Void = {
      _, _, _, _ in
    },
    agentUnboundHandler: @escaping @MainActor (PaneID) -> Void = { _ in }
  ) {
    self.client = client
    self.currentAgentKind = currentAgentKind
    self.agentBoundHandler = agentBoundHandler
    self.agentUnboundHandler = agentUnboundHandler
  }

  /// Re-run classification for this pane in response to the given trigger
  /// and write only when the result differs from the current binding.
  /// See the type-level doc comment for the signal contract.
  func consider(paneID: PaneID, trigger: Trigger) {
    let existing = currentAgentKind(paneID)

    switch trigger {
    case .foregroundJobChanged(let job):
      let classified = AgentKindPatterns.classify(foregroundJob: job)
      if classified == nil, existing == nil {
        presenceByPane.removeValue(forKey: paneID)
        return
      }
      var presence = presenceByPane[paneID] ?? Presence()
      defer { presenceByPane[paneID] = presence }
      if classified == nil {
        if existing != nil, !presence.shouldRelease(afterMiss: classified) {
          logTransition(
            action: "retain", paneID: paneID, existing: existing,
            classified: classified, job: job, misses: presence.misses
          )
          return
        }
      } else {
        _ = presence.shouldRelease(afterMiss: classified)
      }
      if classified == existing {
        if let kind = classified, !materializedBindings.contains(paneID) {
          materializedBindings.insert(paneID)
          agentBoundHandler(paneID, kind, nil, true)
          logTransition(
            action: "materialize", paneID: paneID, existing: existing,
            classified: classified, job: job, misses: presence.misses
          )
        } else {
          binderLogger.debug("noop pane=\(Self.paneTag(paneID), privacy: .public)")
        }
        return
      }
      writeIfChanged(
        paneID: paneID,
        existing: existing,
        next: classified,
        job: job,
        misses: presence.misses,
        assumeUserInputSeen: false
      )
    }
  }

  /// Pane teardown: clear the agent binding. Always calls the writer; the
  /// underlying writer is idempotent so a never-bound pane costs only a
  /// snapshot read.
  func unbind(_ paneID: PaneID) {
    let existing = currentAgentKind(paneID)
    presenceByPane.removeValue(forKey: paneID)
    materializedBindings.remove(paneID)
    client.setPaneAgentKind(paneID, nil)
    agentUnboundHandler(paneID)
    logTransition(
      action: "unbind", paneID: paneID, existing: existing, classified: nil
    )
  }

  // MARK: - Helpers

  private func writeIfChanged(
    paneID: PaneID,
    existing: AgentKind?,
    next: AgentKind?,
    job: ForegroundJob?,
    misses: UInt8,
    assumeUserInputSeen: Bool
  ) {
    guard existing != next else {
      binderLogger.debug("noop pane=\(Self.paneTag(paneID), privacy: .public)")
      return
    }
    let action: String
    if existing == nil {
      action = "bind"
    } else if next == nil {
      action = "release"
    } else {
      action = "rebind"
    }
    logTransition(
      action: action, paneID: paneID, existing: existing, classified: next,
      job: job, misses: misses
    )
    client.setPaneAgentKind(paneID, next)
    // Post-bind hook — fire AFTER the writer so the registry observes the
    // same kind that just landed in the catalog. Session-id is not modelled
    // here yet (always nil); when `setPaneAgentSessionID` callers wake
    // up, plumb a third channel down through this hook.
    if let kind = next {
      materializedBindings.insert(paneID)
      agentBoundHandler(paneID, kind, nil, assumeUserInputSeen)
    } else {
      materializedBindings.remove(paneID)
      agentUnboundHandler(paneID)
    }
  }

  /// Short pane-id slug for log correlation. UUID-prefix only, no PII.
  private static func paneTag(_ paneID: PaneID) -> String {
    String(paneID.raw.uuidString.prefix(8))
  }

  /// Single-line diagnostic emitted on every binding transition. Format:
  ///
  ///     action=<verb> pane=<id8> kind=<old>→<new> pgid=<n> procs=<a,b,c> misses=<m>/<t>
  ///
  /// Stable column names so `log show --predicate
  /// 'subsystem == "com.gumpw.codans.agentstate" and category == "binder"'`
  /// stays greppable across releases. Process names are basenames — never
  /// commandLines, which can contain secrets in argv.
  private func logTransition(
    action: String,
    paneID: PaneID,
    existing: AgentKind?,
    classified: AgentKind?,
    job: ForegroundJob? = nil,
    misses: UInt8 = 0
  ) {
    let pgidStr = job.map { String($0.processGroupID) } ?? "-"
    let procsStr =
      job?.processes.prefix(4).map(\.processName).joined(separator: ",") ?? "-"
    binderLogger.info(
      "action=\(action, privacy: .public) pane=\(Self.paneTag(paneID), privacy: .public) kind=\(existing?.rawValue ?? "nil", privacy: .public)→\(classified?.rawValue ?? "nil", privacy: .public) pgid=\(pgidStr, privacy: .public) procs=\(procsStr, privacy: .public) misses=\(misses, privacy: .public)/\(Presence.releaseMissThreshold, privacy: .public)"
    )
  }
}
