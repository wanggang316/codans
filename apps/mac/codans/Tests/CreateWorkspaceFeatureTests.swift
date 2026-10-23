import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

/// The Workspace sheets' reducer: Add Workspace and Add Project collect
/// source projects without any branch choice; New Group seeds each project
/// from the client's defaults, shows preflight findings under the project
/// they belong to, streams progress, keeps its input after a failure, and
/// hands the final result up. Effects are stubbed closure by closure; git
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
  private let workspaceID = ProjectID()

  private var appSource: SourceDraft.Source { .project(app.id, name: "app", gitRoot: "/src/app") }
  private var apiSource: SourceDraft.Source { .project(api.id, name: "api", gitRoot: "/src/api") }

  private let appRefs = RefInventory(
    local: ["main", "wip"], remote: ["origin/main", "origin/release"], defaultBaseRef: "origin/main",
    headBranch: "main", checkedOut: ["main": "/src/app"])

  private let appDefaults = MemberCreationOptions(
    sourceGitRoot: "/src/app", name: "app", baseRef: "origin/release", fetch: true, copyIgnored: true,
    copyUntracked: false, agentProfileID: UUID(99), setupCommand: "make setup")
  private let apiDefaults = MemberCreationOptions(
    sourceGitRoot: "/src/api", name: "api", baseRef: "origin/main", fetch: false, copyIgnored: false,
    copyUntracked: true)

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

  /// A client whose checks find nothing; tests replace what they drive.
  private func workspaceClient() -> WorkspaceClient {
    var client = WorkspaceClient.testValue
    client.preflightWorkspace = { _ in WorkspacePreflight() }
    client.preflightGroup = { _ in WorkspacePreflight() }
    return client
  }

  private func makeStore(
    _ initial: Feature.State,
    workspace: WorkspaceClient? = nil,
    clock: TestClock<Duration> = TestClock(),
    agentProfiles: [AgentProfile] = [],
    pickFolder: @escaping @Sendable () -> URL? = { nil }
  ) -> TestStore<Feature.State, Feature.Action> {
    let settings = Settings(agents: AgentSettings(profiles: agentProfiles))
    return TestStore(initialState: initial) {
      Feature()
    } withDependencies: {
      $0.gitWorktreeClient = gitClient(appRefs)
      $0[WorkspaceClient.self] = workspace ?? workspaceClient()
      $0[SettingsWriter.self].readSnapshotSync = { settings }
      $0.continuousClock = clock
      $0.uuid = .incrementing
      $0.fileExists = { _ in false }
      $0[FolderPickerClient.self] = FolderPickerClient(pick: { _ in pickFolder() })
      $0[GitWorktreeCLI.self] = GitWorktreeCLI()
    }
  }

  private func groupState() -> Feature.State {
    Feature.State(candidates: [app, api], mode: .newGroup(projectID: workspaceID, title: "ws", rootPath: "/ws"))
  }

  /// A group form loaded with both projects' defaults and branches.
  private func loadedGroupState(name: String = "feat") -> Feature.State {
    var state = groupState()
    state.isLoadingMembers = false
    state.groupName = name
    state.groupMembers = [GroupMemberDraft(options: appDefaults), GroupMemberDraft(options: apiDefaults)]
    for id in state.groupMembers.ids { state.groupMembers[id: id]?.refs = .loaded(appRefs) }
    return state
  }

  // MARK: - Add Workspace

  @Test
  func addWorkspaceCollectsSourcesWithoutBranchesAndCreates() async {
    let received = LockIsolated<[WorkspaceSourcePlan]>([])
    let createdID = ProjectID()
    var client = workspaceClient()
    client.createWorkspace = { plan in
      received.withValue { $0.append(plan) }
      return createdID
    }
    let store = makeStore(Feature.State(candidates: [app, api], locationPath: "/ws"), workspace: client)
    store.exhaustivity = .off(showSkippedAssertions: false)

    #expect(store.state.createHint == "Enter a title.")
    await store.send(.titleChanged("Checkout Flow"))
    #expect(store.state.rootPath == "/ws/checkout-flow")
    #expect(store.state.createHint == "Add a project.")
    // A project from the menu is listed at once; there is nothing to choose.
    await store.send(.addProjectTapped(app.id))
    #expect(store.state.sources.map(\.source) == [appSource])
    #expect(store.state.availableCandidates == [api])
    await store.send(.addProjectTapped(app.id))
    #expect(store.state.sources.count == 1)
    await store.send(.addProjectTapped(api.id))
    await store.send(.removeSourceTapped(UUID(0)))
    #expect(store.state.sources.map(\.source) == [apiSource])
    #expect(store.state.canCreate)

    await store.send(.createButtonTapped)
    await store.receive(\.delegate.created, createdID)
    #expect(
      received.value == [
        WorkspaceSourcePlan(
          title: "Checkout Flow", rootPath: "/ws/checkout-flow",
          sources: [WorkspaceSource(location: .local(path: "/src/api"))])
      ])
  }

  @Test
  func pickedFoldersBecomeSourcesOrSayWhyNot() async {
    let picked = LockIsolated<URL?>(URL(fileURLWithPath: "/nonexistent-codans-test/notes"))
    var initial = Feature.State(candidates: [app, api])
    initial.sources = [SourceDraft(id: UUID(9), source: appSource)]
    let store = makeStore(initial, pickFolder: { picked.value })
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.addFolderTapped)
    await store.receive(\.addFolderPicked) {
      $0.isResolvingFolder = true
    }
    await store.receive(\.folderResolved) {
      $0.isResolvingFolder = false
      $0.sourceIssue = "/nonexistent-codans-test/notes is not a git repository."
    }
    // Duplicates and bare repositories are refused.
    await store.send(.folderResolved(path: "/src/app", probe: RepositoryProbe(root: "/src/app", isBare: false))) {
      $0.sourceIssue = "/src/app is already in the list."
    }
    await store.send(.folderResolved(path: "/m/t.git", probe: RepositoryProbe(root: "/m/t.git", isBare: true))) {
      $0.sourceIssue = "/m/t.git is a bare repository, which workspaces do not support."
    }
    // A folder inside an open project is that project.
    await store.send(
      .folderResolved(path: "/src/api/sub", probe: RepositoryProbe(root: "/src/api", isBare: false)))
    #expect(store.state.sources.map(\.source) == [appSource, apiSource])
    await store.send(
      .folderResolved(path: "/other/lib", probe: RepositoryProbe(root: "/other/lib", isBare: false)))
    #expect(store.state.sources.last?.source == .localRepo(gitRoot: "/other/lib"))
    // A cancelled picker changes nothing.
    picked.setValue(nil)
    await store.send(.addFolderTapped)
    await store.receive(\.addFolderPicked)
    #expect(store.state.sources.count == 3)
  }

  @Test
  func remoteDialogFollowsTheURLOnceTypingPauses() async {
    let clock = TestClock()
    let store = makeStore(Feature.State(candidates: [app]), clock: clock)
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.addRemoteTapped) {
      $0.remoteEditor = RemoteSourceEditor(id: UUID(0), isNew: true)
    }
    await store.send(.remote(.urlChanged("git@github.com:org/lib.git")))
    #expect(store.state.remoteEditor?.draft == nil)
    await clock.advance(by: .milliseconds(600))
    await store.receive(\.remote)
    #expect(
      store.state.remoteEditor?.draft?.source
        == .remote(url: "git@github.com:org/lib.git", cloneDestination: Self.defaultSource("lib")))
    // A picked clone folder stays the parent when the URL changes.
    await store.send(.remote(.cloneDestinationPicked(URL(fileURLWithPath: "/code", isDirectory: true))))
    await store.send(.remote(.urlChanged("https://github.com/org/tool")))
    #expect(store.state.remoteEditor.map(store.state.canSave(inEditor:)) == false)
    await store.send(.remote(.urlSubmitted))
    #expect(
      store.state.remoteEditor?.draft?.source
        == .remote(url: "https://github.com/org/tool", cloneDestination: "/code/tool"))
    await store.send(.remote(.saveTapped))
    #expect(store.state.remoteEditor == nil)
    #expect(store.state.sources.map(\.source.title) == ["tool"])

    // The same remote in another spelling is refused; paths are reported on
    // Return only.
    await store.send(.addRemoteTapped)
    await store.send(.remote(.urlChanged("git@github.com:org/tool.git")))
    await store.send(.remote(.urlSubmitted)) {
      $0.remoteEditor?.sourceIssue = "This repository is already in the list."
    }
    await store.send(.remote(.urlChanged("/nowhere/repo")))
    await store.send(.remote(.urlSubmitted)) {
      $0.remoteEditor?.sourceIssue = "Enter a URL. To use a folder on this Mac, add a folder instead."
    }
    await store.send(.remote(.saveTapped))
    #expect(store.state.sources.count == 1)
    await store.send(.remote(.cancelTapped)) {
      $0.remoteEditor = nil
    }
  }

  @Test
  func preflightFindingsLandOnTheSourceTheyNameByIndex() async {
    let clock = TestClock()
    var client = workspaceClient()
    client.preflightWorkspace = { plan in
      #expect(plan.sources.count == 2)
      return WorkspacePreflight(
        rootIssues: [.init(kind: .rootExists, message: "The folder already exists.")],
        memberIssues: ["1": [.init(kind: .sourceNotRepository, message: "/src/api is not a git repository")]])
    }
    var initial = Feature.State(candidates: [app, api], locationPath: "/ws")
    initial.titleDraft = "W"
    initial.sources = [SourceDraft(id: UUID(8), source: appSource)]
    let store = makeStore(initial, workspace: client, clock: clock)
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.addProjectTapped(api.id))
    await clock.advance(by: Feature.preflightDebounce)
    await store.receive(\.preflightTick)
    await store.receive(\.preflightFinished)
    #expect(store.state.rootIssues == [.info("The folder already exists.")])
    #expect(store.state.issues(for: store.state.sources[0]).isEmpty)
    #expect(store.state.issues(for: store.state.sources[1]) == [.blocking("/src/api is not a git repository")])
    #expect(!store.state.canCreate)
  }

  // MARK: - Add Project

  @Test
  func addProjectTakesOneNewSourceAndAddsIt() async {
    let rowID = WorktreeID()
    let added = LockIsolated<[(ProjectID, WorkspaceSource)]>([])
    let checkedRoots = LockIsolated<[String]>([])
    let clock = TestClock()
    var client = workspaceClient()
    client.preflightWorkspace = { plan in
      checkedRoots.withValue { $0.append(plan.rootPath) }
      return WorkspacePreflight()
    }
    client.addSource = { projectID, source in
      added.withValue { $0.append((projectID, source)) }
      return rowID
    }
    let mode = Feature.Mode.addSource(
      projectID: workspaceID, title: "ws", rootPath: "/ws", existingSourceRoots: ["/src/app"])
    let store = makeStore(Feature.State(candidates: [app, api], mode: mode), workspace: client, clock: clock)
    store.exhaustivity = .off(showSkippedAssertions: false)

    #expect(store.state.titleDraft == "ws")
    // A project the Workspace already lists is neither offered nor taken.
    #expect(store.state.availableCandidates == [api])
    await store.send(.folderResolved(path: "/src/app", probe: RepositoryProbe(root: "/src/app", isBare: false))) {
      $0.sourceIssue = "/src/app is already part of this workspace."
    }
    await store.send(.addProjectTapped(api.id))
    #expect(!store.state.canAddSources)
    await store.send(.addRemoteTapped)
    #expect(store.state.remoteEditor == nil)
    // Only the source is checked; the Workspace folder exists already.
    await clock.advance(by: Feature.preflightDebounce)
    await store.receive(\.preflightTick)
    await store.receive(\.preflightFinished)
    #expect(checkedRoots.value == [""])

    await store.send(.createButtonTapped)
    await store.receive(\.delegate.added)
    #expect(added.value.map(\.0) == [workspaceID])
    #expect(added.value.map(\.1) == [WorkspaceSource(location: .local(path: "/src/api"))])
  }

  // MARK: - New Group

  @Test
  func newGroupSeedsEveryProjectFromItsDefaults() async {
    let profile = AgentProfile(kind: .claudeCode, name: "Claude")
    let asked = LockIsolated<[ProjectID]>([])
    var client = workspaceClient()
    client.groupCreationDefaults = { projectID in
      asked.withValue { $0.append(projectID) }
      return [appDefaults, apiDefaults]
    }
    let store = makeStore(groupState(), workspace: client, agentProfiles: [profile])
    store.exhaustivity = .off(showSkippedAssertions: false)

    #expect(store.state.createHint == "Loading the workspace\u{2019}s projects\u{2026}")
    await store.send(.onAppear)
    await store.receive(\.groupDefaultsLoaded) {
      $0.isLoadingMembers = false
      $0.agentProfiles = [profile]
    }
    #expect(asked.value == [workspaceID])
    #expect(store.state.groupMembers.map(\.options) == [appDefaults, apiDefaults])
    await store.receive(\.groupMember)
    await store.receive(\.groupMember)
    #expect(store.state.groupMembers.allSatisfy { $0.refs.inventory?.remote == appRefs.remote })
    #expect(store.state.createHint == "Enter a group name.")

    // One branch for every project, the group name unless typed.
    await store.send(.groupNameChanged("feat"))
    #expect(store.state.groupPlan?.branch == "feat")
    await store.send(.branchChanged("task/feat"))
    // Each project keeps its own options.
    await store.send(.groupMember("/src/api", .baseRefChanged("origin/release")))
    await store.send(.groupMember("/src/api", .agentChanged(profile.id)))
    await store.send(.groupMember("/src/app", .fetchChanged(false)))
    var app = appDefaults
    app.fetch = false
    var api = apiDefaults
    api.baseRef = "origin/release"
    api.agentProfileID = profile.id
    #expect(
      store.state.groupPlan
        == WorkspaceGroupPlan(projectID: workspaceID, name: "feat", branch: "task/feat", members: [app, api]))
  }

  @Test
  func aBranchConflictShowsUnderTheProjectThatHasIt() async {
    let clock = TestClock()
    var client = workspaceClient()
    client.preflightGroup = { plan in
      WorkspacePreflight(
        memberIssues: [
          "api": [
            .init(kind: .localBranchExists, message: "Branch \u{201C}\(plan.branch)\u{201D} already exists in api.")
          ]
        ])
    }
    let store = makeStore(loadedGroupState(name: ""), workspace: client, clock: clock)
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.groupNameChanged("feat"))
    await clock.advance(by: Feature.preflightDebounce)
    await store.receive(\.preflightTick)
    await store.receive(\.preflightFinished)
    let members = store.state.groupMembers
    #expect(store.state.issues(for: members[id: "/src/app"]!).isEmpty)
    #expect(
      store.state.issues(for: members[id: "/src/api"]!) == [
        .blocking("Branch \u{201C}feat\u{201D} already exists in api.")
      ])
    #expect(store.state.groupIssues.isEmpty)
    #expect(store.state.groupPlan == nil)
    #expect(store.state.createHint == "Fix the problems above to continue.")
    // An invalid branch is caught while typing.
    await store.send(.branchChanged("bad name"))
    #expect(store.state.groupIssues == [.blocking("\u{201C}bad name\u{201D} is not a valid branch name.")])
  }

  @Test
  func aCheckoutFailureKeepsTheInputListsResidualsAndRetries() async {
    let attempts = LockIsolated(0)
    let result = GroupCreationResult(
      projectID: workspaceID, groupID: WorkspaceGroupID(), groupWorktreeID: WorktreeID(),
      members: [.init(name: "app", worktreeID: WorktreeID(), agentProfileID: UUID(99))])
    var client = workspaceClient()
    client.createGroupStream = { _, _ in
      let attempt = attempts.withValue { value -> Int in
        value += 1
        return value
      }
      return AsyncThrowingStream { continuation in
        continuation.yield(.memberStarted(name: "app", phase: .checkingOut))
        continuation.yield(.memberFinished(name: "app"))
        continuation.yield(.memberStarted(name: "api", phase: .fetching))
        guard attempt > 1 else {
          continuation.yield(.memberFailed(name: "api", message: "fetch failed"))
          continuation.yield(.rollingBack)
          continuation.yield(.rolledBack(failures: ["/ws/feat/app: permission denied"]))
          continuation.finish(throwing: GitWorktreeError.commandFailed(command: "git fetch", stderr: "fetch failed"))
          return
        }
        continuation.yield(.memberFinished(name: "api"))
        continuation.yield(.manifestWritten)
        continuation.yield(.groupCreated(result))
        continuation.finish()
      }
    }
    let initial = loadedGroupState()
    let store = makeStore(initial, workspace: client)
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.branchChanged("task/feat"))
    await store.send(.groupMember("/src/api", .baseRefChanged("origin/release")))
    await store.send(.createButtonTapped)
    await store.receive(\.creationFailed)
    guard case .failed(_, let residuals) = store.state.creation else {
      Issue.record("expected a failure, got \(store.state.creation)")
      return
    }
    #expect(residuals == ["/ws/feat/app: permission denied"])
    #expect(store.state.groupMembers[id: "/src/api"]?.progress == .failed("fetch failed"))
    #expect(store.state.groupMembers[id: "/src/app"]?.progress == .rolledBack)
    // The form is as the user left it, and Create runs again.
    #expect(store.state.groupName == "feat")
    #expect(store.state.branchDraft == "task/feat")
    #expect(store.state.groupMembers[id: "/src/api"]?.options.baseRef == "origin/release")
    #expect(store.state.canCreate)

    await store.send(.createButtonTapped)
    await store.receive(\.delegate.groupCreated, result)
    #expect(attempts.value == 2)
    #expect(store.state.creation == .idle)
  }

  @Test
  func aSetupFailureKeepsTheGroupAndHandsUpTheFinalResult() async {
    let result = GroupCreationResult(
      projectID: workspaceID, groupID: WorkspaceGroupID(), groupWorktreeID: WorktreeID(),
      members: [
        .init(name: "app", worktreeID: WorktreeID(), agentProfileID: UUID(99)),
        .init(name: "api", worktreeID: WorktreeID()),
      ],
      setupFailures: [.init(name: "app", reason: "exit 1")])
    var client = workspaceClient()
    client.createGroupStream = { _, _ in
      AsyncThrowingStream { continuation in
        continuation.yield(.memberStarted(name: "app", phase: .checkingOut))
        continuation.yield(.memberFinished(name: "app"))
        continuation.yield(.memberStarted(name: "api", phase: .checkingOut))
        continuation.yield(.memberFinished(name: "api"))
        continuation.yield(.manifestWritten)
        continuation.yield(.groupRegistered(groupID: result.groupID, memberWorktreeIDs: []))
        continuation.yield(.setupStarted(name: "app"))
        continuation.yield(.setupFailed(name: "app", reason: "exit 1"))
        continuation.yield(.groupCreated(result))
        continuation.finish()
      }
    }
    let store = makeStore(loadedGroupState(), workspace: client)
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.createButtonTapped)
    // Nothing is handed up before the stream reports the final result.
    await store.receive(\.creationEvent, .setupFailed(name: "app", reason: "exit 1"))
    #expect(store.state.groupMembers[id: "/src/app"]?.progress == .setupFailed("exit 1"))
    await store.receive(\.delegate.groupCreated, result)
    #expect(store.state.creation == .createdWithSetupFailures)
    #expect(store.state.groupMembers[id: "/src/api"]?.progress == .done)
    #expect(!store.state.canCreate)
    await store.send(.cancelButtonTapped)
    await store.receive(\.delegate.dismissed)
  }

  @Test
  func cancellingCheckoutsAsksTheClientAndShowsTheRollback() async {
    let cancelled = LockIsolated<[UUID]>([])
    let (stream, continuation) = AsyncThrowingStream<WorkspaceCreationEvent, Error>.makeStream()
    var client = workspaceClient()
    client.createGroupStream = { _, _ in stream }
    client.cancelCreation = { token in
      cancelled.withValue { $0.append(token) }
      continuation.yield(.rollingBack)
      continuation.yield(.rolledBack(failures: []))
      continuation.finish(throwing: WorkspaceError.cancelled)
    }
    let store = makeStore(loadedGroupState(), workspace: client)
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.createButtonTapped)
    continuation.yield(.memberStarted(name: "app", phase: .checkingOut))
    await store.receive(\.creationEvent)
    #expect(store.state.creation == .running(current: "app"))
    await store.send(.cancelButtonTapped) {
      $0.creation = .rollingBack
    }
    await store.receive(\.creationFailed)
    #expect(cancelled.value == [UUID(0)])
    #expect(store.state.creation == .rolledBack(failures: []))
  }

  // MARK: - URL classification

  @Test
  func addEntryClassifierTellsURLsAndPathsApart() {
    let exists: (String) -> Bool = { $0 == "/src/app" || $0 == "rel/path" }
    #expect(
      AddEntryClassifier.classify("https://github.com/o/r.git", fileExists: exists)
        == .url("https://github.com/o/r.git"))
    #expect(
      AddEntryClassifier.classify("git@github.com:o/r.git", fileExists: exists) == .url("git@github.com:o/r.git"))
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
