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
    restoring draft: NewAgentFeature.Draft? = nil, catalog: Catalog? = nil,
    loadSkills: (@Sendable (AgentProfile, URL?) async -> [AgentSkillEntry])? = nil
  ) -> TestStore<NewAgentFeature.State, NewAgentFeature.Action> {
    let catalog = catalog ?? self.catalog
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
      if let loadSkills { $0[AgentSkillClient.self].load = loadSkills }
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

  private nonisolated static let notesDirectory = URL(
    fileURLWithPath: "/tmp/new-agent/notes", isDirectory: true)

  private nonisolated static let reviewSkill = AgentSkillEntry(
    name: "review", summary: "Review a change", source: .user,
    url: URL(fileURLWithPath: "/tmp/skills/review"))
  private nonisolated static let workSkill = AgentSkillEntry(
    name: "deploy", summary: nil, source: .user,
    url: URL(fileURLWithPath: "/srv/work-claude/skills/deploy"))

  private func makeSkillStore(
    catalog: Catalog, loaded: LockIsolated<[AgentKind]>
  ) -> TestStore<NewAgentFeature.State, NewAgentFeature.Action> {
    let store = TestStore(initialState: NewAgentFeature.State(preferredProjectID: nil)) {
      NewAgentFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0[SettingsWriter.self].readSnapshotSync = { Settings() }
      $0[AgentSkillClient.self].load = { profile, _ in
        loaded.withValue { $0.append(profile.kind) }
        return profile.envVars.isEmpty ? [Self.reviewSkill] : [Self.workSkill]
      }
    }
    store.exhaustivity = .off
    return store
  }

  @Test
  func claudeCodeProfileLoadsItsSkillsAndOtherAgentsLoadNone() async {
    let loaded = LockIsolated<[AgentKind]>([])
    let codex = AgentProfile(kind: .codex, name: "Codex")
    let catalog = Catalog(projects: catalog.projects.filter { $0.id == folderProjectID })
    let store = makeSkillStore(catalog: catalog, loaded: loaded)
    await store.send(.onAppear)
    await store.send(.agentProfilesChanged([profile, codex]))
    await store.receive(\.skillsLoaded) {
      $0.skills = [Self.reviewSkill]
      $0.skillsScope = .init(profile: profile, projectDirectory: Self.notesDirectory)
    }
    #expect(store.state.skillLocation == .claudeCode)

    await store.send(.agentSelected(codex.id)) { $0.skills = [] }
    #expect(store.state.skillLocation == .none)
    #expect(loaded.value == [.claudeCode])
  }

  @Test
  func remoteProjectOffersNoSkills() async {
    let loaded = LockIsolated<[AgentKind]>([])
    let remote = Project(
      name: "server", rootPath: "/srv/repo", remoteHost: RemoteHost(alias: "devbox"),
      worktrees: [Worktree(name: "repo", path: "/srv/repo")])
    let store = makeSkillStore(catalog: Catalog(projects: [remote]), loaded: loaded)
    await store.send(.onAppear)
    await store.send(.agentProfilesChanged([profile]))
    #expect(store.state.skillLocation == .none)
    #expect(store.state.skills.isEmpty)
    #expect(loaded.value.isEmpty)
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
      $0.skillsScope = .init(profile: profile, projectDirectory: Self.notesDirectory)
    }

    // Same Skill Location, other home: nothing is offered until the scan
    // for the new profile ends.
    await store.send(.agentSelected(work.id)) {
      $0.skills = []
      $0.skillsScope = nil
    }
    await store.receive(\.skillsLoaded) {
      $0.skills = [Self.workSkill]
      $0.skillsScope = .init(profile: work, projectDirectory: Self.notesDirectory)
    }
    // A late result for the old profile is dropped.
    await store.send(
      .skillsLoaded([Self.reviewSkill], for: .init(profile: profile, projectDirectory: Self.notesDirectory)))
    #expect(store.state.skills == [Self.workSkill])
    #expect(store.state.skillsScope?.profile == work)
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

  /// Claude Code reads project settings in the directory it starts in, and
  /// they can turn plugins on or off, so the scan follows the target.
  @Test
  func skillsFollowTheDirectoryTheAgentStartsIn() async {
    let requested = LockIsolated<[String?]>([])
    var catalog = catalog
    catalog.projects[0].worktrees.append(
      Worktree(name: "dangling", path: "/tmp/new-agent/dangling", branch: "feature/dangling"))
    let store = makeStore(
      preferredProjectID: gitProjectID, catalog: catalog,
      loadSkills: { _, directory in
        requested.withValue { $0.append(directory?.path(percentEncoded: false)) }
        return [Self.reviewSkill]
      })
    await store.send(.onAppear)
    await store.receive(\.worktree.optionsLoaded)
    await store.send(.agentProfilesChanged([profile]))
    await store.receive(\.skillsLoaded)

    await store.send(.targetSelected(.branch("feature/dangling"))) {
      // Skills read for another directory go at once.
      $0.skills = []
      $0.skillsScope = nil
    }
    await store.receive(\.skillsLoaded) {
      $0.skills = [Self.reviewSkill]
      $0.skillsScope = .init(
        profile: self.profile,
        projectDirectory: URL(fileURLWithPath: "/tmp/new-agent/dangling", isDirectory: true))
    }
    // A branch no worktree holds starts in a new worktree of the repository.
    await store.send(.targetSelected(.branch("origin/remote-only")))
    await store.receive(\.skillsLoaded)
    #expect(
      requested.value == ["/tmp/new-agent/repo/", "/tmp/new-agent/dangling/", "/tmp/new-agent/repo/"])

    // A late result for the old directory is dropped.
    await store.send(
      .skillsLoaded(
        [Self.workSkill],
        for: .init(
          profile: profile,
          projectDirectory: URL(fileURLWithPath: "/tmp/new-agent/dangling", isDirectory: true))))
    #expect(store.state.skills == [Self.reviewSkill])
  }

  /// A local branch with a slash is not read as `<remote>/<branch>`: the
  /// agent starts in a new worktree for `feature/dangling`, not in the
  /// worktree of an unrelated `dangling` branch.
  @Test
  func localBranchWithASlashDoesNotScanAnotherBranchesWorktree() async {
    let requested = LockIsolated<[String?]>([])
    var catalog = catalog
    catalog.projects[0].worktrees.append(
      Worktree(name: "dangling", path: "/tmp/new-agent/other", branch: "dangling"))
    let store = makeStore(
      preferredProjectID: gitProjectID, catalog: catalog,
      loadSkills: { _, directory in
        requested.withValue { $0.append(directory?.path(percentEncoded: false)) }
        return []
      })
    await store.send(.onAppear)
    await store.receive(\.worktree.optionsLoaded)
    await store.send(.agentProfilesChanged([profile]))
    await store.receive(\.skillsLoaded)
    await store.send(.targetSelected(.branch("feature/dangling")))
    await store.receive(\.skillsLoaded)
    #expect(requested.value == ["/tmp/new-agent/repo/", "/tmp/new-agent/repo/"])
  }
}
