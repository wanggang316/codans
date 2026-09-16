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
      WorkspaceDrop.self,
      WorkspaceRemove.self,
      WorkspaceShow.self,
    ]
  )
}

struct WorkspaceDrop: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "drop",
    abstract: "Remove a repository from a workspace, unregistering its checkout.",
    discussion: """
      The member's folder is moved out of the workspace and unregistered from
      its source repository; the branch it was on is deleted too unless
      --keep-branch is given (git keeps a branch that is checked out elsewhere
      either way, and the response says so).
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Workspace project id, name, or 'current'.")
  var workspace: String
  @Argument(help: "Member folder name, as shown by `workspace show`.")
  var member: String
  @Flag(name: .long, help: "Keep the member's branch in the source repository.")
  var keepBranch: Bool = false

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let workspaceUUID = try await AliasResolver.resolve(workspace, kind: .project, client: client)
      let response: IPC.WorkspaceDropResponse = try await client.call(
        .workspaceDrop,
        params: IPC.WorkspaceDropRequest(
          projectID: ProjectID(raw: workspaceUUID), member: member, keepBranch: keepBranch),
        timeout: globals.rpcTimeout)
      try Renderer.emitObject(
        ["name": response.name, "path": response.path, "warning": response.warning ?? ""],
        mode: globals.renderMode
      ) { _ in
        var line = "dropped \(response.name)  \(response.path)"
        if let warning = response.warning { line += "\n  note: \(warning)" }
        return line
      }
    }
  }
}

struct WorkspaceRemove: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "remove",
    abstract: "Remove a workspace from Codans, optionally deleting its checkouts.",
    discussion: """
      Without flags only the sidebar entry goes; every checkout and branch
      stays on disk. --delete-files unregisters each member from its source
      repository and deletes the workspace folder — but only when every
      member could be unregistered, so a source repository is never left
      pointing at a folder that is gone. --delete-branches additionally
      deletes each member's branch.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Workspace project id, name, or 'current'.")
  var workspace: String
  @Flag(name: .long, help: "Unregister every checkout and delete the workspace folder.")
  var deleteFiles: Bool = false
  @Flag(name: .long, help: "With --delete-files: also delete each member's branch.")
  var deleteBranches: Bool = false

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      if deleteBranches, !deleteFiles {
        throw CLIError(
          code: .userError, message: "--delete-branches requires --delete-files",
          hint: "pass --delete-files to unregister the checkouts first")
      }
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let workspaceUUID = try await AliasResolver.resolve(workspace, kind: .project, client: client)
      let response: IPC.WorkspaceRemoveResponse = try await client.call(
        .workspaceRemove,
        params: IPC.WorkspaceRemoveRequest(
          projectID: ProjectID(raw: workspaceUUID),
          cleanup: WorkspaceCleanup(deleteFiles: deleteFiles, deleteBranches: deleteBranches)),
        timeout: globals.rpcTimeout)
      try Renderer.emit(WorkspaceRemovalRenderable(response: response), mode: globals.renderMode)
    }
  }
}

struct WorkspaceRemovalRenderable: Encodable, CustomStringConvertible {
  let response: IPC.WorkspaceRemoveResponse

  private enum Key: String, CodingKey {
    case id, rootPath, deletedFolder, failures, keptBranches
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    try container.encode(response.projectID.description, forKey: .id)
    try container.encode(response.rootPath, forKey: .rootPath)
    try container.encode(response.outcome.deletedFolder, forKey: .deletedFolder)
    try container.encode(response.outcome.failures, forKey: .failures)
    try container.encode(response.outcome.keptBranches, forKey: .keptBranches)
  }

  var description: String {
    var lines = ["removed workspace \(response.projectID)  \(response.rootPath)"]
    lines.append(
      response.outcome.deletedFolder ? "  folder deleted" : "  folder kept on disk")
    if !response.outcome.failures.isEmpty {
      lines.append("  could not unregister: \(response.outcome.failures.joined(separator: ", "))")
    }
    for kept in response.outcome.keptBranches {
      lines.append("  note: \(kept)")
    }
    return lines.joined(separator: "\n")
  }
}

struct WorkspaceCreate: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "create",
    abstract: "Create a workspace from two or more repositories.",
    discussion: """
      Each --project names a registered project (id, name, or 'current'); each
      --repo names any local git repository, bare ones included; each --remote
      names a URL that is cloned once into --clone-into (default:
      ~/.codans/sources/<name>; an existing clone of the same remote there is
      reused) and then used like a local repository. Every member is checked
      out into <root>/<name> on --branch (default: a slug of the title),
      created from --base (default: the repository's default remote branch)
      unless --existing selects a local branch that already exists or --track
      checks out the remote-tracking origin/<branch>. With --track, a local
      branch of the same name is checked out as is; --reset-local points it at
      the remote tip instead, discarding local-only commits.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Workspace title.")
  var title: String
  @Option(name: .long, help: "Registered project to include (repeatable).")
  var project: [String] = []
  @Option(name: .long, help: "Local repository path to include, bare or not (repeatable).")
  var repo: [String] = []
  @Option(name: .long, help: "Remote URL to clone and include (repeatable).")
  var remote: [String] = []
  @Option(name: .long, help: "Branch every member checks out. Default: slug of the title.")
  var branch: String?
  @Option(name: .long, help: "Base ref for new branches. Default: each repository's default remote branch.")
  var base: String?
  @Flag(name: .long, help: "Check out an existing local branch instead of creating one.")
  var existing: Bool = false
  @Flag(name: .long, help: "Check out the remote-tracking origin/<branch> instead of creating one.")
  var track: Bool = false
  @Flag(name: .long, help: "With --track: reset a same-named local branch to the remote tip.")
  var resetLocal: Bool = false
  @Option(name: .long, help: "Folder remote members are cloned into. Default: ~/.codans/sources.")
  var cloneInto: String?
  @Option(name: .long, help: "Workspace folder. Default: ~/.codans/workspaces/<slug>.")
  var path: String?
  @Option(name: .long, help: "Task summary stored in the manifest.")
  var description: String?

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let sources = try CLIWorkspaceMemberSource.resolve(
        projects: project, repos: repo, remotes: remote, minimum: WorkspacePlan.minimumMembers)
      let flags = try CLIWorkspaceCheckoutFlags.resolve(
        existing: existing, track: track, ref: nil, resetLocal: resetLocal)
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      var members: [IPC.WorkspaceMemberRequest] = []
      for source in sources {
        var member = try await WorkspaceCommandSupport.member(for: source, client: client)
        if flags.resetLocalBranch == true {
          member = IPC.WorkspaceMemberRequest(
            projectID: member.projectID, path: member.path, remoteURL: member.remoteURL,
            resetLocalBranch: true)
        }
        members.append(member)
      }
      let request = IPC.WorkspaceCreateRequest(
        title: title,
        rootPath: path.map { PathResolver.absolute($0) },
        description: description,
        branch: branch,
        baseRef: base,
        useExistingBranch: flags.useExistingBranch,
        trackRemote: flags.trackRemote,
        cloneBaseDirectory: cloneInto.map { PathResolver.absolute($0) },
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
  @Option(name: .long, help: "Local repository path to add, bare or not.")
  var repo: [String] = []
  @Option(name: .long, help: "Remote URL to clone and add.")
  var remote: [String] = []
  @Option(name: .long, help: "Folder name under the workspace root. Default: the repository's folder name.")
  var name: String?
  @Option(name: .long, help: "Branch to check out. Default: slug of the workspace title, or the --ref branch.")
  var branch: String?
  @Option(name: .long, help: "Base ref for a new branch.")
  var base: String?
  @Flag(name: .long, help: "Check out an existing local branch instead of creating one.")
  var existing: Bool = false
  @Flag(name: .long, help: "Check out the remote-tracking origin/<branch> instead of creating one.")
  var track: Bool = false
  @Option(name: .long, help: "Remote-tracking ref to check out, e.g. origin/feature.")
  var ref: String?
  @Flag(name: .long, help: "With --track or --ref: reset a same-named local branch to the remote tip.")
  var resetLocal: Bool = false
  @Option(name: .long, help: "Folder a remote member is cloned into. Default: ~/.codans/sources.")
  var cloneInto: String?
  @Option(name: .long, help: "Short role recorded in the manifest, e.g. backend.")
  var role: String?

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let source = try CLIWorkspaceMemberSource.resolve(
        projects: project, repos: repo, remotes: remote, minimum: 1, maximum: 1)[0]
      let flags = try CLIWorkspaceCheckoutFlags.resolve(
        existing: existing, track: track, ref: ref, resetLocal: resetLocal)
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let workspaceUUID = try await AliasResolver.resolve(workspace, kind: .project, client: client)
      var member = try await WorkspaceCommandSupport.member(for: source, client: client)
      // `--track` on a single member is `--ref origin/<branch>`, which needs
      // the branch name the server would otherwise default.
      let remoteRef = flags.remoteRef ?? (flags.trackRemote == true ? branch.map { "origin/\($0)" } : nil)
      if flags.trackRemote == true, remoteRef == nil {
        throw CLIError(
          code: .userError, message: "--track needs --branch",
          hint: "pass --branch <name> or --ref <remote>/<branch>")
      }
      member = IPC.WorkspaceMemberRequest(
        name: name, projectID: member.projectID, path: member.path, remoteURL: member.remoteURL,
        branch: branch, baseRef: base, useExistingBranch: flags.useExistingBranch,
        remoteRef: remoteRef, resetLocalBranch: flags.resetLocalBranch, role: role)
      let added: IPC.WorkspaceMemberSummary = try await client.call(
        .workspaceAdd,
        params: IPC.WorkspaceAddRequest(
          projectID: ProjectID(raw: workspaceUUID), member: member,
          cloneBaseDirectory: cloneInto.map { PathResolver.absolute($0) }),
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
  /// root; a remote URL is sent as given and the server picks the clone
  /// destination.
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
    case .remote(let url):
      return IPC.WorkspaceMemberRequest(remoteURL: url)
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
    let source: String
    switch member.sourceKind {
    case .remote: source = "  <- \(member.remoteURL ?? "remote")"
    case .bare: source = "  <- bare \(member.sourceGitRoot ?? "")"
    case .local, nil: source = ""
    }
    return "\(member.name)  [\(branch)]\(role)  \(member.path)\(id)\(source)"
  }
}

struct WorkspaceMemberDTO: Encodable {
  let member: IPC.WorkspaceMemberSummary

  private enum Key: String, CodingKey {
    case name, path, role, branch, sourceGitRoot, sourceKind, remoteURL, worktreeID
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    try container.encode(member.name, forKey: .name)
    try container.encode(member.path, forKey: .path)
    try container.encode(member.role, forKey: .role)
    try container.encode(member.branch, forKey: .branch)
    try container.encode(member.sourceGitRoot, forKey: .sourceGitRoot)
    try container.encode(member.sourceKind?.rawValue, forKey: .sourceKind)
    try container.encode(member.remoteURL, forKey: .remoteURL)
    try container.encode(member.worktreeID?.description, forKey: .worktreeID)
  }
}
