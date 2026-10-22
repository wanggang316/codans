import Foundation
import Testing

@testable import Codans
@testable import CodansCore
@testable import CodansIPC

/// The rename / prune / split / resize verbs go through the same manager
/// calls the sidebar and the keyboard use; these pin the wire contract
/// (`{id, name}`, `{pruned}`, the new session id) and the error mapping.
@MainActor
struct HierarchyHandlersLayoutTests {
  // MARK: - Renames

  @Test
  func renameProjectSetsAndClearsTheOverride() async throws {
    let fixture = Fixture()
    let handlers = fixture.handlers

    let renamed = await handlers.renameProject(
      try JSONValue.encoded(
        HierarchyHandlers.RenameProjectParams(id: fixture.project.id, name: "API")))
    let result: HierarchyHandlers.RenameResult = try Self.decodeUnary(renamed)
    #expect(result.name == "API")
    #expect(fixture.manager.catalog.projects[0].name == "API")

    let cleared = await handlers.renameProject(
      try JSONValue.encoded(
        HierarchyHandlers.RenameProjectParams(id: fixture.project.id, name: "  ")))
    let clearedResult: HierarchyHandlers.RenameResult = try Self.decodeUnary(cleared)
    #expect(clearedResult.name == "repo")
    #expect(fixture.manager.catalog.projects[0].displayName == nil)
  }

  @Test
  func renameWorktreeChangesTheLabelOnlyAndRefusesBlank() async throws {
    let fixture = Fixture()

    let outcome = await fixture.handlers.renameWorktree(
      try JSONValue.encoded(
        HierarchyHandlers.RenameWorktreeParams(
          id: fixture.worktree.id, projectID: fixture.project.id, name: " Hotfix ")))
    let result: HierarchyHandlers.RenameResult = try Self.decodeUnary(outcome)
    #expect(result.name == "Hotfix")
    let worktree = fixture.manager.catalog.projects[0].worktrees[0]
    #expect(worktree.name == "Hotfix")
    #expect(worktree.branch == "main")
    #expect(worktree.path == "/repo")

    let blank = await fixture.handlers.renameWorktree(
      try JSONValue.encoded(
        HierarchyHandlers.RenameWorktreeParams(
          id: fixture.worktree.id, projectID: fixture.project.id, name: "")))
    guard case .failed(.invalidParams) = blank else {
      Issue.record("expected .invalidParams, got \(blank)")
      return
    }
  }

  @Test
  func renameTabSetsAndClearsTheUserTitle() async throws {
    let fixture = Fixture()

    let named = await fixture.handlers.renameTab(
      try JSONValue.encoded(
        HierarchyHandlers.RenameTabParams(
          id: fixture.tab1.id,
          name: "dev server")))
    let namedResult: HierarchyHandlers.RenameResult = try Self.decodeUnary(named)
    #expect(namedResult.name == "dev server")
    #expect(fixture.manager.catalog.tab(fixture.tab1.id)?.name == "dev server")

    let cleared = await fixture.handlers.renameTab(
      try JSONValue.encoded(
        HierarchyHandlers.RenameTabParams(
          id: fixture.tab1.id,
          name: "")))
    let clearedResult: HierarchyHandlers.RenameResult = try Self.decodeUnary(cleared)
    #expect(clearedResult.name == nil)
    #expect(fixture.manager.catalog.tab(fixture.tab1.id)?.name == nil)

    let missing = await fixture.handlers.renameTab(
      try JSONValue.encoded(
        HierarchyHandlers.RenameTabParams(
          id: TabID(),
          name: "x")))
    guard case .failed(.notFound(let kind, _)) = missing else {
      Issue.record("expected .notFound, got \(missing)")
      return
    }
    #expect(kind == "tab")
  }

  // MARK: - Prune

  @Test
  func pruneRunsGitOnTheRepoRootAndReconciles() async throws {
    let calls = CallBox()
    let fixture = Fixture(
      reconcileWorktrees: { calls.reconciled.append($0) },
      worktreePruner: { @MainActor @Sendable root in
        calls.prunedRoots.append(root.path)
        return 2
      })

    let outcome = await fixture.handlers.pruneWorktrees(
      try JSONValue.encoded(HierarchyHandlers.PruneWorktreesParams(projectID: fixture.project.id)))
    let result: HierarchyHandlers.PruneWorktreesResult = try Self.decodeUnary(outcome)

    #expect(result.pruned == 2)
    #expect(calls.prunedRoots == ["/repo"])
    #expect(calls.reconciled == [fixture.project.id])
  }

  @Test
  func pruneRefusesFolderProjectsAndBuildsWithoutGit() async throws {
    let withoutGit = Fixture()
    let unsupported = await withoutGit.handlers.pruneWorktrees(
      try JSONValue.encoded(
        HierarchyHandlers.PruneWorktreesParams(projectID: withoutGit.project.id)))
    guard case .failed(.unsupported) = unsupported else {
      Issue.record("expected .unsupported without a pruner, got \(unsupported)")
      return
    }

    let folder = Fixture(gitRoot: nil, worktreePruner: { @MainActor @Sendable _ in 0 })
    let invalid = await folder.handlers.pruneWorktrees(
      try JSONValue.encoded(HierarchyHandlers.PruneWorktreesParams(projectID: folder.project.id)))
    guard case .failed(.invalidParams) = invalid else {
      Issue.record("expected .invalidParams for a folder project, got \(invalid)")
      return
    }
  }

  @Test
  func pruneMapsGitFailuresLikeCreateDoes() async throws {
    let fixture = Fixture(worktreePruner: { @MainActor @Sendable _ in
      throw GitWorktreeError.commandFailed(command: "wt prune", stderr: "boom")
    })

    let outcome = await fixture.handlers.pruneWorktrees(
      try JSONValue.encoded(HierarchyHandlers.PruneWorktreesParams(projectID: fixture.project.id)))

    guard case .failed(.internal(let message)) = outcome else {
      Issue.record("expected .internal, got \(outcome)")
      return
    }
    #expect(message.contains("boom"))
  }

  // MARK: - Split

  @Test
  func splitPaneAddsBesideTheAnchorWithTheProjectEnvAndLiveDirectory() async throws {
    let fixture = Fixture(env: ["CODANS_TEST_MARK": "from-provider"])
    fixture.runtime.currentWorkingDirectories[fixture.content1] = "/repo/live"

    let outcome = await fixture.handlers.splitPane(
      try JSONValue.encoded(
        HierarchyHandlers.SplitPaneParams(
          paneID: fixture.pane1.id.raw, direction: .down, workingDirectory: nil,
          initialCommand: "htop", labels: ["monitor"])))
    let result: HierarchyHandlers.SplitResult = try Self.decodeUnary(outcome)

    let worktree = fixture.manager.catalog.projects[0].worktrees[0]
    #expect(worktree.panes.count == 3)
    let createdPane = try #require(worktree.pane(result.paneID))
    #expect(createdPane.tabIDs == [result.tabID])
    #expect(createdPane.selectedTab?.contentID == result.contentID)
    #expect(worktree.splitTree.contains(createdPane.id))
    #expect(worktree.focusedPaneID == createdPane.id)
    let created = try #require(worktree.tab(result.tabID)?.content.terminal)
    #expect(created.workingDirectory == "/repo/live")
    #expect(created.initialCommand == "htop")
    #expect(created.labels == ["monitor"])
    let call = try #require(fixture.runtime.ensureSurfaceCalls.last)
    #expect(call.contentID == result.contentID)
    #expect(call.env["CODANS_TEST_MARK"] == "from-provider")
  }

  @Test
  func splitPaneHonoursAnExplicitDirectoryAndRejectsUnknownAnchors() async throws {
    let fixture = Fixture()

    // The anchor may be named by its session id; the split lands beside
    // the Pane holding it.
    let outcome = await fixture.handlers.splitPane(
      try JSONValue.encoded(
        HierarchyHandlers.SplitPaneParams(
          paneID: fixture.content2.raw, direction: .right, workingDirectory: "/elsewhere",
          initialCommand: nil, labels: nil)))
    let result: HierarchyHandlers.SplitResult = try Self.decodeUnary(outcome)
    let worktree = fixture.manager.catalog.projects[0].worktrees[0]
    let created = worktree.tab(result.tabID)?.content.terminal
    #expect(created?.workingDirectory == "/elsewhere")
    #expect(worktree.splitTree.focusTarget(spatial: .left, from: result.paneID) == fixture.pane2.id)

    let missing = await fixture.handlers.splitPane(
      try JSONValue.encoded(
        HierarchyHandlers.SplitPaneParams(
          paneID: PaneID().raw, direction: .right, workingDirectory: nil, initialCommand: nil, labels: nil)))
    guard case .failed(.notFound(let kind, _)) = missing else {
      Issue.record("expected .notFound, got \(missing)")
      return
    }
    #expect(kind == "pane")
  }

  // MARK: - New Tab

  /// `tab new --pane` opens on that Pane's strip (named here by a Tab id);
  /// without one the focused Pane takes it. The answer carries all three
  /// ids and the `t<n>` handle.
  @Test
  func createTabOpensInTheNamedOrFocusedPane() async throws {
    let fixture = Fixture()

    let focused = await fixture.handlers.createTab(
      try JSONValue.encoded(
        HierarchyHandlers.CreateTabParams(
          projectID: fixture.project.id, worktreeID: fixture.worktree.id, paneID: nil, name: nil,
          workingDirectory: NSTemporaryDirectory(), initialCommand: nil, labels: nil)))
    let inFocused: HierarchyHandlers.CreatedTab = try Self.decodeUnary(focused)
    #expect(inFocused.paneID == fixture.pane1.id)
    #expect(inFocused.handle?.hasPrefix("t") == true)

    // The directory must exist: the handler refuses a Tab in a missing one.
    let named = await fixture.handlers.createTab(
      try JSONValue.encoded(
        HierarchyHandlers.CreateTabParams(
          projectID: fixture.project.id, worktreeID: fixture.worktree.id, paneID: fixture.tab2.id.raw,
          name: "logs", workingDirectory: NSTemporaryDirectory(), initialCommand: nil, labels: ["tail"])))
    let created: HierarchyHandlers.CreatedTab = try Self.decodeUnary(named)
    #expect(created.paneID == fixture.pane2.id)
    let pane2 = try #require(fixture.manager.catalog.pane(fixture.pane2.id))
    #expect(pane2.tabIDs == [fixture.tab2.id, created.id])
    #expect(pane2.tab(created.id)?.contentID == created.contentID)
    #expect(pane2.tab(created.id)?.name == "logs")
    #expect(pane2.tab(created.id)?.content.terminal?.labels == ["tail"])
  }

  // MARK: - Zoom / equalize

  @Test
  func zoomPaneTogglesTheZoomAndUnzoomOnlyLeavesIt() async throws {
    let fixture = Fixture()
    let params = try JSONValue.encoded(HierarchyHandlers.ZoomPaneParams(id: fixture.pane2.id.raw))

    let zoomed: HierarchyHandlers.ZoomResult = try Self.decodeUnary(await fixture.handlers.zoomPane(params))
    #expect(zoomed.paneID == fixture.pane2.id)
    #expect(zoomed.zoomed)
    var worktree = fixture.manager.catalog.projects[0].worktrees[0]
    #expect(worktree.splitTree.zoomed == fixture.pane2.id)
    #expect(worktree.focusedPaneID == fixture.pane2.id)

    let toggledBack: HierarchyHandlers.ZoomResult = try Self.decodeUnary(await fixture.handlers.zoomPane(params))
    #expect(!toggledBack.zoomed)
    worktree = fixture.manager.catalog.projects[0].worktrees[0]
    #expect(worktree.splitTree.zoomed == nil)

    // `unzoom` on a Pane that is not zoomed changes nothing.
    let unzoomed: HierarchyHandlers.ZoomResult = try Self.decodeUnary(await fixture.handlers.unzoomPane(params))
    #expect(!unzoomed.zoomed)
    #expect(fixture.manager.catalog.projects[0].worktrees[0].splitTree.zoomed == nil)
  }

  /// A Tab id names the Pane holding it, as every Pane position does.
  @Test
  func zoomPaneAcceptsATabId() async throws {
    let fixture = Fixture()
    let outcome = await fixture.handlers.zoomPane(
      try JSONValue.encoded(HierarchyHandlers.ZoomPaneParams(id: fixture.tab1.id.raw)))
    let result: HierarchyHandlers.ZoomResult = try Self.decodeUnary(outcome)
    #expect(result.paneID == fixture.pane1.id)
    #expect(fixture.manager.catalog.projects[0].worktrees[0].splitTree.zoomed == fixture.pane1.id)
  }

  @Test
  func equalizePanesResetsEveryDivider() async throws {
    let fixture = Fixture()
    _ = await fixture.handlers.resizePane(
      try JSONValue.encoded(
        HierarchyHandlers.ResizePaneParams(paneID: fixture.pane2.id.raw, direction: .right, amount: 80)))

    let outcome = await fixture.handlers.equalizePanes(
      try JSONValue.encoded(
        HierarchyHandlers.EqualizePanesParams(projectID: fixture.project.id, worktreeID: fixture.worktree.id)))
    guard case .unary = outcome else {
      Issue.record("expected unary success, got \(outcome)")
      return
    }
    guard case .split(let split)? = fixture.manager.catalog.projects[0].worktrees[0].splitTree.root else {
      Issue.record("expected a split root")
      return
    }
    #expect(abs(split.ratio - 0.5) < 0.0001)
  }

  // MARK: - Close

  @Test
  func closePaneClosesEveryTabAndKillsEachSession() async throws {
    let calls = CallBox()
    let fixture = Fixture(daemonKiller: { calls.killed.append($0) })
    let extra = try fixture.manager.newTab(
      in: fixture.pane2.id, worktreeID: fixture.worktree.id, projectID: fixture.project.id,
      content: .terminal(workingDirectory: "/repo"))

    let outcome = await fixture.handlers.closePane(
      try JSONValue.encoded(HierarchyHandlers.ClosePaneParams(id: fixture.pane2.id.raw)))
    let result: HierarchyHandlers.ClosedPane = try Self.decodeUnary(outcome)

    #expect(result.id == fixture.pane2.id)
    #expect(result.tabIDs == [fixture.tab2.id, extra.tabID])
    #expect(calls.killed == [fixture.content2, extra.contentID])
    let worktree = fixture.manager.catalog.projects[0].worktrees[0]
    #expect(worktree.panes.map(\.id) == [fixture.pane1.id])
    #expect(!worktree.splitTree.contains(fixture.pane2.id))
  }

  /// `pane close` must not widen one session to its whole Pane: a Tab or
  /// Content id is refused with a message naming `tab close`.
  @Test
  func closePaneRefusesATabOrContentIdAndNamesTabClose() async throws {
    let calls = CallBox()
    let fixture = Fixture(daemonKiller: { calls.killed.append($0) })

    for id in [fixture.tab2.id.raw, fixture.content2.raw] {
      let outcome = await fixture.handlers.closePane(
        try JSONValue.encoded(HierarchyHandlers.ClosePaneParams(id: id)))
      guard case .failed(.invalidParams(let message, _)) = outcome else {
        Issue.record("expected .invalidParams, got \(outcome)")
        continue
      }
      #expect(message.contains("tab close"))
    }
    #expect(calls.killed.isEmpty)
    #expect(fixture.manager.catalog.projects[0].worktrees[0].panes.count == 2)

    let missing = await fixture.handlers.closePane(
      try JSONValue.encoded(HierarchyHandlers.ClosePaneParams(id: UUID())))
    guard case .failed(.notFound(let kind, _)) = missing else {
      Issue.record("expected .notFound, got \(missing)")
      return
    }
    #expect(kind == "pane")
  }

  @Test
  func closeTabKillsItsSessionAndTheLastTabTakesThePane() async throws {
    let calls = CallBox()
    let fixture = Fixture(daemonKiller: { calls.killed.append($0) })

    let outcome = await fixture.handlers.closeTab(
      try JSONValue.encoded(HierarchyHandlers.CloseTabParams(id: fixture.tab2.id)))
    let result: HierarchyHandlers.ClosedTab = try Self.decodeUnary(outcome)

    #expect(result.id == fixture.tab2.id)
    #expect(result.contentID == fixture.content2)
    #expect(calls.killed == [fixture.content2])
    #expect(fixture.manager.catalog.projects[0].worktrees[0].panes.map(\.id) == [fixture.pane1.id])
  }

  // MARK: - Focus

  @Test
  func focusPaneByIdOrByDirection() async throws {
    let fixture = Fixture()

    let byID = await fixture.handlers.focusPane(
      try JSONValue.encoded(
        HierarchyHandlers.FocusPaneParams(id: fixture.pane2.id, projectID: nil, worktreeID: nil, direction: nil)))
    let focused: HierarchyHandlers.FocusedPane = try Self.decodeUnary(byID)
    #expect(focused.paneID == fixture.pane2.id)
    #expect(fixture.manager.catalog.projects[0].worktrees[0].focusedPaneID == fixture.pane2.id)

    // From the Worktree's focused Pane (pane2), left reaches pane1; at the
    // left edge nothing moves.
    let params = HierarchyHandlers.FocusPaneParams(
      id: nil, projectID: fixture.project.id, worktreeID: fixture.worktree.id, direction: .left)
    let moved: HierarchyHandlers.FocusedPane = try Self.decodeUnary(
      await fixture.handlers.focusPane(try JSONValue.encoded(params)))
    #expect(moved.paneID == fixture.pane1.id)
    #expect(moved.moved)
    let edge: HierarchyHandlers.FocusedPane = try Self.decodeUnary(
      await fixture.handlers.focusPane(try JSONValue.encoded(params)))
    #expect(edge.paneID == fixture.pane1.id)
    #expect(!edge.moved)
    #expect(fixture.manager.catalog.projects[0].worktrees[0].focusedPaneID == fixture.pane1.id)
  }

  // MARK: - Resize

  @Test
  func resizePaneMovesTheNearestDividerByTheScaledAmount() async throws {
    let fixture = Fixture()

    // pane2 is the right child of a horizontal split at 0.5; growing it to
    // the right adds 40 / 400 to the ratio.
    let outcome = await fixture.handlers.resizePane(
      try JSONValue.encoded(
        HierarchyHandlers.ResizePaneParams(paneID: fixture.pane2.id.raw, direction: .right, amount: 40)))
    guard case .unary = outcome else {
      Issue.record("expected unary success, got \(outcome)")
      return
    }
    let tree = fixture.manager.catalog.projects[0].worktrees[0].splitTree
    guard case .split(let split)? = tree.root else {
      Issue.record("expected a split root, got \(String(describing: tree.root))")
      return
    }
    #expect(abs(split.ratio - 0.6) < 0.0001)
  }

  @Test
  func resizePaneRejectsUnknownPanesAndNonPositiveAmounts() async throws {
    let fixture = Fixture()

    let missing = await fixture.handlers.resizePane(
      try JSONValue.encoded(
        HierarchyHandlers.ResizePaneParams(paneID: PaneID().raw, direction: .left, amount: nil)))
    guard case .failed(.notFound(let kind, _)) = missing else {
      Issue.record("expected .notFound, got \(missing)")
      return
    }
    #expect(kind == "pane")

    let zero = await fixture.handlers.resizePane(
      try JSONValue.encoded(
        HierarchyHandlers.ResizePaneParams(paneID: fixture.pane1.id.raw, direction: .left, amount: 0)))
    guard case .failed(.invalidParams) = zero else {
      Issue.record("expected .invalidParams, got \(zero)")
      return
    }
  }

  // MARK: - Support

  private static func decodeUnary<T: Decodable>(_ outcome: RouterOutcome) throws -> T {
    guard case .unary(let value) = outcome else {
      Issue.record("expected unary response, got \(outcome)")
      throw TestError.unexpectedOutcome
    }
    return try value.decoded(as: T.self)
  }

  @MainActor
  private final class CallBox {
    var prunedRoots: [String] = []
    var reconciled: [ProjectID] = []
    var killed: [ContentID] = []
  }

  /// One git project, one worktree, two Panes side by side with one Tab
  /// each.
  @MainActor
  private struct Fixture {
    let runtime = FakeHierarchyRuntime()
    let manager: HierarchyManager
    let handlers: HierarchyHandlers
    let project: Project
    let worktree: Worktree
    let tab1: Tab
    let tab2: Tab
    let pane1: Pane
    let pane2: Pane
    var content1: ContentID { tab1.contentID }
    var content2: ContentID { tab2.contentID }

    init(
      gitRoot: String? = "/repo",
      env: [String: String] = [:],
      reconcileWorktrees: @escaping @MainActor (ProjectID) async -> Void = { _ in },
      worktreePruner: (@MainActor @Sendable (URL) async throws -> Int)? = nil,
      daemonKiller: @escaping @MainActor (ContentID) async -> Void = { _ in }
    ) {
      let tab1 = Tab(content: .terminal(workingDirectory: "/repo"))
      let tab2 = Tab(content: .terminal(workingDirectory: "/repo"))
      let pane1 = Pane(tabs: [tab1])
      let pane2 = Pane(tabs: [tab2])
      // swiftlint:disable:next force_try
      let splitTree = try! SplitTree(leaf: pane1.id).inserting(pane2.id, at: pane1.id, direction: .right)
      let worktree = Worktree(
        name: "main", path: "/repo", branch: "main",
        splitTree: splitTree, panes: [pane1, pane2], focusedPaneID: pane1.id)
      let project = Project(name: "repo", rootPath: "/repo", gitRoot: gitRoot, worktrees: [worktree])
      let manager = HierarchyManager(
        catalog: Catalog(projects: [project]),
        store: CatalogStore(
          fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codans-layout-\(UUID().uuidString).json")
        ),
        runtime: runtime
      )
      self.manager = manager
      self.handlers = HierarchyHandlers(
        manager: manager,
        envProvider: { _ in env },
        daemonKiller: daemonKiller,
        reconcileWorktrees: reconcileWorktrees,
        worktreePruner: worktreePruner
      )
      self.project = project
      self.worktree = worktree
      self.tab1 = tab1
      self.tab2 = tab2
      self.pane1 = pane1
      self.pane2 = pane2
    }
  }

  private enum TestError: Error {
    case unexpectedOutcome
  }
}
