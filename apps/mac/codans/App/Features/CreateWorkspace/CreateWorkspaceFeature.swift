import CodansCore
import ComposableArchitecture
import Foundation

/// Reducer behind the New Workspace sheet and, in add mode, a workspace's
/// Add Repository sheet. Collects a title, where the folder goes, and the
/// projects to check out: each is added or edited in a dialog (an open
/// project, a folder, or a remote URL, and how it is checked out) and listed
/// as one row. Then hands a `WorkspacePlan` to `WorkspaceClient`'s streaming
/// creation and shows its progress per project. Its responsibility ends at
/// `delegate(.created)` / `delegate(.added)`; the client has registered and
/// reconciled by then.
@Reducer
struct CreateWorkspaceFeature {
  /// A registered local git Project offered as a member.
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

    var members: IdentifiedArrayOf<MemberDraft> = []
    /// The Add / Edit dialog, while it is open.
    var editor: MemberEditor?

    var creation: CreationState = .idle
    var creationToken: UUID?

    init(
      candidates: [Candidate],
      mode: Mode = .create,
      locationPath: String = WorkspaceLayout.defaultWorkspacesDirectory().path(percentEncoded: false)
    ) {
      self.mode = mode
      self.candidates = IdentifiedArray(uniqueElements: candidates)
      self.locationPath = locationPath
      if case .add(_, let title, _, _) = mode {
        titleDraft = title
      }
    }

    var isAddMode: Bool {
      if case .add = mode { return true }
      return false
    }

    var minimumMembers: Int {
      isAddMode ? 1 : WorkspacePlan.minimumMembers
    }

    /// Add mode takes exactly one project.
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

    /// The name a new branch gets when the user leaves it blank: the
    /// workspace title as a folder name.
    var defaultBranch: String {
      let title = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
      return title.isEmpty ? "" : WorkspaceLayout.folderName(forTitle: title)
    }

    /// Open projects not in the list, apart from the row being edited.
    var availableCandidates: [Candidate] {
      let editingID = editor?.id
      let used = Set(
        members.compactMap { member -> ProjectID? in
          guard member.id != editingID, case .project(let id, _, _) = member.source else { return nil }
          return id
        })
      return candidates.filter { !used.contains($0.id) }
    }

    // MARK: Plan

    /// The plan as it stands; creation uses it once nothing blocks it.
    var draftPlan: WorkspacePlan {
      plan(of: Array(members))
    }

    /// What preflight checks: the list with the dialog's draft in place, so
    /// the dialog sees findings before its project is added.
    var checkedPlan: WorkspacePlan {
      var drafts = Array(members)
      if let draft = editor?.draft {
        if let index = drafts.firstIndex(where: { $0.id == draft.id }) {
          drafts[index] = draft
        } else {
          drafts.append(draft)
        }
      }
      return plan(of: drafts)
    }

    private func plan(of drafts: [MemberDraft]) -> WorkspacePlan {
      WorkspacePlan(
        title: titleDraft.trimmingCharacters(in: .whitespacesAndNewlines),
        rootPath: rootPath,
        members: drafts.map { member in
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
      member.branch(defaultBranch: defaultBranch)
    }

    func checkout(for member: MemberDraft) -> WorkspaceCheckout {
      let branch = branch(for: member)
      switch member.mode {
      case .newBranch:
        return .newBranch(branch: branch, baseRef: member.baseRef)
      case .existing:
        guard member.existingRefIsRemote else { return .existingBranch(branch) }
        return .remoteTrackingRef(
          remoteRef: member.existingRef ?? "", branch: branch, resetLocal: member.localConflict == .resetToRemote)
      }
    }

    /// How a row describes its checkout in one line.
    func checkoutSummary(for member: MemberDraft) -> String {
      let branch = branch(for: member)
      switch member.mode {
      case .newBranch:
        let base = member.baseRef ?? member.refs.inventory?.defaultBaseRef ?? "the default branch"
        return branch.isEmpty ? "New branch from \(base), named after the title" : "New branch \(branch) from \(base)"
      case .existing:
        guard !branch.isEmpty else { return "Existing branch" }
        guard let remoteRef = member.existingRef, member.existingRefIsRemote else { return "Branch \(branch)" }
        guard member.hasLocalConflict else { return "Branch \(branch), tracking \(remoteRef)" }
        return member.localConflict == .resetToRemote
          ? "Branch \(branch), reset to \(remoteRef)"
          : "Local branch \(branch), tracking \(remoteRef)"
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
        issues.append(.blocking("Another project already uses the folder name \u{201C}\(name)\u{201D}."))
      } else if case .add(_, _, _, let existing) = mode, existing.contains(name) {
        issues.append(.blocking("The workspace already has a folder named \u{201C}\(name)\u{201D}."))
      }
      // A folder-name problem already covers "that folder exists".
      let hasNameIssue = !issues.isEmpty
      issues.append(contentsOf: checkoutIssues(for: member))
      if case .failed(let message) = member.refs {
        // Without the list there is no branch to choose; a new branch can
        // still be created from the repository's default.
        issues.append(member.mode == .existing ? .blocking(message) : .warning(message))
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
      case .existing:
        if member.refs.isLoading { return [.incomplete("Loading branches for \(label)…")] }
        guard let ref = member.existingRef, !ref.isEmpty else {
          return [.incomplete("Choose a branch for \(label).")]
        }
        guard let inventory else { return [] }
        if inventory.local.contains(ref) {
          return checkedOutIssue(branch: ref, inventory: inventory)
        }
        guard inventory.remote.contains(ref) else {
          return [.blocking("\u{201C}\(ref)\u{201D} is not a branch of this repository.")]
        }
        // A remote branch is checked out as its local twin. Keep checks that
        // branch out; reset moves it with `-B`. Git refuses both while
        // another worktree has it.
        return member.hasLocalConflict ? checkedOutIssue(branch: branch, inventory: inventory) : []
      }
    }

    /// Git keeps a branch in one worktree at a time, so a branch the source
    /// repository (or another checkout) already holds cannot be checked out
    /// here. The message says what to do about it instead of only refusing.
    private func checkedOutIssue(branch: String, inventory: RefInventory) -> [MemberIssue] {
      guard let path = inventory.checkedOut[branch] else { return [] }
      return [
        .blocking(
          "\u{201C}\(branch)\u{201D} is already checked out at \((path as NSString).abbreviatingWithTildeInPath), "
            + "and git allows that in one place only. Choose New branch to start one from it, or pick another branch.")
      ]
    }

    /// Workspace-level issues: what is still missing, then preflight.
    var workspaceIssues: [MemberIssue] {
      var issues: [MemberIssue] = []
      if !isAddMode, titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        issues.append(.incomplete("Enter a title."))
      }
      if members.count < minimumMembers {
        issues.append(.incomplete(isAddMode ? "Add a project." : "Add at least two projects."))
      }
      issues.append(contentsOf: rootIssues)
      return issues
    }

    var hasBlockingIssues: Bool {
      workspaceIssues.contains(where: \.blocksCreation)
        || members.contains { issues(for: $0).contains(where: \.blocksCreation) }
    }

    var canCreate: Bool {
      plan != nil && !creation.isBusy
    }

    var createButtonTitle: String {
      isAddMode ? "Add" : "Create"
    }

    /// Why Create is disabled, for the bottom bar: the first thing still
    /// missing, or a pointer to the problems shown in the list.
    var createHint: String? {
      guard creation == .idle, !canCreate else { return nil }
      let all = workspaceIssues + members.flatMap { issues(for: $0) }
      if let missing = all.first(where: { $0.severity == .incomplete }) { return missing.message }
      if all.contains(where: { $0.severity == .blocking }) { return "Fix the problems above to continue." }
      return nil
    }

    // MARK: Editor

    /// The open dialog's findings.
    var editorIssues: [MemberIssue] {
      editor.map(issues(inEditor:)) ?? []
    }

    /// A dialog's findings: the source first, then the draft's own. Takes
    /// the dialog rather than reading `editor`, so a closing sheet can show
    /// the copy it still holds.
    func issues(inEditor editor: MemberEditor) -> [MemberIssue] {
      var issues: [MemberIssue] = []
      if let sourceIssue = editor.sourceIssue {
        issues.append(.blocking(sourceIssue))
      }
      guard let draft = editor.draft else {
        if editor.sourceIssue == nil {
          issues.append(
            .incomplete(editor.kind == .remote ? "Enter the repository\u{2019}s URL." : "Choose a repository folder."))
        }
        return issues
      }
      if !editor.isURLApplied, editor.sourceIssue == nil {
        issues.append(.incomplete("Enter a git URL, such as git@github.com:org/repo.git."))
      }
      // A blank new branch is named after the title, which may still be
      // blank; the main sheet asks for the title.
      let followsTitle = draft.mode == .newBranch && branch(for: draft).isEmpty
      issues.append(contentsOf: self.issues(for: draft).filter { !(followsTitle && $0.severity == .incomplete) })
      return issues
    }

    /// A dialog opens only when there is room for another project, no other
    /// dialog is open, and nothing is being created.
    var canOpenEditor: Bool {
      canAddMembers && editor == nil && !creation.isBusy
    }

    var canSaveEditor: Bool {
      editor.map(canSave(inEditor:)) ?? false
    }

    func canSave(inEditor editor: MemberEditor) -> Bool {
      guard editor.draft != nil, !editor.isResolvingSource else { return false }
      return !issues(inEditor: editor).contains(where: \.blocksCreation)
    }

    /// A folder name for `source` no other row uses.
    func suggestedName(for source: MemberDraft.Source, excluding id: MemberDraft.ID?) -> String {
      var taken = Set(
        members.filter { $0.id != id }.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) })
      if case .add(_, _, _, let existing) = mode {
        taken.formUnion(existing)
      }
      let base = source.suggestedName
      var name = base
      var suffix = 2
      while taken.contains(name) {
        name = "\(base)-\(suffix)"
        suffix += 1
      }
      return name
    }
  }

  enum Action: Equatable {
    // Workspace
    case titleChanged(String)
    case chooseLocationTapped
    case locationPicked(URL?)
    // List
    case addProjectTapped(ProjectID)
    case addFolderTapped
    case addFolderPicked(URL?)
    case addRemoteTapped
    case editTapped(MemberDraft.ID)
    /// A row, or the dialog's draft when the id is its.
    case member(MemberDraft.ID, MemberAction)
    case editor(EditorAction)
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
      case existingRefChanged(String?)
      case localConflictChanged(MemberDraft.LocalConflictResolution)
      case chooseCloneDestinationTapped
      case cloneDestinationPicked(URL?)
      case retryRefsTapped
      case refsLoaded(RefInventory)
      case refsFailed(String)
    }

    enum EditorAction: Equatable {
      case chooseFolderTapped
      case folderPicked(URL?)
      case folderResolved(path: String, probe: RepositoryProbe?)
      case urlChanged(String)
      /// Typing paused; a URL is applied, anything else waits for Return.
      case urlSettled
      case urlSubmitted
      case saveTapped
      case cancelTapped
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
    case folderResolve
    case urlSettle
    case preflight
    case creation
  }

  private nonisolated static let remoteRefsTimeout: Duration = .seconds(20)
  private nonisolated static let preflightDebounce: Duration = .milliseconds(300)
  private nonisolated static let urlSettleDelay: Duration = .milliseconds(600)

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

      // MARK: List

      case .addProjectTapped(let projectID):
        guard state.canOpenEditor, let candidate = state.availableCandidates.first(where: { $0.id == projectID })
        else { return .none }
        state.editor = MemberEditor(id: uuid(), kind: .project)
        return setEditorSource(.project(candidate.id, name: candidate.name, gitRoot: candidate.gitRoot), &state)

      case .addFolderTapped:
        guard state.canOpenEditor else { return .none }
        return .run { [picker = folderPicker] send in
          await send(.addFolderPicked(await picker.pick("Add Folder")))
        }

      case .addFolderPicked(let url):
        // The dialog opens on the picked folder, which may still turn out not
        // to be a repository; it says so and offers the picker again.
        guard let url, state.canOpenEditor else { return .none }
        state.editor = MemberEditor(id: uuid(), kind: .folder)
        return resolveFolder(url, &state)

      case .addRemoteTapped:
        guard state.canOpenEditor else { return .none }
        state.editor = MemberEditor(id: uuid(), kind: .remote)
        return .none

      case .editTapped(let id):
        guard let member = state.members[id: id], state.editor == nil, !state.creation.isBusy else {
          return .none
        }
        state.editor = MemberEditor(id: id, kind: .edit, draft: member)
        return .none

      case .member(let id, let memberAction):
        guard state.members[id: id] != nil || state.editor?.draft?.id == id else { return .none }
        return reduceMember(id: id, action: memberAction, state: &state)

      case .editor(let editorAction):
        guard state.editor != nil else { return .none }
        return reduceEditor(editorAction, state: &state)

      // MARK: Validation

      case .preflightTick:
        guard state.creation == .idle else { return .none }
        let plan = state.checkedPlan
        return .run { [client = workspaceClient] send in
          await send(.preflightFinished(await client.preflight(plan)))
        }
        .cancellable(id: CancelID.preflight, cancelInFlight: true)

      case .preflightFinished(let result):
        state.rootIssues = result.rootIssues.map(MemberIssue.init(preflight:))
        func issues(named name: String) -> [WorkspacePreflight.Issue] {
          result.memberIssues[name.trimmingCharacters(in: .whitespacesAndNewlines)] ?? []
        }
        // The row being edited was checked as the dialog's draft; it takes
        // those findings on Save.
        let editingID = state.editor?.draft?.id
        for id in state.members.ids where id != editingID {
          let name = state.members[id: id]?.name ?? ""
          state.members[id: id]?.preflightIssues = issues(named: name)
        }
        if let draft = state.editor?.draft {
          state.editor?.draft?.preflightIssues = issues(named: draft.name)
        }
        return .none

      // MARK: Creation

      case .createButtonTapped:
        guard let plan = state.plan, !state.creation.isBusy, state.editor == nil else { return .none }
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
      guard state.members[id: id] != nil, state.editor == nil, !state.creation.isBusy else { return .none }
      state.members.remove(id: id)
      return .merge(.cancel(id: CancelID.refs(id)), edited(&state))

    case .chooseCloneDestinationTapped:
      return .run { [picker = folderPicker] send in
        await send(.member(id, .cloneDestinationPicked(await picker.pick("Clone Into"))))
      }

    case .cloneDestinationPicked(let url):
      guard let url else { return .none }
      update(id, &state) { draft in
        guard case .remote(let remoteURL, _) = draft.source else { return }
        // The picker returns a parent; the clone gets the repository's name.
        let destination = url.appending(path: draft.source.title).path(percentEncoded: false)
        draft.source = .remote(url: remoteURL, cloneDestination: destination)
      }
      return edited(&state)

    case .retryRefsTapped:
      guard let draft = state.editor?.draft?.id == id ? state.editor?.draft : state.members[id: id] else {
        return .none
      }
      updateEverywhere(id, &state) { $0.refs = .loading }
      return loadRefs(for: draft)

    case .refsLoaded(let inventory):
      updateEverywhere(id, &state) { $0.refs = .loaded(inventory) }
      return .none

    case .refsFailed(let message):
      updateEverywhere(id, &state) { $0.refs = .failed(message) }
      return .none

    case .nameChanged, .modeChanged, .branchOverrideChanged, .baseRefChanged, .existingRefChanged,
      .localConflictChanged:
      if case .nameChanged = action, state.editor?.draft?.id == id {
        state.editor?.nameEditedManually = true
      }
      update(id, &state) { Self.apply(action, to: &$0) }
      return edited(&state)
    }
  }

  /// The field edits, which differ only in what they set.
  private static func apply(_ action: Action.MemberAction, to draft: inout MemberDraft) {
    switch action {
    case .nameChanged(let name):
      draft.name = name
    case .modeChanged(let mode):
      // No remote branch is picked for the user: the default branch's local
      // twin is usually checked out in the source repository already.
      draft.mode = mode
    case .branchOverrideChanged(let branch):
      draft.branchOverride = branch
    case .baseRefChanged(let ref):
      draft.baseRef = ref
    case .existingRefChanged(let ref):
      draft.existingRef = ref
      // Another branch means another local twin; the reset choice belonged
      // to the old one.
      draft.localConflict = .keepLocal
    case .localConflictChanged(let choice):
      draft.localConflict = choice
    case .remove, .chooseCloneDestinationTapped, .cloneDestinationPicked, .retryRefsTapped, .refsLoaded,
      .refsFailed:
      break
    }
  }

  /// An edit goes to the dialog's draft when the id is its, else the row.
  private func update(_ id: MemberDraft.ID, _ state: inout State, _ body: (inout MemberDraft) -> Void) {
    if var draft = state.editor?.draft, draft.id == id {
      body(&draft)
      state.editor?.draft = draft
    } else if var member = state.members[id: id] {
      body(&member)
      state.members[id: id] = member
    }
  }

  /// Facts about the repository reach both copies of an edited row.
  private func updateEverywhere(_ id: MemberDraft.ID, _ state: inout State, _ body: (inout MemberDraft) -> Void) {
    if var draft = state.editor?.draft, draft.id == id {
      body(&draft)
      state.editor?.draft = draft
    }
    if var member = state.members[id: id] {
      body(&member)
      state.members[id: id] = member
    }
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

  // MARK: - Editor

  private func reduceEditor(_ action: Action.EditorAction, state: inout State) -> Effect<Action> {
    switch action {
    case .chooseFolderTapped:
      guard state.editor?.kind == .folder else { return .none }
      return .run { [picker = folderPicker] send in
        await send(.editor(.folderPicked(await picker.pick("Choose Folder"))))
      }

    case .folderPicked(let url):
      guard let url, state.editor?.kind == .folder else { return .none }
      return resolveFolder(url, &state)

    case .folderResolved(let path, let probe):
      state.editor?.isResolvingSource = false
      return useFolder(path, probe: probe, &state)

    case .urlChanged(let text):
      state.editor?.urlText = text
      state.editor?.sourceIssue = nil
      return .run { [clock] send in
        try await clock.sleep(for: Self.urlSettleDelay)
        await send(.editor(.urlSettled))
      }
      .cancellable(id: CancelID.urlSettle, cancelInFlight: true)

    case .urlSettled:
      return applyURL(&state, reportsProblems: false)

    case .urlSubmitted:
      return .merge(.cancel(id: CancelID.urlSettle), applyURL(&state, reportsProblems: true))

    case .saveTapped:
      guard state.canSaveEditor, let editor = state.editor, let draft = editor.draft else { return .none }
      if editor.isNew {
        state.members.append(draft)
      } else {
        state.members[id: draft.id] = draft
      }
      state.editor = nil
      return .merge(.cancel(id: CancelID.urlSettle), .cancel(id: CancelID.folderResolve), edited(&state))

    case .cancelTapped:
      guard let editor = state.editor else { return .none }
      state.editor = nil
      var effects: [Effect<Action>] = [
        .cancel(id: CancelID.urlSettle), .cancel(id: CancelID.folderResolve), schedulePreflight(state),
      ]
      // An edited row keeps its own load; a discarded draft does not.
      if editor.isNew {
        effects.append(.cancel(id: CancelID.refs(editor.id)))
      }
      return .merge(effects)
    }
  }

  private func resolveFolder(_ url: URL, _ state: inout State) -> Effect<Action> {
    state.editor?.sourceIssue = nil
    state.editor?.isResolvingSource = true
    let path = url.path(percentEncoded: false)
    return .run { [cli = gitCLI] send in
      let probe = try? await cli.inspectRepository(at: path)
      await send(.editor(.folderResolved(path: path, probe: probe)))
    }
    .cancellable(id: CancelID.folderResolve, cancelInFlight: true)
  }

  /// A picked folder as the dialog's source: its repository, which may be
  /// an open project, unless it can't be used.
  private func useFolder(_ path: String, probe: RepositoryProbe?, _ state: inout State) -> Effect<Action> {
    state.editor?.sourceIssue = nil
    let shown = (path as NSString).abbreviatingWithTildeInPath
    guard let probe else {
      state.editor?.sourceIssue = "\(shown) is not a git repository."
      return .none
    }
    guard !probe.isBare else {
      state.editor?.sourceIssue = "\(shown) is a bare repository, which workspaces do not support."
      return .none
    }
    let root = HierarchyManager.canonicalPath(probe.root)
    let editingID = state.editor?.id
    if state.members.contains(where: {
      $0.id != editingID && !$0.source.isRemote && HierarchyManager.canonicalPath($0.source.gitRoot) == root
    }) {
      state.editor?.sourceIssue = "\((root as NSString).abbreviatingWithTildeInPath) is already in the list."
      return .none
    }
    if let candidate = state.candidates.first(where: { HierarchyManager.canonicalPath($0.gitRoot) == root }) {
      return setEditorSource(.project(candidate.id, name: candidate.name, gitRoot: candidate.gitRoot), &state)
    }
    return setEditorSource(.localRepo(gitRoot: root), &state)
  }

  /// Points the dialog's draft at `source`, creating the draft on first use.
  /// Another repository has other branches, so branch choices reset and
  /// its refs load.
  private func setEditorSource(_ source: MemberDraft.Source, _ state: inout State) -> Effect<Action> {
    guard let editor = state.editor, editor.draft?.source != source else { return .none }
    var draft = editor.draft ?? MemberDraft(id: editor.id, source: source, name: "")
    draft.source = source
    if !editor.nameEditedManually {
      draft.name = state.suggestedName(for: source, excluding: editor.id)
    }
    draft.baseRef = nil
    draft.existingRef = nil
    draft.localConflict = .keepLocal
    draft.preflightIssues = []
    draft.refs = .loading
    state.editor?.draft = draft
    return .merge(loadRefs(for: draft), edited(&state))
  }

  private func applyURL(_ state: inout State, reportsProblems: Bool) -> Effect<Action> {
    guard let editor = state.editor, editor.kind == .remote else { return .none }
    switch AddEntryClassifier.classify(editor.urlText, fileExists: fileExists) {
    case .empty:
      guard editor.draft != nil else { return .none }
      state.editor?.draft = nil
      return .cancel(id: CancelID.refs(editor.id))
    case .url(let url):
      let key = AddEntryClassifier.normalizedRemoteKey(url)
      if case .remote(let current, _) = editor.draft?.source, AddEntryClassifier.normalizedRemoteKey(current) == key {
        return .none
      }
      let isListed = state.members.contains {
        guard $0.id != editor.id, case .remote(let existing, _) = $0.source else { return false }
        return AddEntryClassifier.normalizedRemoteKey(existing) == key
      }
      guard !isListed else {
        state.editor?.sourceIssue = "This repository is already in the list."
        return .none
      }
      let name = WorkspaceLayout.repositoryName(fromRemoteURL: url) ?? "repository"
      // A clone folder picked for an earlier URL stays the parent.
      let parent =
        editor.draft.map { ($0.source.gitRoot as NSString).deletingLastPathComponent }
        ?? WorkspaceLayout.defaultSourcesDirectory().path(percentEncoded: false)
      return setEditorSource(
        .remote(url: url, cloneDestination: (parent as NSString).appendingPathComponent(name)), &state)
    case .path:
      if reportsProblems {
        state.editor?.sourceIssue = "Enter a URL. To use a folder on this Mac, add a local repository."
      }
      return .none
    case .unrecognized:
      if reportsProblems {
        state.editor?.sourceIssue = "Enter a git URL, such as git@github.com:org/repo.git."
      }
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
