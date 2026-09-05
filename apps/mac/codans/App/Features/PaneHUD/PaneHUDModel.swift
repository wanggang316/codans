import CodansCore
import Foundation

/// What the pane HUD has to decide, resolved from the catalog and the live
/// agent store in one pass: which agent this pane carries, and whether hand
/// off can be offered here. Kept out of the view body so the rules are
/// testable without a view tree and the "why is this unavailable" answers
/// are spelled once.
nonisolated struct PaneHUDModel: Equatable, Sendable {
  /// Agent codans currently attributes to this pane.
  let agent: AgentKind?
  /// Why hand off cannot be offered here, or `nil` when it can. Phrased for
  /// display; the same conditions `RootFeature.handoffRequested` re-checks
  /// authoritatively when the row is actually tapped.
  let handOffBlockedReason: String?

  var canHandOff: Bool { handOffBlockedReason == nil }

  /// Resolves the HUD for `paneID`, or `nil` when the pane is no longer in
  /// the catalog (it was closed while its host was still on screen).
  ///
  /// `agent` comes from the caller rather than `Pane.agentKind` alone: the
  /// live `AgentStateStore` sees an agent the moment its process is
  /// classified, while the catalog field only carries what was persisted.
  /// Callers pass the store's answer and let this fall back to the catalog.
  static func resolve(
    paneID: PaneID,
    in catalog: Catalog,
    agent: AgentKind?
  ) -> PaneHUDModel? {
    guard
      let projectID = catalog.projectID(forPane: paneID),
      let project = catalog.projects.first(where: { $0.id == projectID })
    else {
      return nil
    }
    let resolvedAgent = agent ?? catalog.pane(paneID)?.agentKind
    return PaneHUDModel(
      agent: resolvedAgent,
      handOffBlockedReason: handOffBlockedReason(project: project, agent: resolvedAgent)
    )
  }

  /// Mirrors the guards in `RootFeature.handoffRequested` so the HUD explains
  /// the refusal up front instead of opening the panel and failing.
  private static func handOffBlockedReason(project: Project, agent: AgentKind?) -> String? {
    if project.remoteHost != nil {
      return "Hand off is not available for Server projects"
    }
    if agent == nil {
      return "No agent detected in this pane"
    }
    return nil
  }
}
