import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

/// The New Workspace sheet's reducer: the folder and new branches that
/// follow the title, the Add / Edit dialog for local and remote projects,
/// per-project refs and issues, the debounced preflight, and the creation
/// stream's effect on the list. Effects are stubbed closure by closure; git
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

  private nonisolated static let libHeads = RemoteHeads(defaultBranch: "main", branches: ["main", "release"])
  private static let libRefs = RefInventory(
    local: [], remote: ["origin/main", "origin/release"], defaultBaseRef: "origin/main")

  /// A git client answering every repository with `inventory`, and every
  /// remote with `libHeads`.
  private func gitClient(_ inventory: RefInventory) -> GitWorktreeClient {
    var client = GitWorktreeClient.testValue
    client.branchRefs = { _ in inventory.local + inventory.remote }
    client.localBranchNames = { _ in Set(inventory.local) }
    client.lsWorktrees = { _ in
      inventory.checkedOut.map { GitWtEntry(branch: $0.key, path: $0.value, head: "abc", isBare: false) }
    }
    client.defaultRemoteBranchRef = { _ in inventory.defaultBaseRef }
    client.lsRemoteHeads = { _ in Self.libHeads }
    return client
  }

  private func makeStore(
    _ initial: Feature.State,
    git: GitWorktreeClient? = nil,
    workspace: WorkspaceClient? = nil,
    clock: TestClock<Duration> = TestClock(),
    fileExists: @escaping @Sendable (String) -> Bool = { _ in false },
    pickFolder: @escaping @Sendable () -> URL? = { nil }
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
      $0[FolderPickerClient.self] = FolderPickerClient(pick: { _ in pickFolder() })
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
  func preselectedProjectBecomesTheFirstRowAndLoadsRefs() async {
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
  func titleNamesTheFolderAndEveryUnnamedNewBranch() async {
    var initial = Feature.State(candidates: [app, api], locationPath: "/ws")
    initial.members = [member(1, appSource, name: "app"), member(2, apiSource, name: "api")]
    let store = makeStore(initial)
    store.exhaustivity = .off(showSkippedAssertions: false)
    #expect(store.state.rootPath.isEmpty)
    #expect(store.state.defaultBranch.isEmpty)
    await store.send(.titleChanged("Checkout Flow")) {
      $0.titleDraft = "Checkout Flow"
    }
    #expect(store.state.rootPath == "/ws/checkout-flow")
    await store.send(.locationPicked(URL(fileURLWithPath: "/elsewhere", isDirectory: true))) {
      $0.locationPath = "/elsewhere"
    }
    #expect(store.state.rootPath == "/elsewhere/checkout-flow")
    // A named branch keeps its name; a blank one follows the title.
    await store.send(.member(UUID(2), .branchOverrideChanged("mine")))
    await store.send(.titleChanged("Other"))
    #expect(store.state.rootPath == "/elsewhere/other")
    #expect(store.state.checkout(for: store.state.members[0]) == .newBranch(branch: "other", baseRef: nil))
    #expect(store.state.checkout(for: store.state.members[1]) == .newBranch(branch: "mine", baseRef: nil))
    await store.send(.member(UUID(2), .branchOverrideChanged("  ")))
    await store.send(.member(UUID(2), .baseRefChanged("origin/release")))
    #expect(
      store.state.checkout(for: store.state.members[1]) == .newBranch(branch: "other", baseRef: "origin/release"))
    // A cancelled picker changes nothing.
    await store.send(.locationPicked(nil))
  }

  // MARK: - Dialog

  @Test
  func projectMenuOpensTheDialogOnThatProject() async {
    let store = makeStore(Feature.State(candidates: [app, api]))
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.addProjectTapped(app.id))
    #expect(store.state.editor?.kind == .project)
    #expect(store.state.editor?.draft?.id == UUID(0))
    #expect(store.state.editor?.draft?.source == appSource)
    #expect(store.state.editor?.draft?.name == "app")
    await store.receive(\.member) {
      $0.editor?.draft?.refs = .loaded(appRefs)
    }
    // Nothing reaches the list before Add.
    #expect(store.state.members.isEmpty)
    #expect(store.state.canSaveEditor)
    await store.send(.editor(.saveTapped)) {
      $0.editor = nil
    }
    #expect(store.state.members.map(\.source) == [appSource])
    #expect(store.state.availableCandidates == [api])
    // A listed project is not offered again.
    await store.send(.addProjectTapped(app.id))
    #expect(store.state.editor == nil)
  }

  @Test
  func folderDialogOpensOnThePickedFolderAndOffersAnother() async {
    let picked = LockIsolated<URL?>(URL(fileURLWithPath: "/nonexistent-codans-test/notes"))
    var initial = Feature.State(candidates: [app, api])
    initial.members = [member(9, appSource, name: "app")]
    let store = makeStore(initial, pickFolder: { picked.value })
    store.exhaustivity = .off(showSkippedAssertions: false)

    // The dialog opens on the picked folder and says why it can't be used.
    await store.send(.addFolderTapped)
    await store.receive(\.addFolderPicked) {
      $0.editor = MemberEditor(id: UUID(0), kind: .folder)
      $0.editor?.isResolvingSource = true
    }
    await store.receive(\.editor) {
      $0.editor?.isResolvingSource = false
      $0.editor?.sourceIssue = "/nonexistent-codans-test/notes is not a git repository."
    }
    #expect(store.state.editorIssues == [.blocking("/nonexistent-codans-test/notes is not a git repository.")])
    #expect(!store.state.canSaveEditor)

    // A folder inside an open project is that project; another repository
    // with the same folder name gets a suffix, and replaces the choice.
    await store.send(
      .editor(.folderResolved(path: "/src/api/sub", probe: RepositoryProbe(root: "/src/api", isBare: false))))
    #expect(store.state.editor?.sourceIssue == nil)
    #expect(store.state.editor?.draft?.source == apiSource)
    await store.send(
      .editor(.folderResolved(path: "/other/app", probe: RepositoryProbe(root: "/other/app", isBare: false))))
    #expect(store.state.editor?.draft?.source == .localRepo(gitRoot: "/other/app"))
    #expect(store.state.editor?.draft?.name == "app-2")
    #expect(store.state.editor?.draft?.id == UUID(0))

    // Duplicates, bare repositories, and plain folders are refused.
    await store.send(
      .editor(.folderResolved(path: "/src/app", probe: RepositoryProbe(root: "/src/app", isBare: false)))
    ) {
      $0.editor?.sourceIssue = "/src/app is already in the list."
    }
    #expect(!store.state.canSaveEditor)
    await store.send(
      .editor(.folderResolved(path: "/m/tool.git", probe: RepositoryProbe(root: "/m/tool.git", isBare: true)))
    ) {
      $0.editor?.sourceIssue = "/m/tool.git is a bare repository, which workspaces do not support."
    }
    // Choose… again, then cancel the picker: nothing changes.
    picked.setValue(nil)
    await store.send(.editor(.chooseFolderTapped))
    await store.receive(\.editor)
    #expect(store.state.editor?.draft?.source == .localRepo(gitRoot: "/other/app"))
    #expect(store.state.editor?.isResolvingSource == false)
    // Cancel leaves the list alone.
    await store.send(.editor(.cancelTapped)) {
      $0.editor = nil
    }
    #expect(store.state.members.count == 1)
    // A cancelled picker opens no dialog.
    await store.send(.addFolderTapped)
    await store.receive(\.addFolderPicked)
    #expect(store.state.editor == nil)
  }

  @Test
  func remoteDialogFollowsTheURLOnceTypingPauses() async {
    let clock = TestClock()
    let store = makeStore(Feature.State(candidates: [app]), clock: clock)
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.addRemoteTapped) {
      $0.editor = MemberEditor(id: UUID(0), kind: .remote)
    }
    #expect(store.state.editorIssues == [.incomplete("Enter the repository\u{2019}s URL.")])
    await store.send(.editor(.urlChanged("git@github.com:org/lib.git")))
    #expect(store.state.editor?.draft == nil)
    await clock.advance(by: .milliseconds(600))
    await store.receive(\.editor)
    #expect(
      store.state.editor?.draft?.source
        == .remote(url: "git@github.com:org/lib.git", cloneDestination: Self.defaultSource("lib")))
    #expect(store.state.editor?.draft?.name == "lib")
    await store.receive(\.member) {
      $0.editor?.draft?.refs = .loaded(Self.libRefs)
    }

    // A picked clone folder stays the parent when the URL changes; a URL
    // still being typed can't be added.
    await store.send(.member(UUID(0), .cloneDestinationPicked(URL(fileURLWithPath: "/code", isDirectory: true))))
    #expect(
      store.state.editor?.draft?.source == .remote(url: "git@github.com:org/lib.git", cloneDestination: "/code/lib"))
    await store.send(.editor(.urlChanged("https://github.com/org/tool")))
    #expect(!store.state.canSaveEditor)
    await store.send(.editor(.urlSubmitted))
    #expect(
      store.state.editor?.draft?.source == .remote(url: "https://github.com/org/tool", cloneDestination: "/code/tool"))
    #expect(store.state.editor?.draft?.name == "tool")
    await store.receive(\.member)
    #expect(store.state.canSaveEditor)
    await store.send(.editor(.saveTapped))
    #expect(store.state.members.map(\.name) == ["tool"])

    // The same remote in another spelling is refused; paths and words are
    // reported on Return only.
    await store.send(.addRemoteTapped)
    await store.send(.editor(.urlChanged("git@github.com:org/tool.git")))
    await store.send(.editor(.urlSubmitted)) {
      $0.editor?.sourceIssue = "This repository is already in the list."
    }
    await store.send(.editor(.urlChanged("/nowhere/repo"))) {
      $0.editor?.urlText = "/nowhere/repo"
      $0.editor?.sourceIssue = nil
    }
    await clock.advance(by: .milliseconds(600))
    await store.receive(\.editor)
    #expect(store.state.editor?.sourceIssue == nil)
    await store.send(.editor(.urlSubmitted)) {
      $0.editor?.sourceIssue = "Enter a URL. To use a folder on this Mac, add a local repository."
    }
    await store.send(.editor(.urlChanged("just words")))
    await store.send(.editor(.urlSubmitted)) {
      $0.editor?.sourceIssue = "Enter a git URL, such as git@github.com:org/repo.git."
    }
    #expect(store.state.editor?.draft == nil)
    await store.send(.editor(.saveTapped))
    #expect(store.state.members.count == 1)
  }

  @Test
  func editingARowChangesItOnSaveOnly() async {
    var initial = Feature.State(candidates: [app, api])
    initial.titleDraft = "T"
    initial.members = [member(1, appSource, name: "app", refs: appRefs), member(2, apiSource, name: "api")]
    let store = makeStore(initial)
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.editTapped(UUID(1))) {
      $0.editor = MemberEditor(id: UUID(1), kind: .edit, draft: $0.members[0])
    }
    // Its own project counts as available again; the other row's does not.
    #expect(store.state.availableCandidates == [app])
    await store.send(.member(UUID(1), .modeChanged(.existing)))
    await store.send(.member(UUID(1), .existingRefChanged("wip")))
    await store.send(.member(UUID(1), .nameChanged("front")))
    #expect(store.state.members[0].mode == .newBranch)
    #expect(store.state.members[0].name == "app")
    await store.send(.editor(.cancelTapped)) {
      $0.editor = nil
    }
    #expect(store.state.members[0].mode == .newBranch)

    await store.send(.editTapped(UUID(1)))
    await store.send(.member(UUID(1), .modeChanged(.existing)))
    await store.send(.member(UUID(1), .existingRefChanged("wip")))
    // Branches loaded meanwhile reach the row as well as the dialog.
    await store.send(.member(UUID(1), .refsLoaded(RefInventory(local: ["wip"]))))
    #expect(store.state.members[0].refs == .loaded(RefInventory(local: ["wip"])))
    await store.send(.editor(.saveTapped)) {
      $0.editor = nil
      $0.members[0].mode = .existing
      $0.members[0].existingRef = "wip"
    }
    #expect(store.state.checkoutSummary(for: store.state.members[0]) == "Branch wip")

    // While the dialog is open, rows can't be edited or removed.
    await store.send(.editTapped(UUID(1)))
    await store.send(.editTapped(UUID(2)))
    #expect(store.state.editor?.id == UUID(1))
    await store.send(.member(UUID(1), .remove))
    #expect(store.state.members.count == 2)
    await store.send(.editor(.cancelTapped))
    await store.send(.member(UUID(1), .remove))
    #expect(store.state.members.map(\.id) == [UUID(2)])
  }

  @Test
  func dialogAllowsABranchThatWillFollowTheTitle() async {
    let store = makeStore(Feature.State(candidates: [app]))
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.addProjectTapped(app.id))
    await store.receive(\.member)
    #expect(store.state.defaultBranch.isEmpty)
    #expect(store.state.canSaveEditor)
    // Other missing pieces still hold the dialog back.
    await store.send(.member(UUID(0), .modeChanged(.existing)))
    #expect(store.state.editorIssues == [.incomplete("Choose a branch for app.")])
    #expect(!store.state.canSaveEditor)
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
    initial.titleDraft = "x"
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
    await store.send(.member(UUID(1), .modeChanged(.existing)))
    #expect(
      store.state.issues(for: store.state.members[0]).contains(
        .blocking("The remote did not answer within 20 seconds.")))
    // Removing the row cancels an in-flight load.
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
    #expect(state.createHint == "Add at least two projects.")
    state.members.append(member(2, apiSource, name: "api", refs: RefInventory(local: ["main"])))
    #expect(state.createHint == nil)
    #expect(state.canCreate)
    #expect(state.createButtonTitle == "Create")
    // Without a title, a blank new branch has no name.
    state.titleDraft = "   "
    #expect(state.createHint == "Enter a title.")
    state.members[0].branchOverride = "own"
    #expect(state.issues(for: state.members[0]).isEmpty)
    #expect(state.issues(for: state.members[1]) == [.incomplete("Enter a branch name for api.")])
  }

  @Test
  func checkoutIssuesCoverEachMode() async {
    var initial = Feature.State(candidates: [app])
    initial.titleDraft = "wip"
    initial.members = [
      member(1, appSource, name: "app", refs: appRefs),
      member(2, .localRepo(gitRoot: "/src/lib"), name: "app", refs: RefInventory(local: ["main"])),
    ]
    let store = makeStore(initial)
    store.exhaustivity = .off(showSkippedAssertions: false)

    #expect(
      store.state.issues(for: store.state.members[0]) == [
        .blocking("Another project already uses the folder name \u{201C}app\u{201D}."),
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
    await store.send(.member(UUID(1), .modeChanged(.existing)))
    #expect(store.state.issues(for: store.state.members[0]) == [.incomplete("Choose a branch for app.")])
    await store.send(.member(UUID(1), .existingRefChanged("main")))
    #expect(
      store.state.issues(for: store.state.members[0]) == [
        .blocking(
          "\u{201C}main\u{201D} is already checked out at /src/app, and git allows that in one place only. "
            + "Choose New branch to start one from it, or pick another branch.")
      ])
    await store.send(.member(UUID(1), .existingRefChanged("gone")))
    #expect(
      store.state.issues(for: store.state.members[0]) == [
        .blocking("\u{201C}gone\u{201D} is not a branch of this repository.")
      ])
    #expect(store.state.checkout(for: store.state.members[0]) == .existingBranch("gone"))

    // A remote branch from the same list is checked out as its local twin.
    await store.send(.member(UUID(1), .existingRefChanged("origin/feat/x")))
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
    await store.send(.member(UUID(1), .existingRefChanged("origin/main"))) {
      $0.members[0].existingRef = "origin/main"
      $0.members[0].localConflict = .keepLocal
    }
    #expect(store.state.issues(for: store.state.members[0]).count == 1)
    await store.send(.member(UUID(1), .localConflictChanged(.resetToRemote)))
    #expect(store.state.issues(for: store.state.members[0]).first?.message.contains("already checked out") == true)
    // No local twin: no choice to make.
    await store.send(.member(UUID(1), .existingRefChanged("origin/release")))
    #expect(!store.state.members[0].hasLocalConflict)
    await store.send(.member(UUID(1), .existingRefChanged("upstream/none")))
    #expect(
      store.state.issues(for: store.state.members[0]) == [
        .blocking("\u{201C}upstream/none\u{201D} is not a branch of this repository.")
      ])
  }

  @Test
  func rowsSummarizeTheirCheckout() {
    var state = Feature.State(candidates: [app])
    var row = member(1, appSource, name: "app")
    #expect(state.checkoutSummary(for: row) == "New branch from the default branch, named after the title")
    state.titleDraft = "Checkout Flow"
    row.refs = .loaded(appRefs)
    #expect(state.checkoutSummary(for: row) == "New branch checkout-flow from origin/main")
    row.baseRef = "origin/release"
    row.branchOverride = "feat/y"
    #expect(state.checkoutSummary(for: row) == "New branch feat/y from origin/release")
    row.mode = .existing
    #expect(state.checkoutSummary(for: row) == "Existing branch")
    row.existingRef = "wip"
    #expect(state.checkoutSummary(for: row) == "Branch wip")
    row.existingRef = "origin/release"
    #expect(state.checkoutSummary(for: row) == "Branch release, tracking origin/release")
    row.existingRef = "origin/feat/x"
    #expect(state.checkoutSummary(for: row) == "Local branch feat/x, tracking origin/feat/x")
    row.localConflict = .resetToRemote
    #expect(state.checkoutSummary(for: row) == "Branch feat/x, reset to origin/feat/x")
  }

  // MARK: - Preflight

  @Test
  func preflightIsDebouncedAndLandsOnRowsAndTheDialog() async {
    let clock = TestClock()
    let plans = LockIsolated<[WorkspacePlan]>([])
    var workspace = WorkspaceClient.testValue
    workspace.preflight = { plan in
      plans.withValue { $0.append(plan) }
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
    #expect(plans.value.map(\.title) == ["abc"])
    #expect(store.state.issues(for: store.state.members[0]) == [.blocking("~/ws/app already exists.")])
    #expect(store.state.plan == nil)
    // A folder-name problem already says it; the preflight line is dropped.
    await store.send(.member(UUID(2), .nameChanged("app")))
    #expect(
      store.state.issues(for: store.state.members[1]) == [
        .blocking("Another project already uses the folder name \u{201C}app\u{201D}.")
      ])

    // While a row is edited, the dialog's draft is what gets checked, and
    // the row keeps its findings until Save.
    await store.send(.member(UUID(2), .nameChanged("api")))
    await store.send(.editTapped(UUID(2)))
    await store.send(.member(UUID(2), .nameChanged("app")))
    await clock.advance(by: .milliseconds(300))
    await store.receive(\.preflightTick)
    await store.receive(\.preflightFinished)
    #expect(plans.value.last?.members.map(\.name) == ["app", "app"])
    #expect(store.state.editor?.draft?.preflightIssues.map(\.message) == ["~/ws/app already exists."])
    #expect(store.state.members[1].preflightIssues.map(\.message) == ["~/ws/api already exists."])
    #expect(
      store.state.editorIssues.first == .blocking("Another project already uses the folder name \u{201C}app\u{201D}."))
    #expect(!store.state.canSaveEditor)
  }

  // MARK: - Creation

  private func readyState() -> Feature.State {
    var initial = Feature.State(candidates: [app, api], locationPath: "/tmp")
    initial.titleDraft = "T"
    initial.members = [
      member(1, appSource, name: "app", refs: appRefs), member(2, apiSource, name: "api", refs: appRefs),
    ]
    return initial
  }

  @Test
  func createStreamsProgressOntoRowsAndDelegatesOnRegistration() async {
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
  func failureMarksTheRowAndTheNextEditClearsIt() async {
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
    // The failed row can be edited, and any edit puts the list back to its
    // plain state.
    await store.send(.editTapped(UUID(2)))
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
    // Rows are locked while it runs.
    await store.send(.editTapped(UUID(1)))
    await store.send(.addRemoteTapped)
    #expect(store.state.editor == nil)
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
    #expect(initial.defaultBranch == "handos")
    #expect(initial.createHint == "Add a project.")
    #expect(initial.createButtonTitle == "Add")
    let store = makeStore(initial, workspace: workspace)
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.addProjectTapped(app.id))
    // Names the workspace already has are skipped, and refused when typed.
    #expect(store.state.editor?.draft?.name == "app-2")
    await store.send(.member(UUID(0), .nameChanged("app")))
    #expect(
      store.state.editorIssues.contains(.blocking("The workspace already has a folder named \u{201C}app\u{201D}.")))
    await store.send(.member(UUID(0), .nameChanged("lib")))
    await store.send(.editor(.saveTapped))
    #expect(!store.state.canAddMembers)
    // One project is the whole plan: further adds are ignored.
    await store.send(.addRemoteTapped)
    #expect(store.state.editor == nil)
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
