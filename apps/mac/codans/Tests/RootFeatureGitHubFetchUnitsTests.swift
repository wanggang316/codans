import CodansCore
import Foundation
import Testing

@testable import Codans

/// How `RootFeature` splits a Project into batched GitHub fetches: one per
/// repository its rows belong to. A git Project is one unit under its own
/// id; a workspace is one unit per member repository under a derived,
/// stable group id.
struct RootFeatureGitHubFetchUnitsTests {
  @Test
  func gitProjectIsOneUnitUnderItsOwnID() {
    let main = Worktree(name: "main", path: "/src/app", branch: "main")
    let feature = Worktree(name: "feat", path: "/src/app-feat", branch: "feat")
    let archived = Worktree(name: "old", path: "/src/app-old", branch: "old", archived: true)
    let project = Project(
      name: "app", rootPath: "/src/app", gitRoot: "/src/app", worktrees: [main, feature, archived])
    let units = RootFeature.gitHubFetchUnits(in: project)
    #expect(units.count == 1)
    #expect(units[0].projectID == project.id)
    #expect(units[0].gitRoot.path == "/src/app")
    #expect(units[0].pairs.map(\.worktreeID) == [main.id, feature.id])
  }

  @Test
  func workspaceIsOneUnitPerMemberRepositoryWithStableGroupIDs() {
    let root = Worktree(name: "ws", path: "/tmp/ws")
    let app = Worktree(name: "app", path: "/tmp/ws/app", branch: "feat", sourceGitRoot: "/src/app")
    let api = Worktree(name: "api", path: "/tmp/ws/api", branch: "feat", sourceGitRoot: "/src/api")
    let appDocs = Worktree(name: "docs", path: "/tmp/ws/docs", branch: "docs", sourceGitRoot: "/src/app")
    let project = Project(
      name: "ws", rootPath: "/tmp/ws", worktrees: [root, app, api, appDocs], isWorkspace: true)

    let units = RootFeature.gitHubFetchUnits(in: project)
    #expect(units.count == 2)
    #expect(units[0].gitRoot.path == "/src/app")
    #expect(units[0].pairs.map(\.worktreeID) == [app.id, appDocs.id])
    #expect(units[1].gitRoot.path == "/src/api")
    #expect(units[1].pairs.map(\.worktreeID) == [api.id])
    // Group ids are distinct from each other and from the workspace, and
    // deterministic so the on-disk cache re-seeds the same group.
    #expect(units[0].projectID != units[1].projectID)
    #expect(units[0].projectID != project.id)
    #expect(
      units[0].projectID == RootFeature.workspaceFetchGroupID(workspace: project.id, gitRoot: "/src/app"))
    #expect(RootFeature.gitHubFetchUnits(in: project).map(\.projectID) == units.map(\.projectID))

    // The unit for a row, with a fallback for the root row.
    #expect(RootFeature.gitHubFetchUnit(in: project, worktreeID: api.id, fallback: nil)?.gitRoot.path == "/src/api")
    #expect(RootFeature.gitHubFetchUnit(in: project, worktreeID: root.id, fallback: units[0])?.gitRoot.path == "/src/app")
    #expect(RootFeature.gitHubFetchUnit(in: project, worktreeID: nil, fallback: nil) == nil)
  }

  @Test
  func projectsWithoutARepositoryYieldNoUnits() {
    let dir = Project(name: "d", rootPath: "/tmp/d", worktrees: [Worktree(name: "d", path: "/tmp/d")])
    #expect(RootFeature.gitHubFetchUnits(in: dir).isEmpty)
    let emptyWorkspace = Project(
      name: "ws", rootPath: "/tmp/ws", worktrees: [Worktree(name: "ws", path: "/tmp/ws")], isWorkspace: true)
    #expect(RootFeature.gitHubFetchUnits(in: emptyWorkspace).isEmpty)
  }
}
