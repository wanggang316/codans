import Foundation
import OSLog
import CodansCore

private let binderLogger = Logger(
  subsystem: "com.gumpw.codans.agentstate", category: "binder"
)

/// Identifies which coding agent is running in each pane and persists
/// that decision via `HierarchyClient.setAgentKind`.
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
  private let currentAgentKind: @MainActor (ContentID) -> AgentKind?
  /// Optional post-bind hook: fired immediately AFTER `setAgentKind` lands
  /// a non-nil binding. AppState wires this to `AgentStateStore.onAgentBound`
  /// so the AgentState UI learns about the new agent without a separate
  /// observation pass. Default no-op keeps existing tests / callers
  /// untouched.
  private let agentBoundHandler: @MainActor (ContentID, AgentKind, String?, Bool) -> Void
  /// Companion of `agentBoundHandler` — fires on `unbind(_:)` and on any
  /// path that writes a nil binding through `setAgentKind`. AppState
  /// wires this to `AgentStateStore.onAgentUnbound`.
  private let agentUnboundHandler: @MainActor (ContentID) -> Void
  private var presenceByPane: [ContentID: Presence] = [:]
  private var materializedBindings: Set<ContentID> = []

  init(
    client: HierarchyClient,
    currentAgentKind: @escaping @MainActor (ContentID) -> AgentKind?,
    agentBoundHandler: @escaping @MainActor (ContentID, AgentKind, String?, Bool) -> Void = {
      _, _, _, _ in
    },
    agentUnboundHandler: @escaping @MainActor (ContentID) -> Void = { _ in }
  ) {
    self.client = client
    self.currentAgentKind = currentAgentKind
    self.agentBoundHandler = agentBoundHandler
    self.agentUnboundHandler = agentUnboundHandler
  }

  /// Re-run classification for this pane in response to the given trigger
  /// and write only when the result differs from the current binding.
  /// See the type-level doc comment for the signal contract.
  func consider(contentID: ContentID, trigger: Trigger) {
    let existing = currentAgentKind(contentID)

    switch trigger {
    case .foregroundJobChanged(let job):
      let classified = AgentKindPatterns.classify(foregroundJob: job)
      if classified == nil, existing == nil {
        presenceByPane.removeValue(forKey: contentID)
        return
      }
      var presence = presenceByPane[contentID] ?? Presence()
      defer { presenceByPane[contentID] = presence }
      if classified == nil {
        if existing != nil, !presence.shouldRelease(afterMiss: classified) {
          logTransition(
            action: "retain", contentID: contentID, existing: existing,
            classified: classified, job: job, misses: presence.misses
          )
          return
        }
      } else {
        _ = presence.shouldRelease(afterMiss: classified)
      }
      if classified == existing {
        if let kind = classified, !materializedBindings.contains(contentID) {
          materializedBindings.insert(contentID)
          agentBoundHandler(contentID, kind, nil, true)
          logTransition(
            action: "materialize", contentID: contentID, existing: existing,
            classified: classified, job: job, misses: presence.misses
          )
        } else {
          binderLogger.debug("noop pane=\(Self.paneTag(contentID), privacy: .public)")
        }
        return
      }
      writeIfChanged(
        contentID: contentID,
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
  func unbind(_ contentID: ContentID) {
    let existing = currentAgentKind(contentID)
    presenceByPane.removeValue(forKey: contentID)
    materializedBindings.remove(contentID)
    client.setAgentKind(contentID, nil)
    agentUnboundHandler(contentID)
    logTransition(
      action: "unbind", contentID: contentID, existing: existing, classified: nil
    )
  }

  /// Catalog-membership backstop for the two per-pane maps.
  ///
  /// `unbind` is the only other cleaner and it rides on `.paneExited` /
  /// `.paneCrashed` / `.paneClosedByTab`. Archive and project removal use
  /// `suspendSurface`, which emits none of those, so a pane torn down that
  /// way keeps its `materializedBindings` membership forever. Archive makes
  /// that user-visible: soft-hide keeps the same `ContentID` and leaves
  /// `Pane.agentKind` set, so when the user unarchives and the agent runs
  /// again `consider` sees `classified == existing` with the pane still
  /// marked materialized and takes the noop branch — `agentBoundHandler`
  /// never fires and the Agents View row the archive retired never returns.
  ///
  /// Deliberately does NOT write a nil binding through the client the way
  /// `unbind` does: this runs from the catalog-mutation drain, and writing
  /// back into the catalog here would feed itself. Dropping the local maps
  /// is enough — the next `consider` re-materializes from scratch.
  func reconcileMembership(liveContentIDs: Set<ContentID>) {
    presenceByPane = presenceByPane.filter { liveContentIDs.contains($0.key) }
    materializedBindings.formIntersection(liveContentIDs)
  }

  // MARK: - Helpers

  private func writeIfChanged(
    contentID: ContentID,
    existing: AgentKind?,
    next: AgentKind?,
    job: ForegroundJob?,
    misses: UInt8,
    assumeUserInputSeen: Bool
  ) {
    guard existing != next else {
      binderLogger.debug("noop pane=\(Self.paneTag(contentID), privacy: .public)")
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
      action: action, contentID: contentID, existing: existing, classified: next,
      job: job, misses: misses
    )
    client.setAgentKind(contentID, next)
    // Post-bind hook — fire AFTER the writer so the registry observes the
    // same kind that just landed in the catalog. Session-id is not modelled
    // here yet (always nil); when `setPaneAgentSessionID` callers wake
    // up, plumb a third channel down through this hook.
    if let kind = next {
      materializedBindings.insert(contentID)
      agentBoundHandler(contentID, kind, nil, assumeUserInputSeen)
    } else {
      materializedBindings.remove(contentID)
      agentUnboundHandler(contentID)
    }
  }

  /// Short pane-id slug for log correlation. UUID-prefix only, no PII.
  private static func paneTag(_ contentID: ContentID) -> String {
    String(contentID.raw.uuidString.prefix(8))
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
    contentID: ContentID,
    existing: AgentKind?,
    classified: AgentKind?,
    job: ForegroundJob? = nil,
    misses: UInt8 = 0
  ) {
    let pgidStr = job.map { String($0.processGroupID) } ?? "-"
    let procsStr =
      job?.processes.prefix(4).map(\.processName).joined(separator: ",") ?? "-"
    binderLogger.info(
      "action=\(action, privacy: .public) pane=\(Self.paneTag(contentID), privacy: .public) kind=\(existing?.rawValue ?? "nil", privacy: .public)→\(classified?.rawValue ?? "nil", privacy: .public) pgid=\(pgidStr, privacy: .public) procs=\(procsStr, privacy: .public) misses=\(misses, privacy: .public)/\(Presence.releaseMissThreshold, privacy: .public)"
    )
  }
}
