import ArgumentParser
import Foundation
import TouchCodeCore
import TouchCodeIPC
import tcKit

struct ProjectList: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List projects."
  )

  @OptionGroup var globals: GlobalOptions

  func run() async throws {
    await CommandRunner.run {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      struct Result: Codable { let projects: [Project] }
      let result: Result = try await client.call(
        .hierarchyListProjects,
        params: EmptyParams()
      )
      try Renderer.emit(ProjectListRenderable(projects: result.projects), mode: globals.renderMode)
    }
  }
}

struct ProjectCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "project",
    abstract: "Create and remove projects.",
    subcommands: [
      ProjectAdd.self,
      ProjectRemove.self,
    ]
  )
}

struct ProjectAdd: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "add",
    abstract: "Add an existing directory as a project."
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Project directory.")
  var path: String
  @Option(name: .long, help: "Display name. Defaults to the directory name.")
  var name: String?

  func run() async throws {
    await CommandRunner.run {
      let resolvedPath = PathResolver.absolute(path)
      let displayName = name ?? URL(fileURLWithPath: resolvedPath).lastPathComponent
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      struct Params: Codable {
        let name: String
        let rootPath: String
        let gitRoot: String?
      }
      struct Result: Codable { let id: ProjectID }
      let result: Result = try await client.call(
        .hierarchyAddProject,
        params: Params(name: displayName, rootPath: resolvedPath, gitRoot: nil)
      )
      try Renderer.emitObject(
        ["id": result.id.description, "name": displayName, "path": resolvedPath],
        mode: globals.renderMode
      ) { obj in
        "added project \(obj["id"] ?? "?")  \(displayName)"
      }
    }
  }
}

struct ProjectRemove: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "rm",
    abstract: "Remove a project from TouchCode."
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Project id, name, or 'current'.")
  var project: String

  func run() async throws {
    await CommandRunner.run {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let uuid = try await AliasResolver.resolve(project, kind: .project, client: client)
      struct Params: Codable { let id: ProjectID }
      _ = try await client.callRaw(
        .hierarchyRemoveProject,
        params: Params(id: ProjectID(raw: uuid))
      )
      try Renderer.emit(
        IDMessage(id: uuid.uuidString, message: "removed project \(uuid.uuidString)"), mode: globals.renderMode)
    }
  }
}

struct ProjectListPayload: Codable { let projects: [Project] }

struct ProjectListRenderable: Encodable, CustomStringConvertible {
  let projects: [Project]
  private enum Key: String, CodingKey { case projects }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    try container.encode(projects.map(ProjectDTO.init(project:)), forKey: .projects)
  }

  var description: String {
    projects.isEmpty
      ? "(no projects)"
      : projects.map { "\($0.id)  \($0.name)  \($0.rootPath)" }.joined(separator: "\n")
  }
}

struct ProjectDTO: Encodable {
  let id: String
  let name: String
  let rootPath: String
  let gitRoot: String?
  let selectedWorktreeID: String?

  init(project: Project) {
    self.id = project.id.description
    self.name = project.name
    self.rootPath = project.rootPath
    self.gitRoot = project.gitRoot
    self.selectedWorktreeID = project.selectedWorktreeID?.description
  }
}
