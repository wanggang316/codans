import CodansCore
import ComposableArchitecture
import Foundation

/// Reducer behind the Workspace sheets, one per mode:
/// - Add Workspace: a title, where the folder goes, and the source projects
///   the `default` group references. No branch is chosen; sources stay as
///   they are.
/// - Add Project: one more source project for an existing Workspace.
/// - New Group: a name and one branch for every project of the Workspace,
///   each project with its own base ref, fetch, copy and agent options.
///
/// Hands the result to `WorkspaceClient` and shows its progress. Its
/// responsibility ends at a delegate: the client has registered and
/// reconciled by then. Group mode keeps its input after a failure so Create
/// can retry, and lists what a rollback could not remove.
@Reducer
struct CreateWorkspaceFeature {
  /// A registered local git Project offered as a source.
  struct Candidate: Equatable, Identifiable, Sendable {
    let id: ProjectID
    let name: String
    let gitRoot: String
    var icon: ProjectIcon?
    var color: ProjectColor?

    init(id: ProjectID, name: String, gitRoot: String, icon: ProjectIcon? = nil, color: ProjectColor? = nil) {
      self.id = id
      self.name = name
      self.gitRoot = gitRoot
      self.icon = icon
      self.color = color
    }
  }

  enum Mode: Equatable, Sendable {
    case addWorkspace
    /// One source project for an existing Workspace. `existingSourceRoots`
    /// are the source main checkouts it already lists.
    case addSource(projectID: ProjectID, title: String, rootPath: String, existingSourceRoots: Set<String>)
    /// A new named group in an existing Workspace.
    case newGroup(projectID: ProjectID, title: String, rootPath: String)
  }

  enum CreationState: Equatable, Sendable {
    case idle
    /// `current` names the group member being worked on, if any.
    case running(current: String?)
    case finalizing(String)
    case rollingBack
    /// Rolled back after a cancel; `failures` names what needs a hand.
    case rolledBack(failures: [String])
    /// Rolled back after an error. `residuals` names what the rollback
    /// could not remove, with the reason.
    case failed(message: String, residuals: [String])
    /// The group exists, but a setup command failed; the members show
    /// which. Only Done is left.
    case createdWithSetupFailures

    var isBusy: Bool {
      switch self {
      case .running, .finalizing, .rollingBack: return true
      case .idle, .rolledBack, .failed, .createdWithSetupFailures: return false
      }
    }

    /// A finished attempt whose outcome is still on screen; the next edit
    /// or Create clears it.
    var isSettled: Bool {
      switch self {
      case .rolledBack, .failed: return true
      case .idle, .running, .finalizing, .rollingBack, .createdWithSetupFailures: return false
      }
    }
  }

  @ObservableState
  struct State: Equatable {
    var mode: Mode
    var candidates: IdentifiedArrayOf<Candidate>

    // MARK: Add Workspace / Add Project

    var titleDraft = ""
    /// The folder the workspace folder is created in; the workspace folder
    /// itself is named after the title.
    var locationPath: String
    /// Preflight findings about the workspace folder.
    var rootIssues: [MemberIssue] = []
    var sources: IdentifiedArrayOf<SourceDraft> = []
    /// Why the folder picked last can't be added.
    var sourceIssue: String?
    var isResolvingFolder = false
    /// The Add Remote dialog, while it is open.
    var remoteEditor: RemoteSourceEditor?

    // MARK: New Group

    var groupName = ""
    /// Empty uses the group name.
    var branchDraft = ""
    /// Group-level preflight findings: name, folder, and branch.
    var groupPreflightIssues: [WorkspacePreflight.Issue] = []
    var groupMembers: IdentifiedArrayOf<GroupMemberDraft> = []
    /// Enabled agent profiles offered per project.
    var agentProfiles: [AgentProfile] = []
    /// The projects and their defaults are still loading.
    var isLoadingMembers = false

    var creation: CreationState = .idle
    var creationToken: UUID?

    init(
      candidates: [Candidate],
      mode: Mode = .addWorkspace,
      locationPath: String = WorkspaceLayout.defaultWorkspacesDirectory().path(percentEncoded: false)
    ) {
      self.mode = mode
      self.candidates = IdentifiedArray(uniqueElements: candidates)
      self.locationPath = locationPath
      switch mode {
      case .addSource(_, let title, _, _):
        titleDraft = title
      case .newGroup:
        isLoadingMembers = true
      case .addWorkspace:
        break
      }
    }

    var isGroupMode: Bool {
      if case .newGroup = mode { return true }
      return false
    }

    var isAddSourceMode: Bool {
      if case .addSource = mode { return true }
      return false
    }

    var rootPath: String {
      switch mode {
      case .addSource(_, _, let rootPath, _), .newGroup(_, _, let rootPath):
        return rootPath
      case .addWorkspace:
        guard !titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return (locationPath as NSString).appendingPathComponent(WorkspaceLayout.folderName(forTitle: titleDraft))
      }
    }

    var createButtonTitle: String {
      switch mode {
      case .addSource: return "Add"
      case .addWorkspace, .newGroup: return "Create"
      }
    }

    var canCreate: Bool {
      guard !creation.isBusy, creation != .createdWithSetupFailures else { return false }
      switch mode {
      case .addWorkspace, .addSource: return sourcePlanIsReady
      case .newGroup: return groupPlan != nil
      }
    }

    /// Why Create is disabled, for the bottom bar: the first thing still
    /// missing, or a pointer to the problems shown in the form.
    var createHint: String? {
      guard creation == .idle, !canCreate else { return nil }
      let all = isGroupMode ? allGroupIssues : allSourceIssues
      if let missing = all.first(where: { $0.severity == .incomplete }) { return missing.message }
      if all.contains(where: { $0.severity == .blocking }) { return "Fix the problems above to continue." }
      return nil
    }

    // MARK: Sources

    /// One source is the whole plan when adding to an existing Workspace.
    var canAddSources: Bool {
      !isAddSourceMode || sources.isEmpty
    }

    /// Source main checkouts the Workspace already lists, canonical.
    var listedSourceRoots: Set<String> {
      guard case .addSource(_, _, _, let roots) = mode else { return [] }
      return Set(roots.map(HierarchyManager.canonicalPath))
    }

    /// Open projects not listed in the sheet or the Workspace.
    var availableCandidates: [Candidate] {
      let used = Set(
        sources.compactMap { source -> ProjectID? in
          guard case .project(let id, _, _) = source.source else { return nil }
          return id
        })
      let listed = listedSourceRoots
      return candidates.filter {
        !used.contains($0.id) && !listed.contains(HierarchyManager.canonicalPath($0.gitRoot))
      }
    }

    var sourcePlan: WorkspaceSourcePlan {
      WorkspaceSourcePlan(
        title: titleDraft.trimmingCharacters(in: .whitespacesAndNewlines),
        rootPath: rootPath,
        sources: sources.map(\.source.workspaceSource))
    }

    func issues(for source: SourceDraft) -> [MemberIssue] {
      source.preflightIssues.map(MemberIssue.init(preflight:))
    }

    /// Workspace-level issues: what is still missing, then preflight.
    var workspaceIssues: [MemberIssue] {
      var issues: [MemberIssue] = []
      if case .addWorkspace = mode, titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        issues.append(.incomplete("Enter a title."))
      }
      if sources.isEmpty {
        issues.append(.incomplete("Add a project."))
      }
      issues.append(contentsOf: rootIssues)
      return issues
    }

    private var allSourceIssues: [MemberIssue] {
      workspaceIssues + sources.flatMap { issues(for: $0) }
    }

    private var sourcePlanIsReady: Bool {
      remoteEditor == nil && !isResolvingFolder && !allSourceIssues.contains(where: \.blocksCreation)
    }

    // MARK: Remote dialog

    /// The open dialog's findings.
    func issues(inEditor editor: RemoteSourceEditor) -> [MemberIssue] {
      if let sourceIssue = editor.sourceIssue { return [.blocking(sourceIssue)] }
      if !editor.isURLApplied { return [.incomplete("Enter a git URL, such as git@github.com:org/repo.git.")] }
      return []
    }

    func canSave(inEditor editor: RemoteSourceEditor) -> Bool {
      editor.draft != nil && !issues(inEditor: editor).contains(where: \.blocksCreation)
    }

    /// A dialog or picker opens only when there is room for another
    /// source, no dialog is open, and nothing is being created.
    var canOpenEditor: Bool {
      canAddSources && remoteEditor == nil && !creation.isBusy
    }

    // MARK: Group

    /// The branch every member is created on.
    var groupBranch: String {
      let branch = branchDraft.trimmingCharacters(in: .whitespacesAndNewlines)
      return branch.isEmpty ? groupName.trimmingCharacters(in: .whitespacesAndNewlines) : branch
    }

    var groupDraftPlan: WorkspaceGroupPlan? {
      guard case .newGroup(let projectID, _, _) = mode else { return nil }
      return WorkspaceGroupPlan(
        projectID: projectID,
        name: groupName.trimmingCharacters(in: .whitespacesAndNewlines),
        branch: groupBranch,
        members: groupMembers.map(\.options))
    }

    /// The plan when nothing blocks it.
    var groupPlan: WorkspaceGroupPlan? {
      allGroupIssues.contains(where: \.blocksCreation) ? nil : groupDraftPlan
    }

    /// Findings about the name and the branch, and about the Workspace's
    /// project list.
    var groupIssues: [MemberIssue] {
      var issues: [MemberIssue] = []
      if isLoadingMembers {
        issues.append(.incomplete("Loading the workspace\u{2019}s projects\u{2026}"))
      } else if groupMembers.isEmpty {
        issues.append(.blocking("The workspace has no projects. Add one in Workspace Settings first."))
      }
      if groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        issues.append(.incomplete("Enter a group name."))
        return issues
      }
      if BranchNameSyntax.quickCheck(groupBranch) != nil {
        issues.append(.blocking("\u{201C}\(groupBranch)\u{201D} is not a valid branch name."))
      }
      for issue in groupPreflightIssues.map(MemberIssue.init(preflight:))
      where !issues.contains(issue) {
        issues.append(issue)
      }
      return issues
    }

    /// One project's findings: its branches, then the client's preflight
    /// (a branch the group would create that already exists is reported
    /// here, under the project that has it).
    func issues(for member: GroupMemberDraft) -> [MemberIssue] {
      var issues: [MemberIssue] = []
      if case .failed(let message) = member.refs {
        issues.append(.warning(message))
      }
      issues.append(contentsOf: member.preflightIssues.map(MemberIssue.init(preflight:)))
      return issues
    }

    private var allGroupIssues: [MemberIssue] {
      groupIssues + groupMembers.flatMap { issues(for: $0) }
    }
  }

  enum Action: Equatable {
    // Workspace
    case titleChanged(String)
    case chooseLocationTapped
    case locationPicked(URL?)
    // Sources
    case addProjectTapped(ProjectID)
    case addFolderTapped
    case addFolderPicked(URL?)
    case folderResolved(path: String, probe: RepositoryProbe?)
    case addRemoteTapped
    case editRemoteTapped(UUID)
    case removeSourceTapped(UUID)
    case remote(RemoteAction)
    // Group
    case onAppear
    case groupDefaultsLoaded([MemberCreationOptions], agentProfiles: [AgentProfile])
    case groupNameChanged(String)
    case branchChanged(String)
    case groupMember(String, GroupMemberAction)
    // Validation
    case preflightTick
    case preflightFinished(WorkspacePreflight)
    // Creation
    case createButtonTapped
    case creationEvent(WorkspaceCreationEvent)
    case creationFailed(message: String, cancelled: Bool)
    case cancelButtonTapped
    case delegate(Delegate)

    enum RemoteAction: Equatable {
      case urlChanged(String)
      /// Typing paused; a URL is applied, anything else waits for Return.
      case urlSettled
      case urlSubmitted
      case chooseCloneDestinationTapped
      case cloneDestinationPicked(URL?)
      case saveTapped
      case cancelTapped
    }

    enum GroupMemberAction: Equatable {
      case baseRefChanged(String?)
      case fetchChanged(Bool)
      case copyIgnoredChanged(Bool)
      case copyUntrackedChanged(Bool)
      case agentChanged(UUID?)
      case retryRefsTapped
      case refsLoaded(RefInventory)
      case refsFailed(String)
    }

    @CasePathable
    enum Delegate: Equatable {
      case dismissed
      /// The workspace is on disk, registered, and reconciled.
      case created(ProjectID)
      /// The source is in the Workspace and its reference row registered.
      case added(ProjectID, WorktreeID)
      /// The group exists with every checkout. Its agents have not been
      /// started; the result says which to start.
      case groupCreated(GroupCreationResult)
    }
  }

  nonisolated enum CancelID: Hashable, Sendable {
    case refs(String)
    case folderResolve
    case urlSettle
    case preflight
    case creation
  }

  nonisolated static let preflightDebounce: Duration = .milliseconds(300)
  private nonisolated static let urlSettleDelay: Duration = .milliseconds(600)

  @Dependency(WorkspaceClient.self) var workspaceClient
  @Dependency(GitWorktreeClient.self) var gitWorktreeClient
  @Dependency(FolderPickerClient.self) private var folderPicker
  @Dependency(GitWorktreeCLI.self) private var gitCLI
  @Dependency(SettingsWriter.self) var settingsWriter
  @Dependency(\.continuousClock) var clock
  @Dependency(\.uuid) var uuid
  @Dependency(FileExistsDependencyKey.self) private var fileExists

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      // MARK: Workspace

      case .titleChanged(let title):
        state.titleDraft = title
        return edited(&state)

      case .chooseLocationTapped:
        return .run { [picker = folderPicker] send in
          await send(.locationPicked(await picker.pick("Choose Location")))
        }

      case .locationPicked(let url):
        guard let url else { return .none }
        state.locationPath = (url.path(percentEncoded: false) as NSString).standardizingPath
        return edited(&state)

      // MARK: Sources

      case .addProjectTapped(let projectID):
        guard state.canOpenEditor, let candidate = state.availableCandidates.first(where: { $0.id == projectID })
        else { return .none }
        state.sourceIssue = nil
        state.sources.append(
          SourceDraft(id: uuid(), source: .project(candidate.id, name: candidate.name, gitRoot: candidate.gitRoot)))
        return edited(&state)

      case .addFolderTapped:
        guard state.canOpenEditor else { return .none }
        return .run { [picker = folderPicker] send in
          await send(.addFolderPicked(await picker.pick("Add Folder")))
        }

      case .addFolderPicked(let url):
        guard let url, state.canOpenEditor else { return .none }
        state.sourceIssue = nil
        state.isResolvingFolder = true
        let path = url.path(percentEncoded: false)
        return .run { [cli = gitCLI] send in
          let probe = try? await cli.inspectRepository(at: path)
          await send(.folderResolved(path: path, probe: probe))
        }
        .cancellable(id: CancelID.folderResolve, cancelInFlight: true)

      case .folderResolved(let path, let probe):
        state.isResolvingFolder = false
        return useFolder(path, probe: probe, &state)

      case .addRemoteTapped:
        guard state.canOpenEditor else { return .none }
        state.sourceIssue = nil
        state.remoteEditor = RemoteSourceEditor(id: uuid(), isNew: true)
        return .none

      case .editRemoteTapped(let id):
        guard let source = state.sources[id: id], source.source.isRemote, state.remoteEditor == nil,
          !state.creation.isBusy
        else { return .none }
        state.remoteEditor = RemoteSourceEditor(id: id, isNew: false, draft: source)
        return .none

      case .removeSourceTapped(let id):
        guard state.sources[id: id] != nil, state.remoteEditor == nil, !state.creation.isBusy else { return .none }
        state.sources.remove(id: id)
        return edited(&state)

      case .remote(let remoteAction):
        guard state.remoteEditor != nil else { return .none }
        return reduceRemote(remoteAction, state: &state)

      // MARK: Group

      case .onAppear:
        guard case .newGroup(let projectID, _, _) = state.mode, state.isLoadingMembers else { return .none }
        return .run { [client = workspaceClient, settings = settingsWriter] send in
          let defaults = await client.groupCreationDefaults(projectID)
          // Async read: this effect resumes off the main actor, where the
          // synchronous read traps.
          let profiles = await settings.readSnapshot().agents.enabledProfiles
          await send(.groupDefaultsLoaded(defaults, agentProfiles: profiles))
        }

      case .groupDefaultsLoaded(let defaults, let profiles):
        return membersLoaded(defaults, agentProfiles: profiles, state: &state)

      case .groupNameChanged(let name):
        state.groupName = name
        return edited(&state)

      case .branchChanged(let branch):
        state.branchDraft = branch
        return edited(&state)

      case .groupMember(let id, let memberAction):
        guard state.groupMembers[id: id] != nil else { return .none }
        return reduceGroupMember(id: id, action: memberAction, state: &state)

      // MARK: Validation

      case .preflightTick:
        guard state.creation == .idle else { return .none }
        return preflight(state)

      case .preflightFinished(let result):
        applyPreflight(result, to: &state)
        return .none

      // MARK: Creation

      case .createButtonTapped:
        guard state.canCreate else { return .none }
        switch state.mode {
        case .addWorkspace:
          return startWorkspaceCreation(&state)
        case .addSource(let projectID, _, _, _):
          return startSourceAddition(projectID: projectID, &state)
        case .newGroup:
          guard let plan = state.groupPlan else { return .none }
          return startGroupCreation(plan, &state)
        }

      case .creationEvent(let event):
        return reduceGroupEvent(event, state: &state)

      case .creationFailed(let message, let cancelled):
        var residuals: [String] = []
        if case .rolledBack(let failures) = state.creation { residuals = failures }
        state.creation = cancelled ? .rolledBack(failures: residuals) : .failed(message: message, residuals: residuals)
        return .none

      case .cancelButtonTapped:
        switch state.creation {
        case .idle, .rolledBack, .failed, .createdWithSetupFailures:
          return .merge(.cancel(id: CancelID.preflight), .send(.delegate(.dismissed)))
        case .running:
          guard state.isGroupMode else {
            // Workspace creation rolls back what it made when its task is
            // cancelled; nothing is left to report.
            state.creation = .rolledBack(failures: [])
            return .cancel(id: CancelID.creation)
          }
          guard let token = state.creationToken else { return .none }
          state.creation = .rollingBack
          return .run { [client = workspaceClient] _ in await client.cancelCreation(token) }
        case .finalizing, .rollingBack:
          // Past the checkouts the group is being registered or set up, and
          // a rollback is already running; neither can stop half way.
          return .none
        }

      case .delegate:
        return .none
      }
    }
  }

  // MARK: - Sources

  /// A picked folder as a source: its repository, which may be an open
  /// project, unless it can't be used.
  private func useFolder(_ path: String, probe: RepositoryProbe?, _ state: inout State) -> Effect<Action> {
    let shown = (path as NSString).abbreviatingWithTildeInPath
    guard let probe else {
      state.sourceIssue = "\(shown) is not a git repository."
      return .none
    }
    guard !probe.isBare else {
      state.sourceIssue = "\(shown) is a bare repository, which workspaces do not support."
      return .none
    }
    let root = HierarchyManager.canonicalPath(probe.root)
    let abbreviated = (root as NSString).abbreviatingWithTildeInPath
    if state.listedSourceRoots.contains(root) {
      state.sourceIssue = "\(abbreviated) is already part of this workspace."
      return .none
    }
    if state.sources.contains(where: {
      !$0.source.isRemote && HierarchyManager.canonicalPath($0.source.gitRoot) == root
    }) {
      state.sourceIssue = "\(abbreviated) is already in the list."
      return .none
    }
    let source: SourceDraft.Source
    if let candidate = state.candidates.first(where: { HierarchyManager.canonicalPath($0.gitRoot) == root }) {
      source = .project(candidate.id, name: candidate.name, gitRoot: candidate.gitRoot)
    } else {
      source = .localRepo(gitRoot: root)
    }
    state.sources.append(SourceDraft(id: uuid(), source: source))
    return edited(&state)
  }

  private func reduceRemote(_ action: Action.RemoteAction, state: inout State) -> Effect<Action> {
    switch action {
    case .urlChanged(let text):
      state.remoteEditor?.urlText = text
      state.remoteEditor?.sourceIssue = nil
      return .run { [clock] send in
        try await clock.sleep(for: Self.urlSettleDelay)
        await send(.remote(.urlSettled))
      }
      .cancellable(id: CancelID.urlSettle, cancelInFlight: true)

    case .urlSettled:
      applyURL(&state, reportsProblems: false)
      return .none

    case .urlSubmitted:
      applyURL(&state, reportsProblems: true)
      return .cancel(id: CancelID.urlSettle)

    case .chooseCloneDestinationTapped:
      return .run { [picker = folderPicker] send in
        await send(.remote(.cloneDestinationPicked(await picker.pick("Clone Into"))))
      }

    case .cloneDestinationPicked(let url):
      guard let url, var draft = state.remoteEditor?.draft, case .remote(let remoteURL, _) = draft.source else {
        return .none
      }
      // The picker returns a parent; the clone gets the repository's name.
      draft.source = .remote(
        url: remoteURL, cloneDestination: url.appending(path: draft.source.title).path(percentEncoded: false))
      state.remoteEditor?.draft = draft
      return .none

    case .saveTapped:
      guard let editor = state.remoteEditor, state.canSave(inEditor: editor), var draft = editor.draft else {
        return .none
      }
      draft.preflightIssues = []
      if editor.isNew {
        state.sources.append(draft)
      } else {
        state.sources[id: draft.id] = draft
      }
      state.remoteEditor = nil
      return .merge(.cancel(id: CancelID.urlSettle), edited(&state))

    case .cancelTapped:
      state.remoteEditor = nil
      return .cancel(id: CancelID.urlSettle)
    }
  }

  private func applyURL(_ state: inout State, reportsProblems: Bool) {
    guard let editor = state.remoteEditor else { return }
    switch AddEntryClassifier.classify(editor.urlText, fileExists: fileExists) {
    case .empty:
      state.remoteEditor?.draft = nil
    case .url(let url):
      let key = AddEntryClassifier.normalizedRemoteKey(url)
      if case .remote(let current, _) = editor.draft?.source, AddEntryClassifier.normalizedRemoteKey(current) == key {
        return
      }
      let isListed = state.sources.contains {
        guard $0.id != editor.id, case .remote(let existing, _) = $0.source else { return false }
        return AddEntryClassifier.normalizedRemoteKey(existing) == key
      }
      guard !isListed else {
        state.remoteEditor?.sourceIssue = "This repository is already in the list."
        return
      }
      let name = WorkspaceLayout.repositoryName(fromRemoteURL: url) ?? "repository"
      // A clone folder picked for an earlier URL stays the parent.
      let parent =
        editor.draft.map { ($0.source.gitRoot as NSString).deletingLastPathComponent }
        ?? WorkspaceLayout.defaultSourcesDirectory().path(percentEncoded: false)
      state.remoteEditor?.draft = SourceDraft(
        id: editor.id, source: .remote(url: url, cloneDestination: (parent as NSString).appendingPathComponent(name)))
    case .path:
      if reportsProblems {
        state.remoteEditor?.sourceIssue = "Enter a URL. To use a folder on this Mac, add a folder instead."
      }
    case .unrecognized:
      if reportsProblems {
        state.remoteEditor?.sourceIssue = "Enter a git URL, such as git@github.com:org/repo.git."
      }
    }
  }

  // MARK: - Workspace and source creation

  private func startWorkspaceCreation(_ state: inout State) -> Effect<Action> {
    let plan = state.sourcePlan
    state.creation = .running(current: nil)
    return .merge(
      .cancel(id: CancelID.preflight),
      .run { [client = workspaceClient] send in
        do {
          let projectID = try await client.createWorkspace(plan)
          await send(.delegate(.created(projectID)))
        } catch {
          await send(Self.failure(error))
        }
      }
      .cancellable(id: CancelID.creation, cancelInFlight: true)
    )
  }

  private func startSourceAddition(projectID: ProjectID, _ state: inout State) -> Effect<Action> {
    guard let source = state.sources.first?.source.workspaceSource else { return .none }
    state.creation = .running(current: nil)
    return .merge(
      .cancel(id: CancelID.preflight),
      .run { [client = workspaceClient] send in
        do {
          let worktreeID = try await client.addSource(projectID, source)
          await send(.delegate(.added(projectID, worktreeID)))
        } catch {
          await send(Self.failure(error))
        }
      }
      .cancellable(id: CancelID.creation, cancelInFlight: true)
    )
  }

  nonisolated static func failure(_ error: any Error) -> Action {
    .creationFailed(message: WorkspaceClient.describe(error), cancelled: (error as? WorkspaceError) == .cancelled)
  }

  // MARK: - Validation

  /// What the client finds about the plan as it stands, without side
  /// effects.
  private func preflight(_ state: State) -> Effect<Action> {
    let client = workspaceClient
    switch state.mode {
    case .addWorkspace:
      let plan = state.sourcePlan
      return .run { send in await send(.preflightFinished(await client.preflightWorkspace(plan))) }
        .cancellable(id: CancelID.preflight, cancelInFlight: true)
    case .addSource:
      // The Workspace root exists already; only the source is checked.
      var sourcesOnly = state.sourcePlan
      sourcesOnly.rootPath = ""
      let plan = sourcesOnly
      return .run { send in await send(.preflightFinished(await client.preflightWorkspace(plan))) }
        .cancellable(id: CancelID.preflight, cancelInFlight: true)
    case .newGroup:
      guard let plan = state.groupDraftPlan, !plan.name.isEmpty, !state.groupMembers.isEmpty else {
        return .send(.preflightFinished(WorkspacePreflight()))
      }
      return .run { send in await send(.preflightFinished(await client.preflightGroup(plan))) }
        .cancellable(id: CancelID.preflight, cancelInFlight: true)
    }
  }

  private func applyPreflight(_ result: WorkspacePreflight, to state: inout State) {
    switch state.mode {
    case .addWorkspace, .addSource:
      state.rootIssues = result.rootIssues.map(MemberIssue.init(preflight:))
      // Source findings are keyed by the source's index in the plan.
      for (index, id) in state.sources.ids.enumerated() {
        state.sources[id: id]?.preflightIssues = result.memberIssues[String(index)] ?? []
      }
    case .newGroup:
      state.groupPreflightIssues = result.groupIssues
      for id in state.groupMembers.ids {
        let name = state.groupMembers[id: id]?.name ?? ""
        state.groupMembers[id: id]?.preflightIssues = result.memberIssues[name] ?? []
      }
    }
  }

  // MARK: - Helpers

  /// Every edit: clear a finished attempt's outcome, then re-check the plan
  /// once typing pauses.
  func edited(_ state: inout State) -> Effect<Action> {
    if state.creation.isSettled {
      state.creation = .idle
      for id in state.groupMembers.ids { state.groupMembers[id: id]?.progress = .pending }
    }
    return schedulePreflight(state)
  }

  private func schedulePreflight(_ state: State) -> Effect<Action> {
    guard state.creation == .idle else { return .none }
    return .run { [clock] send in
      try await clock.sleep(for: Self.preflightDebounce)
      await send(.preflightTick)
    }
    .cancellable(id: CancelID.preflight, cancelInFlight: true)
  }
}

// MARK: - File existence dependency

/// `FileManager.fileExists` behind a dependency so path detection in the URL
/// field is deterministic in tests.
nonisolated enum FileExistsDependencyKey: DependencyKey {
  static let liveValue: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
  static let testValue: @Sendable (String) -> Bool = { _ in false }
}

extension DependencyValues {
  var fileExists: @Sendable (String) -> Bool {
    get { self[FileExistsDependencyKey.self] }
    set { self[FileExistsDependencyKey.self] = newValue }
  }
}
