import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

/// The New Workspace sheet's reducer: derivation of folder and branch from
/// the title, the unified add field, per-row ref loading and issues, the
/// debounced preflight, and the creation stream's effect on rows. Effects
/// are stubbed closure by closure; git never runs.
@MainActor
struct CreateWorkspaceFeatureTests {
  private typealias Feature = CreateWorkspaceFeature

  private static func defaultRoot(_ slug: String) -> String {
    (WorkspaceLayout.defaultWorkspacesDirectory().path(percentEncoded: false) as NSString)
      .appendingPathComponent(slug)
  }

  private static func defaultSource(_ name: String) -> String {
    (WorkspaceLayout.defaultSourcesDirectory().path(percentEncoded: false) as NSString)
      .appendingPathComponent(name)
  }

  private let app = Feature.Candidate(id: ProjectID(), name: "app", gitRoot: "/src/app")
  private let api = Feature.Candidate(id: ProjectID(), name: "api", gitRoot: "/src/api")

  private let appRefs = RefInventory(
    local: ["main", "wip"], remote: ["origin/main", "origin/feat/x"], defaultBaseRef: "origin/main",
    checkedOut: ["main": "/src/app"])

  /// A git client answering every repository with `inventory`.
  private func gitClient(_ inventory: RefInventory) -> GitWorktreeClient {
    var client = GitWorktreeClient.testValue
    client.branchRefs = { _ in inventory.local + inventory.remote }
    client.localBranchNames = { _ in Set(inventory.local) }
    client.lsWorktrees = { _ in
      inventory.checkedOut.map { GitWtEntry(branch: $0.key, path: $0.value, head: "abc", isBare: false) }
    }
    client.defaultRemoteBranchRef = { _ in inventory.defaultBaseRef }
    return client
  }

  private func makeStore(
    _ initial: Feature.State,
    git: GitWorktreeClient? = nil,
    workspace: WorkspaceClient? = nil,
    clock: TestClock<Duration> = TestClock(),
    fileExists: @escaping @Sendable (String) -> Bool = { _ in false }
  ) -> TestStore<Feature.State, Feature.Action> {
    TestStore(initialState: initial) {
      Feature()
    } withDependencies: {
      $0.gitWorktreeClient = git ?? gitClient(appRefs)
      var stub = WorkspaceClient.testValue
      stub.preflight = { _ in WorkspacePreflight() }
      $0[WorkspaceClient.self] = workspace ?? stub
      $0.continuousClock = clock
      $0.uuid = .incrementing
      $0.fileExists = fileExists
      $0[GitWorktreeCLI.self] = GitWorktreeCLI()
    }
  }

  private func settleDebounce(_ store: TestStore<Feature.State, Feature.Action>, clock: TestClock<Duration>) async {
    await clock.advance(by: .milliseconds(300))
    await store.receive(\.preflightTick)
    await store.receive(\.preflightFinished)
  }

  // MARK: - Derivation

  @Test
  func preselectedProjectBecomesTheFirstRowAndLoadsRefs() async {
    let clock = TestClock()
    let store = makeStore(Feature.State(candidates: [app, api], preselected: app.id), clock: clock)
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.onAppear)
    await store.receive(\.member) {
      $0.members[0].refs = .loaded(appRefs)
      $0.members[0].baseRef = nil
    }
    #expect(store.state.members.count == 1)
    #expect(store.state.members[0].source == .project(app.id, gitRoot: "/src/app"))
    #expect(store.state.members[0].name == "app")
    #expect(store.state.preselected == nil)
    await settleDebounce(store, clock: clock)
  }

  @Test
  func titleDerivesFolderAndSharedBranchUntilEditedByHand() async {
    let clock = TestClock()
    let store = makeStore(Feature.State(candidates: []), clock: clock)
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.titleChanged("Checkout Flow")) {
      $0.titleDraft = "Checkout Flow"
      $0.rootPathDraft = Self.defaultRoot("checkout-flow")
      $0.sharedBranch = "checkout-flow"
    }
    await store.send(.sharedBranchChanged("feat/x")) {
      $0.sharedBranch = "feat/x"
      $0.sharedBranchEditedManually = true
    }
    await store.send(.rootPathChanged("/tmp/custom")) {
      $0.rootPathDraft = "/tmp/custom"
      $0.rootPathEditedManually = true
    }
    // Neither derived field moves once the user owns it.
    await store.send(.titleChanged("Other")) {
      $0.titleDraft = "Other"
    }
  }

  @Test
  func sharedBranchReachesOnlyRowsThatFollowIt() async {
    var initial = Feature.State(candidates: [app, api])
    initial.sharedBranch = "feat/a"
    var first = MemberDraft(id: UUID(1), source: .project(app.id, gitRoot: "/src/app"), name: "app", branch: "feat/a")
    first.refs = .loaded(appRefs)
    var second = MemberDraft(id: UUID(2), source: .project(api.id, gitRoot: "/src/api"), name: "api", branch: "mine")
    second.branchEditedManually = true
    var third = MemberDraft(id: UUID(3), source: .localRepo(gitRoot: "/src/lib"), name: "lib", branch: "main")
    third.mode = .existingLocal
    initial.members = [first, second, third]
    let store = makeStore(initial)
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.sharedBranchChanged("feat/b")) {
      $0.sharedBranch = "feat/b"
      $0.sharedBranchEditedManually = true
      $0.members[0].branch = "feat/b"
      // Overridden and existing-branch rows are untouched.
      $0.members[1].branch = "mine"
      $0.members[2].branch = "main"
    }
    await store.send(.member(UUID(2), .useSharedBranchTapped)) {
      $0.members[1].branch = "feat/b"
      $0.members[1].branchEditedManually = false
    }
    // A shared base ref lands only where the repository has it.
    await store.send(.sharedBaseRefChanged("origin/feat/x")) {
      $0.sharedBaseRef = "origin/feat/x"
      $0.members[0].baseRef = "origin/feat/x"
      $0.members[1].baseRef = "origin/feat/x"  // refs not loaded yet: taken on trust
    }
    await store.send(.member(UUID(2), .refsLoaded(RefInventory(local: ["main"], remote: ["origin/main"])))) {
      $0.members[1].refs = .loaded(RefInventory(local: ["main"], remote: ["origin/main"]))
      $0.members[1].baseRef = nil
    }
    #expect(
      store.state.issues(for: store.state.members[1]).contains { $0.severity == .warning && $0.field == .baseRef })
  }

  // MARK: - Add field

  @Test
  func addFieldClassifiesURLsAndAddsARemoteMember() async {
    let clock = TestClock()
    var git = gitClient(appRefs)
    git.lsRemoteHeads = { _ in RemoteHeads(defaultBranch: "main", branches: ["main", "release"]) }
    var initial = Feature.State(candidates: [app])
    initial.sharedBranch = "feat/x"
    let store = makeStore(initial, git: git, clock: clock)
    store.exhaustivity = .off(showSkippedAssertions: false)

    // A paste-sized URL is added without a Return.
    await store.send(.addDraftChanged("git@github.com:org/lib.git"))
    #expect(store.state.addDraft.isEmpty)
    #expect(store.state.members.count == 1)
    let member = store.state.members[0]
    #expect(
      member.source
        == .remote(
          url: "git@github.com:org/lib.git", cloneDestination: Self.defaultSource("lib"),
          destinationEditedManually: false))
    #expect(member.name == "lib")
    #expect(member.branch == "feat/x")
    await store.receive(\.member) {
      $0.members[0].refs = .loaded(
        RefInventory(local: [], remote: ["origin/main", "origin/release"], defaultBaseRef: "origin/main"))
    }
    // The same remote in another spelling is refused — on paste, so the
    // draft stays for the user to fix.
    await store.send(.addDraftChanged("https://github.com/org/lib")) {
      $0.addDraft = "https://github.com/org/lib"
      $0.addKind = .url("https://github.com/org/lib")
      $0.addSuggestions = []
      $0.addHighlightedIndex = nil
      $0.addIssue = "Already in the list."
    }
    await store.send(.addSubmitted)
    await settleDebounce(store, clock: clock)
  }

  @Test
  func addFieldSearchesOpenProjectsWithKeyboard() async {
    let clock = TestClock()
    let store = makeStore(Feature.State(candidates: [app, api]), clock: clock)
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.addDraftChanged("a")) {
      $0.addDraft = "a"
      $0.addKind = .search("a")
      $0.addSuggestions = [self.app, self.api]
      $0.addHighlightedIndex = 0
    }
    await store.send(.addMoveHighlight(by: 1)) { $0.addHighlightedIndex = 1 }
    await store.send(.addMoveHighlight(by: 5)) { $0.addHighlightedIndex = 1 }
    await store.send(.addSubmitted)
    await store.receive(\.addSuggestionTapped)
    #expect(store.state.members.map(\.name) == ["api"])
    #expect(store.state.addDraft.isEmpty)
    // The added project leaves the suggestions.
    await store.send(.addDraftChanged("a")) {
      $0.addDraft = "a"
      $0.addKind = .search("a")
      $0.addSuggestions = [self.app]
      $0.addHighlightedIndex = 0
    }
    await store.send(.addCleared) {
      $0.addDraft = ""
      $0.addKind = .empty
      $0.addSuggestions = [self.app]
      $0.addHighlightedIndex = 0
    }
    await store.send(.addDraftChanged("zzz")) {
      $0.addDraft = "zzz"
      $0.addKind = .search("zzz")
      $0.addSuggestions = []
      $0.addHighlightedIndex = nil
    }
    await store.send(.addSubmitted) {
      $0.addIssue = "No open project matches \"zzz\"."
    }
    await settleDebounce(store, clock: clock)
  }

  @Test
  func addFieldReportsMissingPathsWithoutProbing() async {
    let store = makeStore(Feature.State(candidates: []))
    await store.send(.addDraftChanged("/nowhere/repo")) {
      $0.addDraft = "/nowhere/repo"
      $0.addKind = .path("/nowhere/repo", exists: false)
    }
    await store.send(.addSubmitted) {
      $0.addIssue = "No folder at /nowhere/repo."
    }
  }

  @Test
  func resolvedPathsBecomeProjectLocalOrBareRows() async {
    let clock = TestClock()
    let store = makeStore(Feature.State(candidates: [app]), clock: clock)
    store.exhaustivity = .off(showSkippedAssertions: false)
    // A path inside an open project resolves to that project.
    await store.send(.addPathResolved(path: "/src/app/sub", probe: RepositoryProbe(root: "/src/app", isBare: false)))
    #expect(store.state.members.last?.source == .project(app.id, gitRoot: "/src/app"))
    await store.send(.addPathResolved(path: "/src/lib", probe: RepositoryProbe(root: "/src/lib", isBare: false)))
    #expect(store.state.members.last?.source == .localRepo(gitRoot: "/src/lib"))
    await store.send(
      .addPathResolved(path: "/mirrors/tool.git", probe: RepositoryProbe(root: "/mirrors/tool.git", isBare: true)))
    #expect(store.state.members.last?.source == .bareRepo(gitRoot: "/mirrors/tool.git"))
    #expect(store.state.members.last?.name == "tool")
    // Duplicates and non-repositories are refused.
    await store.send(.addPathResolved(path: "/src/lib", probe: RepositoryProbe(root: "/src/lib", isBare: false))) {
      $0.isResolvingAdd = false
      $0.addIssue = "Already in the list."
    }
    await store.send(.addPathResolved(path: "/tmp/notes", probe: nil)) {
      $0.addIssue = "/tmp/notes is not a git repository."
    }
    #expect(store.state.members.count == 3)
    await settleDebounce(store, clock: clock)
  }

  // MARK: - Refs and issues

  @Test
  func remoteRefsTimeOutAndCanBeRetried() async {
    let clock = TestClock()
    var git = gitClient(appRefs)
    git.lsRemoteHeads = { _ in
      try await Task.sleep(for: .seconds(60))
      return RemoteHeads()
    }
    var initial = Feature.State(candidates: [])
    initial.members = [
      MemberDraft(
        id: UUID(1), source: .remote(url: "https://h/r", cloneDestination: "/src/r", destinationEditedManually: false),
        name: "r", branch: "x")
    ]
    let store = makeStore(initial, git: git, clock: clock)
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.member(UUID(1), .loadRefsTapped)) {
      $0.members[0].refs = .loading
    }
    await clock.advance(by: .seconds(20))
    await store.receive(\.member) {
      $0.members[0].refs = .failed("Timed out after 20 s reaching the remote.")
    }
    // A failure only warns for a new branch, but blocks a remote checkout.
    #expect(store.state.issues(for: store.state.members[0]).allSatisfy { $0.severity != .blocking })
    await store.send(.member(UUID(1), .modeChanged(.existingRemote)))
    #expect(store.state.issues(for: store.state.members[0]).contains { $0.severity == .blocking && $0.field == .refs })
    // Removing the row cancels an in-flight load.
    await store.send(.member(UUID(1), .loadRefsTapped))
    await store.send(.member(UUID(1), .remove)) {
      $0.members = []
    }
  }

  @Test
  func pureIssuesCoverNamesBranchesAndCheckedOutRefs() async {
    var initial = Feature.State(candidates: [app])
    initial.titleDraft = "T"
    initial.rootPathDraft = "/tmp/ws"
    var first = MemberDraft(id: UUID(1), source: .project(app.id, gitRoot: "/src/app"), name: "app", branch: "wip")
    first.refs = .loaded(appRefs)
    var second = MemberDraft(id: UUID(2), source: .localRepo(gitRoot: "/src/lib"), name: "app", branch: "bad..name")
    second.refs = .loaded(RefInventory(local: ["main"], remote: []))
    initial.members = [first, second]
    let store = makeStore(initial)
    store.exhaustivity = .off(showSkippedAssertions: false)

    let firstIssues = store.state.issues(for: store.state.members[0])
    #expect(firstIssues.contains(.blocking(.name, "Another repository already uses this folder name.")))
    #expect(firstIssues.contains(.blocking(.branch, "Branch exists here. Choose Existing branch or rename.")))
    let secondIssues = store.state.issues(for: store.state.members[1])
    #expect(secondIssues.contains(.blocking(.branch, "Not a valid branch name.")))
    #expect(store.state.plan == nil)

    // Existing local: must exist and not be checked out elsewhere.
    await store.send(.member(UUID(1), .modeChanged(.existingLocal)))
    await store.send(.member(UUID(1), .branchChanged("main")))
    #expect(
      store.state.issues(for: store.state.members[0]).contains {
        $0.field == .branch && $0.message.contains("checked out at")
      })
    await store.send(.member(UUID(1), .branchChanged("nope")))
    #expect(store.state.issues(for: store.state.members[0]).contains(.blocking(.branch, "No local branch named nope.")))

    // Remote branch: the ref defaults to the repository's default, the local
    // branch name follows it, and a same-named local branch shows the choice.
    await store.send(.member(UUID(1), .modeChanged(.existingRemote)))
    #expect(store.state.members[0].remoteRef == "origin/main")
    #expect(store.state.members[0].branch == "nope")  // edited by hand above, so kept
    await store.send(.member(UUID(1), .useSharedBranchTapped))
    await store.send(.member(UUID(1), .remoteRefChanged("origin/main")))
    #expect(store.state.members[0].branch == "main")
    #expect(store.state.members[0].hasLocalConflict)
    #expect(store.state.issues(for: store.state.members[0]).contains { $0.severity == .info && $0.field == .remoteRef })
    #expect(
      store.state.checkout(for: store.state.members[0])
        == .remoteTrackingRef(remoteRef: "origin/main", branch: "main", resetLocal: false))
    await store.send(.member(UUID(1), .localConflictChanged(.resetToRemote))) {
      $0.members[0].localConflict = .resetToRemote
    }
    #expect(
      store.state.checkout(for: store.state.members[0])
        == .remoteTrackingRef(remoteRef: "origin/main", branch: "main", resetLocal: true))
    // Picking another ref forgets the reset.
    await store.send(.member(UUID(1), .remoteRefChanged("origin/feat/x"))) {
      $0.members[0].remoteRef = "origin/feat/x"
      $0.members[0].localConflict = .keepLocal
      $0.members[0].branch = "feat/x"
    }
  }

  // MARK: - Preflight

  @Test
  func preflightIsDebouncedAndLandsOnRows() async {
    let clock = TestClock()
    let calls = LockIsolated(0)
    var workspace = WorkspaceClient.testValue
    workspace.preflight = { plan in
      calls.withValue { $0 += 1 }
      #expect(plan.title == "abc")
      return WorkspacePreflight(
        rootIssues: [.init(kind: .rootExists, message: "Folder exists; checkouts are added inside it.")],
        memberIssues: ["app": [.init(kind: .destinationExists, message: "/tmp/ws/app already exists")]])
    }
    var initial = Feature.State(candidates: [app])
    initial.members = [
      MemberDraft(id: UUID(1), source: .project(app.id, gitRoot: "/src/app"), name: "app", branch: "x")
    ]
    let store = makeStore(initial, workspace: workspace, clock: clock)
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.titleChanged("a"))
    await store.send(.titleChanged("ab"))
    await store.send(.titleChanged("abc"))
    await clock.advance(by: .milliseconds(300))
    await store.receive(\.preflightTick)
    await store.receive(\.preflightFinished) {
      $0.rootIssues = [.info(.row, "Folder exists; checkouts are added inside it.")]
      $0.members[0].asyncIssues = [.blocking(.name, "/tmp/ws/app already exists")]
    }
    #expect(calls.value == 1)
    #expect(store.state.plan == nil)
  }

  // MARK: - Creation

  private func readyState() -> Feature.State {
    var initial = Feature.State(candidates: [app, api])
    initial.titleDraft = "T"
    initial.rootPathDraft = "/tmp/ws"
    initial.sharedBranch = "t"
    var first = MemberDraft(id: UUID(1), source: .project(app.id, gitRoot: "/src/app"), name: "app", branch: "t")
    first.refs = .loaded(appRefs)
    var second = MemberDraft(id: UUID(2), source: .project(api.id, gitRoot: "/src/api"), name: "api", branch: "t")
    second.refs = .loaded(appRefs)
    initial.members = [first, second]
    return initial
  }

  @Test
  func createStreamsProgressOntoRowsAndDelegatesOnRegistration() async {
    let created = ProjectID()
    var workspace = WorkspaceClient.testValue
    workspace.preflight = { _ in WorkspacePreflight() }
    workspace.createStream = { plan, _ in
      #expect(plan.title == "T")
      #expect(plan.members.map(\.name) == ["app", "api"])
      #expect(plan.members[0].checkout == .newBranch(branch: "t", baseRef: nil))
      return AsyncThrowingStream { continuation in
        continuation.yield(.memberStarted(name: "app", phase: .checkingOut))
        continuation.yield(.memberFinished(name: "app"))
        continuation.yield(.memberStarted(name: "api", phase: .checkingOut))
        continuation.yield(.progressLine(name: "api", line: "Preparing worktree"))
        continuation.yield(.memberFinished(name: "api"))
        continuation.yield(.manifestWritten)
        continuation.yield(.registered(projectID: created, worktreeID: nil))
        continuation.finish()
      }
    }
    let store = makeStore(readyState(), workspace: workspace)
    #expect(store.state.canCreate)
    #expect(store.state.createButtonTitle == "Create 2 checkouts")
    await store.send(.createButtonTapped) {
      $0.creationToken = UUID(0)
      $0.creation = .running(current: nil)
    }
    await store.receive(\.creationEvent) {
      $0.members[0].progress = .running(.checkingOut, lastLine: nil)
      $0.creation = .running(current: UUID(1))
    }
    await store.receive(\.creationEvent) { $0.members[0].progress = .done }
    await store.receive(\.creationEvent) {
      $0.members[1].progress = .running(.checkingOut, lastLine: nil)
      $0.creation = .running(current: UUID(2))
    }
    await store.receive(\.creationEvent) {
      $0.members[1].progress = .running(.checkingOut, lastLine: "Preparing worktree")
    }
    await store.receive(\.creationEvent) { $0.members[1].progress = .done }
    await store.receive(\.creationEvent) { $0.creation = .finalizing("Registering…") }
    await store.receive(\.creationEvent) { $0.creation = .idle }
    await store.receive(\.delegate.created)
  }

  @Test
  func failureMarksTheRowRollsBackTheRestAndAllowsRetry() async {
    let attempts = LockIsolated(0)
    var workspace = WorkspaceClient.testValue
    workspace.preflight = { _ in WorkspacePreflight() }
    workspace.createStream = { _, _ in
      attempts.withValue { $0 += 1 }
      return AsyncThrowingStream { continuation in
        continuation.yield(.memberStarted(name: "app", phase: .checkingOut))
        continuation.yield(.memberFinished(name: "app"))
        continuation.yield(.memberStarted(name: "api", phase: .checkingOut))
        continuation.yield(.memberFailed(name: "api", message: "branch \"t\" already exists"))
        continuation.yield(.rollingBack)
        continuation.yield(.rolledBack(failures: []))
        continuation.finish(throwing: GitWorktreeError.branchExists("t"))
      }
    }
    let store = makeStore(readyState(), workspace: workspace)
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.createButtonTapped)
    await store.receive(\.creationFailed) {
      $0.creation = .failed(message: "branch \"t\" already exists")
    }
    #expect(store.state.members[0].progress == .rolledBack)
    #expect(store.state.members[1].progress == .failed("branch \"t\" already exists"))
    #expect(store.state.expandedMemberID == UUID(2))
    await store.send(.retryTapped) {
      $0.creation = .idle
    }
    await store.receive(\.createButtonTapped)
    #expect(attempts.value == 2)
    await store.skipReceivedActions()
    await store.send(.editAgainTapped) {
      $0.creation = .idle
      $0.members[0].progress = .pending
      $0.members[1].progress = .pending
    }
  }

  @Test
  func cancelStopsTheRunAndReportsTheRollback() async {
    let cancelled = LockIsolated<UUID?>(nil)
    let gate = AsyncStream<Void>.makeStream()
    var workspace = WorkspaceClient.testValue
    workspace.preflight = { _ in WorkspacePreflight() }
    workspace.createStream = { _, _ in
      AsyncThrowingStream { continuation in
        continuation.yield(.memberStarted(name: "app", phase: .checkingOut))
        let task = Task {
          for await _ in gate.stream { break }
          continuation.yield(.rollingBack)
          continuation.yield(.rolledBack(failures: ["worktree at /tmp/ws/app"]))
          continuation.finish(throwing: WorkspaceError.cancelled)
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }
    workspace.cancelCreation = { token in
      cancelled.setValue(token)
      gate.continuation.yield()
    }
    let store = makeStore(readyState(), workspace: workspace)
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.createButtonTapped) {
      $0.creationToken = UUID(0)
      $0.creation = .running(current: nil)
    }
    await store.receive(\.creationEvent)
    await store.send(.cancelButtonTapped) {
      $0.creation = .rollingBack
    }
    await store.receive(\.creationEvent) {
      $0.members[0].progress = .rolledBack
      $0.members[1].progress = .rolledBack
    }
    await store.receive(\.creationEvent) {
      $0.creation = .rolledBack(failures: ["worktree at /tmp/ws/app"])
    }
    await store.receive(\.creationFailed)
    #expect(cancelled.value == UUID(0))
    await store.send(.doneTapped)
    await store.receive(\.delegate.dismissed)
  }

  // MARK: - Add mode

  @Test
  func addModeFixesTheWorkspaceAndGoesThroughAddStream() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    var workspace = WorkspaceClient.testValue
    workspace.preflight = { _ in WorkspacePreflight() }
    workspace.addStream = { id, member, _ in
      #expect(id == projectID)
      #expect(member.name == "lib")
      #expect(member.checkout == .newBranch(branch: "handos", baseRef: nil))
      return AsyncThrowingStream { continuation in
        continuation.yield(.registered(projectID: projectID, worktreeID: worktreeID))
        continuation.finish()
      }
    }
    var initial = Feature.State(
      candidates: [app],
      mode: .add(projectID: projectID, title: "handos", rootPath: "/ws/handos", existingNames: ["app"]))
    #expect(initial.titleDraft == "handos")
    #expect(initial.rootPathDraft == "/ws/handos")
    #expect(initial.sharedBranch == "handos")
    #expect(initial.minimumMembers == 1)
    var taken = MemberDraft(id: UUID(1), source: .project(app.id, gitRoot: "/src/app"), name: "app", branch: "handos")
    taken.refs = .loaded(RefInventory())
    initial.members = [taken]
    let store = makeStore(initial, workspace: workspace)
    store.exhaustivity = .off(showSkippedAssertions: false)
    #expect(
      store.state.issues(for: store.state.members[0]).contains {
        $0.field == .name && $0.message.contains("already has")
      })
    #expect(store.state.plan == nil)
    await store.send(.member(UUID(1), .nameChanged("lib")))
    #expect(store.state.plan != nil)
    await store.send(.createButtonTapped)
    await store.receive(\.creationEvent) { $0.creation = .idle }
    await store.receive(\.delegate.added)
  }

  // MARK: - Pure helpers

  @Test
  func addEntryClassifierTellsURLsPathsAndSearchesApart() {
    let exists: (String) -> Bool = { $0 == "/src/app" || $0 == "rel/path" }
    #expect(
      AddEntryClassifier.classify("https://github.com/o/r.git", fileExists: exists)
        == .url("https://github.com/o/r.git"))
    #expect(AddEntryClassifier.classify("git@github.com:o/r.git", fileExists: exists) == .url("git@github.com:o/r.git"))
    #expect(AddEntryClassifier.classify("github.com/o/r", fileExists: exists) == .url("https://github.com/o/r"))
    #expect(AddEntryClassifier.classify("/src/app", fileExists: exists) == .path("/src/app", exists: true))
    #expect(AddEntryClassifier.classify("/src/nope", fileExists: exists) == .path("/src/nope", exists: false))
    #expect(AddEntryClassifier.classify("rel/path", fileExists: exists) == .path("rel/path", exists: true))
    #expect(AddEntryClassifier.classify("  app ", fileExists: exists) == .search("app"))
    #expect(AddEntryClassifier.classify("", fileExists: exists) == .empty)
    #expect(AddEntryClassifier.normalizedRemoteKey("HTTPS://GitHub.com/o/r.git/") == "github.com/o/r")
    #expect(AddEntryClassifier.normalizedRemoteKey("git@github.com:o/r.git") == "github.com/o/r")
    #expect(AddEntryClassifier.normalizedRemoteKey("ssh://git@github.com:22/o/r") == "github.com/o/r")
    let ranked = AddEntryClassifier.rank(
      ["handbox", "hand-ai", "linko", "shared"], query: "ha", name: { $0 }, folder: { $0 })
    #expect(ranked == ["handbox", "hand-ai", "shared"])
  }

  @Test
  func commandPreviewSpellsEveryCheckoutShape() {
    let plan = WorkspacePlan(
      title: "T", rootPath: "/tmp/ws",
      members: [
        WorkspacePlan.Member(name: "a", sourceGitRoot: "/src/a", checkout: .newBranch(branch: "f", baseRef: nil)),
        WorkspacePlan.Member(name: "b", sourceGitRoot: "/src/b", checkout: .existingBranch("main")),
        WorkspacePlan.Member(
          name: "c", source: .remote(url: "git@h:o/c.git", cloneDestination: "/src/c"),
          checkout: .remoteTrackingRef(remoteRef: "origin/x", branch: "x", resetLocal: true)),
      ])
    #expect(WorkspaceCommandPreview.treeLines(for: plan) == ["ws/", "├─ a/  (f)", "├─ b/  (main)", "└─ c/  (x)"])
    #expect(
      WorkspaceCommandPreview.commands(for: plan) == [
        "mkdir -p /tmp/ws",
        "git -C /src/a worktree add -b f /tmp/ws/a '<default branch>'",
        "git -C /src/b worktree add /tmp/ws/b main",
        "git clone --progress git@h:o/c.git /src/c",
        "git -C /src/c worktree add --track -B x /tmp/ws/c origin/x",
        "write /tmp/ws/.codans/workspace.json",
      ])
  }
}
