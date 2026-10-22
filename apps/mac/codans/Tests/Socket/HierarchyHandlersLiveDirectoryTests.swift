import Foundation
import Testing

@testable import Codans
@testable import CodansCore
@testable import CodansIPC

@MainActor
struct HierarchyHandlersLiveDirectoryTests {
  @Test
  func listTabsUsesLiveWorkingDirectoryWhenAvailable() async throws {
    let fixture = Self.makeFixture(liveDirectory: "/repo/app")
    let params = try JSONValue.encoded(
      HierarchyHandlers.ListTabsParams(
        worktreeID: fixture.worktreeID,
        projectID: fixture.projectID,
        paneID: fixture.paneID.raw
      )
    )

    let outcome = await fixture.handlers.listTabs(params)
    let payload: ListTabsPayload = try Self.decodeUnary(outcome)

    #expect(payload.tabs.map(\.workingDirectory) == ["/repo/app"])
    #expect(payload.tabs.map(\.paneID) == [fixture.paneID.description])
  }

  @Test
  func listProjectsOverlaysLiveWorkingDirectoryInNestedPanes() async throws {
    let fixture = Self.makeFixture(liveDirectory: "/repo/packages/api")
    let outcome = await fixture.handlers.listProjects(.object([:]))
    let payload: ListProjectsPayload = try Self.decodeUnary(outcome)

    let directory = payload.projects.first?.worktrees.first?.panes.first?.tabs.first?
      .content.terminal?.workingDirectory
    #expect(directory == "/repo/packages/api")
  }

  @Test
  func focusPanePromotesSurfaceView() async throws {
    let fixture = Self.makeFixture(liveDirectory: "/repo/app")
    let params = try JSONValue.encoded(
      HierarchyHandlers.FocusPaneParams(id: fixture.paneID, projectID: nil, worktreeID: nil, direction: nil)
    )

    let outcome = await fixture.handlers.focusPane(params)
    guard case .unary = outcome else {
      Issue.record("expected unary response, got \(outcome)")
      return
    }

    #expect(fixture.runtime.focusSurfaceViewCalls.last == fixture.contentID)
    #expect(fixture.runtime.ensureSurfaceCalls.last?.contentID == fixture.contentID)
  }

  private static func makeFixture(liveDirectory: String) -> Fixture {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let tabID = TabID()
    let paneID = PaneID()
    let contentID = ContentID()
    let tab = Tab(id: tabID, name: "Run", content: .terminal(id: contentID, workingDirectory: "/repo"))
    let pane = Pane(id: paneID, tabs: [tab])
    let worktree = Worktree(
      id: worktreeID,
      name: "main",
      path: "/repo",
      branch: "main",
      splitTree: SplitTree(leaf: paneID),
      panes: [pane],
      focusedPaneID: paneID
    )
    let project = Project(
      id: projectID,
      name: "repo",
      rootPath: "/repo",
      gitRoot: "/repo",
      worktrees: [worktree],
      selectedWorktreeID: worktreeID
    )
    let runtime = FakeHierarchyRuntime()
    runtime.currentWorkingDirectories[contentID] = liveDirectory
    let manager = HierarchyManager(
      catalog: Catalog(projects: [project]),
      store: CatalogStore(fileURL: Self.tempURL()),
      runtime: runtime
    )
    return Fixture(
      handlers: HierarchyHandlers(manager: manager),
      runtime: runtime,
      projectID: projectID,
      worktreeID: worktreeID,
      tabID: tabID,
      paneID: paneID,
      contentID: contentID
    )
  }

  private static func decodeUnary<T: Decodable>(_ outcome: RouterOutcome) throws -> T {
    guard case .unary(let value) = outcome else {
      Issue.record("expected unary response, got \(outcome)")
      throw TestError.unexpectedOutcome
    }
    return try value.decoded(as: T.self)
  }

  private static func tempURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("codans-hierarchy-handler-tests-\(UUID().uuidString).json")
  }

  private struct Fixture {
    let handlers: HierarchyHandlers
    let runtime: FakeHierarchyRuntime
    let projectID: ProjectID
    let worktreeID: WorktreeID
    let tabID: TabID
    let paneID: PaneID
    let contentID: ContentID
  }

  private enum TestError: Error {
    case unexpectedOutcome
  }
}
