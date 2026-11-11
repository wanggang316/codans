import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

/// `NewAgentFeature`: project seeding, the agent default, and what each
/// target sends — a new worktree, a branch a worktree holds, a dangling
/// local branch, and a remote-only branch.
@MainActor
struct NewAgentFeatureTests {
  private let gitProjectID = ProjectID()
  private let folderProjectID = ProjectID()
  private let mainWorktreeID = WorktreeID()
  private let folderWorktreeID = WorktreeID()
  private let profile = AgentProfile(kind: .claudeCode, name: "Claude")

  private var catalog: Catalog {
    Catalog(projects: [
      Project(
        id: gitProjectID, name: "repo", rootPath: "/tmp/new-agent/repo",
        gitRoot: "/tmp/new-agent/repo",
        worktrees: [
          Worktree(id: mainWorktreeID, name: "repo", path: "/tmp/new-agent/repo", branch: "main"),
          Worktree(
            name: "old", path: "/tmp/new-agent/old", branch: "feature/old", archived: true),
        ]),
      Project(
        id: folderProjectID, name: "notes", rootPath: "/tmp/new-agent/notes",
        worktrees: [Worktree(id: folderWorktreeID, name: "notes", path: "/tmp/new-agent/notes")]),
    ])
  }

  private func makeStore(
    preferredProjectID: ProjectID?, pendingCounts: [ProjectID: Int] = [:],
    restoring draft: NewAgentFeature.Draft? = nil
  ) -> TestStore<NewAgentFeature.State, NewAgentFeature.Action> {
    let catalog = catalog
    let store = TestStore(
      initialState: NewAgentFeature.State(
        preferredProjectID: preferredProjectID, pendingCounts: pendingCounts, restoring: draft)
    ) {
      NewAgentFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0[SettingsWriter.self].readSnapshotSync = { Settings() }
      $0.gitWorktreeClient.branchRefs = { _ in
        ["feature/dangling", "feature/old", "main", "origin/main", "origin/remote-only"]
      }
      $0.gitWorktreeClient.localBranchNames = { _ in ["feature/dangling", "feature/old", "main"] }
      $0.gitWorktreeClient.lsWorktrees = { _ in
        [
          GitWtEntry(branch: "main", path: "/tmp/new-agent/repo", head: "abc", isBare: false),
          GitWtEntry(branch: "feature/old", path: "/tmp/new-agent/old", head: "def", isBare: false),
        ]
      }
      $0.gitWorktreeClient.defaultRemoteBranchRef = { _ in "origin/main" }
    }
    store.exhaustivity = .off
    return store
  }

  /// Opens the dialog on the git project with options loaded and the agent
  /// list supplied, the way the view does on appear.
  private func openOnGitProject() async -> TestStore<NewAgentFeature.State, NewAgentFeature.Action> {
    let store = makeStore(preferredProjectID: gitProjectID)
    await store.send(.onAppear)
    await store.receive(\.worktree.optionsLoaded)
    await store.send(.agentProfilesChanged([profile]))
    return store
  }

  @Test
  func opensOnPreferredGitProjectWithNewWorktreeForm() async {
    let store = await openOnGitProject()
    #expect(store.state.projects.map(\.id) == [gitProjectID, folderProjectID])
    #expect(store.state.projectID == gitProjectID)
    #expect(store.state.target == .newWorktree)
    #expect(store.state.isCreatingWorktree)
    #expect(store.state.worktree?.selectedBaseRef == "origin/main")
    // The dialog's agent menu decides; the form's own picker stays empty.
    #expect(store.state.worktree?.agentProfiles.isEmpty == true)
    #expect(store.state.agentProfileID == profile.id)
  }

  @Test
  func branchListsSkipArchivedAndSplitLocalFromRemote() async {
    let store = await openOnGitProject()
    #expect(store.state.localBranches == ["feature/dangling", "main"])
    #expect(store.state.remoteBranches == ["origin/main", "origin/remote-only"])
  }

  @Test
  func agentProfilesChangedKeepsAStillOfferedChoice() async {
    let other = AgentProfile(kind: .codex, name: "Codex")
    let store = await openOnGitProject()
    await store.send(.agentSelected(profile.id))
    await store.send(.agentProfilesChanged([other, profile])) {
      $0.agentProfiles = [other, profile]
    }
    #expect(store.state.agentProfileID == profile.id)
    await store.send(.agentProfilesChanged([other]))
    #expect(store.state.agentProfileID == other.id)
    await store.send(.agentProfilesChanged([]))
    #expect(store.state.agentProfileID == nil)
    #expect(!store.state.canSend)
  }

  @Test
  func newWorktreeSendNeedsABranchName() async {
    let store = await openOnGitProject()
    #expect(!store.state.canSend)
    await store.send(.sendTapped)
    await store.send(.worktree(.branchDraftChanged("feature/agent")))
    #expect(store.state.canSend)
  }

  @Test
  func newWorktreeSendCreatesWorktreeCarryingAgentAndPrompt() async {
    let store = await openOnGitProject()
    await store.send(.worktree(.branchDraftChanged("feature/agent")))
    await store.send(.promptChanged("  Fix the login bug\n"))
    await store.send(.sendTapped)
    await store.receive(\.worktree.createButtonTapped)
    await store.receive(\.worktree.delegate.beginCreate)
    let pending = await Self.receiveCreatedPending(store)
    #expect(pending?.projectID == gitProjectID)
    #expect(pending?.spec.name == "feature/agent")
    #expect(pending?.spec.baseRef == "origin/main")
    #expect(pending?.launchAgentProfileID == profile.id)
    #expect(pending?.launchAgentPrompt == "Fix the login bug")
  }

  @Test
  func branchHeldByAWorktreeLaunchesThere() async {
    let store = await openOnGitProject()
    await store.send(.targetSelected(.branch("main")))
    #expect(!store.state.isCreatingWorktree)
    await store.send(.sendTapped)
    await store.receive(
      .delegate(
        .launchAgent(
          profileID: profile.id, prompt: nil, projectID: gitProjectID, worktreeID: mainWorktreeID)))
  }

  @Test
  func remoteRefOfACheckedOutBranchLaunchesInItsWorktree() async {
    let store = await openOnGitProject()
    await store.send(.targetSelected(.branch("origin/main")))
    await store.send(.sendTapped)
    await store.receive(
      .delegate(
        .launchAgent(
          profileID: profile.id, prompt: nil, projectID: gitProjectID, worktreeID: mainWorktreeID)))
  }

  @Test
  func danglingLocalBranchIsCheckedOutIntoANamedPath() async {
    let store = await openOnGitProject()
    await store.send(.targetSelected(.branch("feature/dangling")))
    await store.send(.sendTapped)
    let pending = await Self.receiveCreatedPending(store)
    #expect(pending?.spec.name == "feature/dangling")
    #expect(pending?.spec.baseRef == "")
    #expect(pending?.spec.pathOverride?.lastPathComponent == "dangling")
    #expect(pending?.launchAgentProfileID == profile.id)
  }

  @Test
  func remoteOnlyBranchBecomesALocalBranchFromTheRemoteRef() async {
    let store = await openOnGitProject()
    await store.send(.targetSelected(.branch("origin/remote-only")))
    await store.send(.sendTapped)
    let pending = await Self.receiveCreatedPending(store)
    #expect(pending?.spec.name == "remote-only")
    #expect(pending?.spec.baseRef == "origin/remote-only")
    #expect(pending?.displayName == "remote-only")
  }

  @Test
  func branchCheckoutRespectsThePendingCap() async {
    let store = makeStore(preferredProjectID: gitProjectID, pendingCounts: [gitProjectID: 8])
    await store.send(.onAppear)
    await store.receive(\.worktree.optionsLoaded)
    await store.send(.agentProfilesChanged([profile]))
    await store.send(.targetSelected(.branch("origin/remote-only")))
    await store.send(.sendTapped) {
      $0.submitError = CreateWorktreeFeature.capMessage
    }
  }

  @Test
  func folderProjectLaunchesInItsWorktree() async {
    let store = makeStore(preferredProjectID: folderProjectID)
    await store.send(.onAppear)
    #expect(store.state.worktree == nil)
    #expect(!store.state.isCreatingWorktree)
    await store.send(.agentProfilesChanged([profile]))
    await store.send(.promptChanged("Summarize the notes"))
    await store.send(.sendTapped)
    await store.receive(
      .delegate(
        .launchAgent(
          profileID: profile.id, prompt: "Summarize the notes", projectID: folderProjectID,
          worktreeID: folderWorktreeID)))
  }

  @Test
  func switchingToAFolderProjectDropsTheWorktreeForm() async {
    let store = await openOnGitProject()
    await store.send(.targetSelected(.branch("main")))
    await store.send(.projectSelected(folderProjectID)) {
      $0.projectID = folderProjectID
      $0.target = .newWorktree
      $0.worktree = nil
    }
  }

  @Test
  func reopeningRestoresTheDraft() async {
    let first = await openOnGitProject()
    await first.send(.worktreeOptionsToggled)
    await first.send(.worktree(.baseRefSelected("origin/remote-only")))
    await first.send(.worktree(.fetchOriginToggled(false)))
    await first.send(.worktree(.branchDraftChanged("feature/agent")))
    await first.send(.promptChanged("Fix the login bug"))

    let reopened = makeStore(preferredProjectID: folderProjectID, restoring: first.state.draft)
    await reopened.send(.onAppear)
    await reopened.receive(\.worktree.optionsLoaded)
    await reopened.receive(\.worktree.branchDraftChanged)
    await reopened.send(.agentProfilesChanged([profile]))
    #expect(reopened.state.projectID == gitProjectID)
    #expect(reopened.state.showsWorktreeOptions)
    #expect(reopened.state.prompt == "Fix the login bug")
    #expect(reopened.state.worktree?.branchNameDraft == "feature/agent")
    #expect(reopened.state.worktree?.selectedBaseRef == "origin/remote-only")
    #expect(reopened.state.worktree?.fetchOrigin == false)
    #expect(reopened.state.restoring == nil)
    #expect(reopened.state.canSend)
  }

  @Test
  func restoredBranchThatIsGoneFallsBackToNewWorktree() async {
    let first = await openOnGitProject()
    await first.send(.targetSelected(.branch("feature/gone")))
    let reopened = makeStore(preferredProjectID: nil, restoring: first.state.draft)
    await reopened.send(.onAppear)
    #expect(reopened.state.target == .branch("feature/gone"))
    await reopened.receive(\.worktree.optionsLoaded)
    #expect(reopened.state.target == .newWorktree)
  }

  @Test
  func opensWithoutProjectsOnAddProject() async {
    let store = TestStore(initialState: NewAgentFeature.State(preferredProjectID: nil)) {
      NewAgentFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { Catalog() }
    }
    await store.send(.onAppear)
    #expect(store.state.projects.isEmpty)
    await store.send(.addProjectTapped(.cloneRepository))
    await store.receive(.delegate(.addProject(.cloneRepository)))
  }

  /// Receives the `createWorktree` delegate and hands back its creation.
  private static func receiveCreatedPending(
    _ store: TestStore<NewAgentFeature.State, NewAgentFeature.Action>
  ) async -> PendingWorktree? {
    let captured = LockIsolated<PendingWorktree?>(nil)
    await store.receive { action in
      guard case .delegate(.createWorktree(let pending)) = action else { return false }
      captured.setValue(pending)
      return true
    }
    return captured.value
  }

  @Test
  func pickedFilesGoAtTheCaret() async {
    let store = TestStore(initialState: NewAgentFeature.State(preferredProjectID: nil)) {
      NewAgentFeature()
    }
    await store.send(.promptChanged("Fix bug")) { $0.prompt = "Fix bug" }
    await store.send(.filesSelected([URL(fileURLWithPath: "/tmp/a b.txt")], selection: 3..<3)) {
      $0.prompt = "Fix '/tmp/a b.txt' bug"
    }
  }

  @Test
  func pickedFilesWithoutCaretAppendAndEmptyPickKeepsPrompt() async {
    let store = TestStore(initialState: NewAgentFeature.State(preferredProjectID: nil)) {
      NewAgentFeature()
    }
    await store.send(.promptChanged("Read")) { $0.prompt = "Read" }
    await store.send(.filesSelected([], selection: 4..<4))
    await store.send(.filesSelected([URL(fileURLWithPath: "/tmp/a.txt")], selection: nil)) {
      $0.prompt = "Read '/tmp/a.txt'"
    }
  }

  // MARK: - Skills

  private nonisolated static func notesScope(_ profile: AgentProfile) -> NewAgentFeature.SkillScope {
    NewAgentFeature.SkillScope(
      profile: profile, projectStart: URL(fileURLWithPath: "/tmp/new-agent/notes", isDirectory: true))
  }

  private nonisolated static let reviewSkill = AgentSkillEntry(
    name: "review", summary: "Review a change", source: .user,
    url: URL(fileURLWithPath: "/tmp/skills/review"))
  private nonisolated static let workSkill = AgentSkillEntry(
    name: "deploy", summary: nil, source: .user,
    url: URL(fileURLWithPath: "/srv/work-claude/skills/deploy"))

  private nonisolated static func projectSkill(at path: String) -> AgentSkillEntry {
    AgentSkillEntry(
      name: "local", summary: path, source: .project,
      url: URL(fileURLWithPath: "\(path)/.claude/skills/local"))
  }

  private typealias RemoteLoad =
    @Sendable (AgentProfile, RemoteHost, String?, NewWorktreeSource?) async
    -> Result<[AgentSkillEntry], RemoteSkillReadError>

  private func makeSkillStore(
    catalog: Catalog, loaded: LockIsolated<[AgentKind]>,
    starts: LockIsolated<[String?]> = LockIsolated([]),
    copies: LockIsolated<[NewWorktreeSource?]> = LockIsolated([]),
    preferredProjectID: ProjectID? = nil,
    remote: RemoteLoad? = nil
  ) -> TestStore<NewAgentFeature.State, NewAgentFeature.Action> {
    let store = TestStore(initialState: NewAgentFeature.State(preferredProjectID: preferredProjectID)) {
      NewAgentFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0[SettingsWriter.self].readSnapshotSync = { Settings() }
      $0.gitWorktreeClient.branchRefs = { _ in ["feature/live", "main", "origin/main"] }
      $0.gitWorktreeClient.localBranchNames = { _ in ["feature/live", "main"] }
      $0.gitWorktreeClient.lsWorktrees = { _ in
        [
          GitWtEntry(branch: "main", path: "/tmp/new-agent/repo", head: "abc", isBare: false),
          GitWtEntry(branch: "feature/live", path: "/tmp/new-agent/live", head: "def", isBare: false)
        ]
      }
      $0.gitWorktreeClient.defaultRemoteBranchRef = { _ in "origin/main" }
      $0[AgentSkillClient.self].load = { launch, start, newWorktree in
        let profile = launch.profile
        loaded.withValue { $0.append(profile.kind) }
        copies.withValue { $0.append(newWorktree) }
        let path = start.map { url in
          let path = url.path(percentEncoded: false)
          return path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        starts.withValue { $0.append(path) }
        if let path, path != "/tmp/new-agent/notes" { return [Self.projectSkill(at: path)] }
        return profile.envVars.isEmpty ? [Self.reviewSkill] : [Self.workSkill]
      }
      if let remote { $0[AgentSkillClient.self].loadRemote = remote }
    }
    store.exhaustivity = .off
    return store
  }

  @Test
  func claudeCodeProfileLoadsItsSkillsAndAnAgentWithoutStyleLoadsNone() async {
    let loaded = LockIsolated<[AgentKind]>([])
    let gemini = AgentProfile(kind: .gemini, name: "Gemini")
    let catalog = Catalog(projects: catalog.projects.filter { $0.id == folderProjectID })
    let store = makeSkillStore(catalog: catalog, loaded: loaded)
    await store.send(.onAppear)
    await store.send(.agentProfilesChanged([profile, gemini]))
    await store.receive(\.skillsLoaded) {
      $0.skills = [Self.reviewSkill]
      $0.skillsScope = Self.notesScope(profile)
    }
    #expect(store.state.skillLocation == .claudeCode)

    await store.send(.agentSelected(gemini.id)) { $0.skills = [] }
    #expect(store.state.skillLocation == .none)
    #expect(loaded.value == [.claudeCode])
  }

  @Test
  func changingTheAgentRescansAndUsesTheNewInvocationStyle() async {
    let loaded = LockIsolated<[AgentKind]>([])
    let codex = AgentProfile(kind: .codex, name: "Codex")
    let catalog = Catalog(projects: catalog.projects.filter { $0.id == folderProjectID })
    let store = makeSkillStore(catalog: catalog, loaded: loaded)
    await store.send(.onAppear)
    await store.send(.agentProfilesChanged([profile, codex]))
    await store.receive(\.skillsLoaded)
    #expect(store.state.skillLocation.invocationStyle == .slash)

    await store.send(.agentSelected(codex.id)) {
      $0.skills = []
      $0.skillsScope = nil
    }
    await store.receive(\.skillsLoaded) {
      $0.skills = [Self.reviewSkill]
      $0.skillsScope = Self.notesScope(codex)
    }
    #expect(loaded.value == [.claudeCode, .codex])
    #expect(store.state.skillLocation == .codex)

    // The list and the token the composer inserts follow Codex.
    let completion = ComposerSkillCompletion()
    completion.location = store.state.skillLocation
    completion.skills = store.state.skills
    completion.update(text: "/re", caret: 3)
    #expect(!completion.isOpen)
    completion.update(text: "$re", caret: 3)
    #expect(completion.matches == [Self.reviewSkill])
    #expect(completion.handle(.accept, text: "$re") == .insert(text: "$review ", caret: 8))

    await store.send(.promptChanged("fix")) { $0.prompt = "fix" }
    await store.send(.skillsButtonTapped(selection: 3..<3)) { $0.prompt = "fix $" }
  }

  @Test
  func remoteProjectReadsItsSkillsOnTheHost() async {
    let loaded = LockIsolated<[AgentKind]>([])
    let reads = LockIsolated<[String]>([])
    let host = RemoteHost(alias: "devbox")
    let remote = Project(
      name: "server", rootPath: "/srv/repo", remoteHost: host,
      worktrees: [Worktree(name: "repo", path: "/srv/repo")])
    let store = makeSkillStore(catalog: Catalog(projects: [remote]), loaded: loaded) {
      profile, readHost, start, creates in
      reads.withValue { $0.append("\(profile.kind.rawValue) \(readHost.alias) \(start ?? "-") \(creates != nil)") }
      return .success([Self.projectSkill(at: "/srv/repo")])
    }
    await store.send(.onAppear)
    await store.send(.agentProfilesChanged([profile]))
    await store.receive(\.skillsLoaded) {
      $0.skills = [Self.projectSkill(at: "/srv/repo")]
    }
    #expect(store.state.skillLocation == .claudeCode)
    #expect(store.state.skillsUnavailableReason == nil)
    #expect(store.state.skillsScope?.host == host)
    #expect(reads.value == ["claude-code devbox /srv/repo/ false"])
    // The local reader never runs for a remote project.
    #expect(loaded.value.isEmpty)
  }

  @Test
  func aFailedRemoteReadDisablesSkillsWithTheReason() async {
    let remote = Project(
      name: "server", rootPath: "/srv/repo", remoteHost: RemoteHost(alias: "devbox"),
      worktrees: [Worktree(name: "repo", path: "/srv/repo")])
    let store = makeSkillStore(catalog: Catalog(projects: [remote]), loaded: LockIsolated([])) { _, _, _, _ in
      .failure(RemoteSkillReadError(reason: "Could not connect to devbox"))
    }
    await store.send(.onAppear)
    await store.send(.agentProfilesChanged([profile]))
    await store.receive(\.skillsFailed) {
      $0.skillsFailure = "Could not connect to devbox"
    }
    #expect(store.state.skills.isEmpty)
    #expect(store.state.skillsUnavailableReason == "Could not connect to devbox")

    // The Skills button does nothing while it is disabled.
    await store.send(.skillsButtonTapped(selection: nil))
    #expect(store.state.prompt.isEmpty)
  }

  @Test
  func aRemoteProjectWithoutItsHostReadsNothing() async {
    let loaded = LockIsolated<[AgentKind]>([])
    let remoteReads = LockIsolated(0)
    // The Host record is gone, so the catalog resolved no connection.
    var orphan = Project(
      name: "server", rootPath: "/tmp/new-agent/notes",
      worktrees: [Worktree(name: "notes", path: "/tmp/new-agent/notes")])
    orphan.hostID = HostID(raw: UUID())
    let store = makeSkillStore(catalog: Catalog(projects: [orphan]), loaded: loaded) { _, _, _, _ in
      remoteReads.withValue { $0 += 1 }
      return .success([Self.reviewSkill])
    }
    await store.send(.onAppear)
    await store.send(.agentProfilesChanged([profile]))
    await store.receive(\.skillsFailed) {
      $0.skillsFailure = "The host of this remote project is not available"
    }
    #expect(store.state.skills.isEmpty)
    #expect(store.state.skillsUnavailableReason == "The host of this remote project is not available")
    // Neither this Mac's files at the same path nor a remote read.
    #expect(loaded.value.isEmpty)
    #expect(remoteReads.value == 0)
  }

  @Test
  func anotherAgentClearsARemoteFailure() async {
    let codex = AgentProfile(kind: .codex, name: "Codex")
    let remote = Project(
      name: "server", rootPath: "/srv/repo", remoteHost: RemoteHost(alias: "devbox"),
      worktrees: [Worktree(name: "repo", path: "/srv/repo")])
    let store = makeSkillStore(catalog: Catalog(projects: [remote]), loaded: LockIsolated([])) { profile, _, _, _ in
      profile.kind == .codex ? .success([Self.reviewSkill]) : .failure(RemoteSkillReadError(reason: "timed out"))
    }
    await store.send(.onAppear)
    await store.send(.agentProfilesChanged([profile, codex]))
    await store.receive(\.skillsFailed)
    await store.send(.agentSelected(codex.id)) { $0.skillsFailure = nil }
    await store.receive(\.skillsLoaded) { $0.skills = [Self.reviewSkill] }
    #expect(store.state.skillsUnavailableReason == nil)
  }

  @Test
  func switchingClaudeProfilesDropsThePreviousSkillsAtOnce() async {
    let loaded = LockIsolated<[AgentKind]>([])
    let work = AgentProfile(
      kind: .claudeCode, name: "Work", envVars: ["CLAUDE_CONFIG_DIR": "/srv/work-claude"])
    let catalog = Catalog(projects: catalog.projects.filter { $0.id == folderProjectID })
    let store = makeSkillStore(catalog: catalog, loaded: loaded)
    await store.send(.onAppear)
    await store.send(.agentProfilesChanged([profile, work]))
    await store.receive(\.skillsLoaded) {
      $0.skills = [Self.reviewSkill]
      $0.skillsScope = Self.notesScope(profile)
    }

    // Same Skill Location, other home: nothing is offered until the scan
    // for the new profile ends.
    await store.send(.agentSelected(work.id)) {
      $0.skills = []
      $0.skillsScope = nil
    }
    await store.receive(\.skillsLoaded) {
      $0.skills = [Self.workSkill]
      $0.skillsScope = Self.notesScope(work)
    }
    // A late result for the old profile is dropped.
    await store.send(.skillsLoaded([Self.reviewSkill], for: Self.notesScope(profile)))
    #expect(store.state.skills == [Self.workSkill])
    #expect(store.state.skillsScope == Self.notesScope(work))
  }

  @Test
  func reloadingTheSameProfileKeepsItsSkillsUntilTheScanEnds() async {
    let loaded = LockIsolated<[AgentKind]>([])
    let catalog = Catalog(projects: catalog.projects.filter { $0.id == folderProjectID })
    let store = makeSkillStore(catalog: catalog, loaded: loaded)
    await store.send(.onAppear)
    await store.send(.agentProfilesChanged([profile]))
    await store.receive(\.skillsLoaded)
    await store.send(.agentSelected(profile.id))
    #expect(store.state.skills == [Self.reviewSkill])
    await store.receive(\.skillsLoaded)
  }

  private var skillCatalog: Catalog {
    var catalog = catalog
    catalog.projects[0].worktrees.append(
      Worktree(name: "live", path: "/tmp/new-agent/live", branch: "feature/live"))
    return catalog
  }

  @Test
  func selectingAnotherProjectRescansAndReplacesTheList() async {
    let loaded = LockIsolated<[AgentKind]>([])
    let starts = LockIsolated<[String?]>([])
    let store = makeSkillStore(
      catalog: skillCatalog, loaded: loaded, starts: starts, preferredProjectID: folderProjectID)
    await store.send(.onAppear)
    await store.send(.agentProfilesChanged([profile]))
    await store.receive(\.skillsLoaded) { $0.skills = [Self.reviewSkill] }

    // Another project, another start directory: the old list goes at once.
    await store.send(.projectSelected(gitProjectID)) {
      $0.skills = []
      $0.skillsScope = nil
    }
    await store.receive(\.skillsLoaded) {
      $0.skills = [Self.projectSkill(at: "/tmp/new-agent/repo")]
    }
    // The git project's options load next and pick the base ref of the
    // new worktree, which scans the main checkout again with that ref.
    await store.skipReceivedActions()
    #expect(starts.value == ["/tmp/new-agent/notes", "/tmp/new-agent/repo", "/tmp/new-agent/repo"])
  }

  @Test
  func selectingAnotherTargetRescansFromItsWorktree() async {
    let loaded = LockIsolated<[AgentKind]>([])
    let starts = LockIsolated<[String?]>([])
    let store = makeSkillStore(
      catalog: skillCatalog, loaded: loaded, starts: starts, preferredProjectID: gitProjectID)
    await store.send(.onAppear)
    await store.receive(\.worktree.optionsLoaded)
    await store.send(.agentProfilesChanged([profile]))
    // A new worktree does not exist yet: the main checkout stands in.
    await store.receive(\.skillsLoaded) {
      $0.skills = [Self.projectSkill(at: "/tmp/new-agent/repo")]
    }

    await store.send(.targetSelected(.branch("feature/live"))) {
      $0.skills = []
      $0.skillsScope = nil
    }
    await store.receive(\.skillsLoaded) {
      $0.skills = [Self.projectSkill(at: "/tmp/new-agent/live")]
    }

    // Back to a new worktree: the main checkout again.
    await store.send(.targetSelected(.newWorktree))
    await store.receive(\.skillsLoaded)
    #expect(store.state.skills == [Self.projectSkill(at: "/tmp/new-agent/repo")])
    #expect(
      starts.value == [
        "/tmp/new-agent/repo", "/tmp/new-agent/live", "/tmp/new-agent/repo"
      ])
  }

  @Test
  func changingACopyOptionRescansForANewWorktree() async {
    let loaded = LockIsolated<[AgentKind]>([])
    let copies = LockIsolated<[NewWorktreeSource?]>([])
    let store = makeSkillStore(
      catalog: skillCatalog, loaded: loaded, copies: copies, preferredProjectID: gitProjectID)
    await store.send(.onAppear)
    await store.receive(\.worktree.optionsLoaded)
    await store.send(.agentProfilesChanged([profile]))
    await store.receive(\.skillsLoaded)

    // Other options, other files in the new worktree: the old list goes at
    // once.
    await store.send(.worktree(.copyIgnoredToggled(true))) {
      $0.skills = []
      $0.skillsScope = nil
    }
    await store.receive(\.skillsLoaded) {
      $0.skills = [Self.projectSkill(at: "/tmp/new-agent/repo")]
    }
    await store.send(.worktree(.copyUntrackedToggled(true)))
    await store.receive(\.skillsLoaded)
    #expect(
      copies.value == [
        NewWorktreeSource(ref: "origin/main", copyIgnored: false, copyUntracked: false),
        NewWorktreeSource(ref: "origin/main", copyIgnored: true, copyUntracked: false),
        NewWorktreeSource(ref: "origin/main", copyIgnored: true, copyUntracked: true),
      ])
    #expect(store.state.skillsScope?.newWorktree == NewWorktreeSource(ref: "origin/main", copyIgnored: true, copyUntracked: true))
  }

  @Test
  func changingACopyOptionKeepsTheSkillsOfAnExistingWorktree() async {
    let loaded = LockIsolated<[AgentKind]>([])
    let copies = LockIsolated<[NewWorktreeSource?]>([])
    let store = makeSkillStore(
      catalog: skillCatalog, loaded: loaded, copies: copies, preferredProjectID: gitProjectID)
    await store.send(.onAppear)
    await store.receive(\.worktree.optionsLoaded)
    await store.send(.agentProfilesChanged([profile]))
    await store.receive(\.skillsLoaded)
    await store.send(.targetSelected(.branch("feature/live")))
    await store.receive(\.skillsLoaded)
    #expect(store.state.skillsScope?.newWorktree == nil)

    await store.send(.worktree(.copyIgnoredToggled(true)))
    await store.send(.worktree(.copyUntrackedToggled(true)))
    #expect(store.state.skills == [Self.projectSkill(at: "/tmp/new-agent/live")])
    #expect(copies.value == [NewWorktreeSource(ref: "origin/main", copyIgnored: false, copyUntracked: false), nil])
  }

  /// A new worktree gets its tracked files from the base ref, so another
  /// base ref rescans with it.
  @Test
  func changingTheBaseRefRescansForANewWorktree() async {
    let loaded = LockIsolated<[AgentKind]>([])
    let copies = LockIsolated<[NewWorktreeSource?]>([])
    let store = makeSkillStore(
      catalog: skillCatalog, loaded: loaded, copies: copies, preferredProjectID: gitProjectID)
    await store.send(.onAppear)
    await store.receive(\.worktree.optionsLoaded)
    await store.send(.agentProfilesChanged([profile]))
    await store.receive(\.skillsLoaded)
    await store.send(.worktree(.baseRefSelected("main"))) {
      $0.skills = []
      $0.skillsScope = nil
    }
    await store.receive(\.skillsLoaded)
    #expect(copies.value.map { $0?.ref } == ["origin/main", "main"])
  }

  /// The agent can be known before the worktree options load. The first
  /// scan has no base ref yet; the loaded options scan again with it.
  @Test
  func loadedOptionsRescanWithTheBaseRef() async {
    let loaded = LockIsolated<[AgentKind]>([])
    let copies = LockIsolated<[NewWorktreeSource?]>([])
    let store = makeSkillStore(
      catalog: skillCatalog, loaded: loaded, copies: copies, preferredProjectID: gitProjectID)
    await store.send(.agentProfilesChanged([profile]))
    await store.send(.onAppear)
    await store.skipReceivedActions()
    #expect(copies.value.last??.ref == "origin/main")
    #expect(store.state.skillsScope?.newWorktree?.ref == "origin/main")
  }

  /// A branch that no worktree holds is checked out into a new worktree
  /// with the dialog's copy options, so the scan follows them too.
  @Test
  func branchWithoutAWorktreeScansWithTheCopyOptions() async {
    let loaded = LockIsolated<[AgentKind]>([])
    let copies = LockIsolated<[NewWorktreeSource?]>([])
    let store = makeSkillStore(
      catalog: skillCatalog, loaded: loaded, copies: copies, preferredProjectID: gitProjectID)
    await store.send(.onAppear)
    await store.receive(\.worktree.optionsLoaded)
    await store.send(.agentProfilesChanged([profile]))
    await store.receive(\.skillsLoaded)
    await store.send(.worktree(.copyUntrackedToggled(true)))
    await store.receive(\.skillsLoaded)
    await store.send(.targetSelected(.branch("origin/next")))
    await store.receive(\.skillsLoaded)
    #expect(copies.value.last == NewWorktreeSource(ref: "origin/next", copyIgnored: false, copyUntracked: true))
  }

  /// A local branch with a slash is not read as `<remote>/<branch>`: the
  /// agent starts in a new worktree for `feature/live`, so the scan reads
  /// the main checkout, not the worktree of an unrelated `live` branch.
  @Test
  func localBranchWithASlashDoesNotScanAnotherBranchesWorktree() async {
    let loaded = LockIsolated<[AgentKind]>([])
    let starts = LockIsolated<[String?]>([])
    var catalog = catalog
    catalog.projects[0].worktrees.append(
      Worktree(name: "other", path: "/tmp/new-agent/other", branch: "live"))
    let store = makeSkillStore(
      catalog: catalog, loaded: loaded, starts: starts, preferredProjectID: gitProjectID)
    await store.send(.onAppear)
    await store.receive(\.worktree.optionsLoaded)
    await store.send(.agentProfilesChanged([profile]))
    await store.receive(\.skillsLoaded)
    await store.send(.targetSelected(.branch("feature/live")))
    await store.receive(\.skillsLoaded)
    #expect(starts.value == ["/tmp/new-agent/repo", "/tmp/new-agent/repo"])
  }

  // MARK: - Skills button

  @Test
  func skillsButtonInsertsThePrefixWhenSkillsAreAvailable() async {
    let loaded = LockIsolated<[AgentKind]>([])
    let catalog = Catalog(projects: catalog.projects.filter { $0.id == folderProjectID })
    let store = makeSkillStore(catalog: catalog, loaded: loaded)
    await store.send(.onAppear)
    await store.send(.agentProfilesChanged([profile]))
    await store.receive(\.skillsLoaded)
    #expect(store.state.skillsUnavailableReason == nil)

    await store.send(.promptChanged("fix")) { $0.prompt = "fix" }
    await store.send(.skillsButtonTapped(selection: 3..<3)) { $0.prompt = "fix /" }
  }

  @Test
  func skillsButtonIsOffForAnAgentWithoutInvocationStyle() async {
    let loaded = LockIsolated<[AgentKind]>([])
    let gemini = AgentProfile(kind: .gemini, name: "Work Gemini")
    let catalog = Catalog(projects: catalog.projects.filter { $0.id == folderProjectID })
    let store = makeSkillStore(catalog: catalog, loaded: loaded)
    await store.send(.onAppear)
    await store.send(.agentProfilesChanged([gemini]))
    #expect(store.state.skillLocation == .none)
    #expect(store.state.skillsUnavailableReason == "Skill suggestions are not available for Gemini CLI")

    await store.send(.promptChanged("fix")) { $0.prompt = "fix" }
    await store.send(.skillsButtonTapped(selection: 3..<3))
    #expect(store.state.prompt == "fix")
    #expect(loaded.value.isEmpty)
  }

  @Test
  func skillsButtonIsOffWithoutAnAgent() async {
    let loaded = LockIsolated<[AgentKind]>([])
    let catalog = Catalog(projects: catalog.projects.filter { $0.id == folderProjectID })
    let store = makeSkillStore(catalog: catalog, loaded: loaded)
    await store.send(.onAppear)
    #expect(store.state.skillsUnavailableReason == "Choose an agent to see its skills")
  }

  // MARK: - Project menu

  private static func folder(
    _ name: String, active: TimeInterval? = nil, hostID: HostID? = nil
  ) -> Project {
    Project(
      name: name, rootPath: "/tmp/new-agent/\(name)", hostID: hostID,
      remoteHost: hostID.map { _ in RemoteHost(alias: "box") },
      lastActiveAt: active.map { Date(timeIntervalSince1970: $0) })
  }

  @Test
  func projectOptionCarriesIconColorKindAndHost() {
    var workspace = Self.folder("ws")
    workspace.icon = .symbol("hammer")
    workspace.color = .red
    workspace.isWorkspace = true
    let option = ProjectMenuOption(workspace)
    #expect(option.icon == .symbol("hammer"))
    #expect(option.color == .red)
    #expect(option.defaultSymbol == ProjectIconView.workspaceSymbol)
    #expect(!option.isRemote)
    let remote = ProjectMenuOption(Self.folder("server", hostID: HostID()))
    #expect(remote.isRemote)
    #expect(remote.defaultSymbol == ProjectIconView.folderSymbol)
    #expect(remote.icon == nil && remote.color == nil)
  }

  /// A Host reference whose record is gone, or a connection without a Host
  /// reference, still marks the project remote: the dialog must not read
  /// its skills from This Mac.
  @Test
  func eitherHostFieldMarksTheOptionRemote() {
    var orphan = Self.folder("orphan")
    orphan.hostID = HostID(raw: UUID())
    #expect(orphan.remoteHost == nil)
    #expect(ProjectMenuOption(orphan).isRemote)
    let connection = Project(
      name: "legacy", rootPath: "/srv/legacy", remoteHost: RemoteHost(alias: "box"))
    #expect(connection.hostID == nil)
    #expect(ProjectMenuOption(connection).isRemote)
  }

  @Test
  func menuWithoutRemoteProjectsHasOneProjectsSectionAndNoRecentUpToThree() {
    let projects = [
      Self.folder("a", active: 3), Self.folder("b", active: 1), Self.folder("c", active: 2),
    ]
    let menu = ProjectMenu(Catalog(projects: projects))
    #expect(menu.recent.isEmpty)
    #expect(menu.sections.map(\.title) == ["Projects"])
    #expect(menu.sections.first?.projects.map(\.name) == ["a", "b", "c"])
  }

  @Test
  func recentListsThreeNewestActiveProjectsOnlyAboveThree() {
    let projects = [
      Self.folder("never"), Self.folder("old", active: 1), Self.folder("newest", active: 9),
      Self.folder("mid", active: 5), Self.folder("newer", active: 7),
    ]
    let menu = ProjectMenu(Catalog(projects: projects))
    #expect(menu.recent.map(\.name) == ["newest", "newer", "mid"])
    // Recent projects stay in their section too, in catalog order.
    #expect(menu.sections.first?.projects.map(\.name) == ["never", "old", "newest", "mid", "newer"])
  }

  @Test
  func recentSkipsProjectsWithNoActivity() {
    let projects = [
      Self.folder("a"), Self.folder("b", active: 2), Self.folder("c"), Self.folder("d"),
    ]
    let menu = ProjectMenu(Catalog(projects: projects))
    #expect(menu.recent.map(\.name) == ["b"])
  }

  @Test
  func remoteProjectsGroupByHostInSidebarOrderIgnoringFiltersAndCollapse() {
    let first = HostRecord(address: "first.example", name: "First")
    let second = HostRecord(address: "second.example")
    var catalog = Catalog(
      projects: [
        Self.folder("on-second", hostID: second.id), Self.folder("local-1"),
        Self.folder("on-first", hostID: first.id), Self.folder("local-2"),
      ],
      hosts: [first, second])
    catalog.sidebarFilter = .pullRequests
    catalog.collapsedSidebarHosts = [.thisMac, .host(first.id)]
    let menu = ProjectMenu(catalog)
    #expect(menu.sections.map(\.title) == [HostRecord.thisMacName, "First", "second.example"])
    #expect(menu.sections.map { $0.projects.map(\.name) } == [["local-1", "local-2"], ["on-first"], ["on-second"]])
  }

  @Test
  func onAppearBuildsTheProjectMenu() async {
    let store = makeStore(preferredProjectID: folderProjectID)
    await store.send(.onAppear)
    #expect(store.state.projectMenu == ProjectMenu(catalog))
    #expect(store.state.projectID == folderProjectID)
  }
}
