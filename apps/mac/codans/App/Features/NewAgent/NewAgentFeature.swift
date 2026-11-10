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
  /// Where the agent works in a git project.
  enum Target: Hashable {
    /// A worktree created from the dialog's branch name and options.
    case newWorktree
    /// A local branch name or a remote-tracking ref (`origin/feature`). A
    /// branch a worktree already holds sends the agent there; any other
    /// branch is checked out into a new worktree first.
    case branch(String)
  }

  /// The agent and the directory a skill scan reads for.
  struct SkillScope: Equatable {
    let profile: AgentProfile
    /// Where the agent starts, for its project-level skills.
    let projectStart: URL?
    /// Where the files of the worktree the agent starts in come from, when
    /// the target creates one. `projectStart` is then the main checkout,
    /// and the project files are read from a view of the new worktree
    /// (ADR 0010).
    var newWorktree: NewWorktreeSource?
  }

  /// The sidebar's Add Project menu, offered while no project exists.
  enum AddProjectKind: Equatable, CaseIterable {
    case openFolder
    case cloneRepository
    case openRemoteProject
    case newWorkspace
  }

  /// What the user set in a dialog they closed without sending. The next
  /// open restores it, so a half-written prompt is not lost. Kept in memory
  /// only, for the app session.
  struct Draft: Equatable {
    var projectID: ProjectID
    var target: Target
    var showsWorktreeOptions: Bool
    var branchName: String
    var baseRef: String?
    var fetchOrigin: Bool
    var copyIgnored: Bool
    var copyUntracked: Bool
    var agentProfileID: UUID?
    var prompt: String
  }

  @ObservableState
  struct State: Equatable {
    /// Project selected when the dialog opened; the dialog starts on it.
    let preferredProjectID: ProjectID?
    /// In-flight worktree creations per project, for the 8-creation cap.
    let pendingCounts: [ProjectID: Int]

    /// Every project, in catalog order.
    var projects: [ProjectMenuOption] = []
    var projectMenu = ProjectMenu.empty
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
    /// Agent Skills the selected agent can call, for prompt completion.
    var skills: [AgentSkillEntry] = []
    /// What `skills` were read for. The profile's home and environment and
    /// the directory the agent starts in decide which skills exist, so the
    /// skills of another scope are never shown.
    var skillsScope: SkillScope?
    var submitError: String?
    /// Draft to restore on appear. The worktree part waits until the form's
    /// options load: the base ref, the branch-name checks, and the branch
    /// list all need them.
    var restoring: Draft?

    init(
      preferredProjectID: ProjectID?, pendingCounts: [ProjectID: Int] = [:],
      restoring draft: Draft? = nil
    ) {
      self.preferredProjectID = preferredProjectID
      self.pendingCounts = pendingCounts
      self.restoring = draft
    }

    /// The current choices, for the next open. `nil` before a project is
    /// chosen.
    var draft: Draft? {
      guard let projectID else { return nil }
      return Draft(
        projectID: projectID,
        target: target,
        showsWorktreeOptions: showsWorktreeOptions,
        branchName: worktree?.branchNameDraft ?? "",
        baseRef: worktree?.selectedBaseRef,
        fetchOrigin: worktree?.fetchOrigin ?? true,
        copyIgnored: worktree?.copyIgnored ?? false,
        copyUntracked: worktree?.copyUntracked ?? false,
        agentProfileID: agentProfileID,
        prompt: prompt
      )
    }

    var selectedProject: ProjectMenuOption? {
      projects.first { $0.id == projectID }
    }

    var selectedAgent: AgentProfile? {
      agentProfiles.first { $0.id == agentProfileID }
    }

    /// How the prompt calls the selected agent's skills. `none` without an
    /// agent and in a remote project (ADR 0010).
    var skillLocation: SkillLocation {
      guard let agent = selectedAgent, selectedProject?.isRemote == false else { return .none }
      return agent.descriptor.skillLocation
    }

    /// Why the prompt offers no skills, for the Skills button's tooltip.
    /// `nil` when typing the call prefix opens the list.
    var skillsUnavailableReason: String? {
      guard selectedProject != nil else { return "Add a project to see its skills" }
      guard let agent = selectedAgent else { return "Choose an agent to see its skills" }
      return ComposerSkillCompletion.unavailableReason(
        for: agent.descriptor, isRemote: selectedProject?.isRemote == true)
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
    /// Picked files, and the prompt's caret or selection as UTF-16 offsets
    /// (`nil` appends to the end).
    case filesSelected([URL], selection: Range<Int>?)
    case skillsLoaded([AgentSkillEntry], for: SkillScope)
    /// The Skills button: put the call prefix at the prompt's caret or
    /// selection (UTF-16 offsets, `nil` for the end), so the list opens.
    case skillsButtonTapped(selection: Range<Int>?)
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
  @Dependency(AgentSkillClient.self) private var agentSkillClient
  @Dependency(SettingsWriter.self) private var settingsWriter
  @Dependency(\.dismiss) private var dismiss

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .onAppear:
        let catalog = hierarchyClient.snapshot()
        state.projects = catalog.projects.map(ProjectMenuOption.init)
        state.projectMenu = ProjectMenu(catalog)
        if let draft = state.restoring,
          state.projects.contains(where: { $0.id == draft.projectID })
        {
          return restore(draft, state: &state)
        }
        state.restoring = nil
        let initial =
          state.projects.first { $0.id == state.preferredProjectID } ?? state.projects.first
        guard let initial else { return .none }
        return selectProject(initial.id, state: &state)

      case .projectSelected(let projectID):
        guard projectID != state.projectID else { return .none }
        return .merge(selectProject(projectID, state: &state), loadSkills(state: &state))

      case .targetSelected(let target):
        state.target = target
        state.submitError = nil
        return loadSkills(state: &state)

      case .worktreeOptionsToggled:
        state.showsWorktreeOptions.toggle()
        return .none

      case .agentProfilesChanged(let profiles):
        state.agentProfiles = profiles
        if !profiles.contains(where: { $0.id == state.agentProfileID }) {
          state.agentProfileID = profiles.first?.id
        }
        return loadSkills(state: &state)

      case .agentSelected(let profileID):
        state.agentProfileID = profileID
        return loadSkills(state: &state)

      case .promptChanged(let prompt):
        state.prompt = prompt
        return .none

      case .filesSelected(let urls, let selection):
        if let result = ComposerPathInsertion.insert(urls, into: state.prompt, selection: selection) {
          state.prompt = result.text
        }
        return .none

      case .skillsLoaded(let skills, let scope):
        // A scan that finished after the agent, project, or target changed
        // is dropped.
        guard state.skillLocation.supportsCompletion, skillScope(state: state) == scope else {
          return .none
        }
        state.skills = skills
        state.skillsScope = scope
        return .none

      case .skillsButtonTapped(let selection):
        let location = state.skillLocation
        guard state.skillsUnavailableReason == nil, let prefix = location.invocationStyle.prefix,
          let result = ComposerSkillCompletion.insertingPrefix(
            prefix, into: state.prompt, selection: selection, position: location.invocationPosition)
        else { return .none }
        state.prompt = result.text
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

      case .worktree(.copyIgnoredToggled), .worktree(.copyUntrackedToggled), .worktree(.baseRefSelected):
        // The base ref and the copy options decide which project files the
        // new worktree has. A target in an existing worktree keeps its scope
        // and list.
        guard skillScope(state: state) != state.skillsScope else { return .none }
        return loadSkills(state: &state)

      case .worktree(.optionsLoaded):
        guard let draft = state.restoring else {
          // The loaded options pick the base ref a new worktree starts from.
          guard skillScope(state: state) != state.skillsScope else { return .none }
          return loadSkills(state: &state)
        }
        state.restoring = nil
        return .merge(restoreWorktree(draft, state: &state), loadSkills(state: &state))

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

  private nonisolated enum CancelID { case skills }

  /// Reads the selected agent's skills again. The agent's home and
  /// environment come from the profile, so a profile edit reloads too.
  /// When the profile or the start directory changes, the old skills go at
  /// once instead of when the scan ends (ADR 0010).
  private func loadSkills(state: inout State) -> Effect<Action> {
    guard state.skillLocation.supportsCompletion, let scope = skillScope(state: state) else {
      state.skills = []
      state.skillsScope = nil
      return .cancel(id: CancelID.skills)
    }
    if state.skillsScope != scope {
      state.skills = []
      state.skillsScope = nil
    }
    let client = agentSkillClient
    return .run { send in
      await send(
        .skillsLoaded(
          client.load(scope.profile, scope.projectStart, scope.newWorktree), for: scope))
    }
    .cancellable(id: CancelID.skills, cancelInFlight: true)
  }

  /// The selected agent and the directory it would start in for the
  /// selected project and target.
  private func skillScope(state: State) -> SkillScope? {
    guard let profile = state.selectedAgent else { return nil }
    let project = hierarchyClient.snapshot().projects.first { $0.id == state.projectID }
    var branch: String?
    // The ref a new worktree gets its tracked files from: the base ref for
    // New Worktree; for a branch no worktree holds, the local branch, else
    // the remote ref a new local branch is made from.
    var sourceRef = state.worktree?.selectedBaseRef
    if case .branch(let ref) = state.target, let form = state.worktree {
      let resolved = Self.branch(for: ref, locals: Set(form.localBranchNamesByLower.values))
      branch = resolved?.name
      sourceRef = resolved.map { $0.remoteRef ?? $0.name }
    }
    var newWorktree: NewWorktreeSource?
    if let project, let form = state.worktree,
      SkillLocationResolver.createsWorktree(in: project, branch: branch)
    {
      newWorktree = NewWorktreeSource(
        ref: sourceRef, copyIgnored: form.copyIgnored, copyUntracked: form.copyUntracked)
    }
    return SkillScope(
      profile: profile,
      projectStart: project.flatMap {
        SkillLocationResolver.projectStartDirectory(in: $0, branch: branch)
      },
      newWorktree: newWorktree)
  }

  /// Puts back what `onAppear` can set at once. The form is seeded fresh, so
  /// the pending count and the branch lists are current.
  private func restore(_ draft: Draft, state: inout State) -> Effect<Action> {
    let load = selectProject(draft.projectID, state: &state)
    state.showsWorktreeOptions = draft.showsWorktreeOptions
    state.agentProfileID = draft.agentProfileID
    state.prompt = draft.prompt
    guard state.worktree != nil else {
      state.restoring = nil
      return load
    }
    state.target = draft.target
    state.worktree?.branchNameDraft = draft.branchName
    state.worktree?.fetchOrigin = draft.fetchOrigin
    state.worktree?.copyIgnored = draft.copyIgnored
    state.worktree?.copyUntracked = draft.copyUntracked
    return load
  }

  /// Puts back the parts that need the loaded options. A base ref or a
  /// branch that is gone falls back to the default.
  private func restoreWorktree(_ draft: Draft, state: inout State) -> Effect<Action> {
    guard let form = state.worktree else { return .none }
    if let ref = draft.baseRef, form.baseRefOptions.contains(ref) {
      state.worktree?.selectedBaseRef = ref
    }
    if case .branch(let ref) = state.target,
      !state.localBranches.contains(ref) && !state.remoteBranches.contains(ref)
    {
      state.target = .newWorktree
    }
    // Runs the name checks the restored text skipped.
    return .send(.worktree(.branchDraftChanged(form.branchNameDraft)))
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
      guard let worktree = project.soleWorkingWorktree else {
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
    guard let (branch, remoteRef) = Self.branch(for: ref, locals: Set(form.localBranchNamesByLower.values))
    else {
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
      state.submitError = "Checking out an existing branch is not supported on a remote project."
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

  /// The local branch `ref` names, and the remote-tracking ref to create it
  /// from when no local copy exists. `nil` when `ref` is neither a local
  /// branch nor a remote-tracking ref.
  static func branch(for ref: String, locals: Set<String>) -> (name: String, remoteRef: String?)? {
    if locals.contains(ref) { return (ref, nil) }
    guard let slash = ref.firstIndex(of: "/") else { return nil }
    let name = String(ref[ref.index(after: slash)...])
    return (name, locals.contains(name) ? nil : ref)
  }

  /// The prompt as the agent receives it; blank means none.
  static func normalizedPrompt(_ prompt: String) -> String? {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
