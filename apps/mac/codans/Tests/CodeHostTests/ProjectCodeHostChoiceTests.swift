import CodansCore
import Foundation
import Testing

@testable import Codans

/// Which Project's "Code Host" choice applies to a fetch unit (ADR 0004 items 10, 16).
struct ProjectCodeHostChoiceTests {
  private let app = Project(name: "app", rootPath: "/repos/app", gitRoot: "/repos/app")
  private let api = Project(name: "api", rootPath: "/repos/api", gitRoot: "/repos/api")
  private let workspace = Project(name: "ws", rootPath: "/ws", isWorkspace: true)

  private var settings: Settings {
    var settings = Settings.default
    settings.projects[app.id] = ProjectSettings(git: GitProjectSettings(codeHost: .gitlab))
    return settings
  }

  @Test
  func aGitProjectUnitUsesItsOwnChoice() {
    let catalog = Catalog(projects: [app, api, workspace])
    #expect(choice(unit: app.id, root: "/repos/app", catalog) == .gitlab)
    #expect(choice(unit: api.id, root: "/repos/api", catalog) == nil)
  }

  /// A Workspace member uses the choice of the registered Project of its repository, so
  /// one Workspace can mix Code Hosts.
  @Test
  func aWorkspaceUnitUsesTheChoiceOfTheProjectOfItsRepository() {
    let catalog = Catalog(projects: [app, api, workspace])
    let appUnit = RootFeature.workspaceFetchGroupID(workspace: workspace.id, gitRoot: "/repos/app")
    let apiUnit = RootFeature.workspaceFetchGroupID(workspace: workspace.id, gitRoot: "/repos/api")
    #expect(choice(unit: appUnit, root: "/repos/app", catalog) == .gitlab)
    #expect(choice(unit: apiUnit, root: "/repos/api", catalog) == nil)
  }

  @Test
  func aWorkspaceMemberWithNoRegisteredProjectIsAuto() {
    let catalog = Catalog(projects: [workspace])
    let unit = RootFeature.workspaceFetchGroupID(workspace: workspace.id, gitRoot: "/repos/app")
    #expect(choice(unit: unit, root: "/repos/app", catalog) == nil)
  }

  private func choice(unit: ProjectID, root: String, _ catalog: Catalog) -> CodeHostKind? {
    ProjectCodeHostChoiceClient.choice(
      unitID: unit, gitRoot: URL(fileURLWithPath: root), catalog: catalog, settings: settings)
  }
}
