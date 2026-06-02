import ComposableArchitecture
import Foundation
import TouchCodeCore

/// Split viewport reducer. Actions mutate the active Tab's `SplitTree`
/// through `HierarchyClient`; live pane surfaces are created / destroyed
/// through `TerminalClient`. Per DEC-3 the state seeds `activeTabID:
/// TabID?` so M5's lazy-surface lifecycle can react to `.tabActivated`
/// without state restructuring.
@Reducer
struct SplitViewportFeature {
  @ObservableState
  struct State: Equatable {
    /// The Tab currently rendered in the viewport. Set by parent features
    /// (RootFeature selection stream in M4; lazy lifecycle in M5).
    var activeTabID: TabID?
    /// Lifecycle state for every pane currently rendered in the viewport.
    /// The view bridges catalog changes into this array via
    /// `.panesInActiveTabChanged(_:)`; existing entries are preserved by
    /// `paneID` so a `.ready` surface does not get knocked back to
    /// `.loading` on an unrelated catalog mutation.
    var paneHosts: IdentifiedArrayOf<PaneHostFeature.State> = []
  }

  enum Action: Equatable {
    case activeTabChanged(TabID?)
    /// Emitted by `SplitViewportView` when the active Tab's pane list
    /// changes (pane opened, closed, split). The seeds carry the pane
    /// address; existing `paneHosts` entries with the same `paneID` are
    /// carried over unchanged.
    case panesInActiveTabChanged([PaneHostFeature.State])
    case paneHosts(IdentifiedActionOf<PaneHostFeature>)
    case newPaneButtonTapped(
      inTab: TabID, inWorktree: WorktreeID, inProject: ProjectID,
      workingDirectory: String)
    case splitButtonTapped(
      PaneID, direction: SplitTree<PaneID>.NewDirection,
      inTab: TabID, inWorktree: WorktreeID, inProject: ProjectID,
      workingDirectory: String)
    case closePaneButtonTapped(
      PaneID, inTab: TabID, inWorktree: WorktreeID, inProject: ProjectID)
    case focusPaneRequested(
      PaneID, inTab: TabID, inWorktree: WorktreeID, inProject: ProjectID)
    case resizeSplitRequested(
      SplitTree<PaneID>.Path, ratio: Double,
      inTab: TabID, inWorktree: WorktreeID, inProject: ProjectID)
    /// Emitted by `PaneDropDelegate` when a pane is dropped onto an edge of
    /// another pane in the same Tab. Re-positions the dragged pane next to
    /// the anchor; the moved pane's surface is preserved (no teardown).
    case movePaneRequested(
      PaneID, anchor: PaneID, direction: SplitTree<PaneID>.NewDirection,
      inTab: TabID, inWorktree: WorktreeID, inProject: ProjectID)
  }

  @Dependency(HierarchyClient.self) private var hierarchyClient
  /// Used to eager-attach warm ghostty surfaces when new pane seeds land —
  /// cuts the "Creating surface…" placeholder frame on tab / worktree
  /// switches when the surface already lives in the engine registry.
  @Dependency(TerminalClient.self) private var terminalClient

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .activeTabChanged(let tabID):
        state.activeTabID = tabID
        return .none

      case .panesInActiveTabChanged(let seeds):
        let existing = state.paneHosts
        state.paneHosts = IdentifiedArray(
          uniqueElements: seeds.map { seed in
            if let carry = existing[id: seed.paneID] { return carry }
            // First time seeing this pane in state, but the surface may
            // already be warm from an earlier lifecycle (worktree revisit,
            // auto-seeded pane). Skip the `.loading → .ready` round-trip
            // so the view renders the live surface on the first frame.
            var seeded = seed
            if let surface = terminalClient.surface(seed.paneID) {
              seeded.phase = .ready
              seeded.surface = SurfaceBox(surface: surface)
            }
            return seeded
          }
        )
        return .none

      case .paneHosts:
        return .none

      case .newPaneButtonTapped(let tabID, let worktreeID, let projectID, let cwd):
        // `openPane` is async (zmx daemon spawn + control-socket handshake);
        // hop into an effect so the reducer thread doesn't await. Focus
        // tail-call mirrors PaneActionRouterFeature.newSplit so the user
        // lands on the freshly opened pane without an extra click.
        return .run { [client = hierarchyClient] _ in
          guard
            let newPaneID = try? await client.openPane(
              tabID, worktreeID, projectID, cwd, nil
            )
          else { return }
          await MainActor.run { client.focusSurfaceView(newPaneID) }
        }

      case .splitButtonTapped(
        let paneID, let direction,
        let tabID, let worktreeID, let projectID, let cwd
      ):
        return .run { [client = hierarchyClient] _ in
          guard
            let newPaneID = try? await client.splitPane(
              paneID, direction, tabID, worktreeID, projectID, cwd, nil
            )
          else { return }
          await MainActor.run { client.focusSurfaceView(newPaneID) }
        }

      case .closePaneButtonTapped(let paneID, let tabID, let worktreeID, let projectID):
        try? hierarchyClient.closePane(paneID, tabID, worktreeID, projectID)
        return .none

      case .focusPaneRequested(let paneID, let tabID, let worktreeID, let projectID):
        try? hierarchyClient.focusPane(paneID, tabID, worktreeID, projectID)
        return .none

      case .resizeSplitRequested(
        let path, let ratio,
        let tabID, let worktreeID, let projectID
      ):
        try? hierarchyClient.resizeSplit(path, ratio, tabID, worktreeID, projectID)
        return .none

      case .movePaneRequested(
        let paneID, let anchorID, let direction,
        let tabID, let worktreeID, let projectID
      ):
        try? hierarchyClient.movePane(
          paneID, anchorID, direction, tabID, worktreeID, projectID
        )
        // Keep the moved pane focused after the layout settles — mirrors the
        // post-split focus tail-call. The surface view needs the rebuilt
        // hierarchy attached before `makeFirstResponder` takes, so hop async.
        return .run { [client = hierarchyClient] _ in
          await MainActor.run { client.focusSurfaceView(paneID) }
        }
      }
    }
    .forEach(\.paneHosts, action: \.paneHosts) {
      PaneHostFeature()
    }
  }
}
