import Foundation
import Testing

@testable import Codans
@testable import CodansCore
@testable import CodansIPC

/// A pane opened over IPC must start with the same environment the sidebar's
/// new-pane paths resolve — the project's `envVars` plus the always-on keys
/// (socket, `CODANS_CLI`, the `TERM_PROGRAM` marker). The handler used to
/// call the manager without an env, so CLI-spawned panes inherited the bare
/// app environment.
@MainActor
struct HierarchyHandlersOpenPaneEnvTests {
  @Test
  func openPaneHandsTheResolvedProjectEnvToTheSurface() async throws {
    let runtime = FakeHierarchyRuntime()
    let tab = Tab(name: "dev")
    let worktree = Worktree(name: "main", path: "/repo", branch: "main", tabs: [tab])
    let project = Project(name: "repo", rootPath: "/repo", gitRoot: "/repo", worktrees: [worktree])
    let manager = HierarchyManager(
      catalog: Catalog(projects: [project]),
      store: CatalogStore(
        fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
          .appendingPathComponent("codans-open-pane-env-\(UUID().uuidString).json")
      ),
      runtime: runtime
    )
    let handlers = HierarchyHandlers(
      manager: manager,
      envProvider: { projectID in
        #expect(projectID == project.id)
        return ["CODANS_TEST_MARK": "from-provider"]
      }
    )
    let params = try JSONValue.encoded(
      HierarchyHandlers.OpenPaneParams(
        projectID: project.id,
        worktreeID: worktree.id,
        tabID: tab.id,
        workingDirectory: "/repo",
        initialCommand: nil,
        labels: []
      )
    )

    let outcome = await handlers.openPane(params)

    guard case .unary = outcome else {
      Issue.record("expected unary success, got \(outcome)")
      return
    }
    let call = try #require(runtime.ensureSurfaceCalls.last)
    #expect(call.env["CODANS_TEST_MARK"] == "from-provider")
  }
}
