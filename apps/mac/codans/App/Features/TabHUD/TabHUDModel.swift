import CodansCore
import Foundation

/// What the Tab HUD has to decide, resolved from the catalog and the live
/// agent store in one pass: which agent this Tab's Content carries, and
/// whether hand off can be offered here. Kept out of the view body so the rules are
/// testable without a view tree and the "why is this unavailable" answers
/// are spelled once.
nonisolated struct TabHUDModel: Equatable, Sendable {
  /// Agent codans currently attributes to this Tab's Content.
  let agent: AgentKind?
  /// Why hand off cannot be offered here, or `nil` when it can. Phrased for
  /// display; the same conditions `RootFeature.handoffRequested` re-checks
  /// authoritatively when the row is actually tapped.
  let handOffBlockedReason: String?
  /// Commands parked on this Tab's Content. Shows the queue button under the actions
  /// button and the count on the Command Queue row; zero renders neither.
  let queuedCommandCount: Int

  var canHandOff: Bool { handOffBlockedReason == nil }

  /// Resolves the HUD for `contentID`, or `nil` when its Tab is no longer in
  /// the catalog (it was closed while its host was still on screen).
  ///
  /// `agent` comes from the caller rather than `TerminalContentState.agentKind` alone: the
  /// live `AgentStateStore` sees an agent the moment its process is
  /// classified, while the catalog field only carries what was persisted.
  /// Callers pass the store's answer and let this fall back to the catalog.
  static func resolve(
    contentID: ContentID,
    in catalog: Catalog,
    agent: AgentKind?
  ) -> TabHUDModel? {
    guard
      let projectID = catalog.projectID(forContent: contentID),
      let project = catalog.projects.first(where: { $0.id == projectID })
    else {
      return nil
    }
    let content = catalog.content(contentID)?.terminal
    let resolvedAgent = agent ?? content?.agentKind
    return TabHUDModel(
      agent: resolvedAgent,
      handOffBlockedReason: handOffBlockedReason(project: project, agent: resolvedAgent),
      queuedCommandCount: content?.commandQueue.count ?? 0
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
