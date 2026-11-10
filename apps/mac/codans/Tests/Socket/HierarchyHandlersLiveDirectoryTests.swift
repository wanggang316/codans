import Foundation
import Testing

@testable import Codans
@testable import CodansCore
@testable import CodansIPC

@MainActor
struct HierarchyHandlersLiveDirectoryTests {
  @Test
  func listPanesUsesLiveWorkingDirectoryWhenAvailable() async throws {
    let fixture = Self.makeFixture(liveDirectory: "/repo/app")
    let params = try JSONValue.encoded(
      HierarchyHandlers.ListPanesParams(
        tabID: fixture.tabID,
        worktreeID: fixture.worktreeID,
        projectID: fixture.projectID
      )
    )

    let outcome = await fixture.handlers.listPanes(params)
    let payload: ListPanesPayload = try Self.decodeUnary(outcome)

    #expect(payload.panes.map(\.workingDirectory) == ["/repo/app"])
  }

  @Test
  func listProjectsOverlaysLiveWorkingDirectoryInNestedPanes() async throws {
    let fixture = Self.makeFixture(liveDirectory: "/repo/packages/api")
    let outcome = await fixture.handlers.listProjects(.object([:]))
    let payload: ListProjectsPayload = try Self.decodeUnary(outcome)

    #expect(payload.projects.first?.worktrees.first?.tabs.first?.panes.first?.workingDirectory == "/repo/packages/api")
  }

  @Test
  func focusPanePromotesSurfaceView() async throws {
    let fixture = Self.makeFixture(liveDirectory: "/repo/app")
    let params = try JSONValue.encoded(
      HierarchyHandlers.PaneLocatorParams(
        id: fixture.paneID,
        tabID: fixture.tabID,
        worktreeID: fixture.worktreeID,
        projectID: fixture.projectID
      )
    )

    let outcome = await fixture.handlers.focusPane(params)
    guard case .unary = outcome else {
      Issue.record("expected unary response, got \(outcome)")
      return
    }

    #expect(fixture.runtime.focusSurfaceViewCalls.last == fixture.paneID)
    #expect(fixture.runtime.ensureSurfaceCalls.last?.paneID == fixture.paneID)
  }

  @Test
  func focusPaneInAnArchivedWorktreeFails() async throws {
    let fixture = Self.makeFixture(liveDirectory: "/repo/app", archived: true)
    let params = try JSONValue.encoded(
      HierarchyHandlers.PaneLocatorParams(
        id: fixture.paneID,
        tabID: fixture.tabID,
        worktreeID: fixture.worktreeID,
        projectID: fixture.projectID
      )
    )

    let outcome = await fixture.handlers.focusPane(params)
    guard case .failed = outcome else {
      Issue.record("expected failure, got \(outcome)")
      return
    }
    #expect(fixture.runtime.focusSurfaceViewCalls.isEmpty)
  }

  @Test
  func activateTabInAnArchivedWorktreeFails() async throws {
    let fixture = Self.makeFixture(liveDirectory: "/repo/app", archived: true)
    let params = try JSONValue.encoded(HierarchyHandlers.ActivateParams(id: fixture.tabID.raw))

    let outcome = await fixture.handlers.activateTab(params)
    guard case .failed = outcome else {
      Issue.record("expected failure, got \(outcome)")
      return
    }
  }

  private static func makeFixture(liveDirectory: String, archived: Bool = false) -> Fixture {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let tabID = TabID()
    let paneID = PaneID()
    let pane = Pane(id: paneID, workingDirectory: "/repo", initialCommand: nil)
    let tab = Tab(id: tabID, name: "Run", splitTree: SplitTree(leaf: paneID), panes: [pane])
    let worktree = Worktree(
      id: worktreeID,
      name: "main",
      path: "/repo",
      branch: "main",
      tabs: [tab],
      selectedTabID: tabID,
      archived: archived
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
    runtime.currentWorkingDirectories[paneID] = liveDirectory
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
      paneID: paneID
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
  }

  private enum TestError: Error {
    case unexpectedOutcome
  }
}
