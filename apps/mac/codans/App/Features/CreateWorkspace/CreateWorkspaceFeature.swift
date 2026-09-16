import CodansCore
import ComposableArchitecture
import Foundation

/// Reducer behind the New Workspace sheet (and, in add mode, the workspace's
/// Add Repository sheet). Collects the workspace's title and folder, a list
/// of member repositories from open projects, local paths, bare
/// repositories, or remote URLs, and per member how it is checked out; keeps
/// every problem it can find anchored to the field it concerns; then hands
/// a `WorkspacePlan` to `WorkspaceClient`'s streaming creation and renders
/// its progress per row. Its responsibility ends at `delegate(.created)` /
/// `delegate(.added)`; the client has already registered and reconciled by
/// then.
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
    /// member is enough, and the plan goes through `addStream`.
    case add(projectID: ProjectID, title: String, rootPath: String, existingNames: Set<String>)
  }

  enum CreationState: Equatable, Sendable {
    case idle
    case running(current: MemberDraft.ID?)
    case finalizing(String)
    case rollingBack
    /// Rolled back after a cancel; `failures` names what needs a hand.
    case rolledBack(failures: [String])
    /// Rolled back after an error; the failing row carries the detail.
    case failed(message: String)

    var isBusy: Bool {
      switch self {
      case .running, .finalizing, .rollingBack: return true
      case .idle, .rolledBack, .failed: return false
      }
    }

    /// The form re-enables here; Create becomes Retry / Done.
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

    // Workspace
    var titleDraft = ""
    var rootPathDraft = ""
    /// Set once the user edits the folder by hand so title edits stop
    /// re-deriving it out from under them.
    var rootPathEditedManually = false
    /// Findings from preflight about the folder.
    var rootIssues: [MemberIssue] = []

    // Branch for all
    var sharedBranch = ""
    var sharedBranchEditedManually = false
    /// Nil = each repository's default branch.
    var sharedBaseRef: String?

    // Members
    var members: IdentifiedArrayOf<MemberDraft> = []
    var expandedMemberID: MemberDraft.ID?

    // Add field
    var addDraft = ""
    var addKind: AddEntryKind = .empty
    var addSuggestions: [Candidate] = []
    var addHighlightedIndex: Int?
    var addIssue: String?
    var isResolvingAdd = false

    // Preview
    var showCommands = false

    // Creation
    var creation: CreationState = .idle
    var creationToken: UUID?

    init(candidates: [Candidate], preselected: ProjectID? = nil, mode: Mode = .create) {
      self.mode = mode
      self.candidates = IdentifiedArray(uniqueElements: candidates)
      if case .add(_, let title, let rootPath, _) = mode {
        titleDraft = title
        rootPathDraft = rootPath
        rootPathEditedManually = true
        sharedBranch = WorkspaceLayout.folderName(forTitle: title)
      }
      // `preselected` is seeded by the reducer's `onAppear` so the row's refs
      // load through the normal path; remembered here.
      self.preselected = preselected
    }

    /// Consumed by `onAppear`.
    var preselected: ProjectID?

    var isAddMode: Bool {
      if case .add = mode { return true }
      return false
    }

    var minimumMembers: Int {
      isAddMode ? 1 : WorkspacePlan.minimumMembers
    }

    // MARK: Derived

    /// The plan as it stands, blocking issues or not — the preview shows it.
    var draftPlan: WorkspacePlan {
      WorkspacePlan(
        title: titleDraft.trimmingCharacters(in: .whitespacesAndNewlines),
        rootPath: rootPathDraft.trimmingCharacters(in: .whitespacesAndNewlines),
        members: members.map { member in
          WorkspacePlan.Member(
            name: member.name.trimmingCharacters(in: .whitespacesAndNewlines),
            source: member.source.planSource,
            checkout: checkout(for: member))
        })
    }

    /// The plan when nothing blocks it.
    var plan: WorkspacePlan? {
      blockingCount == 0 && members.count >= minimumMembers ? draftPlan : nil
    }

    func checkout(for member: MemberDraft) -> WorkspaceCheckout {
      let branch = member.branch.trimmingCharacters(in: .whitespacesAndNewlines)
      switch member.mode {
      case .newBranch:
        return .newBranch(branch: branch, baseRef: member.baseRef)
      case .existingLocal:
        return .existingBranch(branch)
      case .existingRemote:
        return .remoteTrackingRef(
          remoteRef: member.remoteRef ?? "",
          branch: branch,
          resetLocal: member.localConflict == .resetToRemote)
      }
    }

    /// Problems the reducer can see without I/O, per row, plus the
    /// preflight findings the client reported for it.
    func issues(for member: MemberDraft) -> [MemberIssue] {
      var issues: [MemberIssue] = []
      let name = member.name.trimmingCharacters(in: .whitespacesAndNewlines)
      if !WorkspaceManifest.isValidChildPath(name) {
        issues.append(.blocking(.name, "Folder name must be a single path component."))
      } else if members.contains(where: {
        $0.id != member.id && $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == name
      }) {
        issues.append(.blocking(.name, "Another repository already uses this folder name."))
      } else if case .add(_, _, _, let existing) = mode, existing.contains(name) {
        issues.append(.blocking(.name, "The workspace already has a repository named \"\(name)\"."))
      }
      if case .remote(_, let destination, _) = member.source,
        destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        issues.append(.blocking(.cloneDestination, "Choose a folder to clone into."))
      }

      issues.append(contentsOf: checkoutIssues(for: member))
      if case .failed(let message) = member.refs {
        let severity: MemberIssue.Severity = member.mode == .existingRemote ? .blocking : .warning
        issues.append(MemberIssue(severity: severity, field: .refs, message: message))
      }
      issues.append(contentsOf: member.asyncIssues)
      return issues
    }

    /// Problems with how the row is checked out, given what its refs say.
    private func checkoutIssues(for member: MemberDraft) -> [MemberIssue] {
      var issues: [MemberIssue] = []
      let branch = member.branch.trimmingCharacters(in: .whitespacesAndNewlines)
      let inventory = member.refs.inventory
      switch member.mode {
      case .newBranch:
        issues.append(contentsOf: branchSyntaxIssues(branch))
        if let inventory, inventory.local.contains(branch) {
          issues.append(.blocking(.branch, "Branch exists here. Choose Existing branch or rename."))
        }
        if let shared = sharedBaseRef, member.baseRef == nil, !member.baseRefEditedManually, let inventory,
          !inventory.contains(shared)
        {
          issues.append(.warning(.baseRef, "\(shared) isn't in this repository; its default branch will be used."))
        }
      case .existingLocal:
        issues.append(contentsOf: branchSyntaxIssues(branch))
        if let inventory {
          if !inventory.local.contains(branch) {
            issues.append(.blocking(.branch, "No local branch named \(branch)."))
          } else if let path = inventory.checkedOut[branch] {
            issues.append(
              .blocking(
                .branch,
                "\(branch) is checked out at \((path as NSString).abbreviatingWithTildeInPath); git allows one checkout per branch."
              ))
          }
        }
      case .existingRemote:
        if let remoteRef = member.remoteRef, !remoteRef.isEmpty {
          if let inventory, !inventory.remote.contains(remoteRef) {
            issues.append(.blocking(.remoteRef, "\(remoteRef) isn't a remote branch of this repository."))
          }
          issues.append(contentsOf: branchSyntaxIssues(branch))
          if member.hasLocalConflict {
            if member.localConflict == .keepLocal, let path = inventory?.checkedOut[branch] {
              issues.append(
                .blocking(
                  .branch,
                  "\(branch) is checked out at \((path as NSString).abbreviatingWithTildeInPath); git allows one checkout per branch."
                ))
            }
            issues.append(
              .info(
                .remoteRef,
                "A local branch \(branch) already exists. Keep local checks it out as is (default). Reset to remote points it at \(remoteRef)."
              ))
          }
        } else {
          issues.append(.blocking(.remoteRef, "Pick a remote branch."))
        }
        if member.refs.isLoading {
          issues.append(.blocking(.refs, "Loading branches…"))
        }
      }
      return issues
    }

    private func branchSyntaxIssues(_ branch: String) -> [MemberIssue] {
      if branch.isEmpty { return [.blocking(.branch, "Branch name required.")] }
      return BranchNameSyntax.quickCheck(branch) == nil ? [] : [.blocking(.branch, "Not a valid branch name.")]
    }

    /// Workspace-level problems, pure plus preflight.
    var workspaceIssues: [MemberIssue] {
      var issues: [MemberIssue] = []
      if !isAddMode, titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        issues.append(.blocking(.row, "Give the workspace a title."))
      }
      if rootPathDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        issues.append(.blocking(.row, "Choose a folder."))
      }
      if members.count < minimumMembers {
        let word = minimumMembers == 1 ? "repository" : "repositories"
        issues.append(.blocking(.row, "Add at least \(minimumMembers) \(word)."))
      }
      issues.append(contentsOf: rootIssues)
      return issues
    }

    var blockingCount: Int {
      workspaceIssues.filter { $0.severity == .blocking }.count
        + members.reduce(0) { $0 + issues(for: $1).filter { $0.severity == .blocking }.count }
    }

    var warningCount: Int {
      workspaceIssues.filter { $0.severity == .warning }.count
        + members.reduce(0) { $0 + issues(for: $1).filter { $0.severity == .warning }.count }
    }

    /// The first row with a blocking issue, for the footer's summary tap.
    var firstOffendingMemberID: MemberDraft.ID? {
      members.first { issues(for: $0).contains { $0.severity == .blocking } }?.id
    }

    var canCreate: Bool {
      plan != nil && creation == .idle && !isResolvingAdd
    }

    var createButtonTitle: String {
      if isAddMode { return "Add Repository" }
      let count = members.count
      return count == 1 ? "Create 1 checkout" : "Create \(count) checkouts"
    }
  }

  enum Action: Equatable {
    case onAppear
    // Workspace
    case titleChanged(String)
    case rootPathChanged(String)
    case browseRootTapped
    case browseRootPicked(URL?)
    // Add field
    case addDraftChanged(String)
    case addMoveHighlight(by: Int)
    case addSubmitted
    case addCleared
    case addFieldLostFocus
    case addSuggestionTapped(ProjectID)
    case addFolderTapped
    case addBareTapped
    case addPathPicked(URL?)
    case addPathResolved(path: String, probe: RepositoryProbe?)
    // Branch for all
    case sharedBranchChanged(String)
    case sharedBaseRefChanged(String?)
    // Members
    case member(MemberDraft.ID, MemberAction)
    // Validation
    case preflightTick
    case preflightFinished(WorkspacePreflight)
    // Preview
    case showCommandsChanged(Bool)
    // Creation
    case createButtonTapped
    case creationEvent(WorkspaceCreationEvent)
    case creationFailed(message: String, cancelled: Bool)
    case cancelButtonTapped
    case retryTapped
    case editAgainTapped
    case doneTapped
    case delegate(Delegate)

    enum MemberAction: Equatable {
      case toggleExpanded
      case remove
      case nameChanged(String)
      case modeChanged(MemberDraft.CheckoutMode)
      case branchChanged(String)
      case useSharedBranchTapped
      case baseRefChanged(String?)
      case remoteRefChanged(String?)
      case localConflictChanged(MemberDraft.LocalConflictResolution)
      case cloneDestinationChanged(String)
      case browseCloneDestinationTapped
      case cloneDestinationPicked(URL?)
      case loadRefsTapped
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

  private static let remoteRefsTimeout: Duration = .seconds(20)
  private static let preflightDebounce: Duration = .milliseconds(300)

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
        return appendMember(source: .project(candidate.id, gitRoot: candidate.gitRoot), to: &state)

      // MARK: Workspace

      case .titleChanged(let title):
        state.titleDraft = title
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = WorkspaceLayout.folderName(forTitle: title)
        if !state.rootPathEditedManually {
          state.rootPathDraft =
            trimmed.isEmpty
            ? ""
            : (WorkspaceLayout.defaultWorkspacesDirectory().path(percentEncoded: false) as NSString)
              .appendingPathComponent(slug)
        }
        if !state.sharedBranchEditedManually {
          state.sharedBranch = trimmed.isEmpty ? "" : slug
          propagateSharedBranch(&state)
        }
        return preflightDebounced(&state)

      case .rootPathChanged(let path):
        state.rootPathDraft = path
        state.rootPathEditedManually = true
        return preflightDebounced(&state)

      case .browseRootTapped:
        return .run { [picker = folderPicker] send in
          let url = await picker.pick("Choose Workspace Folder")
          await send(.browseRootPicked(url))
        }

      case .browseRootPicked(let url):
        guard let url else { return .none }
        // The picker returns a PARENT folder; append the slug so the user
        // lands on a ready-to-confirm destination.
        let slug = WorkspaceLayout.folderName(forTitle: state.titleDraft)
        state.rootPathDraft = url.appending(path: slug).path(percentEncoded: false)
        state.rootPathEditedManually = true
        return preflightDebounced(&state)

      // MARK: Add field

      case .addDraftChanged(let draft):
        let previous = state.addDraft
        state.addDraft = draft
        state.addIssue = nil
        state.addKind = AddEntryClassifier.classify(draft, fileExists: fileExists)
        refreshSuggestions(&state)
        // A paste of a URL is meant to be added; do not make the user press
        // Return on top of it.
        if case .url = state.addKind, draft.count - previous.count >= 8 {
          return submitAddEntry(&state)
        }
        return .none

      case .addMoveHighlight(let delta):
        guard !state.addSuggestions.isEmpty else { return .none }
        let current = state.addHighlightedIndex ?? 0
        state.addHighlightedIndex = min(max(current + delta, 0), state.addSuggestions.count - 1)
        return .none

      case .addSubmitted:
        return submitAddEntry(&state)

      case .addCleared:
        clearAddField(&state)
        return .none

      case .addFieldLostFocus:
        if case .url = state.addKind { return submitAddEntry(&state) }
        return .none

      case .addSuggestionTapped(let id):
        guard let candidate = state.candidates[id: id] else { return .none }
        clearAddField(&state)
        return appendMember(source: .project(candidate.id, gitRoot: candidate.gitRoot), to: &state)

      case .addFolderTapped:
        return .run { [picker = folderPicker] send in
          let url = await picker.pick("Add Repository")
          await send(.addPathPicked(url))
        }

      case .addBareTapped:
        return .run { [picker = folderPicker] send in
          let url = await picker.pick("Add Bare Repository")
          await send(.addPathPicked(url))
        }

      case .addPathPicked(let url):
        guard let url else { return .none }
        return resolvePath(url.path(percentEncoded: false), &state)

      case .addPathResolved(let path, let probe):
        state.isResolvingAdd = false
        guard let probe else {
          state.addIssue = "\((path as NSString).abbreviatingWithTildeInPath) is not a git repository."
          return .none
        }
        let root = HierarchyManager.canonicalPath(probe.root)
        if state.members.contains(where: {
          !$0.source.isRemote && HierarchyManager.canonicalPath($0.source.gitRoot) == root
        }) {
          state.addIssue = "Already in the list."
          return .none
        }
        clearAddField(&state)
        let source: MemberDraft.Source
        if let candidate = state.candidates.first(where: { HierarchyManager.canonicalPath($0.gitRoot) == root }) {
          source = .project(candidate.id, gitRoot: candidate.gitRoot)
        } else if probe.isBare {
          source = .bareRepo(gitRoot: root)
        } else {
          source = .localRepo(gitRoot: root)
        }
        return appendMember(source: source, to: &state)

      // MARK: Branch for all

      case .sharedBranchChanged(let branch):
        state.sharedBranch = branch
        state.sharedBranchEditedManually = true
        propagateSharedBranch(&state)
        return preflightDebounced(&state)

      case .sharedBaseRefChanged(let ref):
        state.sharedBaseRef = ref
        for member in state.members where member.mode == .newBranch && !member.baseRefEditedManually {
          let applies = sharedBaseRefApplicable(ref, to: member)
          state.members[id: member.id]?.baseRef = applies ? ref : nil
        }
        return .none

      // MARK: Members

      case .member(let id, let memberAction):
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
          state.members[id: id]?.asyncIssues = (result.memberIssues[name] ?? []).map(MemberIssue.init(preflight:))
        }
        return .none

      // MARK: Preview

      case .showCommandsChanged(let value):
        state.showCommands = value
        return .none

      // MARK: Creation

      case .createButtonTapped:
        guard let plan = state.plan, state.creation == .idle else { return .none }
        let token = uuid()
        state.creationToken = token
        for id in state.members.ids { state.members[id: id]?.progress = .pending }
        state.creation = .running(current: nil)
        let stream: AsyncThrowingStream<WorkspaceCreationEvent, Error>
        switch state.mode {
        case .create:
          stream = workspaceClient.createStream(plan, token)
        case .add(let projectID, _, _, _):
          guard let member = plan.members.first else { return .none }
          stream = workspaceClient.addStream(projectID, member, token)
        }
        return .run { send in
          do {
            for try await event in stream {
              await send(.creationEvent(event))
            }
          } catch {
            await send(
              .creationFailed(
                message: WorkspaceClient.describe(error),
                cancelled: (error as? WorkspaceError) == .cancelled))
          }
        }
        .cancellable(id: CancelID.creation, cancelInFlight: true)

      case .creationEvent(let event):
        return reduceCreationEvent(event, state: &state)

      case .creationFailed(let message, let cancelled):
        if cancelled {
          if case .rolledBack = state.creation {} else { state.creation = .rolledBack(failures: []) }
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

      case .retryTapped:
        guard state.creation.isSettled else { return .none }
        state.creation = .idle
        return .send(.createButtonTapped)

      case .editAgainTapped:
        guard state.creation.isSettled else { return .none }
        state.creation = .idle
        for id in state.members.ids { state.members[id: id]?.progress = .pending }
        return preflightDebounced(&state)

      case .doneTapped:
        return .send(.delegate(.dismissed))

      case .delegate:
        return .none
      }
    }
  }

  // MARK: - Members

  // swiftlint:disable:next cyclomatic_complexity
  private func reduceMember(id: MemberDraft.ID, action: Action.MemberAction, state: inout State) -> Effect<Action> {
    guard state.members[id: id] != nil else { return .none }
    switch action {
    case .toggleExpanded:
      state.expandedMemberID = state.expandedMemberID == id ? nil : id
      return .none

    case .remove:
      state.members.remove(id: id)
      if state.expandedMemberID == id { state.expandedMemberID = nil }
      refreshSuggestions(&state)
      return .merge(.cancel(id: CancelID.refs(id)), preflightDebounced(&state))

    case .nameChanged(let name):
      state.members[id: id]?.name = name
      state.members[id: id]?.nameEditedManually = true
      return preflightDebounced(&state)

    case .modeChanged(let mode):
      state.members[id: id]?.mode = mode
      if mode == .existingRemote {
        // Seed the ref with the repository's default and follow it for the
        // branch name unless the user already typed one.
        if state.members[id: id]?.remoteRef == nil {
          let defaultRef = state.members[id: id]?.refs.inventory?.defaultBaseRef
          state.members[id: id]?.remoteRef = defaultRef
        }
        if state.members[id: id]?.branchEditedManually == false, let branch = state.members[id: id]?.remoteRefBranch {
          state.members[id: id]?.branch = branch
        }
      } else if state.members[id: id]?.branchEditedManually == false {
        let shared = state.sharedBranch
        state.members[id: id]?.branch = shared
      }
      return preflightDebounced(&state)

    case .branchChanged(let branch):
      state.members[id: id]?.branch = branch
      state.members[id: id]?.branchEditedManually = true
      return preflightDebounced(&state)

    case .useSharedBranchTapped:
      state.members[id: id]?.branchEditedManually = false
      state.members[id: id]?.baseRefEditedManually = false
      let shared = state.sharedBranch
      let sharedBase = state.sharedBaseRef
      let applies = sharedBaseRefApplicable(sharedBase, to: state.members[id: id])
      state.members[id: id]?.branch = shared
      state.members[id: id]?.baseRef = applies ? sharedBase : nil
      return preflightDebounced(&state)

    case .baseRefChanged(let ref):
      state.members[id: id]?.baseRef = ref
      state.members[id: id]?.baseRefEditedManually = true
      return .none

    case .remoteRefChanged(let ref):
      state.members[id: id]?.remoteRef = ref
      // A different ref means a different local branch; the reset choice
      // belonged to the old one.
      state.members[id: id]?.localConflict = .keepLocal
      if state.members[id: id]?.branchEditedManually == false, let branch = state.members[id: id]?.remoteRefBranch {
        state.members[id: id]?.branch = branch
      }
      return preflightDebounced(&state)

    case .localConflictChanged(let choice):
      state.members[id: id]?.localConflict = choice
      return .none

    case .cloneDestinationChanged(let path):
      guard case .remote(let url, _, _) = state.members[id: id]?.source else { return .none }
      state.members[id: id]?.source = .remote(url: url, cloneDestination: path, destinationEditedManually: true)
      return preflightDebounced(&state)

    case .browseCloneDestinationTapped:
      return .run { [picker = folderPicker] send in
        let url = await picker.pick("Clone Into")
        await send(.member(id, .cloneDestinationPicked(url)))
      }

    case .cloneDestinationPicked(let url):
      guard let url, case .remote(let remoteURL, _, _) = state.members[id: id]?.source,
        let member = state.members[id: id]
      else { return .none }
      // The picker returns a parent; the clone gets the repository's name.
      let destination = url.appending(path: member.source.suggestedName).path(percentEncoded: false)
      state.members[id: id]?.source = .remote(
        url: remoteURL, cloneDestination: destination, destinationEditedManually: true)
      return preflightDebounced(&state)

    case .loadRefsTapped:
      guard let member = state.members[id: id] else { return .none }
      state.members[id: id]?.refs = .loading
      return loadRefs(for: member)

    case .refsLoaded(let inventory):
      state.members[id: id]?.refs = .loaded(inventory)
      guard let member = state.members[id: id] else { return .none }
      if member.mode == .newBranch, !member.baseRefEditedManually {
        let sharedBase = state.sharedBaseRef
        let applies = sharedBaseRefApplicable(sharedBase, to: member)
        state.members[id: id]?.baseRef = applies ? sharedBase : nil
      }
      if member.mode == .existingRemote, member.remoteRef == nil {
        state.members[id: id]?.remoteRef = inventory.defaultBaseRef
        if !member.branchEditedManually, let branch = state.members[id: id]?.remoteRefBranch {
          state.members[id: id]?.branch = branch
        }
      }
      return .none

    case .refsFailed(let message):
      state.members[id: id]?.refs = .failed(message)
      return .none
    }
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
      state.expandedMemberID = id
    case .manifestWritten:
      state.creation = .finalizing("Registering…")
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

  private func appendMember(source: MemberDraft.Source, to state: inout State) -> Effect<Action> {
    var name = source.suggestedName
    let taken = Set(state.members.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) })
    var suffix = 2
    let base = name
    while taken.contains(name) {
      name = "\(base)-\(suffix)"
      suffix += 1
    }
    var member = MemberDraft(id: uuid(), source: source, name: name, branch: state.sharedBranch)
    member.refs = .loading
    state.members.append(member)
    refreshSuggestions(&state)
    return .merge(loadRefs(for: member), preflightDebounced(&state))
  }

  private func loadRefs(for member: MemberDraft) -> Effect<Action> {
    let id = member.id
    let client = gitWorktreeClient
    switch member.source {
    case .project(_, let gitRoot), .localRepo(let gitRoot), .bareRepo(let gitRoot):
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
    case .remote(let url, _, _):
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
          await send(
            .member(
              id,
              .refsFailed("Timed out after \(Int(Self.remoteRefsTimeout.components.seconds)) s reaching the remote.")))
        } catch {
          await send(
            .member(id, .refsFailed("Couldn't read the remote's branches: \(WorkspaceClient.describe(error))")))
        }
      }
      .cancellable(id: CancelID.refs(id), cancelInFlight: true)
    }
  }

  private nonisolated struct RemoteRefsTimeout: Error {}

  private func resolvePath(_ path: String, _ state: inout State) -> Effect<Action> {
    state.isResolvingAdd = true
    state.addIssue = nil
    return .run { [cli = gitCLI] send in
      let probe = try? await cli.inspectRepository(at: path)
      await send(.addPathResolved(path: path, probe: probe))
    }
    .cancellable(id: CancelID.addResolve, cancelInFlight: true)
  }

  private func submitAddEntry(_ state: inout State) -> Effect<Action> {
    switch state.addKind {
    case .empty:
      return .none
    case .url(let url):
      let key = AddEntryClassifier.normalizedRemoteKey(url)
      if state.members.contains(where: {
        if case .remote(let existing, _, _) = $0.source {
          return AddEntryClassifier.normalizedRemoteKey(existing) == key
        }
        return false
      }) {
        state.addIssue = "Already in the list."
        return .none
      }
      let name = WorkspaceLayout.repositoryName(fromRemoteURL: url) ?? "repository"
      let destination = (WorkspaceLayout.defaultSourcesDirectory().path(percentEncoded: false) as NSString)
        .appendingPathComponent(name)
      clearAddField(&state)
      return appendMember(
        source: .remote(url: url, cloneDestination: destination, destinationEditedManually: false), to: &state)
    case .path(let path, let exists):
      guard exists else {
        state.addIssue = "No folder at \((path as NSString).abbreviatingWithTildeInPath)."
        return .none
      }
      return resolvePath(path, &state)
    case .search(let query):
      guard !state.addSuggestions.isEmpty else {
        state.addIssue = "No open project matches \"\(query)\"."
        return .none
      }
      let index = min(state.addHighlightedIndex ?? 0, state.addSuggestions.count - 1)
      return .send(.addSuggestionTapped(state.addSuggestions[index].id))
    }
  }

  private func clearAddField(_ state: inout State) {
    state.addDraft = ""
    state.addKind = .empty
    state.addIssue = nil
    state.addHighlightedIndex = nil
    refreshSuggestions(&state)
  }

  /// Candidates not yet in the list, ranked against the search text; empty
  /// unless the field holds a search.
  private func refreshSuggestions(_ state: inout State) {
    let used = Set(
      state.members.compactMap { member -> ProjectID? in
        if case .project(let id, _) = member.source { return id }
        return nil
      })
    let available = state.candidates.filter { !used.contains($0.id) }
    switch state.addKind {
    case .search(let query):
      state.addSuggestions = AddEntryClassifier.rank(available, query: query, name: \.name) {
        ($0.gitRoot as NSString).lastPathComponent
      }
    case .empty:
      state.addSuggestions = Array(available.prefix(6))
    case .url, .path:
      state.addSuggestions = []
    }
    if state.addSuggestions.isEmpty {
      state.addHighlightedIndex = nil
    } else if let index = state.addHighlightedIndex {
      state.addHighlightedIndex = min(index, state.addSuggestions.count - 1)
    } else {
      state.addHighlightedIndex = 0
    }
  }

  /// Rows on a new branch that have not been overridden follow the shared
  /// branch.
  private func propagateSharedBranch(_ state: inout State) {
    let shared = state.sharedBranch
    for member in state.members where member.mode == .newBranch && !member.branchEditedManually {
      state.members[id: member.id]?.branch = shared
    }
  }

  /// A shared base ref applies to a row only when its repository has it;
  /// before refs load it is taken on trust and re-checked in `refsLoaded`.
  private func sharedBaseRefApplicable(_ ref: String?, to member: MemberDraft?) -> Bool {
    guard let ref, let member else { return false }
    guard let inventory = member.refs.inventory else { return true }
    return inventory.contains(ref)
  }

  private func preflightDebounced(_ state: inout State) -> Effect<Action> {
    guard state.creation == .idle else { return .none }
    return .run { [clock] send in
      try await clock.sleep(for: Self.preflightDebounce)
      await send(.preflightTick)
    }
    .cancellable(id: CancelID.preflight, cancelInFlight: true)
  }
}

// MARK: - File existence dependency

/// `FileManager.fileExists` behind a dependency so the add field's path
/// detection is deterministic in tests.
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
