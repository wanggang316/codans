import ArgumentParser
import CodansCore
import CodansIPC
import CodansKit
import Foundation

/// `codans workspace …` — create a multi-repository workspace, add a
/// repository to one, or describe one. The server materializes the checkouts
/// on disk (this is the one CLI group whose verbs write outside the catalog),
/// so every mutating verb threads `--timeout` through to the RPC.
struct WorkspaceCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "workspace",
    abstract: "Create and extend multi-repository workspaces.",
    subcommands: [
      WorkspaceCreate.self,
      WorkspaceAdd.self,
      WorkspaceShow.self,
    ]
  )
}

struct WorkspaceCreate: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "create",
    abstract: "Create a workspace from two or more repositories.",
    discussion: """
      Each --project names a registered project (id, name, or 'current'); each
      --repo names any local git repository. Every member is checked out into
      <root>/<name> on --branch (default: a slug of the title), created from
      --base (default: the repository's default remote branch) unless
      --existing selects a branch that already exists.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Workspace title.")
  var title: String
  @Option(name: .long, help: "Registered project to include (repeatable).")
  var project: [String] = []
  @Option(name: .long, help: "Local repository path to include (repeatable).")
  var repo: [String] = []
  @Option(name: .long, help: "Branch every member checks out. Default: slug of the title.")
  var branch: String?
  @Option(name: .long, help: "Base ref for new branches. Default: each repository's default remote branch.")
  var base: String?
  @Flag(name: .long, help: "Check out an existing branch instead of creating one.")
  var existing: Bool = false
  @Option(name: .long, help: "Workspace folder. Default: ~/.codans/workspaces/<slug>.")
  var path: String?
  @Option(name: .long, help: "Task summary stored in the manifest.")
  var description: String?

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let sources = try CLIWorkspaceMemberSource.resolve(
        projects: project, repos: repo, minimum: WorkspacePlan.minimumMembers)
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      var members: [IPC.WorkspaceMemberRequest] = []
      for source in sources {
        members.append(try await WorkspaceCommandSupport.member(for: source, client: client))
      }
      let request = IPC.WorkspaceCreateRequest(
        title: title,
        rootPath: path.map { PathResolver.absolute($0) },
        description: description,
        branch: branch,
        baseRef: base,
        useExistingBranch: existing ? true : nil,
        members: members
      )
      let summary: IPC.WorkspaceSummary = try await client.call(
        .workspaceCreate, params: request, timeout: globals.rpcTimeout)
      try Renderer.emit(WorkspaceSummaryRenderable(summary: summary, verb: "created"), mode: globals.renderMode)
    }
  }
}

struct WorkspaceAdd: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "add",
    abstract: "Add a repository to a workspace."
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Workspace project id, name, or 'current'.")
  var workspace: String
  @Option(name: .long, help: "Registered project to add.")
  var project: [String] = []
  @Option(name: .long, help: "Local repository path to add.")
  var repo: [String] = []
  @Option(name: .long, help: "Folder name under the workspace root. Default: the repository's folder name.")
  var name: String?
  @Option(name: .long, help: "Branch to check out. Default: slug of the workspace title.")
  var branch: String?
  @Option(name: .long, help: "Base ref for a new branch.")
  var base: String?
  @Flag(name: .long, help: "Check out an existing branch instead of creating one.")
  var existing: Bool = false
  @Option(name: .long, help: "Short role recorded in the manifest, e.g. backend.")
  var role: String?

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let source = try CLIWorkspaceMemberSource.resolve(
        projects: project, repos: repo, minimum: 1, maximum: 1)[0]
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let workspaceUUID = try await AliasResolver.resolve(workspace, kind: .project, client: client)
      var member = try await WorkspaceCommandSupport.member(for: source, client: client)
      member = IPC.WorkspaceMemberRequest(
        name: name, projectID: member.projectID, path: member.path,
        branch: branch, baseRef: base, useExistingBranch: existing ? true : nil, role: role)
      let added: IPC.WorkspaceMemberSummary = try await client.call(
        .workspaceAdd,
        params: IPC.WorkspaceAddRequest(projectID: ProjectID(raw: workspaceUUID), member: member),
        timeout: globals.rpcTimeout)
      try Renderer.emit(WorkspaceMemberRenderable(member: added), mode: globals.renderMode)
    }
  }
}

struct WorkspaceShow: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "show",
    abstract: "Describe a workspace and its repositories."
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Workspace project id, name, or 'current'.")
  var workspace: String = "current"

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let workspaceUUID = try await AliasResolver.resolve(workspace, kind: .project, client: client)
      let summary: IPC.WorkspaceSummary = try await client.call(
        .workspaceDescribe,
        params: IPC.WorkspaceDescribeRequest(projectID: ProjectID(raw: workspaceUUID)),
        timeout: globals.rpcTimeout)
      try Renderer.emit(WorkspaceSummaryRenderable(summary: summary, verb: nil), mode: globals.renderMode)
    }
  }
}

// MARK: - Support

enum WorkspaceCommandSupport {
  /// A registered project resolves to its id here (the server reads its git
  /// root); a repository path is sent absolute and the server discovers the
  /// root.
  static func member(
    for source: CLIWorkspaceMemberSource,
    client: RPCClient
  ) async throws -> IPC.WorkspaceMemberRequest {
    switch source {
    case .project(let alias):
      let uuid = try await AliasResolver.resolve(alias, kind: .project, client: client)
      return IPC.WorkspaceMemberRequest(projectID: ProjectID(raw: uuid))
    case .repo(let path):
      return IPC.WorkspaceMemberRequest(path: PathResolver.absolute(path))
    }
  }
}

/// Stable-key JSON for a workspace (nil fields encode as null) plus the text
/// rendering.
struct WorkspaceSummaryRenderable: Encodable, CustomStringConvertible {
  let summary: IPC.WorkspaceSummary
  /// Leading verb for the text form (`created`), nil for `show`.
  let verb: String?

  private enum Key: String, CodingKey {
    case id, title, rootPath, description, taskLinks, members
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    try container.encode(summary.projectID.description, forKey: .id)
    try container.encode(summary.title, forKey: .title)
    try container.encode(summary.rootPath, forKey: .rootPath)
    try container.encode(summary.description, forKey: .description)
    try container.encode(summary.taskLinks, forKey: .taskLinks)
    try container.encode(summary.members.map(WorkspaceMemberDTO.init(member:)), forKey: .members)
  }

  var description: String {
    var lines: [String] = []
    if let verb {
      lines.append("\(verb) workspace \(summary.projectID)  \(summary.title)")
    } else {
      lines.append("\(summary.title)  \(summary.projectID)")
    }
    lines.append("  path: \(summary.rootPath)")
    if let description = summary.description, !description.isEmpty {
      lines.append("  \(description)")
    }
    for member in summary.members {
      lines.append("  " + WorkspaceMemberRenderable(member: member).description)
    }
    return lines.joined(separator: "\n")
  }
}

struct WorkspaceMemberRenderable: Encodable, CustomStringConvertible {
  let member: IPC.WorkspaceMemberSummary

  func encode(to encoder: Encoder) throws {
    try WorkspaceMemberDTO(member: member).encode(to: encoder)
  }

  var description: String {
    let branch = member.branch ?? "no branch"
    let role = member.role.map { "  (\($0))" } ?? ""
    let id = member.worktreeID.map { "  \($0)" } ?? ""
    return "\(member.name)  [\(branch)]\(role)  \(member.path)\(id)"
  }
}

struct WorkspaceMemberDTO: Encodable {
  let member: IPC.WorkspaceMemberSummary

  private enum Key: String, CodingKey {
    case name, path, role, branch, sourceGitRoot, worktreeID
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    try container.encode(member.name, forKey: .name)
    try container.encode(member.path, forKey: .path)
    try container.encode(member.role, forKey: .role)
    try container.encode(member.branch, forKey: .branch)
    try container.encode(member.sourceGitRoot, forKey: .sourceGitRoot)
    try container.encode(member.worktreeID?.description, forKey: .worktreeID)
  }
}
