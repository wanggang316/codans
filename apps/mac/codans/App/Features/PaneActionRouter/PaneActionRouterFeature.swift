import ComposableArchitecture
import Foundation
import CodansCore
import os.log

/// Pure router reducer for `TerminalEvent.paneActionRequested`. Maps each
/// typed `PaneActionRequest` onto exactly one `HierarchyClient` closure —
/// the single place where libghostty-sourced tab/split intents meet the
/// catalog mutation layer.
///
/// State is empty by design: the router is a fan-out table, not a state
/// machine. Every error path (missing pane address, stale catalog, invalid
/// resize direction) is swallowed and logged; a race with teardown must
/// never crash the runtime callback thread.
///
/// Two simplifications worth noting:
/// - `PaneActionRequest.gotoSplit` currently collapses spatial directions
///   (up/down/left/right) onto the tree's previous/next neighbor order
///   (`SplitTree.focusTarget`). A real spatial walk needs frame geometry
///   the reducer does not own; upgrade later if users ask.
/// - `PaneActionRequest.toggleSplitZoom` reads the live catalog snapshot
///   to decide between `focusPane` (zoom) and `unzoomTab` (unzoom). This
///   is a read-then-write pair — benign at user-keystroke cadence.
@Reducer
struct PaneActionRouterFeature {
  @ObservableState
  struct State: Equatable {}

  enum Action: Equatable {
    case requested(PaneID, PaneActionRequest)
    case delegate(Delegate)

    /// Parent-consumed delegate. `PresentTerminal` and
    /// `ToggleCommandPalette` are UI-level intents the root reducer owns;
    /// the router only lifts them onto a typed action so the parent can
    /// service them without re-decoding the ghostty action. Both carry
    /// the source pane so the parent can resolve per-pane context
    /// (e.g. which pane is focused when the palette opens).
    enum Delegate: Equatable {
      case presentTerminalRequested(PaneID)
      case commandPaletteToggleRequested(PaneID)
    }
  }

  @Dependency(HierarchyClient.self) private var hierarchyClient

  private static let logger = Logger(
    subsystem: "com.gumpw.codans.router", category: "pane"
  )

  var body: some Reducer<State, Action> {
    Reduce { _, action in
      switch action {
      case .requested(let paneID, let request):
        return dispatch(paneID, request)
      case .delegate:
        return .none
      }
    }
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func dispatch(_ paneID: PaneID, _ request: PaneActionRequest) -> Effect<Action> {
    switch request {
    case .newTab:
      guard let address = hierarchyClient.addressOf(paneID) else {
        Self.logger.info("newTab: no address for pane \(paneID.raw.uuidString, privacy: .public)")
        return .none
      }
      // Inherit the source pane's cwd so the new tab opens in the same
      // directory. Missing source (already closed?) falls back to the
      // worktree root via `findWorktreePath`.
      let catalog = hierarchyClient.snapshot()
      let cwd =
        findPane(
          paneID: paneID, tabID: address.tabID,
          worktreeID: address.worktreeID, projectID: address.projectID,
          in: catalog
        )?.workingDirectory ?? findWorktree(
          worktreeID: address.worktreeID, projectID: address.projectID,
          in: catalog
        )?.path ?? NSHomeDirectory()
      guard
        let newTabID = try? hierarchyClient.createTab(
          address.worktreeID, address.projectID, nil
        )
      else { return .none }
      // Without this, HierarchyManager.createTab initialises an empty Tab
      // and the UI shows "No panes" until the user opens one manually —
      // a surprise for a keybind that asked for a working tab.
      let cwdForTab = cwd
      let worktreeID = address.worktreeID
      let projectID = address.projectID
      return .run { [client = hierarchyClient] _ in
        _ = try? await client.openPane(
          newTabID, worktreeID, projectID, cwdForTab, nil
        )
      }

    case .closeTab(.this):
      guard let address = hierarchyClient.addressOf(paneID) else { return .none }
      try? hierarchyClient.closeTab(
        address.tabID, address.worktreeID, address.projectID
      )
      return .none

    case .closeTab(.other):
      closeSiblingTabs(from: paneID, mode: .other)
      return .none

    case .closeTab(.right):
      closeSiblingTabs(from: paneID, mode: .right)
      return .none

    case .moveTab(let offset):
      guard let address = hierarchyClient.addressOf(paneID) else { return .none }
      try? hierarchyClient.moveTab(
        address.tabID, address.worktreeID, address.projectID, offset
      )
      return .none

    case .gotoTab(let target):
      gotoTab(from: paneID, target: target)
      return .none

    case .newSplit(let direction):
      Self.logger.info(
        "newSplit received: paneID=\(paneID.raw.uuidString, privacy: .public) dir=\(String(describing: direction), privacy: .public)"
      )
      guard let address = hierarchyClient.addressOf(paneID) else {
        Self.logger.info(
          "newSplit aborted: no address for paneID=\(paneID.raw.uuidString, privacy: .public)"
        )
        return .none
      }
      let catalog = hierarchyClient.snapshot()
      guard
        let sourcePane = findPane(
          paneID: paneID, tabID: address.tabID,
          worktreeID: address.worktreeID, projectID: address.projectID,
          in: catalog
        )
      else { return .none }
      let newDir = Self.splitDirection(for: direction)
      let tabID = address.tabID
      let worktreeID = address.worktreeID
      let projectID = address.projectID
      let cwd = sourcePane.workingDirectory
      // Match ghostty macOS controller: focus the new pane. Dispatched
      // async so the surface view has been attached to the hosting
      // window by the time `makeFirstResponder` runs — at this moment
      // the NSViewRepresentable update cycle hasn't finished yet.
      return .run { [client = hierarchyClient] _ in
        guard
          let newPaneID = try? await client.splitPane(
            paneID, newDir,
            tabID, worktreeID, projectID,
            cwd, nil
          )
        else { return }
        await MainActor.run {
          client.focusSurfaceView(newPaneID)
        }
      }

    case .closePane:
      guard let address = hierarchyClient.addressOf(paneID) else { return .none }
      let catalog = hierarchyClient.snapshot()
      guard
        let tab = findTab(
          tabID: address.tabID, worktreeID: address.worktreeID,
          projectID: address.projectID, in: catalog
        )
      else { return .none }
      // Single-pane tab: closing the last pane should also retire the
      // now-empty tab, mirroring the ⌘W `close_surface` path in
      // RootFeature. A zombie tab with no panes shows a blank pane area.
      if tab.panes.count <= 1 {
        try? hierarchyClient.closeTab(
          address.tabID, address.worktreeID, address.projectID
        )
        return .none
      }
      // Multi-pane tab: resolve the survivor BEFORE mutating the tree so
      // the leaf identity is still valid, drop the pane, then promote the
      // survivor's surface to first responder so input follows the close.
      let focusTarget = tab.splitTree.focusTargetAfterClosing(paneID)
      try? hierarchyClient.closePane(
        paneID, address.tabID, address.worktreeID, address.projectID
      )
      guard let focusTarget else { return .none }
      return .run { [client = hierarchyClient] _ in
        await MainActor.run {
          client.focusSurfaceView(focusTarget)
        }
      }

    case .gotoSplit(let direction):
      return gotoSplit(from: paneID, direction: direction)

    case .resizeSplit(let direction, let amount):
      try? hierarchyClient.resizePane(paneID, direction, amount)
      return .none

    case .equalizeSplits:
      guard let address = hierarchyClient.addressOf(paneID) else { return .none }
      try? hierarchyClient.equalizeTabSplits(
        address.tabID, address.worktreeID, address.projectID
      )
      return .none

    case .toggleSplitZoom:
      toggleSplitZoom(paneID: paneID)
      return .none

    case .presentTerminal:
      return .send(.delegate(.presentTerminalRequested(paneID)))

    case .toggleCommandPalette:
      return .send(.delegate(.commandPaletteToggleRequested(paneID)))
    }
  }

  // MARK: - Tab helpers

  /// Closes every tab in the source pane's Worktree that matches `mode`
  /// relative to the source's own tab. `.other` keeps only the current tab;
  /// `.right` keeps the current tab plus every tab to its left. Ordering is
  /// the catalog's natural tab-array order. Snapshots the catalog once so
  /// closes don't chase indexes as the array shrinks.
  private func closeSiblingTabs(from paneID: PaneID, mode: CloseTabMode) {
    guard let address = hierarchyClient.addressOf(paneID) else { return }
    let catalog = hierarchyClient.snapshot()
    guard
      let worktree = findWorktree(
        worktreeID: address.worktreeID, projectID: address.projectID,
        in: catalog
      )
    else { return }
    guard let currentIndex = worktree.tabs.firstIndex(where: { $0.id == address.tabID })
    else { return }

    let doomed: [TabID]
    switch mode {
    case .other:
      doomed = worktree.tabs.enumerated()
        .filter { $0.offset != currentIndex }
        .map { $0.element.id }
    case .right:
      doomed = worktree.tabs.suffix(from: currentIndex + 1).map(\.id)
    case .this:
      return  // handled in dispatch.
    }
    for tabID in doomed {
      try? hierarchyClient.closeTab(
        tabID, address.worktreeID, address.projectID
      )
    }
  }

  private func gotoTab(from paneID: PaneID, target: GotoTabTarget) {
    guard let address = hierarchyClient.addressOf(paneID) else { return }
    let catalog = hierarchyClient.snapshot()
    guard
      let worktree = findWorktree(
        worktreeID: address.worktreeID, projectID: address.projectID,
        in: catalog
      ),
      !worktree.tabs.isEmpty,
      let currentIndex = worktree.tabs.firstIndex(where: { $0.id == address.tabID })
    else { return }

    let count = worktree.tabs.count
    let targetIndex: Int
    switch target {
    case .previous:
      targetIndex = (currentIndex - 1 + count) % count
    case .next:
      targetIndex = (currentIndex + 1) % count
    case .last:
      targetIndex = count - 1
    case .index(let n):
      // Ghostty's `goto_tab:n` is 1-based; values beyond the tab count
      // should clamp to the last tab rather than no-op. `n <= 0` is still
      // rejected — negative numbers have no sensible target.
      guard n >= 1 else { return }
      targetIndex = min(n - 1, count - 1)
    }
    guard targetIndex != currentIndex else { return }
    let targetTabID = worktree.tabs[targetIndex].id
    try? hierarchyClient.selectTab(
      targetTabID, address.worktreeID, address.projectID
    )
  }

  // MARK: - Split helpers

  /// Maps ghostty's four-way `NewSplitDirection` onto the SplitTree's
  /// `NewDirection`. The two enums are 1:1 — libghostty tells us exactly
  /// which side the user asked for and we honor it.
  private static func splitDirection(
    for direction: NewSplitDirection
  ) -> SplitTree<PaneID>.NewDirection {
    switch direction {
    case .right: return .right
    case .left: return .left
    case .up: return .up
    case .down: return .down
    }
  }

  /// Resolves the target pane for `gotoSplit`, updates the catalog via
  /// `focusPane`, and then asynchronously promotes the neighbor's surface
  /// view to first responder so the cursor (and keyboard input) actually
  /// follows the focus change. Without the `focusSurfaceView` step the
  /// catalog flips `lastFocusedPane` and the dim overlay swaps, but the
  /// underlying `NSView` still holds the system caret.
  ///
  /// `previous`/`next` walk the tree's leaf order (used by
  /// `focusTargetAfterClosing` and any "tab through panes" flow). The
  /// four spatial directions resolve through `SplitTree`'s virtual
  /// layout — the split tree's own `direction`/`ratio` is enough to
  /// derive relative geometry, no live frame data needed. Returns nil
  /// (no-op) when the source pane is on the edge in the requested
  /// direction so "up means up" stays predictable.
  private func gotoSplit(from paneID: PaneID, direction: FocusDirection) -> Effect<Action> {
    guard let address = hierarchyClient.addressOf(paneID) else { return .none }
    let catalog = hierarchyClient.snapshot()
    guard
      let tab = findTab(
        tabID: address.tabID, worktreeID: address.worktreeID,
        projectID: address.projectID, in: catalog
      )
    else { return .none }

    let neighborID: PaneID?
    switch direction {
    case .previous:
      neighborID = tab.splitTree.focusTarget(for: .previous, from: paneID)
    case .next:
      neighborID = tab.splitTree.focusTarget(for: .next, from: paneID)
    case .up:
      neighborID = tab.splitTree.focusTarget(spatial: .up, from: paneID)
    case .down:
      neighborID = tab.splitTree.focusTarget(spatial: .down, from: paneID)
    case .left:
      neighborID = tab.splitTree.focusTarget(spatial: .left, from: paneID)
    case .right:
      neighborID = tab.splitTree.focusTarget(spatial: .right, from: paneID)
    }
    guard let neighborID else { return .none }
    try? hierarchyClient.focusPane(
      neighborID, address.tabID, address.worktreeID, address.projectID
    )
    // Mirror `newSplit`'s pattern: dispatch makeFirstResponder async so
    // the view tree has settled (zoom toggle / dim overlay diff) before
    // we steal first-responder status.
    return .run { [client = hierarchyClient] _ in
      await MainActor.run {
        client.focusSurfaceView(neighborID)
      }
    }
  }

  private func toggleSplitZoom(paneID: PaneID) {
    guard let address = hierarchyClient.addressOf(paneID) else { return }
    let catalog = hierarchyClient.snapshot()
    guard
      let tab = findTab(
        tabID: address.tabID, worktreeID: address.worktreeID,
        projectID: address.projectID, in: catalog
      )
    else { return }

    if tab.splitTree.zoomed == paneID {
      try? hierarchyClient.unzoomTab(
        address.tabID, address.worktreeID, address.projectID
      )
    } else {
      try? hierarchyClient.focusPane(
        paneID, address.tabID, address.worktreeID, address.projectID
      )
    }
  }

  // MARK: - Catalog lookups

  private func findWorktree(
    worktreeID: WorktreeID,
    projectID: ProjectID,
    in catalog: Catalog
  ) -> Worktree? {
    catalog.projects.first(where: { $0.id == projectID })?
      .worktrees.first(where: { $0.id == worktreeID })
  }

  private func findTab(
    tabID: TabID,
    worktreeID: WorktreeID,
    projectID: ProjectID,
    in catalog: Catalog
  ) -> Tab? {
    findWorktree(
      worktreeID: worktreeID, projectID: projectID, in: catalog
    )?.tabs.first(where: { $0.id == tabID })
  }

  private func findPane(
    paneID: PaneID,
    tabID: TabID,
    worktreeID: WorktreeID,
    projectID: ProjectID,
    in catalog: Catalog
  ) -> Pane? {
    findTab(
      tabID: tabID, worktreeID: worktreeID, projectID: projectID,
      in: catalog
    )?.panes.first(where: { $0.id == paneID })
  }
}
