import CodansCore
import ComposableArchitecture
import Foundation

/// Reducer behind the New Workspace sheet and, in add mode, a workspace's
/// Add Repository sheet. Collects a title, where the folder goes, a branch
/// for the new checkouts, and the member repositories (open projects,
/// folders on disk, remote URLs) with how each is checked out; then hands a
/// `WorkspacePlan` to `WorkspaceClient`'s streaming creation and shows its
/// progress per member. Its responsibility ends at `delegate(.created)` /
/// `delegate(.added)`; the client has registered and reconciled by then.
@Reducer
struct CreateWorkspaceFeature {
  /// A registered local git Project offered as a member.
  struct Candidate: Equatable, Identifiable, Sendable {
    let id: ProjectID
    let name: String
    let gitRoot: String
  }

  enum Mode: Equatable, Sendable {
    case create
    /// Adding to an existing workspace: title and folder are fixed, one
    /// member is the whole plan, and it goes through `addStream`.
    case add(projectID: ProjectID, title: String, rootPath: String, existingNames: Set<String>)
  }

  enum CreationState: Equatable, Sendable {
    case idle
    case running(current: MemberDraft.ID?)
    case finalizing(String)
    case rollingBack
    /// Rolled back after a cancel; `failures` names what needs a hand.
    case rolledBack(failures: [String])
    /// Rolled back after an error; the failing member carries the detail.
    case failed(message: String)

    var isBusy: Bool {
      switch self {
      case .running, .finalizing, .rollingBack: return true
      case .idle, .rolledBack, .failed: return false
      }
    }

    /// A finished attempt whose outcome is still on screen; the next edit
    /// or Create clears it.
    var isSettled: Bool {
      switch self {
      case .rolledBack, .failed: return true
      case .idle, .running, .finalizing, .rollingBack: return false
      }
    }
  }

  @ObservableState
  struct State: Equatable {
    var mode: Mode
    var candidates: IdentifiedArrayOf<Candidate>

    var titleDraft = ""
    /// The folder the workspace folder is created in; the workspace folder
    /// itself is named after the title.
    var locationPath: String
    /// Preflight findings about the workspace folder.
    var rootIssues: [MemberIssue] = []

    /// Branch for new checkouts. Follows the title until edited.
    var sharedBranch = ""
    var sharedBranchEditedManually = false

    var members: IdentifiedArrayOf<MemberDraft> = []

    var remoteURLDraft = ""
    var addIssue: String?
    var isResolvingAdd = false

    var creation: CreationState = .idle
    var creationToken: UUID?

    /// Added by `onAppear`, so its refs load through the normal path.
    var preselected: ProjectID?

    init(
      candidates: [Candidate],
      preselected: ProjectID? = nil,
      mode: Mode = .create,
      locationPath: String = WorkspaceLayout.defaultWorkspacesDirectory().path(percentEncoded: false)
    ) {
      self.mode = mode
      self.candidates = IdentifiedArray(uniqueElements: candidates)
      self.preselected = preselected
      self.locationPath = locationPath
      if case .add(_, let title, _, _) = mode {
        titleDraft = title
        sharedBranch = WorkspaceLayout.folderName(forTitle: title)
      }
    }

    var isAddMode: Bool {
      if case .add = mode { return true }
      return false
    }

    var minimumMembers: Int {
      isAddMode ? 1 : WorkspacePlan.minimumMembers
    }

    /// Add mode takes exactly one repository.
    var canAddMembers: Bool {
      !isAddMode || members.isEmpty
    }

    var rootPath: String {
      switch mode {
      case .add(_, _, let rootPath, _):
        return rootPath
      case .create:
        guard !titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return (locationPath as NSString).appendingPathComponent(WorkspaceLayout.folderName(forTitle: titleDraft))
      }
    }

    /// Open projects not in the list yet.
    var availableCandidates: [Candidate] {
      let used = Set(
        members.compactMap { member -> ProjectID? in
          if case .project(let id, _, _) = member.source { return id }
          return nil
        })
      return candidates.filter { !used.contains($0.id) }
    }

    // MARK: Plan

    /// The plan as it stands; preflight checks it before it is complete.
    var draftPlan: WorkspacePlan {
      WorkspacePlan(
        title: titleDraft.trimmingCharacters(in: .whitespacesAndNewlines),
        rootPath: rootPath,
        members: members.map { member in
          WorkspacePlan.Member(
            name: member.name.trimmingCharacters(in: .whitespacesAndNewlines),
            source: member.source.planSource,
            checkout: checkout(for: member))
        })
    }

    /// The plan when nothing blocks it.
    var plan: WorkspacePlan? {
      hasBlockingIssues ? nil : draftPlan
    }

    func branch(for member: MemberDraft) -> String {
      member.branch(sharedBranch: sharedBranch)
    }

    func checkout(for member: MemberDraft) -> WorkspaceCheckout {
      let branch = branch(for: member)
      switch member.mode {
      case .newBranch:
        return .newBranch(branch: branch, baseRef: member.baseRef)
      case .existingLocal:
        return .existingBranch(branch)
      case .existingRemote:
        return .remoteTrackingRef(
          remoteRef: member.remoteRef ?? "", branch: branch, resetLocal: member.localConflict == .resetToRemote)
      }
    }

    // MARK: Issues

    /// What the reducer can tell about a member without I/O, then what the
    /// client's preflight reported for it.
    func issues(for member: MemberDraft) -> [MemberIssue] {
      var issues: [MemberIssue] = []
      let name = member.name.trimmingCharacters(in: .whitespacesAndNewlines)
      if name.isEmpty {
        issues.append(.blocking("Enter a folder name."))
      } else if !WorkspaceManifest.isValidChildPath(name) {
        issues.append(
          .blocking("The folder name can't contain \u{201C}/\u{201D} or be \u{201C}.\u{201D} or \u{201C}..\u{201D}."))
      } else if members.contains(where: {
        $0.id != member.id && $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == name
      }) {
        issues.append(.blocking("Another repository already uses the folder name \u{201C}\(name)\u{201D}."))
      } else if case .add(_, _, _, let existing) = mode, existing.contains(name) {
        issues.append(.blocking("The workspace already has a folder named \u{201C}\(name)\u{201D}."))
      }
      // A folder-name problem already covers "that folder exists".
      let hasNameIssue = !issues.isEmpty
      issues.append(contentsOf: checkoutIssues(for: member))
      if case .failed(let message) = member.refs {
        issues.append(member.mode == .existingRemote ? .blocking(message) : .warning(message))
      }
      issues.append(
        contentsOf: member.preflightIssues
          .filter { !(hasNameIssue && $0.kind == .destinationExists) }
          .map(MemberIssue.init(preflight:)))
      return issues
    }

    private func checkoutIssues(for member: MemberDraft) -> [MemberIssue] {
      let branch = branch(for: member)
      let inventory = member.refs.inventory
      let label = member.source.title
      switch member.mode {
      case .newBranch:
        if branch.isEmpty { return [.incomplete("Enter a branch name for \(label).")] }
        if BranchNameSyntax.quickCheck(branch) != nil {
          return [.blocking("\u{201C}\(branch)\u{201D} is not a valid branch name.")]
        }
        if let inventory, inventory.local.contains(branch) {
          return [
            .blocking(
              "A branch named \u{201C}\(branch)\u{201D} already exists here. Choose Existing branch to check it out.")
          ]
        }
        return []
      case .existingLocal:
        if member.refs.isLoading { return [.incomplete("Loading branches for \(label)…")] }
        guard !branch.isEmpty else { return [.incomplete("Choose a branch for \(label).")] }
        guard let inventory else { return [] }
        if !inventory.local.contains(branch) {
          return [.blocking("There is no local branch named \u{201C}\(branch)\u{201D}.")]
        }
        return checkedOutIssue(branch: branch, inventory: inventory)
      case .existingRemote:
        if member.refs.isLoading { return [.incomplete("Loading branches for \(label)…")] }
        guard let remoteRef = member.remoteRef, !remoteRef.isEmpty else {
          return [.incomplete("Choose a remote branch for \(label).")]
        }
        guard let inventory else { return [] }
        if !inventory.remote.contains(remoteRef) {
          return [.blocking("\u{201C}\(remoteRef)\u{201D} is not a remote branch of this repository.")]
        }
        // Keep checks the local branch out; reset moves it with `-B`. Git
        // refuses both while another worktree has it.
        return member.hasLocalConflict ? checkedOutIssue(branch: branch, inventory: inventory) : []
      }
    }

    private func checkedOutIssue(branch: String, inventory: RefInventory) -> [MemberIssue] {
      guard let path = inventory.checkedOut[branch] else { return [] }
      return [
        .blocking(
          "\u{201C}\(branch)\u{201D} is checked out at \((path as NSString).abbreviatingWithTildeInPath). "
            + "A branch can be checked out in only one place.")
      ]
    }

    /// Workspace-level issues: what is still missing, then preflight.
    var workspaceIssues: [MemberIssue] {
      var issues: [MemberIssue] = []
      if !isAddMode, titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        issues.append(.incomplete("Enter a title."))
      }
      if members.count < minimumMembers {
        issues.append(.incomplete(isAddMode ? "Choose a repository to add." : "Add at least two repositories."))
      }
      issues.append(contentsOf: rootIssues)
      return issues
    }

    var hasBlockingIssues: Bool {
      workspaceIssues.contains(where: \.blocksCreation)
        || members.contains { issues(for: $0).contains(where: \.blocksCreation) }
    }

    var canCreate: Bool {
      plan != nil && !creation.isBusy && !isResolvingAdd
    }

    var createButtonTitle: String {
      isAddMode ? "Add" : "Create"
    }

    /// Why Create is disabled, for the bottom bar: the first thing still
    /// missing, or a pointer to the problems shown in the form.
    var createHint: String? {
      guard creation == .idle, !canCreate else { return nil }
      if isResolvingAdd { return "Checking the folder…" }
      let all = workspaceIssues + members.flatMap { issues(for: $0) }
      if let missing = all.first(where: { $0.severity == .incomplete }) { return missing.message }
      if all.contains(where: { $0.severity == .blocking }) { return "Fix the problems above to continue." }
      return nil
    }
  }

  enum Action: Equatable {
    case onAppear
    // Workspace
    case titleChanged(String)
    case chooseLocationTapped
    case locationPicked(URL?)
    case sharedBranchChanged(String)
    // Adding members
    case addProjectTapped(ProjectID)
    case addFolderTapped
    case addFolderPicked(URL?)
    case addPathResolved(path: String, probe: RepositoryProbe?)
    case remoteURLDraftChanged(String)
    case addRemoteURLSubmitted
    // Members
    case member(MemberDraft.ID, MemberAction)
    // Validation
    case preflightTick
    case preflightFinished(WorkspacePreflight)
    // Creation
    case createButtonTapped
    case creationEvent(WorkspaceCreationEvent)
    case creationFailed(message: String, cancelled: Bool)
    case cancelButtonTapped
    case delegate(Delegate)

    enum MemberAction: Equatable {
      case remove
      case nameChanged(String)
      case modeChanged(MemberDraft.CheckoutMode)
      case branchOverrideChanged(String)
      case baseRefChanged(String?)
      case localBranchChanged(String?)
      case remoteRefChanged(String?)
      case localConflictChanged(MemberDraft.LocalConflictResolution)
      case chooseCloneDestinationTapped
      case cloneDestinationPicked(URL?)
      case retryRefsTapped
      case refsLoaded(RefInventory)
      case refsFailed(String)
    }

    @CasePathable
    enum Delegate: Equatable {
      case dismissed
      /// The workspace is on disk, registered, and reconciled.
      case created(ProjectID)
      /// The member is on disk and its row registered.
      case added(ProjectID, WorktreeID)
    }
  }

  private nonisolated enum CancelID: Hashable, Sendable {
    case refs(MemberDraft.ID)
    case addResolve
    case preflight
    case creation
  }

  private nonisolated static let remoteRefsTimeout: Duration = .seconds(20)
  private nonisolated static let preflightDebounce: Duration = .milliseconds(300)

  @Dependency(WorkspaceClient.self) private var workspaceClient
  @Dependency(GitWorktreeClient.self) private var gitWorktreeClient
  @Dependency(FolderPickerClient.self) private var folderPicker
  @Dependency(GitWorktreeCLI.self) private var gitCLI
  @Dependency(\.continuousClock) private var clock
  @Dependency(\.uuid) private var uuid
  @Dependency(FileExistsDependencyKey.self) private var fileExists

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .onAppear:
        guard let preselected = state.preselected, let candidate = state.candidates[id: preselected] else {
          return .none
        }
        state.preselected = nil
        return appendMember(source: .project(candidate.id, name: candidate.name, gitRoot: candidate.gitRoot), &state)

      // MARK: Workspace

      case .titleChanged(let title):
        state.titleDraft = title
        if !state.sharedBranchEditedManually {
          let isBlank = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          state.sharedBranch = isBlank ? "" : WorkspaceLayout.folderName(forTitle: title)
        }
        return edited(&state)

      case .chooseLocationTapped:
        return .run { [picker = folderPicker] send in
          await send(.locationPicked(await picker.pick("Choose Location")))
        }

      case .locationPicked(let url):
        guard let url else { return .none }
        state.locationPath = (url.path(percentEncoded: false) as NSString).standardizingPath
        return edited(&state)

      case .sharedBranchChanged(let branch):
        state.sharedBranch = branch
        state.sharedBranchEditedManually = true
        return edited(&state)

      // MARK: Adding members

      case .addProjectTapped(let id):
        guard state.canAddMembers, let candidate = state.candidates[id: id] else { return .none }
        state.addIssue = nil
        return appendMember(source: .project(candidate.id, name: candidate.name, gitRoot: candidate.gitRoot), &state)

      case .addFolderTapped:
        return .run { [picker = folderPicker] send in
          await send(.addFolderPicked(await picker.pick("Add Repository")))
        }

      case .addFolderPicked(let url):
        guard let url else { return .none }
        return resolvePath(url.path(percentEncoded: false), &state)

      case .addPathResolved(let path, let probe):
        state.isResolvingAdd = false
        return addResolvedPath(path, probe: probe, &state)

      case .remoteURLDraftChanged(let draft):
        state.remoteURLDraft = draft
        state.addIssue = nil
        return .none

      case .addRemoteURLSubmitted:
        return submitRemoteURL(&state)

      // MARK: Members

      case .member(let id, let memberAction):
        guard state.members[id: id] != nil else { return .none }
        return reduceMember(id: id, action: memberAction, state: &state)

      // MARK: Validation

      case .preflightTick:
        guard state.creation == .idle else { return .none }
        let plan = state.draftPlan
        return .run { [client = workspaceClient] send in
          await send(.preflightFinished(await client.preflight(plan)))
        }
        .cancellable(id: CancelID.preflight, cancelInFlight: true)

      case .preflightFinished(let result):
        state.rootIssues = result.rootIssues.map(MemberIssue.init(preflight:))
        for id in state.members.ids {
          let name = state.members[id: id]?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          state.members[id: id]?.preflightIssues = result.memberIssues[name] ?? []
        }
        return .none

      // MARK: Creation

      case .createButtonTapped:
        guard let plan = state.plan, !state.creation.isBusy, !state.isResolvingAdd else { return .none }
        return startCreation(plan, &state)

      case .creationEvent(let event):
        return reduceCreationEvent(event, state: &state)

      case .creationFailed(let message, let cancelled):
        if cancelled {
          if !state.creation.isSettled { state.creation = .rolledBack(failures: []) }
        } else {
          state.creation = .failed(message: message)
        }
        return .none

      case .cancelButtonTapped:
        switch state.creation {
        case .idle, .rolledBack, .failed:
          return .merge(.cancel(id: CancelID.preflight), .send(.delegate(.dismissed)))
        case .running, .finalizing:
          guard let token = state.creationToken else { return .none }
          state.creation = .rollingBack
          return .run { [client = workspaceClient] _ in await client.cancelCreation(token) }
        case .rollingBack:
          return .none
        }

      case .delegate:
        return .none
      }
    }
  }

  // MARK: - Members

  private func reduceMember(id: MemberDraft.ID, action: Action.MemberAction, state: inout State) -> Effect<Action> {
    switch action {
    case .remove:
      state.members.remove(id: id)
      return .merge(.cancel(id: CancelID.refs(id)), edited(&state))

    case .nameChanged(let name):
      state.members[id: id]?.name = name
      return edited(&state)

    case .modeChanged(let mode):
      // No remote branch is picked for the user: the default branch's local
      // twin is usually checked out in the source repository already.
      state.members[id: id]?.mode = mode
      return edited(&state)

    case .branchOverrideChanged(let branch):
      state.members[id: id]?.branchOverride = branch
      return edited(&state)

    case .baseRefChanged(let ref):
      state.members[id: id]?.baseRef = ref
      return edited(&state)

    case .localBranchChanged(let branch):
      state.members[id: id]?.localBranch = branch
      return edited(&state)

    case .remoteRefChanged(let ref):
      state.members[id: id]?.remoteRef = ref
      // Another ref means another local branch; the reset choice belonged to
      // the old one.
      state.members[id: id]?.localConflict = .keepLocal
      return edited(&state)

    case .localConflictChanged(let choice):
      state.members[id: id]?.localConflict = choice
      return edited(&state)

    case .chooseCloneDestinationTapped:
      return .run { [picker = folderPicker] send in
        await send(.member(id, .cloneDestinationPicked(await picker.pick("Clone Into"))))
      }

    case .cloneDestinationPicked(let url):
      guard let url, let member = state.members[id: id], case .remote(let remoteURL, _) = member.source else {
        return .none
      }
      // The picker returns a parent; the clone gets the repository's name.
      let destination = url.appending(path: member.source.title).path(percentEncoded: false)
      state.members[id: id]?.source = .remote(url: remoteURL, cloneDestination: destination)
      return edited(&state)

    case .retryRefsTapped:
      guard let member = state.members[id: id] else { return .none }
      state.members[id: id]?.refs = .loading
      return loadRefs(for: member)

    case .refsLoaded(let inventory):
      state.members[id: id]?.refs = .loaded(inventory)
      return .none

    case .refsFailed(let message):
      state.members[id: id]?.refs = .failed(message)
      return .none
    }
  }

  private func appendMember(source: MemberDraft.Source, _ state: inout State) -> Effect<Action> {
    let taken = Set(state.members.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) })
    let base = source.suggestedName
    var name = base
    var suffix = 2
    while taken.contains(name) {
      name = "\(base)-\(suffix)"
      suffix += 1
    }
    var member = MemberDraft(id: uuid(), source: source, name: name)
    member.refs = .loading
    state.members.append(member)
    return .merge(loadRefs(for: member), edited(&state))
  }

  private func loadRefs(for member: MemberDraft) -> Effect<Action> {
    let id = member.id
    let client = gitWorktreeClient
    switch member.source {
    case .project(_, _, let gitRoot), .localRepo(let gitRoot):
      let repoRoot = URL(fileURLWithPath: gitRoot, isDirectory: true)
      return .run { send in
        async let refs = (try? client.branchRefs(repoRoot)) ?? []
        async let locals = (try? client.localBranchNames(repoRoot)) ?? []
        async let worktrees = (try? client.lsWorktrees(repoRoot)) ?? []
        async let auto = (try? client.defaultRemoteBranchRef(repoRoot)) ?? nil
        let inventory = RefInventory(
          branchRefs: await refs, localBranchNames: await locals, worktrees: await worktrees,
          defaultRemoteBranchRef: await auto)
        await send(.member(id, .refsLoaded(inventory)))
      }
      .cancellable(id: CancelID.refs(id), cancelInFlight: true)
    case .remote(let url, _):
      let clock = clock
      return .run { send in
        do {
          let heads = try await withThrowingTaskGroup(of: RemoteHeads.self) { group in
            group.addTask { try await client.lsRemoteHeads(url) }
            group.addTask {
              try await clock.sleep(for: Self.remoteRefsTimeout)
              throw RemoteRefsTimeout()
            }
            let first = try await group.next()
            group.cancelAll()
            return first ?? RemoteHeads()
          }
          await send(.member(id, .refsLoaded(RefInventory(remoteHeads: heads))))
        } catch is RemoteRefsTimeout {
          let seconds = Int(Self.remoteRefsTimeout.components.seconds)
          await send(.member(id, .refsFailed("The remote did not answer within \(seconds) seconds.")))
        } catch {
          await send(
            .member(id, .refsFailed("Couldn't list the remote's branches: \(WorkspaceClient.describe(error))")))
        }
      }
      .cancellable(id: CancelID.refs(id), cancelInFlight: true)
    }
  }

  private nonisolated struct RemoteRefsTimeout: Error {}

  // MARK: - Adding

  private func resolvePath(_ path: String, _ state: inout State) -> Effect<Action> {
    guard state.canAddMembers else { return .none }
    state.isResolvingAdd = true
    state.addIssue = nil
    return .run { [cli = gitCLI] send in
      let probe = try? await cli.inspectRepository(at: path)
      await send(.addPathResolved(path: path, probe: probe))
    }
    .cancellable(id: CancelID.addResolve, cancelInFlight: true)
  }

  private func addResolvedPath(_ path: String, probe: RepositoryProbe?, _ state: inout State) -> Effect<Action> {
    let shown = (path as NSString).abbreviatingWithTildeInPath
    guard let probe else {
      state.addIssue = "\(shown) is not a git repository."
      return .none
    }
    guard !probe.isBare else {
      state.addIssue = "\(shown) is a bare repository, which workspaces do not support."
      return .none
    }
    let root = HierarchyManager.canonicalPath(probe.root)
    if state.members.contains(where: {
      !$0.source.isRemote && HierarchyManager.canonicalPath($0.source.gitRoot) == root
    }) {
      state.addIssue = "\((root as NSString).abbreviatingWithTildeInPath) is already in the list."
      return .none
    }
    state.addIssue = nil
    state.remoteURLDraft = ""
    if let candidate = state.candidates.first(where: { HierarchyManager.canonicalPath($0.gitRoot) == root }) {
      return appendMember(source: .project(candidate.id, name: candidate.name, gitRoot: candidate.gitRoot), &state)
    }
    return appendMember(source: .localRepo(gitRoot: root), &state)
  }

  private func submitRemoteURL(_ state: inout State) -> Effect<Action> {
    guard state.canAddMembers else { return .none }
    switch AddEntryClassifier.classify(state.remoteURLDraft, fileExists: fileExists) {
    case .empty:
      return .none
    case .url(let url):
      let key = AddEntryClassifier.normalizedRemoteKey(url)
      let isListed = state.members.contains {
        guard case .remote(let existing, _) = $0.source else { return false }
        return AddEntryClassifier.normalizedRemoteKey(existing) == key
      }
      guard !isListed else {
        state.addIssue = "This remote is already in the list."
        return .none
      }
      let name = WorkspaceLayout.repositoryName(fromRemoteURL: url) ?? "repository"
      let destination = (WorkspaceLayout.defaultSourcesDirectory().path(percentEncoded: false) as NSString)
        .appendingPathComponent(name)
      state.remoteURLDraft = ""
      state.addIssue = nil
      return appendMember(source: .remote(url: url, cloneDestination: destination), &state)
    case .path(let path, let exists):
      guard exists else {
        state.addIssue = "There is no folder at \((path as NSString).abbreviatingWithTildeInPath)."
        return .none
      }
      return resolvePath(path, &state)
    case .unrecognized:
      state.addIssue = "Enter a git URL, such as git@github.com:org/repo.git."
      return .none
    }
  }

  // MARK: - Creation

  private func startCreation(_ plan: WorkspacePlan, _ state: inout State) -> Effect<Action> {
    let stream: AsyncThrowingStream<WorkspaceCreationEvent, Error>
    let token = uuid()
    switch state.mode {
    case .create:
      stream = workspaceClient.createStream(plan, token)
    case .add(let projectID, _, _, _):
      guard let member = plan.members.first else { return .none }
      stream = workspaceClient.addStream(projectID, member, token)
    }
    state.creationToken = token
    for id in state.members.ids { state.members[id: id]?.progress = .pending }
    state.creation = .running(current: nil)
    return .merge(
      .cancel(id: CancelID.preflight),
      .run { send in
        do {
          for try await event in stream {
            await send(.creationEvent(event))
          }
        } catch {
          await send(
            .creationFailed(
              message: WorkspaceClient.describe(error), cancelled: (error as? WorkspaceError) == .cancelled))
        }
      }
      .cancellable(id: CancelID.creation, cancelInFlight: true)
    )
  }

  private func reduceCreationEvent(_ event: WorkspaceCreationEvent, state: inout State) -> Effect<Action> {
    func memberID(named name: String) -> MemberDraft.ID? {
      state.members.first { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == name }?.id
    }
    switch event {
    case .memberStarted(let name, let phase):
      guard let id = memberID(named: name) else { return .none }
      state.members[id: id]?.progress = .running(phase, lastLine: nil)
      state.creation = .running(current: id)
    case .progressLine(let name, let line):
      guard let id = memberID(named: name), case .running(let phase, _) = state.members[id: id]?.progress else {
        return .none
      }
      state.members[id: id]?.progress = .running(phase, lastLine: line)
    case .memberFinished(let name):
      guard let id = memberID(named: name) else { return .none }
      state.members[id: id]?.progress = .done
    case .memberFailed(let name, let message):
      guard let id = memberID(named: name) else { return .none }
      state.members[id: id]?.progress = .failed(message)
    case .manifestWritten:
      state.creation = .finalizing("Adding to the sidebar…")
    case .registered(let projectID, let worktreeID):
      state.creation = .idle
      if let worktreeID {
        return .send(.delegate(.added(projectID, worktreeID)))
      }
      return .send(.delegate(.created(projectID)))
    case .rollingBack:
      state.creation = .rollingBack
      for id in state.members.ids {
        if case .failed = state.members[id: id]?.progress { continue }
        state.members[id: id]?.progress = .rolledBack
      }
    case .rolledBack(let failures):
      state.creation = .rolledBack(failures: failures)
    }
    return .none
  }

  // MARK: - Helpers

  /// Every edit: clear a finished attempt's outcome, then re-check the plan
  /// once typing pauses.
  private func edited(_ state: inout State) -> Effect<Action> {
    if state.creation.isSettled {
      state.creation = .idle
      for id in state.members.ids { state.members[id: id]?.progress = .pending }
    }
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
