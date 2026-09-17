import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

/// The New Workspace sheet's reducer: the folder and branch that follow the
/// title, adding members from open projects, folders, and remote URLs,
/// per-member refs and issues, the debounced preflight, and the creation
/// stream's effect on members. Effects are stubbed closure by closure; git
/// never runs.
@MainActor
struct CreateWorkspaceFeatureTests {
  private typealias Feature = CreateWorkspaceFeature

  private static func defaultSource(_ name: String) -> String {
    (WorkspaceLayout.defaultSourcesDirectory().path(percentEncoded: false) as NSString)
      .appendingPathComponent(name)
  }

  private let app = Feature.Candidate(id: ProjectID(), name: "app", gitRoot: "/src/app")
  private let api = Feature.Candidate(id: ProjectID(), name: "api", gitRoot: "/src/api")

  private var appSource: MemberDraft.Source { .project(app.id, name: "app", gitRoot: "/src/app") }
  private var apiSource: MemberDraft.Source { .project(api.id, name: "api", gitRoot: "/src/api") }

  private let appRefs = RefInventory(
    local: ["feat/x", "main", "wip"], remote: ["origin/main", "origin/feat/x", "origin/release"],
    defaultBaseRef: "origin/main", checkedOut: ["main": "/src/app"])

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

  private func member(
    _ id: Int, _ source: MemberDraft.Source, name: String, refs: RefInventory? = nil
  ) -> MemberDraft {
    var draft = MemberDraft(id: UUID(id), source: source, name: name)
    if let refs { draft.refs = .loaded(refs) }
    return draft
  }

  private func shown(_ issues: [MemberIssue]) -> [MemberIssue] {
    issues.filter { $0.severity != .incomplete }
  }

  // MARK: - Workspace fields

  @Test
  func preselectedProjectBecomesTheFirstMemberAndLoadsRefs() async {
    let store = makeStore(Feature.State(candidates: [app, api], preselected: app.id))
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.onAppear)
    await store.receive(\.member) {
      $0.members[0].refs = .loaded(appRefs)
    }
    #expect(store.state.members.map(\.source) == [appSource])
    #expect(store.state.members[0].name == "app")
    #expect(store.state.preselected == nil)
    #expect(store.state.availableCandidates == [api])
  }

  @Test
  func titleNamesTheFolderAndTheBranchUntilTheBranchIsEdited() async {
    let store = makeStore(Feature.State(candidates: [], locationPath: "/ws"))
    store.exhaustivity = .off(showSkippedAssertions: false)
    #expect(store.state.rootPath.isEmpty)
    await store.send(.titleChanged("Checkout Flow")) {
      $0.titleDraft = "Checkout Flow"
      $0.sharedBranch = "checkout-flow"
    }
    #expect(store.state.rootPath == "/ws/checkout-flow")
    await store.send(.locationPicked(URL(fileURLWithPath: "/elsewhere", isDirectory: true))) {
      $0.locationPath = "/elsewhere"
    }
    #expect(store.state.rootPath == "/elsewhere/checkout-flow")
    await store.send(.sharedBranchChanged("feat/x")) {
      $0.sharedBranch = "feat/x"
      $0.sharedBranchEditedManually = true
    }
    // The folder keeps following the title; the edited branch does not.
    await store.send(.titleChanged("Other")) {
      $0.titleDraft = "Other"
    }
    #expect(store.state.rootPath == "/elsewhere/other")
    // A cancelled picker changes nothing.
    await store.send(.locationPicked(nil))
  }

  @Test
  func newBranchMembersFollowTheWorkspaceBranchUnlessTheyNameTheirOwn() async {
    var initial = Feature.State(candidates: [app, api])
    initial.sharedBranch = "feat/a"
    initial.members = [member(1, appSource, name: "app"), member(2, apiSource, name: "api")]
    let store = makeStore(initial)
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.member(UUID(2), .branchOverrideChanged("mine")))
    await store.send(.sharedBranchChanged("feat/b"))
    #expect(store.state.checkout(for: store.state.members[0]) == .newBranch(branch: "feat/b", baseRef: nil))
    #expect(store.state.checkout(for: store.state.members[1]) == .newBranch(branch: "mine", baseRef: nil))
    // Clearing the override follows the workspace branch again.
    await store.send(.member(UUID(2), .branchOverrideChanged("  ")))
    await store.send(.member(UUID(2), .baseRefChanged("origin/release")))
    #expect(
      store.state.checkout(for: store.state.members[1]) == .newBranch(branch: "feat/b", baseRef: "origin/release"))
  }

  // MARK: - Adding members

  @Test
  func openProjectsAndFoldersBecomeMembers() async {
    let store = makeStore(Feature.State(candidates: [app, api]))
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.addProjectTapped(app.id))
    #expect(store.state.members.map(\.source) == [appSource])
    #expect(store.state.availableCandidates == [api])

    // A folder inside an open project resolves to that project; another
    // repository with the same folder name gets a suffix.
    await store.send(.addPathResolved(path: "/src/api/sub", probe: RepositoryProbe(root: "/src/api", isBare: false)))
    #expect(store.state.members.last?.source == apiSource)
    await store.send(.addPathResolved(path: "/other/app", probe: RepositoryProbe(root: "/other/app", isBare: false)))
    #expect(store.state.members.last?.source == .localRepo(gitRoot: "/other/app"))
    #expect(store.state.members.last?.name == "app-2")

    // Duplicates, bare repositories, and plain folders are refused.
    await store.send(.addPathResolved(path: "/other/app", probe: RepositoryProbe(root: "/other/app", isBare: false))) {
      $0.addIssue = "/other/app is already in the list."
    }
    await store.send(.addPathResolved(path: "/m/tool.git", probe: RepositoryProbe(root: "/m/tool.git", isBare: true))) {
      $0.addIssue = "/m/tool.git is a bare repository, which workspaces do not support."
    }
    await store.send(.addPathResolved(path: "/tmp/notes", probe: nil)) {
      $0.addIssue = "/tmp/notes is not a git repository."
    }
    #expect(store.state.members.count == 3)
  }

  @Test
  func remoteURLsAreAddedOnceWithTheirBranches() async {
    var git = gitClient(appRefs)
    git.lsRemoteHeads = { _ in RemoteHeads(defaultBranch: "main", branches: ["main", "release"]) }
    let store = makeStore(Feature.State(candidates: [app]), git: git)
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.remoteURLDraftChanged("git@github.com:org/lib.git"))
    await store.send(.addRemoteURLSubmitted) {
      $0.remoteURLDraft = ""
    }
    #expect(
      store.state.members.map(\.source) == [
        .remote(url: "git@github.com:org/lib.git", cloneDestination: Self.defaultSource("lib"))
      ])
    #expect(store.state.members[0].name == "lib")
    #expect(store.state.members[0].availableModes == [.newBranch, .existingRemote])
    await store.receive(\.member) {
      $0.members[0].refs = .loaded(
        RefInventory(local: [], remote: ["origin/main", "origin/release"], defaultBaseRef: "origin/main"))
    }

    // The same remote in another spelling is refused and the text kept.
    await store.send(.remoteURLDraftChanged("https://github.com/org/lib"))
    await store.send(.addRemoteURLSubmitted) {
      $0.addIssue = "This remote is already in the list."
    }
    await store.send(.remoteURLDraftChanged("/nowhere/repo")) {
      $0.remoteURLDraft = "/nowhere/repo"
      $0.addIssue = nil
    }
    await store.send(.addRemoteURLSubmitted) {
      $0.addIssue = "There is no folder at /nowhere/repo."
    }
    await store.send(.remoteURLDraftChanged("just words"))
    await store.send(.addRemoteURLSubmitted) {
      $0.addIssue = "Enter a git URL, such as git@github.com:org/repo.git."
    }
    #expect(store.state.members.count == 1)

    // Clone destination: the picker gives a parent; the clone keeps its name.
    await store.send(.member(UUID(0), .cloneDestinationPicked(URL(fileURLWithPath: "/code", isDirectory: true))))
    #expect(
      store.state.members[0].source
        == .remote(url: "git@github.com:org/lib.git", cloneDestination: "/code/lib"))
  }

  @Test
  func remoteRefsTimeOutAndCanBeRetried() async {
    let clock = TestClock()
    var git = gitClient(appRefs)
    git.lsRemoteHeads = { _ in
      try await Task.sleep(for: .seconds(60))
      return RemoteHeads()
    }
    var initial = Feature.State(candidates: [])
    initial.members = [member(1, .remote(url: "https://h/r", cloneDestination: "/src/r"), name: "r")]
    initial.sharedBranch = "x"
    let store = makeStore(initial, git: git, clock: clock)
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.member(UUID(1), .retryRefsTapped)) {
      $0.members[0].refs = .loading
    }
    await clock.advance(by: .seconds(20))
    await store.receive(\.member) {
      $0.members[0].refs = .failed("The remote did not answer within 20 seconds.")
    }
    // A failure only warns for a new branch, but blocks a remote checkout.
    #expect(store.state.issues(for: store.state.members[0]).allSatisfy { !$0.blocksCreation })
    await store.send(.member(UUID(1), .modeChanged(.existingRemote)))
    #expect(
      store.state.issues(for: store.state.members[0]).contains(
        .blocking("The remote did not answer within 20 seconds.")))
    // Removing the member cancels an in-flight load.
    await store.send(.member(UUID(1), .retryRefsTapped))
    await store.send(.member(UUID(1), .remove)) {
      $0.members = []
    }
  }

  // MARK: - Issues

  @Test
  func incompleteFormsBlockCreateWithoutShowingErrors() {
    var state = Feature.State(candidates: [app])
    state.members = [member(1, appSource, name: "app", refs: appRefs)]
    #expect(state.plan == nil)
    #expect(state.createHint == "Enter a title.")
    #expect(shown(state.workspaceIssues).isEmpty)
    #expect(shown(state.issues(for: state.members[0])).isEmpty)

    state.titleDraft = "T"
    state.sharedBranch = ""
    #expect(state.createHint == "Add at least two repositories.")
    state.members.append(member(2, apiSource, name: "api", refs: RefInventory(local: ["main"])))
    #expect(state.createHint == "Enter a branch name for app.")
    state.sharedBranch = "t"
    #expect(state.createHint == nil)
    #expect(state.canCreate)
    #expect(state.createButtonTitle == "Create")
  }

  @Test
  func checkoutIssuesCoverEachMode() async {
    var initial = Feature.State(candidates: [app])
    initial.titleDraft = "T"
    initial.sharedBranch = "wip"
    initial.members = [
      member(1, appSource, name: "app", refs: appRefs),
      member(2, .localRepo(gitRoot: "/src/lib"), name: "app", refs: RefInventory(local: ["main"])),
    ]
    let store = makeStore(initial)
    store.exhaustivity = .off(showSkippedAssertions: false)

    #expect(
      store.state.issues(for: store.state.members[0]) == [
        .blocking("Another repository already uses the folder name \u{201C}app\u{201D}."),
        .blocking("A branch named \u{201C}wip\u{201D} already exists here. Choose Existing branch to check it out."),
      ])
    await store.send(.member(UUID(2), .nameChanged("lib")))
    await store.send(.member(UUID(2), .branchOverrideChanged("bad..name")))
    #expect(
      store.state.issues(for: store.state.members[1]) == [
        .blocking("\u{201C}bad..name\u{201D} is not a valid branch name.")
      ])
    #expect(store.state.plan == nil)

    // Existing branch: must be chosen, exist, and be free.
    await store.send(.member(UUID(1), .modeChanged(.existingLocal)))
    #expect(store.state.issues(for: store.state.members[0]) == [.incomplete("Choose a branch for app.")])
    await store.send(.member(UUID(1), .localBranchChanged("main")))
    #expect(
      store.state.issues(for: store.state.members[0]) == [
        .blocking(
          "\u{201C}main\u{201D} is checked out at /src/app. A branch can be checked out in only one place.")
      ])
    await store.send(.member(UUID(1), .localBranchChanged("gone")))
    #expect(
      store.state.issues(for: store.state.members[0]) == [
        .blocking("There is no local branch named \u{201C}gone\u{201D}.")
      ])
    #expect(store.state.checkout(for: store.state.members[0]) == .existingBranch("gone"))

    // Remote branch: nothing is picked for the user.
    await store.send(.member(UUID(1), .modeChanged(.existingRemote)))
    #expect(store.state.members[0].remoteRef == nil)
    #expect(store.state.issues(for: store.state.members[0]) == [.incomplete("Choose a remote branch for app.")])
    await store.send(.member(UUID(1), .remoteRefChanged("origin/feat/x")))
    #expect(store.state.members[0].hasLocalConflict)
    #expect(store.state.issues(for: store.state.members[0]).isEmpty)
    #expect(
      store.state.checkout(for: store.state.members[0])
        == .remoteTrackingRef(remoteRef: "origin/feat/x", branch: "feat/x", resetLocal: false))
    await store.send(.member(UUID(1), .localConflictChanged(.resetToRemote))) {
      $0.members[0].localConflict = .resetToRemote
    }
    #expect(
      store.state.checkout(for: store.state.members[0])
        == .remoteTrackingRef(remoteRef: "origin/feat/x", branch: "feat/x", resetLocal: true))
    // Another ref forgets the reset; a checked-out local twin blocks either
    // way, since git refuses `-B` on it too.
    await store.send(.member(UUID(1), .remoteRefChanged("origin/main"))) {
      $0.members[0].remoteRef = "origin/main"
      $0.members[0].localConflict = .keepLocal
    }
    #expect(store.state.issues(for: store.state.members[0]).count == 1)
    await store.send(.member(UUID(1), .localConflictChanged(.resetToRemote)))
    #expect(store.state.issues(for: store.state.members[0]).first?.message.contains("checked out at") == true)
    // No local twin: no choice to make.
    await store.send(.member(UUID(1), .remoteRefChanged("origin/release")))
    #expect(!store.state.members[0].hasLocalConflict)
    await store.send(.member(UUID(1), .remoteRefChanged("upstream/none")))
    #expect(
      store.state.issues(for: store.state.members[0]) == [
        .blocking("\u{201C}upstream/none\u{201D} is not a remote branch of this repository.")
      ])
  }

  // MARK: - Preflight

  @Test
  func preflightIsDebouncedAndLandsOnMembers() async {
    let clock = TestClock()
    let calls = LockIsolated(0)
    var workspace = WorkspaceClient.testValue
    workspace.preflight = { plan in
      calls.withValue { $0 += 1 }
      #expect(plan.title == "abc")
      return WorkspacePreflight(
        rootIssues: [.init(kind: .rootExists, message: "The folder already exists.")],
        memberIssues: [
          "app": [.init(kind: .destinationExists, message: "~/ws/app already exists.")],
          "api": [.init(kind: .destinationExists, message: "~/ws/api already exists.")],
        ])
    }
    var initial = Feature.State(candidates: [app, api], mode: .create)
    initial.members = [member(1, appSource, name: "app"), member(2, apiSource, name: "api")]
    let store = makeStore(initial, workspace: workspace, clock: clock)
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.titleChanged("a"))
    await store.send(.titleChanged("ab"))
    await store.send(.titleChanged("abc"))
    await clock.advance(by: .milliseconds(300))
    await store.receive(\.preflightTick)
    await store.receive(\.preflightFinished) {
      $0.rootIssues = [.info("The folder already exists.")]
      $0.members[0].preflightIssues = [.init(kind: .destinationExists, message: "~/ws/app already exists.")]
      $0.members[1].preflightIssues = [.init(kind: .destinationExists, message: "~/ws/api already exists.")]
    }
    #expect(calls.value == 1)
    #expect(store.state.issues(for: store.state.members[0]) == [.blocking("~/ws/app already exists.")])
    #expect(store.state.plan == nil)
    // A folder-name problem already says it; the preflight line is dropped.
    await store.send(.member(UUID(2), .nameChanged("app")))
    #expect(
      store.state.issues(for: store.state.members[1]) == [
        .blocking("Another repository already uses the folder name \u{201C}app\u{201D}.")
      ])
  }

  // MARK: - Creation

  private func readyState() -> Feature.State {
    var initial = Feature.State(candidates: [app, api], locationPath: "/tmp")
    initial.titleDraft = "T"
    initial.sharedBranch = "t"
    initial.members = [
      member(1, appSource, name: "app", refs: appRefs), member(2, apiSource, name: "api", refs: appRefs),
    ]
    return initial
  }

  @Test
  func createStreamsProgressOntoMembersAndDelegatesOnRegistration() async {
    let created = ProjectID()
    var workspace = WorkspaceClient.testValue
    workspace.preflight = { _ in WorkspacePreflight() }
    workspace.createStream = { plan, _ in
      #expect(plan.title == "T")
      #expect(plan.rootPath == "/tmp/t")
      #expect(plan.members.map(\.name) == ["app", "api"])
      #expect(plan.members[0].checkout == .newBranch(branch: "t", baseRef: nil))
      return AsyncThrowingStream { continuation in
        continuation.yield(.memberStarted(name: "app", phase: .checkingOut))
        continuation.yield(.memberFinished(name: "app"))
        continuation.yield(.memberStarted(name: "api", phase: .cloning))
        continuation.yield(.progressLine(name: "api", line: "Receiving objects: 50%"))
        continuation.yield(.memberFinished(name: "api"))
        continuation.yield(.manifestWritten)
        continuation.yield(.registered(projectID: created, worktreeID: nil))
        continuation.finish()
      }
    }
    let store = makeStore(readyState(), workspace: workspace)
    #expect(store.state.canCreate)
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
      $0.members[1].progress = .running(.cloning, lastLine: nil)
      $0.creation = .running(current: UUID(2))
    }
    await store.receive(\.creationEvent) {
      $0.members[1].progress = .running(.cloning, lastLine: "Receiving objects: 50%")
    }
    await store.receive(\.creationEvent) { $0.members[1].progress = .done }
    await store.receive(\.creationEvent) { $0.creation = .finalizing("Adding to the sidebar…") }
    await store.receive(\.creationEvent) { $0.creation = .idle }
    await store.receive(\.delegate.created)
  }

  @Test
  func failureMarksTheMemberAndTheNextEditClearsIt() async {
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
    // Create is available again as a retry.
    #expect(store.state.canCreate)
    await store.send(.createButtonTapped)
    await store.receive(\.creationFailed)
    #expect(attempts.value == 2)
    // Any edit puts the form back to its plain state.
    await store.send(.member(UUID(2), .branchOverrideChanged("other"))) {
      $0.creation = .idle
      $0.members[0].progress = .pending
      $0.members[1].progress = .pending
    }
  }

  @Test
  func cancelStopsTheRunReportsTheRollbackThenCloses() async {
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
          continuation.yield(.rolledBack(failures: ["worktree at /tmp/t/app"]))
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
      $0.creation = .rolledBack(failures: ["worktree at /tmp/t/app"])
    }
    await store.receive(\.creationFailed)
    #expect(store.state.creation == .rolledBack(failures: ["worktree at /tmp/t/app"]))
    #expect(cancelled.value == UUID(0))
    await store.send(.cancelButtonTapped)
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
    let initial = Feature.State(
      candidates: [app],
      mode: .add(projectID: projectID, title: "handos", rootPath: "/ws/handos", existingNames: ["app"]))
    #expect(initial.titleDraft == "handos")
    #expect(initial.rootPath == "/ws/handos")
    #expect(initial.sharedBranch == "handos")
    #expect(initial.createHint == "Choose a repository to add.")
    #expect(initial.createButtonTitle == "Add")
    let store = makeStore(initial, workspace: workspace)
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.addProjectTapped(app.id))
    #expect(!store.state.canAddMembers)
    #expect(
      store.state.issues(for: store.state.members[0]).contains(
        .blocking("The workspace already has a folder named \u{201C}app\u{201D}.")))
    // One repository is the whole plan: further adds are ignored.
    await store.send(.remoteURLDraftChanged("git@h:o/r.git"))
    await store.send(.addRemoteURLSubmitted)
    #expect(store.state.members.count == 1)
    await store.send(.member(UUID(0), .nameChanged("lib")))
    #expect(store.state.plan != nil)
    await store.send(.createButtonTapped)
    await store.receive(\.creationEvent) { $0.creation = .idle }
    await store.receive(\.delegate.added)
  }

  // MARK: - Pure helpers

  @Test
  func addEntryClassifierTellsURLsAndPathsApart() {
    let exists: (String) -> Bool = { $0 == "/src/app" || $0 == "rel/path" }
    #expect(
      AddEntryClassifier.classify("https://github.com/o/r.git", fileExists: exists)
        == .url("https://github.com/o/r.git"))
    #expect(AddEntryClassifier.classify("git@github.com:o/r.git", fileExists: exists) == .url("git@github.com:o/r.git"))
    #expect(AddEntryClassifier.classify("github.com/o/r", fileExists: exists) == .url("https://github.com/o/r"))
    #expect(AddEntryClassifier.classify("/src/app", fileExists: exists) == .path("/src/app", exists: true))
    #expect(AddEntryClassifier.classify("/src/nope", fileExists: exists) == .path("/src/nope", exists: false))
    #expect(AddEntryClassifier.classify("rel/path", fileExists: exists) == .path("rel/path", exists: true))
    #expect(AddEntryClassifier.classify("  app ", fileExists: exists) == .unrecognized("app"))
    #expect(AddEntryClassifier.classify("", fileExists: exists) == .empty)
    #expect(AddEntryClassifier.normalizedRemoteKey("HTTPS://GitHub.com/o/r.git/") == "github.com/o/r")
    #expect(AddEntryClassifier.normalizedRemoteKey("git@github.com:o/r.git") == "github.com/o/r")
    #expect(AddEntryClassifier.normalizedRemoteKey("ssh://git@github.com:22/o/r") == "github.com/o/r")
  }
}
