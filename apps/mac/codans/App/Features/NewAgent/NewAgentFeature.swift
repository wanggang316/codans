import CodansCore
import ComposableArchitecture
import Foundation

/// Reducer backing the New Agent dialog (⌘⇧N, or the header's New Agent
/// button): pick a project, pick where the agent works — a new worktree or
/// an existing branch — write the first prompt, and send it to an agent.
///
/// The new-worktree form is `CreateWorktreeFeature` itself, embedded as a
/// child, so the dialog shares the Create Worktree sheet's defaults,
/// validation, and branch-collision rules instead of keeping a copy. The
/// dialog's own job ends at a delegate: `RootFeature` starts the pending
/// creation (whose agent launches once the worktree exists) or launches the
/// agent in an existing worktree.
@Reducer
struct NewAgentFeature {
  /// A project the dialog can target, snapshotted from the catalog when it
  /// opens.
  struct ProjectOption: Equatable, Identifiable {
    let id: ProjectID
    let name: String
    /// SF Symbol for the project's menu row. Menus draw SF Symbols only, so a
    /// custom project image falls back to the default glyph.
    let symbol: String
    /// A git project offers a new worktree or a branch. A folder or a
    /// workspace has one place to work, so the dialog offers neither.
    let isGit: Bool

    init(_ project: Project) {
      id = project.id
      name = project.name
      if case .symbol(let name) = project.icon {
        symbol = name
      } else {
        symbol = project.isWorkspace ? "square.stack.3d.up" : ProjectIconView.folderSymbol
      }
      isGit = project.supportsWorktrees && !project.isWorkspace
    }
  }

  /// Where the agent works in a git project.
  enum Target: Hashable {
    /// A worktree created from the dialog's branch name and options.
    case newWorktree
    /// A local branch name or a remote-tracking ref (`origin/feature`). A
    /// branch a worktree already holds sends the agent there; any other
    /// branch is checked out into a new worktree first.
    case branch(String)
  }

  /// The sidebar's Add Project menu, offered while no project exists.
  enum AddProjectKind: Equatable, CaseIterable {
    case openFolder
    case cloneRepository
    case connectServer
    case newWorkspace
  }

  @ObservableState
  struct State: Equatable {
    /// Project selected when the dialog opened; the dialog starts on it.
    let preferredProjectID: ProjectID?
    /// In-flight worktree creations per project, for the 8-creation cap.
    let pendingCounts: [ProjectID: Int]

    var projects: [ProjectOption] = []
    var projectID: ProjectID?
    var target: Target = .newWorktree
    /// The worktree options under the branch name (base ref, fetch, copy).
    var showsWorktreeOptions = false
    /// New-worktree form for the selected git project. `nil` for a folder or
    /// workspace project, and before a project is chosen.
    var worktree: CreateWorktreeFeature.State?
    /// Profiles the agent menu offers, in Settings order. The view supplies
    /// them because only it can see which agent CLIs are installed.
    var agentProfiles: [AgentProfile] = []
    var agentProfileID: UUID?
    var prompt = ""
    var submitError: String?

    init(preferredProjectID: ProjectID?, pendingCounts: [ProjectID: Int] = [:]) {
      self.preferredProjectID = preferredProjectID
      self.pendingCounts = pendingCounts
    }

    var selectedProject: ProjectOption? {
      projects.first { $0.id == projectID }
    }

    var selectedAgent: AgentProfile? {
      agentProfiles.first { $0.id == agentProfileID }
    }

    /// The branch-name field and the worktree options apply.
    var isCreatingWorktree: Bool {
      worktree != nil && target == .newWorktree
    }

    /// Local branches the target menu offers. A branch an archived worktree
    /// holds is left out: the sidebar hides that worktree, so sending an
    /// agent there would land somewhere the user cannot see. A server
    /// project offers only branches a worktree already holds, because
    /// checking out an existing branch over SSH is not supported.
    var localBranches: [String] {
      guard let form = worktree else { return [] }
      return form.localBranchNamesByLower
        .filter { lower, _ in
          form.archivedBranchOwnersByLower[lower] == nil
            && (!form.isRemote || form.liveWorktreeOwnersByLower[lower] != nil)
        }
        .map(\.value)
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Remote-tracking refs the target menu offers, in git's order.
    var remoteBranches: [String] {
      guard let form = worktree else { return [] }
      let locals = Set(form.localBranchNamesByLower.values)
      return form.baseRefOptions.filter { !locals.contains($0) }
    }

    var canSend: Bool {
      guard selectedProject != nil, selectedAgent != nil else { return false }
      guard isCreatingWorktree, let form = worktree else { return true }
      return !form.branchNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && form.validationError == nil
        && form.selectedBaseRef != nil
        && form.branchCollisionKind == .none
        && form.currentPendingCountForProject < 8
    }
  }

  enum Action: Equatable {
    case onAppear
    case projectSelected(ProjectID)
    case targetSelected(Target)
    case worktreeOptionsToggled
    case agentProfilesChanged([AgentProfile])
    case agentSelected(UUID)
    case promptChanged(String)
    case sendTapped
    case addProjectTapped(AddProjectKind)
    case manageAgentsTapped
    case cancelTapped
    case worktree(CreateWorktreeFeature.Action)
    case delegate(Delegate)

    enum Delegate: Equatable {
      /// Start the agent in an existing worktree and take the user there.
      case launchAgent(
        profileID: UUID, prompt: String?, projectID: ProjectID, worktreeID: WorktreeID)
      /// Create a worktree; `pending` carries the agent and prompt to launch
      /// once it exists.
      case createWorktree(PendingWorktree)
      /// Run the sidebar's Add Project flow. The dialog closes first.
      case addProject(AddProjectKind)
      /// Open Settings → Agents.
      case manageAgents
    }
  }

  @Dependency(HierarchyClient.self) private var hierarchyClient
  @Dependency(SettingsWriter.self) private var settingsWriter
  @Dependency(\.dismiss) private var dismiss

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .onAppear:
        let catalog = hierarchyClient.snapshot()
        state.projects = catalog.sorted(catalog.projects).map(ProjectOption.init)
        let initial =
          state.projects.first { $0.id == state.preferredProjectID } ?? state.projects.first
        guard let initial else { return .none }
        return selectProject(initial.id, state: &state)

      case .projectSelected(let projectID):
        guard projectID != state.projectID else { return .none }
        return selectProject(projectID, state: &state)

      case .targetSelected(let target):
        state.target = target
        state.submitError = nil
        return .none

      case .worktreeOptionsToggled:
        state.showsWorktreeOptions.toggle()
        return .none

      case .agentProfilesChanged(let profiles):
        state.agentProfiles = profiles
        if !profiles.contains(where: { $0.id == state.agentProfileID }) {
          state.agentProfileID = profiles.first?.id
        }
        return .none

      case .agentSelected(let profileID):
        state.agentProfileID = profileID
        return .none

      case .promptChanged(let prompt):
        state.prompt = prompt
        return .none

      case .sendTapped:
        return send(state: &state)

      case .addProjectTapped(let kind):
        return .send(.delegate(.addProject(kind)))

      case .manageAgentsTapped:
        return .send(.delegate(.manageAgents))

      case .cancelTapped:
        let dismiss = dismiss
        return .run { _ in await dismiss() }

      case .worktree(.delegate(.beginCreate(var pending))):
        // The embedded form validated the branch name and built the
        // creation; attach the agent and the prompt it starts with.
        pending.launchAgentProfileID = state.agentProfileID
        pending.launchAgentPrompt = Self.normalizedPrompt(state.prompt)
        return .send(.delegate(.createWorktree(pending)))

      case .worktree:
        return .none

      case .delegate:
        return .none
      }
    }
    .ifLet(\.worktree, action: \.worktree) {
      CreateWorktreeFeature()
    }
  }

  private func selectProject(_ projectID: ProjectID, state: inout State) -> Effect<Action> {
    state.projectID = projectID
    state.target = .newWorktree
    state.submitError = nil
    let project = hierarchyClient.snapshot().projects.first { $0.id == projectID }
    guard let project, project.supportsWorktrees, !project.isWorkspace else {
      state.worktree = nil
      return .none
    }
    var form = CreateWorktreeFeature.State.seeded(
      for: project,
      settings: settingsWriter.readSnapshotSync(),
      pendingCount: state.pendingCounts[projectID] ?? 0
    )
    // The dialog's own agent menu decides what launches.
    form?.agentProfiles = []
    form?.launchAgentProfileID = nil
    state.worktree = form
    return form == nil ? .none : .send(.worktree(.onAppear))
  }

  private func send(state: inout State) -> Effect<Action> {
    guard state.canSend, let projectID = state.projectID, let profileID = state.agentProfileID
    else { return .none }
    state.submitError = nil
    let prompt = Self.normalizedPrompt(state.prompt)
    guard let project = hierarchyClient.snapshot().projects.first(where: { $0.id == projectID })
    else {
      state.submitError = "This project is no longer open."
      return .none
    }
    guard let form = state.worktree else {
      // A folder or workspace project: its one worktree.
      let worktree =
        project.worktrees.first { $0.id == project.selectedWorktreeID && !$0.archived }
        ?? project.worktrees.first { !$0.archived }
      guard let worktree else {
        state.submitError = "This project has no folder to start the agent in."
        return .none
      }
      return .send(
        .delegate(
          .launchAgent(
            profileID: profileID, prompt: prompt, projectID: projectID, worktreeID: worktree.id)))
    }
    switch state.target {
    case .newWorktree:
      // The form validates and answers with `.delegate(.beginCreate)`.
      return .send(.worktree(.createButtonTapped))
    case .branch(let ref):
      return checkOut(
        ref, in: project, form: form, profileID: profileID, prompt: prompt, state: &state)
    }
  }

  /// Sends the agent to the worktree holding `ref`'s branch, or checks the
  /// branch out into a new worktree first. A remote-tracking ref whose
  /// branch has no local copy becomes a new local branch from that ref.
  private func checkOut(
    _ ref: String, in project: Project, form: CreateWorktreeFeature.State,
    profileID: UUID, prompt: String?, state: inout State
  ) -> Effect<Action> {
    let locals = Set(form.localBranchNamesByLower.values)
    let branch: String
    var remoteRef: String?
    if locals.contains(ref) {
      branch = ref
    } else if let slash = ref.firstIndex(of: "/") {
      branch = String(ref[ref.index(after: slash)...])
      if !locals.contains(branch) { remoteRef = ref }
    } else {
      state.submitError = "\"\(ref)\" is not a branch of this project."
      return .none
    }

    if let worktree = project.worktrees.first(where: { !$0.archived && $0.branch == branch }) {
      return .send(
        .delegate(
          .launchAgent(
            profileID: profileID, prompt: prompt, projectID: project.id, worktreeID: worktree.id)))
    }
    let lower = branch.lowercased()
    if let owner = form.archivedBranchOwnersByLower[lower] {
      state.submitError =
        "\"\(owner.branch)\" belongs to the archived worktree \"\(owner.worktreeName)\". "
        + "Unarchive it first, or choose another branch."
      return .none
    }
    if let owner = form.liveWorktreeOwnersByLower[lower] {
      state.submitError =
        "\"\(owner.branch)\" is checked out by the worktree \"\(owner.worktreeName)\", "
        + "which codans does not list. Add it to the project first."
      return .none
    }
    if remoteRef == nil && form.isRemote {
      state.submitError = "Checking out an existing branch is not supported on a server project."
      return .none
    }
    guard form.currentPendingCountForProject < 8 else {
      state.submitError = CreateWorktreeFeature.capMessage
      return .none
    }
    let directory = GitWorktreeClient.sanitizeBranchName(branch)
    let target = form.worktreesDirectory.appending(path: directory)
    if !form.isRemote, FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
      state.submitError =
        "A folder named \"\(directory)\" already exists in the project's worktrees directory."
      return .none
    }
    let spec = CreateWorktreeSpec(
      repoRoot: form.repoRoot,
      baseDirectory: form.worktreesDirectory,
      name: branch,
      baseRef: remoteRef ?? "",
      fetchOrigin: remoteRef != nil && form.fetchOrigin,
      copyIgnored: form.copyIgnored,
      copyUntracked: form.copyUntracked,
      // `wt` checks out an existing local branch only into a named path.
      pathOverride: form.isRemote ? nil : target
    )
    let pending = PendingWorktree(
      id: PendingWorktreeID(),
      projectID: project.id,
      remoteHost: form.remoteHost,
      spec: spec,
      displayName: branch,
      status: .running,
      lastProgressLine: nil,
      startedAt: Date(),
      launchAgentProfileID: profileID,
      launchAgentPrompt: prompt
    )
    return .send(.delegate(.createWorktree(pending)))
  }

  /// The prompt as the agent receives it; blank means none.
  static func normalizedPrompt(_ prompt: String) -> String? {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
