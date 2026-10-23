import ComposableArchitecture
import Foundation
import CodansCore

/// Split viewport reducer. Actions mutate the Worktree's `SplitTree` of
/// Panes through `HierarchyClient`; live surfaces are created / destroyed
/// through `TerminalClient`. State seeds `worktreeID` so the lazy-surface
/// lifecycle can react to worktree switches.
@Reducer
struct SplitViewportFeature {
  @ObservableState
  struct State: Equatable {
    /// The Worktree currently rendered in the viewport. Set by parent
    /// features (the RootFeature selection stream).
    var worktreeID: WorktreeID?
    /// Lifecycle state for every Content currently shown in the viewport:
    /// one per Pane, for its selected Tab. The view bridges catalog changes
    /// into this array via `.hostsChanged(_:)`; existing entries are
    /// preserved by `contentID` so a `.ready` surface does not get knocked
    /// back to `.loading` on an unrelated catalog mutation.
    var paneHosts: IdentifiedArrayOf<PaneHostFeature.State> = []
  }

  enum Action: Equatable {
    case worktreeChanged(WorktreeID?)
    /// Emitted by `SplitViewportView` when the set of shown Contents
    /// changes (Tab selected, Pane opened / closed / split). The seeds
    /// carry the Tab address; existing `paneHosts` entries with the same
    /// `contentID` are carried over unchanged.
    case hostsChanged([PaneHostFeature.State])
    case paneHosts(IdentifiedActionOf<PaneHostFeature>)
    /// "New Tab" from the viewport: lands in `inPane` (nil = the focused
    /// Pane, or the first Pane of an empty Worktree).
    case newTabButtonTapped(
      inPane: PaneID?, inWorktree: WorktreeID, inProject: ProjectID,
      workingDirectory: String)
    case splitButtonTapped(
      PaneID, direction: SplitTree<PaneID>.NewDirection, workingDirectory: String)
    case closePaneButtonTapped(PaneID)
    case focusPaneRequested(PaneID)
    case resizeSplitRequested(
      SplitTree<PaneID>.Path, ratio: Double, inWorktree: WorktreeID, inProject: ProjectID)
    /// Emitted by `PaneDropDelegate` when a Pane is dropped onto an edge of
    /// another Pane in the same Worktree. Re-positions the dragged Pane next
    /// to the anchor; its Contents are preserved (no teardown).
    case moveTabRequested(TabID, toPane: PaneID, at: Int)
    case splitTabRequested(TabID, anchor: PaneID, direction: SplitTree<PaneID>.NewDirection)
  }

  @Dependency(HierarchyClient.self) private var hierarchyClient
  /// Used to eager-attach warm ghostty surfaces when new host seeds land —
  /// cuts the "Creating surface…" placeholder frame on tab / worktree
  /// switches when the surface already lives in the engine registry.
  @Dependency(TerminalClient.self) private var terminalClient

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .worktreeChanged(let worktreeID):
        state.worktreeID = worktreeID
        return .none

      case .hostsChanged(let seeds):
        let existing = state.paneHosts
        state.paneHosts = IdentifiedArray(
          uniqueElements: seeds.map { seed in
            if let carry = existing[id: seed.contentID] { return carry }
            // First time seeing this Content in state, but the surface may
            // already be warm from an earlier lifecycle (worktree revisit,
            // a Tab switched away and back). Skip the `.loading → .ready`
            // round-trip so the view renders the live surface on the first
            // frame.
            var seeded = seed
            if let surface = terminalClient.surface(seed.contentID) {
              seeded.phase = .ready
              seeded.surface = SurfaceBox(surface: surface)
            }
            return seeded
          }
        )
        return .none

      case .paneHosts:
        return .none

      case .newTabButtonTapped(let paneID, let worktreeID, let projectID, let cwd):
        guard
          let created = try? hierarchyClient.newTab(
            paneID, worktreeID, projectID, .terminal(workingDirectory: cwd), nil, nil, true)
        else { return .none }
        return bringUpAndFocus(created.contentID)

      case .splitButtonTapped(let paneID, let direction, let cwd):
        guard
          let created = try? hierarchyClient.splitPane(
            paneID, direction, .terminal(workingDirectory: cwd), nil, nil)
        else { return .none }
        return bringUpAndFocus(created.contentID)

      case .closePaneButtonTapped(let paneID):
        try? hierarchyClient.closePane(paneID)
        return .none

      case .focusPaneRequested(let paneID):
        try? hierarchyClient.focusPane(paneID)
        return .none

      case .resizeSplitRequested(let path, let ratio, let worktreeID, let projectID):
        try? hierarchyClient.resizeSplit(path, ratio, worktreeID, projectID)
        return .none

      case .moveTabRequested(let tabID, let paneID, let index):
        guard (try? hierarchyClient.moveTabToPane(tabID, paneID, index)) != nil else { return .none }
        return focusMovedTab(tabID)

      case .splitTabRequested(let tabID, let anchorID, let direction):
        guard (try? hierarchyClient.splitTab(tabID, anchorID, direction)) != nil else { return .none }
        return focusMovedTab(tabID)
      }
    }
    .forEach(\.paneHosts, action: \.paneHosts) {
      PaneHostFeature()
    }
  }

  /// Keeps the moved Tab focused after the layout settles — mirrors the
  /// post-split focus tail-call. The surface view needs the rebuilt
  /// hierarchy attached before `makeFirstResponder` takes, so hop async.
  private func focusMovedTab(_ tabID: TabID) -> Effect<Action> {
    guard let contentID = hierarchyClient.snapshot().address(forTab: tabID)?.contentID else {
      return .none
    }
    return .run { [client = hierarchyClient] _ in
      await MainActor.run { client.focusSurfaceView(contentID) }
    }
  }

  /// Spawn the new Tab's session, then focus it. `ensureSurface` is async
  /// (zmx daemon spawn + control-socket handshake); hop into an effect so
  /// the reducer thread doesn't await. The focus tail-call mirrors
  /// `PaneActionRouterFeature` so the user lands on the fresh session
  /// without an extra click.
  private func bringUpAndFocus(_ contentID: ContentID) -> Effect<Action> {
    .run { [client = hierarchyClient] _ in
      guard (try? await client.ensureSurface(contentID)) != nil else { return }
      await MainActor.run { client.focusSurfaceView(contentID) }
    }
  }
}
