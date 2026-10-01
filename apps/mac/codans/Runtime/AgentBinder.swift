import CodansCore
import Foundation
import OSLog

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
  private let surfaceGeneration: @MainActor (PaneID) -> UUID?
  private let currentSessionID: @MainActor (PaneID) -> String?
  private let verifiedBindingHandler: @MainActor (AgentBinding, Bool) -> Void
  private let bindingValidityHandler: @MainActor (PaneID, Bool) -> Void
  private var verifiedBindings: [PaneID: AgentBinding] = [:]
  private var bindingValidity: [PaneID: Bool] = [:]

  init(
    client: HierarchyClient,
    currentAgentKind: @escaping @MainActor (PaneID) -> AgentKind?,
    agentBoundHandler: @escaping @MainActor (PaneID, AgentKind, String?, Bool) -> Void = {
      _, _, _, _ in
    },
    agentUnboundHandler: @escaping @MainActor (PaneID) -> Void = { _ in },
    surfaceGeneration: @escaping @MainActor (PaneID) -> UUID? = { _ in nil },
    currentSessionID: @escaping @MainActor (PaneID) -> String? = { _ in nil },
    verifiedBindingHandler: @escaping @MainActor (AgentBinding, Bool) -> Void = { _, _ in },
    bindingValidityHandler: @escaping @MainActor (PaneID, Bool) -> Void = { _, _ in }
  ) {
    self.client = client
    self.currentAgentKind = currentAgentKind
    self.agentBoundHandler = agentBoundHandler
    self.agentUnboundHandler = agentUnboundHandler
    self.surfaceGeneration = surfaceGeneration
    self.currentSessionID = currentSessionID
    self.verifiedBindingHandler = verifiedBindingHandler
    self.bindingValidityHandler = bindingValidityHandler
  }

  /// Re-run classification for this pane in response to the given trigger
  /// and write only when the result differs from the current binding.
  /// See the type-level doc comment for the signal contract.
  func consider(paneID: PaneID, trigger: Trigger) {
    let existing = currentAgentKind(paneID)

    switch trigger {
    case .foregroundJobChanged(let job):
      // Verified ownership supersedes the legacy display-only path. An
      // uncertain probe must retain the last instance and its recovery budget.
      defer { updateVerifiedBinding(paneID: paneID, job: job, wasBound: existing != nil) }
      let classified = AgentKindPatterns.classify(foregroundJob: job)
      // A failed/empty OS probe is not evidence that the instance ended.
      // Releasing it would replenish attempts after repeated probe failures.
      if job.isEmpty, verifiedBindings[paneID] != nil { return }
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
          publishDisplayBinding(paneID: paneID, kind: kind, job: job, assumeUserInputSeen: true)
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
    verifiedBindings.removeValue(forKey: paneID)
    setBindingValidity(false, paneID: paneID)
    client.setPaneAgentKind(paneID, nil)
    agentUnboundHandler(paneID)
    logTransition(
      action: "unbind", paneID: paneID, existing: existing, classified: nil
    )
  }

  /// Catalog-membership backstop for the two per-pane maps.
  ///
  /// `unbind` is the only other cleaner and it rides on `.paneExited` /
  /// `.paneCrashed` / `.paneClosedByTab`. Archive and project removal use
  /// `suspendSurface`, which emits none of those, so a pane torn down that
  /// way keeps its `materializedBindings` membership forever. Archive makes
  /// that user-visible: soft-hide keeps the same `PaneID` and leaves
  /// `Pane.agentKind` set, so when the user unarchives and the agent runs
  /// again `consider` sees `classified == existing` with the pane still
  /// marked materialized and takes the noop branch — `agentBoundHandler`
  /// never fires and the Agents View row the archive retired never returns.
  ///
  /// Deliberately does NOT write a nil binding through the client the way
  /// `unbind` does: this runs from the catalog-mutation drain, and writing
  /// back into the catalog here would feed itself. Dropping the local maps
  /// is enough — the next `consider` re-materializes from scratch.
  func reconcileMembership(livePaneIDs: Set<PaneID>) {
    presenceByPane = presenceByPane.filter { livePaneIDs.contains($0.key) }
    materializedBindings.formIntersection(livePaneIDs)
    for paneID in verifiedBindings.keys where !livePaneIDs.contains(paneID) {
      setBindingValidity(false, paneID: paneID)
    }
    verifiedBindings = verifiedBindings.filter { livePaneIDs.contains($0.key) }
    bindingValidity = bindingValidity.filter { livePaneIDs.contains($0.key) }
  }

  /// An uncertain sample retains the last instance so its retry budget survives.
  /// Capturing code must freshly verify this value before attributing new text.
  func binding(for paneID: PaneID) -> AgentBinding? {
    verifiedBindings[paneID]
  }

  func isBindingValid(for paneID: PaneID) -> Bool {
    bindingValidity[paneID] == true
  }

  private func updateVerifiedBinding(paneID: PaneID, job: ForegroundJob, wasBound: Bool) {
    guard let generation = surfaceGeneration(paneID),
      let match = ForegroundJobReader.agentIdentity(in: job)
    else {
      setBindingValidity(false, paneID: paneID)
      return
    }
    let previous = verifiedBindings[paneID]
    let currentSession = currentSessionID(paneID)
    let sessionChanged =
      previous?.sessionID != nil && currentSession != nil
      && previous?.sessionID != currentSession
    let sameInstance =
      previous?.kind == match.kind && previous?.process == match.process
      && previous?.surfaceGeneration == generation && !sessionChanged
    let instanceID = sameInstance ? previous?.instanceID ?? AgentInstanceID() : AgentInstanceID()
    let binding = AgentBinding(
      instanceID: instanceID,
      paneID: paneID, surfaceGeneration: generation, kind: match.kind,
      process: match.process,
      sessionID: currentSession ?? (sameInstance ? previous?.sessionID : nil))
    verifiedBindings[paneID] = binding
    if previous != binding {
      verifiedBindingHandler(binding, wasBound)
    }
    setBindingValidity(true, paneID: paneID)
  }

  private func publishDisplayBinding(
    paneID: PaneID, kind: AgentKind, job: ForegroundJob?, assumeUserInputSeen: Bool
  ) {
    guard verifiedBindings[paneID] == nil else { return }
    if surfaceGeneration(paneID) != nil, let job,
      ForegroundJobReader.agentIdentity(in: job) != nil
    {
      return
    }
    agentBoundHandler(paneID, kind, nil, assumeUserInputSeen)
  }

  private func setBindingValidity(_ valid: Bool, paneID: PaneID) {
    guard bindingValidity[paneID] != valid else { return }
    bindingValidity[paneID] = valid
    bindingValidityHandler(paneID, valid)
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
      publishDisplayBinding(
        paneID: paneID, kind: kind, job: job, assumeUserInputSeen: assumeUserInputSeen)
    } else {
      materializedBindings.remove(paneID)
      verifiedBindings.removeValue(forKey: paneID)
      setBindingValidity(false, paneID: paneID)
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
