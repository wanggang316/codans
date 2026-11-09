import ArgumentParser
import CodansCore
import CodansIPC
import CodansKit
import Foundation

struct TreeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tree",
    abstract: "List projects, worktrees, tabs, and panes.",
    discussion: """
      Use 'codans tree' as the first discovery command. It prints the full hierarchy so
      you do not have to walk projects, worktrees, tabs, and panes one command at
      a time. --host keeps the Projects on one Host.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @OptionGroup var hostOptions: HostOptions
  @Option(name: .long, help: "Restrict output to one project id, name, or 'current'.")
  var project: String?

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let tree = try await HierarchyTree.load(client: client, timeout: globals.rpcTimeout)
      let projects: [Project]
      if let project {
        let uuid = try await hostOptions.resolveProject(project, client: client)
        projects = tree.projects.filter { $0.id.raw == uuid }
        if projects.isEmpty {
          throw CLIError(code: .notFound, message: "project \(uuid.uuidString) not found")
        }
      } else if let host = try hostOptions.selector() {
        if case .host(let id) = host, !tree.hosts.contains(where: { $0.id == id }) {
          throw CLIError(
            code: .notFound, message: "host not found: \(host)", details: ["kind": "host", "id": host.description])
        }
        projects = tree.projects.filter(host.matches)
      } else {
        projects = tree.projects
      }
      try Renderer.emit(
        HierarchyTreeRenderable(projects: projects, handles: tree.handles, hosts: tree.hosts),
        mode: globals.renderMode
      )
    }
  }
}

struct HierarchyTree: Codable, Sendable {
  /// Remote Projects carry a resolved `remoteHost`.
  let projects: [Project]
  let handles: IPC.TargetHandles?
  /// The app's Host list; empty from an app that predates Host records.
  let hosts: [HostRecord]

  static func load(client: RPCClient, timeout: Duration = .seconds(10)) async throws -> HierarchyTree {
    let payload: IPC.ProjectListPayload = try await client.call(
      .hierarchyListProjects,
      params: EmptyParams(),
      timeout: timeout
    )
    return HierarchyTree(
      projects: payload.resolvedProjects, handles: payload.handles, hosts: payload.hosts ?? [])
  }

  func locateWorktree(_ worktreeID: WorktreeID) -> WorktreePath? {
    for project in projects where project.worktrees.contains(where: { $0.id == worktreeID }) {
      return WorktreePath(projectID: project.id, worktreeID: worktreeID)
    }
    return nil
  }

  func locateTab(_ tabID: TabID) -> TabPath? {
    for project in projects {
      for worktree in project.worktrees where worktree.tabs.contains(where: { $0.id == tabID }) {
        return TabPath(projectID: project.id, worktreeID: worktree.id, tabID: tabID)
      }
    }
    return nil
  }

  func locatePane(_ paneID: PaneID) -> PanePath? {
    for project in projects {
      for worktree in project.worktrees {
        for tab in worktree.tabs where tab.panes.contains(where: { $0.id == paneID }) {
          return PanePath(projectID: project.id, worktreeID: worktree.id, tabID: tab.id, paneID: paneID)
        }
      }
    }
    return nil
  }
}

struct WorktreePath: Sendable {
  let projectID: ProjectID
  let worktreeID: WorktreeID
}

struct TabPath: Sendable {
  let projectID: ProjectID
  let worktreeID: WorktreeID
  let tabID: TabID
}

struct PanePath: Sendable {
  let projectID: ProjectID
  let worktreeID: WorktreeID
  let tabID: TabID
  let paneID: PaneID
}
