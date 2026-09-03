import CodansCore
import Foundation

/// Everything the pane HUD renders, resolved from the catalog and the live
/// monitors in one pass. Keeping the resolution rules here rather than in the
/// view body makes them testable without a view tree, and keeps the two
/// "why is this unavailable" answers spelled once.
nonisolated struct PaneHUDModel: Equatable, Sendable {
  let projectID: ProjectID
  let worktreeID: WorktreeID
  /// Absolute worktree root. The diff monitor keys its refresh on this.
  let worktreePath: String
  /// Same root as a human would type it: `$HOME` collapsed to `~`.
  let displayPath: String
  /// `nil` on a detached HEAD.
  let branch: String?
  /// Uncommitted line counts, or `nil` until the monitor has answered.
  let diff: LocalDiffStats?
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
  /// `diff` is a lookup rather than a value because the worktree it is keyed
  /// by is itself resolved here.
  ///
  /// `agent` comes from the caller rather than `Pane.agentKind` alone: the
  /// live `AgentStateStore` sees an agent the moment its process is
  /// classified, while the catalog field only carries what was persisted.
  /// Callers pass the store's answer and let this fall back to the catalog.
  static func resolve(
    paneID: PaneID,
    in catalog: Catalog,
    agent: AgentKind?,
    diff: (WorktreeID) -> LocalDiffStats?,
    homeDirectory: String
  ) -> PaneHUDModel? {
    guard
      let projectID = catalog.projectID(forPane: paneID),
      let worktreeID = catalog.worktreeID(forPane: paneID),
      let project = catalog.projects.first(where: { $0.id == projectID }),
      let worktree = project.worktrees.first(where: { $0.id == worktreeID })
    else {
      return nil
    }
    let resolvedAgent = agent ?? catalog.pane(paneID)?.agentKind
    return PaneHUDModel(
      projectID: projectID,
      worktreeID: worktreeID,
      worktreePath: worktree.path,
      displayPath: displayPath(worktree.path, home: homeDirectory),
      branch: worktree.branch,
      diff: diff(worktreeID),
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

  /// `/Users/me/dev/app` renders as `~/dev/app`. Anything outside `$HOME`
  /// stays absolute rather than being shortened misleadingly.
  static func displayPath(_ path: String, home: String) -> String {
    guard !home.isEmpty else { return path }
    let root = home.hasSuffix("/") ? String(home.dropLast()) : home
    if path == root { return "~" }
    guard path.hasPrefix(root + "/") else { return path }
    return "~/" + path.dropFirst(root.count + 1)
  }
}
