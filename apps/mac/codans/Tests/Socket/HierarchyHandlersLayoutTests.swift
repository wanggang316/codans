import Foundation
import Testing

@testable import Codans
@testable import CodansCore
@testable import CodansIPC

/// The rename / prune / split / resize verbs go through the same manager
/// calls the sidebar and the keyboard use; these pin the wire contract
/// (`{id, name}`, `{pruned}`, the new pane id) and the error mapping.
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
          id: fixture.tab.id, worktreeID: fixture.worktree.id, projectID: fixture.project.id,
          name: "dev server")))
    let namedResult: HierarchyHandlers.RenameResult = try Self.decodeUnary(named)
    #expect(namedResult.name == "dev server")
    #expect(fixture.manager.catalog.projects[0].worktrees[0].tabs[0].name == "dev server")

    let cleared = await fixture.handlers.renameTab(
      try JSONValue.encoded(
        HierarchyHandlers.RenameTabParams(
          id: fixture.tab.id, worktreeID: fixture.worktree.id, projectID: fixture.project.id,
          name: "")))
    let clearedResult: HierarchyHandlers.RenameResult = try Self.decodeUnary(cleared)
    #expect(clearedResult.name == nil)
    #expect(fixture.manager.catalog.projects[0].worktrees[0].tabs[0].name == nil)

    let missing = await fixture.handlers.renameTab(
      try JSONValue.encoded(
        HierarchyHandlers.RenameTabParams(
          id: TabID(), worktreeID: fixture.worktree.id, projectID: fixture.project.id,
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
    fixture.runtime.currentWorkingDirectories[fixture.pane1.id] = "/repo/live"

    let outcome = await fixture.handlers.splitPane(
      try JSONValue.encoded(
        HierarchyHandlers.SplitPaneParams(
          paneID: fixture.pane1.id, tabID: fixture.tab.id, worktreeID: fixture.worktree.id,
          projectID: fixture.project.id, direction: .down, workingDirectory: nil,
          initialCommand: "htop", labels: ["monitor"])))
    let result: PaneIDPayload = try Self.decodeUnary(outcome)

    let tab = fixture.manager.catalog.projects[0].worktrees[0].tabs[0]
    #expect(tab.panes.count == 3)
    #expect(tab.splitTree.contains(result.id))
    let created = try #require(tab.panes.first(where: { $0.id == result.id }))
    #expect(created.workingDirectory == "/repo/live")
    #expect(created.initialCommand == "htop")
    #expect(created.labels == ["monitor"])
    let call = try #require(fixture.runtime.ensureSurfaceCalls.last)
    #expect(call.paneID == result.id)
    #expect(call.env["CODANS_TEST_MARK"] == "from-provider")
  }

  @Test
  func splitPaneHonoursAnExplicitDirectoryAndRejectsUnknownAnchors() async throws {
    let fixture = Fixture()

    let outcome = await fixture.handlers.splitPane(
      try JSONValue.encoded(
        HierarchyHandlers.SplitPaneParams(
          paneID: fixture.pane2.id, tabID: fixture.tab.id, worktreeID: fixture.worktree.id,
          projectID: fixture.project.id, direction: .right, workingDirectory: "/elsewhere",
          initialCommand: nil, labels: nil)))
    let result: PaneIDPayload = try Self.decodeUnary(outcome)
    let created = fixture.manager.catalog.projects[0].worktrees[0].tabs[0].panes
      .first(where: { $0.id == result.id })
    #expect(created?.workingDirectory == "/elsewhere")

    let missing = await fixture.handlers.splitPane(
      try JSONValue.encoded(
        HierarchyHandlers.SplitPaneParams(
          paneID: PaneID(), tabID: fixture.tab.id, worktreeID: fixture.worktree.id,
          projectID: fixture.project.id, direction: .right, workingDirectory: nil,
          initialCommand: nil, labels: nil)))
    guard case .failed(.notFound(let kind, _)) = missing else {
      Issue.record("expected .notFound, got \(missing)")
      return
    }
    #expect(kind == "pane")
  }

  // MARK: - Resize

  @Test
  func resizePaneMovesTheNearestDividerByTheScaledAmount() async throws {
    let fixture = Fixture()

    // pane2 is the right child of a horizontal split at 0.5; growing it to
    // the right adds 40 / 400 to the ratio.
    let outcome = await fixture.handlers.resizePane(
      try JSONValue.encoded(
        HierarchyHandlers.ResizePaneParams(paneID: fixture.pane2.id, direction: .right, amount: 40)))
    guard case .unary = outcome else {
      Issue.record("expected unary success, got \(outcome)")
      return
    }
    let tree = fixture.manager.catalog.projects[0].worktrees[0].tabs[0].splitTree
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
        HierarchyHandlers.ResizePaneParams(paneID: PaneID(), direction: .left, amount: nil)))
    guard case .failed(.notFound(let kind, _)) = missing else {
      Issue.record("expected .notFound, got \(missing)")
      return
    }
    #expect(kind == "pane")

    let zero = await fixture.handlers.resizePane(
      try JSONValue.encoded(
        HierarchyHandlers.ResizePaneParams(paneID: fixture.pane1.id, direction: .left, amount: 0)))
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
  }

  /// One git project, one worktree, one tab with two panes side by side.
  @MainActor
  private struct Fixture {
    let runtime = FakeHierarchyRuntime()
    let manager: HierarchyManager
    let handlers: HierarchyHandlers
    let project: Project
    let worktree: Worktree
    let tab: Tab
    let pane1: Pane
    let pane2: Pane

    init(
      gitRoot: String? = "/repo",
      env: [String: String] = [:],
      reconcileWorktrees: @escaping @MainActor (ProjectID) async -> Void = { _ in },
      worktreePruner: (@MainActor @Sendable (URL) async throws -> Int)? = nil
    ) {
      let pane1 = Pane(workingDirectory: "/repo")
      let pane2 = Pane(workingDirectory: "/repo")
      // swiftlint:disable:next force_try
      let splitTree = try! SplitTree(leaf: pane1.id).inserting(pane2.id, at: pane1.id, direction: .right)
      let tab = Tab(splitTree: splitTree, panes: [pane1, pane2])
      let worktree = Worktree(name: "main", path: "/repo", branch: "main", tabs: [tab])
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
        reconcileWorktrees: reconcileWorktrees,
        worktreePruner: worktreePruner
      )
      self.project = project
      self.worktree = worktree
      self.tab = tab
      self.pane1 = pane1
      self.pane2 = pane2
    }
  }

  private enum TestError: Error {
    case unexpectedOutcome
  }
}
