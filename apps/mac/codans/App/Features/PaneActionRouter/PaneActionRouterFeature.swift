import CodansCore
import ComposableArchitecture
import Foundation
import os.log

/// Pure router reducer for `TerminalEvent.paneActionRequested`. Maps each
/// typed `PaneActionRequest` onto exactly one `HierarchyClient` closure —
/// the single place where libghostty-sourced tab/split intents meet the
/// catalog mutation layer.
///
/// The request carries the source Content (the surface the keybind fired
/// in); the router resolves its Tab and Pane live, so a Tab that moved
/// since the surface was created still routes to where it is now.
///
/// State is empty by design: the router is a fan-out table, not a state
/// machine. Every error path (missing address, stale catalog, invalid
/// resize direction) is swallowed and logged; a race with teardown must
/// never crash the runtime callback thread.
@Reducer
struct PaneActionRouterFeature {
  @ObservableState
  struct State: Equatable {}

  enum Action: Equatable {
    case requested(ContentID, PaneActionRequest)
    case delegate(Delegate)

    /// Parent-consumed delegate. `PresentTerminal` and
    /// `ToggleCommandPalette` are UI-level intents the root reducer owns;
    /// the router only lifts them onto a typed action so the parent can
    /// service them without re-decoding the ghostty action. Both carry
    /// the source Content so the parent can resolve per-session context
    /// (e.g. which session is focused when the palette opens).
    enum Delegate: Equatable {
      case presentTerminalRequested(ContentID)
      case commandPaletteToggleRequested(ContentID)
      case openLinkRequested(ContentID, raw: String, workingDirectory: String?)
    }
  }

  @Dependency(HierarchyClient.self) private var hierarchyClient

  private static let logger = Logger(
    subsystem: "com.gumpw.codans.router", category: "pane"
  )

  var body: some Reducer<State, Action> {
    Reduce { _, action in
      switch action {
      case .requested(let contentID, let request):
        return dispatch(contentID, request)
      case .delegate:
        return .none
      }
    }
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func dispatch(_ contentID: ContentID, _ request: PaneActionRequest) -> Effect<Action> {
    switch request {
    case .newTab:
      guard let address = hierarchyClient.addressOf(contentID) else {
        Self.logger.info("newTab: no address for content \(contentID.raw.uuidString, privacy: .public)")
        return .none
      }
      // Inherit the source session's cwd so the new Tab opens in the same
      // directory; a Tab lands in the Pane the keybind fired in, not the
      // focused one.
      let catalog = hierarchyClient.snapshot()
      let cwd =
        catalog.content(contentID)?.terminal?.workingDirectory
        ?? findWorktree(worktreeID: address.worktreeID, projectID: address.projectID, in: catalog)?.path
        ?? NSHomeDirectory()
      guard
        let created = try? hierarchyClient.newTab(
          address.paneID, address.worktreeID, address.projectID,
          .terminal(workingDirectory: cwd), nil, nil, true
        )
      else { return .none }
      return bringUpAndFocus(created.contentID)

    case .closeTab(.this):
      guard let address = hierarchyClient.addressOf(contentID) else { return .none }
      try? hierarchyClient.closeTab(address.tabID)
      return .none

    case .closeTab(.other):
      guard let address = hierarchyClient.addressOf(contentID) else { return .none }
      try? hierarchyClient.closeOtherTabs(address.tabID)
      return .none

    case .closeTab(.right):
      guard let address = hierarchyClient.addressOf(contentID) else { return .none }
      try? hierarchyClient.closeTabsToRight(address.tabID)
      return .none

    case .moveTab(let offset):
      guard let address = hierarchyClient.addressOf(contentID) else { return .none }
      try? hierarchyClient.moveTab(address.tabID, offset)
      return .none

    case .gotoTab(let target):
      gotoTab(from: contentID, target: target)
      return .none

    case .newSplit(let direction):
      Self.logger.info(
        "newSplit received: content=\(contentID.raw.uuidString, privacy: .public) dir=\(String(describing: direction), privacy: .public)"
      )
      guard let address = hierarchyClient.addressOf(contentID) else {
        Self.logger.info(
          "newSplit aborted: no address for content=\(contentID.raw.uuidString, privacy: .public)"
        )
        return .none
      }
      let catalog = hierarchyClient.snapshot()
      let cwd =
        catalog.content(contentID)?.terminal?.workingDirectory
        ?? findWorktree(worktreeID: address.worktreeID, projectID: address.projectID, in: catalog)?.path
        ?? NSHomeDirectory()
      guard
        let created = try? hierarchyClient.splitPane(
          address.paneID, Self.splitDirection(for: direction),
          .terminal(workingDirectory: cwd), nil, nil
        )
      else { return .none }
      return bringUpAndFocus(created.contentID)

    case .closePane:
      // ghostty's `close_surface`: close the session the keybind fired in.
      // The manager retires the Pane when it was the last Tab and hands
      // focus to the neighbour.
      guard let address = hierarchyClient.addressOf(contentID) else { return .none }
      try? hierarchyClient.closeTab(address.tabID)
      return .none

    case .gotoSplit(let direction):
      guard let address = hierarchyClient.addressOf(contentID) else { return .none }
      _ = try? hierarchyClient.focusNeighbour(address.paneID, direction)
      return .none

    case .resizeSplit(let direction, let amount):
      guard let address = hierarchyClient.addressOf(contentID) else { return .none }
      try? hierarchyClient.resizePane(address.paneID, direction, amount)
      return .none

    case .equalizeSplits:
      guard let address = hierarchyClient.addressOf(contentID) else { return .none }
      try? hierarchyClient.equalizeSplits(address.worktreeID, address.projectID)
      return .none

    case .toggleSplitZoom:
      guard let address = hierarchyClient.addressOf(contentID) else { return .none }
      _ = try? hierarchyClient.toggleZoom(address.paneID)
      return .none

    case .presentTerminal:
      return .send(.delegate(.presentTerminalRequested(contentID)))

    case .toggleCommandPalette:
      return .send(.delegate(.commandPaletteToggleRequested(contentID)))

    case .openLink(let raw, let workingDirectory):
      return .send(.delegate(.openLinkRequested(contentID, raw: raw, workingDirectory: workingDirectory)))
    }
  }

  /// Spawns the session of a Tab the router just created and, once it is
  /// up, makes it the first responder. Matches ghostty's macOS controller
  /// (focus the new split). Dispatched async so the surface view has been
  /// attached to the hosting window by the time `makeFirstResponder` runs
  /// — at this moment the NSViewRepresentable update cycle hasn't finished.
  private func bringUpAndFocus(_ contentID: ContentID) -> Effect<Action> {
    .run { [client = hierarchyClient] _ in
      guard (try? await client.ensureSurface(contentID)) != nil else { return }
      await MainActor.run {
        client.focusSurfaceView(contentID)
      }
    }
  }

  // MARK: - Tab helpers

  private func gotoTab(from contentID: ContentID, target: GotoTabTarget) {
    guard let address = hierarchyClient.addressOf(contentID) else { return }
    let catalog = hierarchyClient.snapshot()
    guard let pane = catalog.pane(address.paneID), !pane.tabs.isEmpty,
      let currentIndex = pane.tabs.firstIndex(where: { $0.id == address.tabID })
    else { return }

    let count = pane.tabs.count
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
    try? hierarchyClient.selectTab(pane.tabs[targetIndex].id)
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

  // MARK: - Catalog lookups

  private func findWorktree(
    worktreeID: WorktreeID,
    projectID: ProjectID,
    in catalog: Catalog
  ) -> Worktree? {
    catalog.projects.first(where: { $0.id == projectID })?
      .worktrees.first(where: { $0.id == worktreeID })
  }
}
