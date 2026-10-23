import ArgumentParser
import CodansCore
import CodansIPC
import CodansKit
import Foundation

/// `codans workspace …` — a Workspace lists source projects (the `default`
/// group references their main checkouts) and named groups, each with one
/// branch checked out per project. The server writes the checkouts, so
/// every mutating verb threads `--timeout` through to the RPC.
struct WorkspaceCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "workspace",
    abstract: "Create workspaces, edit their projects, and manage their groups.",
    subcommands: [
      WorkspaceCreate.self,
      WorkspaceAdd.self,
      WorkspaceDrop.self,
      WorkspaceRemove.self,
      WorkspaceShow.self,
      WorkspaceGroupCommand.self,
    ]
  )
}

/// Branch flags an older `create` / `add` took. They stay parseable only to
/// fail with a pointer to `group create`, so a script never believes a
/// branch was made.
struct RetiredCheckoutOptions: ParsableArguments {
  @Option(name: .long, help: .hidden) var branch: String?
  @Option(name: .long, help: .hidden) var base: String?
  @Flag(name: .long, help: .hidden) var existing: Bool = false
  @Flag(name: .long, help: .hidden) var track: Bool = false
  @Option(name: .long, help: .hidden) var ref: String?
  @Flag(name: .long, help: .hidden) var resetLocal: Bool = false
  @Option(name: .long, help: .hidden) var role: String?

  func validate() throws {
    let given: [(String, Bool)] = [
      ("--branch", branch != nil), ("--base", base != nil), ("--existing", existing), ("--track", track),
      ("--ref", ref != nil), ("--reset-local", resetLocal), ("--role", role != nil),
    ]
    if let flag = given.first(where: \.1)?.0 {
      throw ValidationError(
        "\(flag) is no longer accepted: a workspace takes source projects only; "
          + "create the branches with `codans workspace group create <workspace> <name> --branch <b>`")
    }
  }
}

struct WorkspaceCreate: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "create",
    abstract: "Create a workspace from source projects.",
    discussion: """
      Each --project names a registered project (id, name, or 'current'); each
      --repo names a folder inside a local git repository (not a bare one);
      each --remote names a URL that is cloned once into --clone-into
      (default: ~/.codans/sources/<name>; an existing clone of the same remote
      there is reused). Every source is listed in the `default` group, which
      links to its main checkout. No branch is created or switched: create
      branches with `codans workspace group create`.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Workspace title.")
  var title: String
  @Option(name: .long, help: "Registered project to include (repeatable).")
  var project: [String] = []
  @Option(name: .long, help: "Local repository path to include (repeatable).")
  var repo: [String] = []
  @Option(name: .long, help: "Remote URL to clone and include (repeatable).")
  var remote: [String] = []
  @Option(name: .long, help: "Folder remote sources are cloned into. Default: ~/.codans/sources.")
  var cloneInto: String?
  @Option(name: .long, help: "Workspace folder. Default: ~/.codans/workspaces/<slug>.")
  var path: String?
  @Option(name: .long, help: "Task summary stored in the manifest.")
  var description: String?
  @OptionGroup var retired: RetiredCheckoutOptions

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let sources = try CLIWorkspaceMemberSource.resolve(
        projects: project, repos: repo, remotes: remote, minimum: 1)
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      var requests: [IPC.WorkspaceSourceRequest] = []
      for source in sources {
        requests.append(try await WorkspaceCommandSupport.source(for: source, client: client))
      }
      let request = IPC.WorkspaceCreateRequest(
        title: title,
        rootPath: path.map { PathResolver.absolute($0) },
        description: description,
        cloneBaseDirectory: cloneInto.map { PathResolver.absolute($0) },
        projects: requests
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
    abstract: "Add a source project to a workspace.",
    discussion: """
      The project is listed in the `default` group, which links to its main
      checkout. Named groups are unchanged. Pass a repository path, or one of
      --project / --repo / --remote.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Workspace project id, name, or 'current'.")
  var workspace: String
  @Argument(help: "Local repository path to add.")
  var path: String?
  @Option(name: .long, help: "Registered project to add.")
  var project: [String] = []
  @Option(name: .long, help: "Local repository path to add.")
  var repo: [String] = []
  @Option(name: .long, help: "Remote URL to clone and add.")
  var remote: [String] = []
  @Option(name: .long, help: "Link name in the default group. Default: the repository's folder name.")
  var name: String?
  @Option(name: .long, help: "Folder a remote source is cloned into. Default: ~/.codans/sources.")
  var cloneInto: String?
  @OptionGroup var retired: RetiredCheckoutOptions

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let source = try CLIWorkspaceMemberSource.resolve(
        projects: project, repos: repo + (path.map { [$0] } ?? []), remotes: remote, minimum: 1, maximum: 1)[0]
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let workspaceUUID = try await AliasResolver.resolve(workspace, kind: .project, client: client)
      let base = try await WorkspaceCommandSupport.source(for: source, client: client)
      let added: IPC.WorkspaceProjectSummary = try await client.call(
        .workspaceAdd,
        params: IPC.WorkspaceAddRequest(
          projectID: ProjectID(raw: workspaceUUID),
          project: IPC.WorkspaceSourceRequest(
            name: name, projectID: base.projectID, path: base.path, remoteURL: base.remoteURL),
          cloneBaseDirectory: cloneInto.map { PathResolver.absolute($0) }),
        timeout: globals.rpcTimeout)
      try Renderer.emit(WorkspaceProjectRenderable(project: added), mode: globals.renderMode)
    }
  }
}

struct WorkspaceDrop: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "drop",
    abstract: "Remove a source project from a workspace.",
    discussion: """
      Removes the project from the workspace and its link from the `default`
      group. The project's folder and every checkout stay on disk; a checkout
      of a named group goes with its group (`codans workspace group delete`).
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Workspace project id, name, or 'current'.")
  var workspace: String
  @Argument(help: "Source project name, as `workspace show` lists it, or its path.")
  var project: String
  @Flag(name: .long, help: .hidden)
  var keepBranch: Bool = false

  func validate() throws {
    if keepBranch {
      throw ValidationError("--keep-branch is no longer accepted: drop never deletes a checkout or a branch")
    }
  }

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let workspaceUUID = try await AliasResolver.resolve(workspace, kind: .project, client: client)
      let looksLikePath = project.contains("/") || project.hasPrefix("~") || project == "."
      let response: IPC.WorkspaceDropResponse = try await client.call(
        .workspaceDrop,
        params: IPC.WorkspaceDropRequest(
          projectID: ProjectID(raw: workspaceUUID),
          project: looksLikePath ? PathResolver.absolute(project) : project),
        timeout: globals.rpcTimeout)
      try Renderer.emitObject(["name": response.name, "path": response.path], mode: globals.renderMode) { _ in
        "dropped \(response.name)  \(response.path) (kept on disk)"
      }
    }
  }
}

struct WorkspaceRemove: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "remove",
    abstract: "Remove a workspace from Codans, optionally deleting the files it owns.",
    discussion: """
      Without flags only the sidebar entry goes; everything stays on disk.
      --delete-files deletes every named group (checkouts and folders), the
      default links, and the workspace folder. Source project folders are never
      deleted. When a group has uncommitted changes, unpushed commits, running
      terminals, or other files, the command fails with the list (exit 3)
      unless --discard accepts losing them. --delete-branches also deletes each
      branch a group created.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Workspace project id, name, or 'current'.")
  var workspace: String
  @Flag(name: .long, help: "Delete the groups, links, and workspace folder.")
  var deleteFiles: Bool = false
  @Flag(name: .long, help: "With --delete-files: also delete the branches the groups created.")
  var deleteBranches: Bool = false
  @Flag(name: .long, help: "With --delete-files: accept losing changes, commits, and running terminals.")
  var discard: Bool = false

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      if deleteBranches || discard, !deleteFiles {
        throw CLIError(
          code: .userError, message: "--delete-branches and --discard require --delete-files",
          hint: "pass --delete-files to delete the files the workspace owns")
      }
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let workspaceUUID = try await AliasResolver.resolve(workspace, kind: .project, client: client)
      let response: IPC.WorkspaceRemoveResponse = try await WorkspaceCommandSupport.withDiscardHint(discard) {
        try await client.call(
          .workspaceRemove,
          params: IPC.WorkspaceRemoveRequest(
            projectID: ProjectID(raw: workspaceUUID),
            cleanup: WorkspaceCleanup(deleteFiles: deleteFiles, deleteBranches: deleteBranches),
            acknowledgeRisks: discard),
          timeout: globals.rpcTimeout)
      }
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
    lines.append(response.outcome.deletedFolder ? "  folder deleted" : "  folder kept on disk")
    for failure in response.outcome.failures {
      lines.append("  not deleted: \(failure)")
    }
    for kept in response.outcome.keptBranches {
      lines.append("  note: \(kept)")
    }
    return lines.joined(separator: "\n")
  }
}

struct WorkspaceShow: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "show",
    abstract: "Describe a workspace: its projects and groups."
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

// MARK: - Groups

struct WorkspaceGroupCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "group",
    abstract: "Create and delete the named groups of a workspace.",
    subcommands: [
      WorkspaceGroupCreate.self,
      WorkspaceGroupDelete.self,
    ]
  )
}

struct WorkspaceGroupCreate: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "create",
    abstract: "Create a named group: one branch checked out for every project.",
    discussion: """
      Checks out --branch from each project into <root>/<name>/<project>. Each
      project's base ref, fetch, and copy settings come from its Codans
      settings unless a flag overrides them; --base <project>=<ref> sets the
      base of one project (repeatable). A local branch with the same name in
      any project blocks the group. When a checkout fails, every checkout made
      so far is removed again. Setup commands run after every checkout exists;
      a failed one keeps the group and is reported. --agent starts that agent
      profile in each member after the group exists.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Workspace project id, name, or 'current'.")
  var workspace: String
  @Argument(help: "Group name; also its folder under the workspace root.")
  var name: String
  @Option(name: .long, help: "Branch to create in every project.")
  var branch: String
  @Option(name: .long, help: "Base ref for one project, as <project>=<ref> (repeatable).")
  var base: [String] = []
  @Flag(name: .long, help: "Do not fetch the base ref's remote first.")
  var noFetch: Bool = false
  @Flag(name: .long, help: "Copy ignored files from each project into its checkout.")
  var copyIgnored: Bool = false
  @Flag(name: .long, help: "Copy untracked files from each project into its checkout.")
  var copyUntracked: Bool = false
  @Option(name: .long, help: "Agent profile (name or id) to start in every member.")
  var agent: String?

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let baseRefs = try CLIKeyValuePairs.parse(base, option: "--base")
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let workspaceUUID = try await AliasResolver.resolve(workspace, kind: .project, client: client)
      // Checked before the group exists, so a typo cannot leave a group
      // without its agents.
      let profile: IPC.AgentProfileSummary?
      if let agent {
        let list: IPC.AgentProfileListResponse = try await client.call(.agentListProfiles, params: EmptyParams())
        profile = try CLIAgentProfileMatch.resolve(agent, in: list.profiles)
      } else {
        profile = nil
      }
      let projectID = ProjectID(raw: workspaceUUID)
      let response: IPC.WorkspaceGroupCreateResponse = try await client.call(
        .workspaceCreateGroup,
        params: IPC.WorkspaceGroupCreateRequest(
          projectID: projectID, name: name, branch: branch, baseRefs: baseRefs.isEmpty ? nil : baseRefs,
          fetch: noFetch ? false : nil, copyIgnored: copyIgnored ? true : nil,
          copyUntracked: copyUntracked ? true : nil),
        timeout: globals.rpcTimeout)
      var agentFailures: [String] = []
      if let profile {
        for member in response.group.members {
          guard let worktreeID = member.worktreeID else { continue }
          do {
            let _: IPC.AgentLaunchResponse = try await client.call(
              .agentLaunch,
              params: IPC.AgentLaunchRequest(
                projectID: projectID, worktreeID: worktreeID, profile: profile.id.uuidString, focus: false))
          } catch {
            agentFailures.append("\(member.name): \(CLIError.from(error).message)")
          }
        }
      }
      try Renderer.emit(
        WorkspaceGroupCreateRenderable(response: response, agentFailures: agentFailures), mode: globals.renderMode)
    }
  }
}

struct WorkspaceGroupDelete: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "delete",
    abstract: "Delete a named group: its checkouts, folder, and terminals.",
    discussion: """
      Checks every member first. Uncommitted changes, unpushed commits,
      running terminals, and other files in the group folder fail the command
      with the list (exit 3) unless --discard accepts losing them; a check that
      cannot run fails it too. --dry-run prints the check and deletes nothing.
      --delete-branches also deletes each branch the group created, unless it
      is checked out elsewhere or is the default branch. When a member cannot
      be removed, the group stays with the rest deleted; run the command again
      to retry. The `default` group cannot be deleted.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Workspace project id, name, or 'current'.")
  var workspace: String
  @Argument(help: "Group name or id.")
  var group: String
  @Flag(name: .long, help: "Also delete the branches the group created.")
  var deleteBranches: Bool = false
  @Flag(name: .long, help: "Accept losing changes, commits, running terminals, and other files.")
  var discard: Bool = false
  @Flag(name: .long, help: "Print what deleting would lose; delete nothing.")
  var dryRun: Bool = false

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let projectID = ProjectID(raw: try await AliasResolver.resolve(workspace, kind: .project, client: client))
      if dryRun {
        let check: GroupDeletionCheck = try await client.call(
          .workspaceCheckGroupDeletion, params: IPC.WorkspaceGroupRequest(projectID: projectID, group: group),
          timeout: globals.rpcTimeout)
        try Renderer.emit(GroupDeletionCheckRenderable(check: check), mode: globals.renderMode)
        return
      }
      let response: IPC.WorkspaceGroupDeleteResponse = try await WorkspaceCommandSupport.withDiscardHint(discard) {
        try await client.call(
          .workspaceDeleteGroup,
          params: IPC.WorkspaceGroupDeleteRequest(
            projectID: projectID, group: group, deleteBranches: deleteBranches, acknowledgeRisks: discard),
          timeout: globals.rpcTimeout)
      }
      try Renderer.emit(GroupDeletionRenderable(response: response), mode: globals.renderMode)
    }
  }
}

// MARK: - Support

enum WorkspaceCommandSupport {
  /// A registered project resolves to its id here (the server reads its git
  /// root); a repository path is sent absolute and the server finds the
  /// root; a remote URL is sent as given and the server picks the clone
  /// destination.
  static func source(
    for source: CLIWorkspaceMemberSource,
    client: RPCClient
  ) async throws -> IPC.WorkspaceSourceRequest {
    switch source {
    case .project(let alias):
      let uuid = try await AliasResolver.resolve(alias, kind: .project, client: client)
      return IPC.WorkspaceSourceRequest(projectID: ProjectID(raw: uuid))
    case .repo(let path):
      return IPC.WorkspaceSourceRequest(path: PathResolver.absolute(path))
    case .remote(let url):
      return IPC.WorkspaceSourceRequest(remoteURL: url)
    }
  }

  /// A `conflict` from a delete lists what would be lost; without
  /// `--discard` the next step is to pass it.
  static func withDiscardHint<T>(_ discard: Bool, _ body: () async throws -> T) async throws -> T {
    do {
      return try await body()
    } catch let error as IPCError {
      guard !discard, case .conflict(let reason) = error, reason.contains("acknowledge the risks") else { throw error }
      throw CLIError(
        code: .conflict, message: reason, hint: "re-run with --discard to delete anyway, or --dry-run to see the check"
      )
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
    case id, title, rootPath, description, taskLinks, projects, groups
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    try container.encode(summary.projectID.description, forKey: .id)
    try container.encode(summary.title, forKey: .title)
    try container.encode(summary.rootPath, forKey: .rootPath)
    try container.encode(summary.description, forKey: .description)
    try container.encode(summary.taskLinks, forKey: .taskLinks)
    try container.encode(summary.projects.map(WorkspaceProjectRenderable.init(project:)), forKey: .projects)
    try container.encode(summary.groups.map(WorkspaceGroupDTO.init(group:)), forKey: .groups)
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
    for group in summary.groups {
      lines.append(contentsOf: WorkspaceGroupDTO(group: group).lines.map { "  " + $0 })
    }
    return lines.joined(separator: "\n")
  }
}

struct WorkspaceProjectRenderable: Encodable, CustomStringConvertible {
  let project: IPC.WorkspaceProjectSummary

  private enum Key: String, CodingKey {
    case name, sourceGitRoot, sourceKind, remoteURL, branch, worktreeID
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    try container.encode(project.name, forKey: .name)
    try container.encode(project.sourceGitRoot, forKey: .sourceGitRoot)
    try container.encode(project.sourceKind.rawValue, forKey: .sourceKind)
    try container.encode(project.remoteURL, forKey: .remoteURL)
    try container.encode(project.branch, forKey: .branch)
    try container.encode(project.worktreeID?.description, forKey: .worktreeID)
  }

  var description: String {
    let remote = project.remoteURL.map { "  <- \($0)" } ?? ""
    let id = project.worktreeID.map { "  \($0)" } ?? ""
    return "\(project.name)  [\(project.branch ?? "no branch")]  \(project.sourceGitRoot)\(id)\(remote)"
  }
}

struct WorkspaceGroupDTO: Encodable {
  let group: IPC.WorkspaceGroupSummary

  private enum Key: String, CodingKey {
    case id, name, isDefault, path, worktreeID, deletion, members
  }

  private enum MemberKey: String, CodingKey {
    case name, path, branch, sourceGitRoot, role, worktreeID
  }

  private enum DeletionKey: String, CodingKey {
    case deleteBranches, startedAt
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    try container.encode(group.id.description, forKey: .id)
    try container.encode(group.name, forKey: .name)
    try container.encode(group.isDefault, forKey: .isDefault)
    try container.encode(group.path, forKey: .path)
    try container.encode(group.worktreeID?.description, forKey: .worktreeID)
    if let deletion = group.deletion {
      var nested = container.nestedContainer(keyedBy: DeletionKey.self, forKey: .deletion)
      try nested.encode(deletion.deleteBranches, forKey: .deleteBranches)
      try nested.encode(ISO8601DateFormatter().string(from: deletion.startedAt), forKey: .startedAt)
    } else {
      try container.encodeNil(forKey: .deletion)
    }
    var members = container.nestedUnkeyedContainer(forKey: .members)
    for member in group.members {
      var nested = members.nestedContainer(keyedBy: MemberKey.self)
      try nested.encode(member.name, forKey: .name)
      try nested.encode(member.path, forKey: .path)
      try nested.encode(member.branch, forKey: .branch)
      try nested.encode(member.sourceGitRoot, forKey: .sourceGitRoot)
      try nested.encode(member.role.rawValue, forKey: .role)
      try nested.encode(member.worktreeID?.description, forKey: .worktreeID)
    }
  }

  var lines: [String] {
    let star = group.isDefault ? "* " : ""
    let state = group.deletion == nil ? "" : "  (deletion incomplete)"
    var lines = ["\(star)group \(group.name)  \(group.path)\(group.worktreeID.map { "  \($0)" } ?? "")\(state)"]
    for member in group.members {
      let id = member.worktreeID.map { "  \($0)" } ?? ""
      lines.append("    \(member.name)  [\(member.branch ?? "no branch")]  \(member.path)\(id)")
    }
    return lines
  }
}

struct WorkspaceGroupCreateRenderable: Encodable, CustomStringConvertible {
  let response: IPC.WorkspaceGroupCreateResponse
  let agentFailures: [String]

  private enum Key: String, CodingKey {
    case projectID, group, setupFailures, agentFailures
  }

  private struct Failure: Encodable {
    let name: String
    let reason: String
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    try container.encode(response.projectID.description, forKey: .projectID)
    try container.encode(WorkspaceGroupDTO(group: response.group), forKey: .group)
    try container.encode(
      response.setupFailures.map { Failure(name: $0.name, reason: $0.reason) }, forKey: .setupFailures)
    try container.encode(agentFailures, forKey: .agentFailures)
  }

  var description: String {
    var lines = ["created " + WorkspaceGroupDTO(group: response.group).lines.joined(separator: "\n")]
    for failure in response.setupFailures {
      lines.append("  setup failed: \(failure.name): \(failure.reason)")
    }
    for failure in agentFailures {
      lines.append("  agent not started: \(failure)")
    }
    return lines.joined(separator: "\n")
  }
}

struct GroupDeletionCheckRenderable: Encodable, CustomStringConvertible {
  let check: GroupDeletionCheck

  private enum Key: String, CodingKey {
    case groupID, groupName, hasRisks, isBlocked, members, busyPaneIDs, extraEntries, groupCheckFailures
  }

  private enum MemberKey: String, CodingKey {
    case name, worktreeID, path, branch, uncommittedCount, unpushedCount, deletableBranches, checkFailure
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    try container.encode(check.groupID.description, forKey: .groupID)
    try container.encode(check.groupName, forKey: .groupName)
    try container.encode(check.hasRisks, forKey: .hasRisks)
    try container.encode(check.isBlocked, forKey: .isBlocked)
    var members = container.nestedUnkeyedContainer(forKey: .members)
    for member in check.members {
      var nested = members.nestedContainer(keyedBy: MemberKey.self)
      try nested.encode(member.name, forKey: .name)
      try nested.encode(member.worktreeID.description, forKey: .worktreeID)
      try nested.encode(member.path, forKey: .path)
      try nested.encode(member.branch, forKey: .branch)
      try nested.encode(member.uncommittedCount, forKey: .uncommittedCount)
      try nested.encode(member.unpushedCount, forKey: .unpushedCount)
      try nested.encode(member.deletableBranches, forKey: .deletableBranches)
      try nested.encode(member.checkFailure, forKey: .checkFailure)
    }
    try container.encode(check.busyPaneIDs.map(\.description), forKey: .busyPaneIDs)
    try container.encode(check.extraEntries, forKey: .extraEntries)
    try container.encode(check.groupCheckFailures, forKey: .groupCheckFailures)
  }

  var description: String {
    var lines = ["group \(check.groupName)"]
    for member in check.members {
      var facts = ["\(member.uncommittedCount) uncommitted", "\(member.unpushedCount) unpushed"]
      if !member.deletableBranches.isEmpty {
        facts.append("deletable branches: \(member.deletableBranches.joined(separator: ", "))")
      }
      if let failure = member.checkFailure { facts.append("check failed: \(failure)") }
      lines.append("  \(member.name)  [\(member.branch ?? "detached")]  \(facts.joined(separator: ", "))")
    }
    if !check.busyPaneIDs.isEmpty { lines.append("  running terminals: \(check.busyPaneIDs.count)") }
    if !check.extraEntries.isEmpty { lines.append("  other files: \(check.extraEntries.joined(separator: ", "))") }
    for failure in check.groupCheckFailures { lines.append("  check failed: \(failure)") }
    if check.isBlocked {
      lines.append("blocked: a check failed; nothing can be deleted until it passes")
    } else if check.hasRisks {
      lines.append("deleting loses the work above; pass --discard to accept")
    } else {
      lines.append("nothing would be lost")
    }
    return lines.joined(separator: "\n")
  }
}

struct GroupDeletionRenderable: Encodable, CustomStringConvertible {
  let response: IPC.WorkspaceGroupDeleteResponse

  private enum Key: String, CodingKey {
    case groupID, groupName, deletedGroup, removedMembers, deletedBranches, keptBranches, failures
  }

  private struct Failure: Encodable {
    let name: String
    let path: String
    let reason: String
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    let outcome = response.outcome
    try container.encode(response.groupID.description, forKey: .groupID)
    try container.encode(response.groupName, forKey: .groupName)
    try container.encode(outcome.deletedGroup, forKey: .deletedGroup)
    try container.encode(outcome.removedMembers, forKey: .removedMembers)
    try container.encode(outcome.deletedBranches, forKey: .deletedBranches)
    try container.encode(outcome.keptBranches, forKey: .keptBranches)
    try container.encode(
      outcome.failures.map { Failure(name: $0.name, path: $0.path, reason: $0.reason) }, forKey: .failures)
  }

  var description: String {
    let outcome = response.outcome
    var lines = [
      outcome.deletedGroup
        ? "deleted group \(response.groupName)"
        : "group \(response.groupName) is partly deleted; run the command again to retry"
    ]
    if !outcome.removedMembers.isEmpty {
      lines.append("  removed: \(outcome.removedMembers.joined(separator: ", "))")
    }
    if !outcome.deletedBranches.isEmpty {
      lines.append("  deleted branches: \(outcome.deletedBranches.joined(separator: ", "))")
    }
    for kept in outcome.keptBranches { lines.append("  note: \(kept)") }
    for failure in outcome.failures {
      lines.append("  not removed: \(failure.name) at \(failure.path): \(failure.reason)")
    }
    return lines.joined(separator: "\n")
  }
}
