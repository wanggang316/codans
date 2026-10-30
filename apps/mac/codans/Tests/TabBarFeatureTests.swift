import ComposableArchitecture
import Foundation
import Testing
import CodansCore

@testable import Codans

@MainActor
struct TabBarFeatureTests {
  @Test
  func newTabButtonCallsCreateTab() async {
    let worktreeID = WorktreeID()
    let projectID = ProjectID()
    let received = LockIsolated<(WorktreeID, ProjectID, String?)?>(nil)

    // Reducer now calls snapshot() + openPane() after createTab so the
    // auto-spawned pane lands in the worktree's cwd (see 1f475ff).
    // Stub the chain so the unimplemented closure does not record an
    // issue when this test runs alongside its siblings.
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.createTab = { w, p, name in
        received.withValue { $0 = (w, p, name) }
        return TabID()
      }
      $0.hierarchyClient.snapshot = {
        Catalog()
      }
    }

    await store.send(
      .newTabButtonTapped(inWorktree: worktreeID, inProject: projectID))
    let captured = received.value
    #expect(captured?.0 == worktreeID)
    #expect(captured?.1 == projectID)
    #expect(captured?.2 == nil)
  }

  @Test
  func tabButtonCallsSelectTab() async {
    let tabID = TabID()
    let worktreeID = WorktreeID()
    let projectID = ProjectID()
    let received = LockIsolated<TabID?>(nil)

    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.selectTab = { id, _, _ in
        received.withValue { $0 = id }
      }
    }

    await store.send(
      .tabButtonTapped(tabID, inWorktree: worktreeID, inProject: projectID))
    #expect(received.value == tabID)
  }

  @Test
  func closeButtonCallsCloseTab() async {
    let tabID = TabID()
    let worktreeID = WorktreeID()
    let projectID = ProjectID()
    let received = LockIsolated<TabID?>(nil)

    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.closeTab = { id, _, _ in
        received.withValue { $0 = id }
      }
    }

    await store.send(
      .closeButtonTapped(tabID, inWorktree: worktreeID, inProject: projectID))
    #expect(received.value == tabID)
  }

  // MARK: - Tab-bar uplift (M2-T2.10)

  @Test
  func renameSubmittedCallsRenameTab() async {
    let tabID = TabID()
    let received = LockIsolated<(TabID, String?)?>(nil)
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.renameTab = { id, _, _, name in
        received.withValue { $0 = (id, name) }
      }
    }
    await store.send(
      .renameSubmitted(
        tabID, name: "new-title",
        inWorktree: WorktreeID(), inProject: ProjectID()
      ))
    #expect(received.value?.0 == tabID)
    #expect(received.value?.1 == "new-title")
  }

  @Test
  func contextMenuCloseOthersCallsClient() async {
    let tabID = TabID()
    let received = LockIsolated<TabID?>(nil)
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.closeOtherTabs = { keep, _, _ in
        received.withValue { $0 = keep }
      }
    }
    await store.send(
      .contextMenuCloseOthers(
        tabID, inWorktree: WorktreeID(), inProject: ProjectID()
      ))
    #expect(received.value == tabID)
  }

  @Test
  func contextMenuCloseToRightCallsClient() async {
    let tabID = TabID()
    let received = LockIsolated<TabID?>(nil)
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.closeTabsToRight = { pivot, _, _ in
        received.withValue { $0 = pivot }
      }
    }
    await store.send(
      .contextMenuCloseToRight(
        tabID, inWorktree: WorktreeID(), inProject: ProjectID()
      ))
    #expect(received.value == tabID)
  }

  @Test
  func contextMenuCloseAllCallsClient() async {
    let received = LockIsolated<Bool>(false)
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.closeAllTabs = { _, _ in
        received.withValue { $0 = true }
      }
    }
    await store.send(
      .contextMenuCloseAll(
        inWorktree: WorktreeID(), inProject: ProjectID()
      ))
    #expect(received.value)
  }

  @Test
  func dragReorderEndedCallsReorderTabs() async {
    let ids = [TabID(), TabID(), TabID()]
    let received = LockIsolated<[TabID]?>(nil)
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.reorderTabs = { _, _, ordered in
        received.withValue { $0 = ordered }
      }
    }
    await store.send(
      .dragReorderEnded(
        orderedIDs: ids,
        inWorktree: WorktreeID(), inProject: ProjectID()
      ))
    #expect(received.value == ids)
  }

  @Test
  func middleClickedCallsCloseTab() async {
    let tabID = TabID()
    let received = LockIsolated<TabID?>(nil)
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.closeTab = { id, _, _ in
        received.withValue { $0 = id }
      }
    }
    await store.send(
      .middleClicked(
        tabID, inWorktree: WorktreeID(), inProject: ProjectID()
      ))
    #expect(received.value == tabID)
  }

  @Test
  func trailingSplitRequestedResolvesAnchorAndSplits() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let tabID = TabID()
    let paneID = PaneID()

    // Build a minimal catalog with a single tab carrying one pane.
    let pane = Pane(id: paneID, workingDirectory: "/tmp/repo", initialCommand: nil)
    let tab = Tab(
      id: tabID, name: "one",
      splitTree: SplitTree(leaf: paneID),
      panes: [pane]
    )
    let worktree = Worktree(
      id: worktreeID, name: "main", path: "/tmp/repo", branch: "main",
      tabs: [tab], selectedTabID: tabID
    )
    let project = Project(
      id: projectID, name: "p", rootPath: "/tmp/repo",
      worktrees: [worktree], selectedWorktreeID: worktreeID
    )
    let catalog = Catalog(projects: [project])

    let received = LockIsolated<(PaneID, SplitTree<PaneID>.NewDirection, String)?>(nil)
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.lastFocusedPane = { _ in nil }
      $0.hierarchyClient.splitPane = { pid, dir, _, _, _, cwd, _ in
        received.withValue { $0 = (pid, dir, cwd) }
        return PaneID()
      }
    }

    await store.send(
      .trailingSplitRequested(
        direction: .right,
        inWorktree: worktreeID, inProject: projectID
      ))
    #expect(received.value?.0 == paneID)
    #expect(received.value?.1 == .right)
    #expect(received.value?.2 == "/tmp/repo")
  }

  @Test
  func trailingSplitRequestedAnchorsOnLastFocusedPane() async throws {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let tabID = TabID()
    let firstPaneID = PaneID()
    let focusedPaneID = PaneID()

    // Two-pane tab: leaves().first is `firstPaneID`, but focus rests on
    // `focusedPaneID`. The split must anchor on the focused pane.
    let firstPane = Pane(id: firstPaneID, workingDirectory: "/tmp/a", initialCommand: nil)
    let focusedPane = Pane(id: focusedPaneID, workingDirectory: "/tmp/b", initialCommand: nil)
    let splitTree = try SplitTree(leaf: firstPaneID)
      .inserting(focusedPaneID, at: firstPaneID, direction: .right)
    let tab = Tab(
      id: tabID, name: "two",
      splitTree: splitTree,
      panes: [firstPane, focusedPane]
    )
    let worktree = Worktree(
      id: worktreeID, name: "main", path: "/tmp/repo", branch: "main",
      tabs: [tab], selectedTabID: tabID
    )
    let project = Project(
      id: projectID, name: "p", rootPath: "/tmp/repo",
      worktrees: [worktree], selectedWorktreeID: worktreeID
    )
    let catalog = Catalog(projects: [project])

    let received = LockIsolated<(PaneID, String)?>(nil)
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.lastFocusedPane = { tid in tid == tabID ? focusedPaneID : nil }
      $0.hierarchyClient.splitPane = { pid, _, _, _, _, cwd, _ in
        received.withValue { $0 = (pid, cwd) }
        return PaneID()
      }
    }

    await store.send(
      .trailingSplitRequested(
        direction: .down,
        inWorktree: worktreeID, inProject: projectID
      ))
    #expect(received.value?.0 == focusedPaneID)
    #expect(received.value?.1 == "/tmp/b")
  }

  @Test
  func trailingSplitRequestedNoOpWhenNoActiveTab() async {
    // Empty catalog — no worktree / tab / pane to anchor off.
    let catalog = Catalog()
    let splitCalled = LockIsolated<Bool>(false)
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.lastFocusedPane = { _ in nil }
      $0.hierarchyClient.splitPane = { _, _, _, _, _, _, _ in
        splitCalled.withValue { $0 = true }
        return PaneID()
      }
    }
    await store.send(
      .trailingSplitRequested(
        direction: .right,
        inWorktree: WorktreeID(), inProject: ProjectID()
      ))
    #expect(!splitCalled.value)
  }

  // MARK: - Agent session resume

  /// One project / worktree / tab, so the reducer can resolve the focused pane.
  private struct ResumeFixture {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let pane: Pane
    let catalog: Catalog

    init(paneAgent: AgentKind? = nil, hasTab: Bool = true, remote: Bool = false) {
      let pane = Pane(workingDirectory: "/repo", agentKind: paneAgent)
      self.pane = pane
      let tabs = hasTab ? [Tab(panes: [pane])] : []
      let worktree = Worktree(
        id: worktreeID, name: "main", path: "/repo", tabs: tabs, selectedTabID: tabs.first?.id)
      let project = Project(
        id: projectID, name: "repo", rootPath: "/repo",
        remoteHost: remote ? RemoteHost(alias: "box") : nil, worktrees: [worktree])
      catalog = Catalog(projects: [project])
    }
  }

  private static let resumeCommand =
    AgentRuntimeAdapters.adapter(for: .claudeCode).resumeCommand(sessionID: "abc-123")

  /// Sends a resume and returns the script the reducer handed to the shared
  /// pipeline, plus where it was asked to run.
  private func resume(
    _ placement: AgentResumePlacement, fixture: ResumeFixture
  ) async -> (ScriptDefinition, ProjectID, WorktreeID)? {
    let ran = LockIsolated<(ScriptDefinition, ProjectID, WorktreeID)?>(nil)
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { fixture.catalog }
      $0.hierarchyClient.lastFocusedPane = { _ in fixture.pane.id }
      $0.hierarchyClient.runAgentCommand = { script, projectID, worktreeID in
        ran.withValue { $0 = (script, projectID, worktreeID) }
      }
    }
    await store.send(
      .resumeAgentSessionTapped(
        agent: .claudeCode, sessionID: "abc-123", placement: placement,
        inWorktree: fixture.worktreeID, inProject: fixture.projectID))
    await store.finish()
    return ran.value
  }

  @Test
  func resumeInNewTabRunsTheResumeCommandInANewTab() async throws {
    let fixture = ResumeFixture()
    let (script, projectID, worktreeID) = try #require(await resume(.newTab, fixture: fixture))
    #expect(script.target == .newTab)
    #expect(script.command == Self.resumeCommand)
    #expect(script.onFinished == .none)
    #expect(script.focus)
    #expect(projectID == fixture.projectID)
    #expect(worktreeID == fixture.worktreeID)
  }

  @Test
  func resumeInPlaceTypesIntoTheFocusedPane() async throws {
    let (script, _, _) = try #require(await resume(.inPlace, fixture: ResumeFixture()))
    #expect(script.target == .focused)
  }

  @Test
  func resumeInSplitUsesTheChosenDirection() async throws {
    let (script, _, _) = try #require(await resume(.split(.up), fixture: ResumeFixture()))
    #expect(script.target == .split)
    #expect(script.direction == .up)
  }

  /// Typing over a live agent session would corrupt it.
  @Test
  func resumeInPlaceOverAnAgentPaneFallsBackToANewTab() async throws {
    let fixture = ResumeFixture(paneAgent: .codex)
    let (script, _, _) = try #require(await resume(.inPlace, fixture: fixture))
    #expect(script.target == .newTab)
  }

  /// The empty-terminal entry: no tab, so nothing to type into or split.
  @Test
  func resumeWithoutAFocusedPaneFallsBackToANewTab() async throws {
    let fixture = ResumeFixture(hasTab: false)
    let (inPlace, _, _) = try #require(await resume(.inPlace, fixture: fixture))
    #expect(inPlace.target == .newTab)
    let (split, _, _) = try #require(await resume(.split(.left), fixture: fixture))
    #expect(split.target == .newTab)
  }

  /// A Server-project pane's shell already runs on the host, so every
  /// placement sends the same plain resume command through the pipeline.
  @Test
  func resumeInAServerProjectRunsTheSameCommandInEveryPlacement() async throws {
    let fixture = ResumeFixture(remote: true)
    for placement in [AgentResumePlacement.newTab, .inPlace, .split(.right)] {
      let (script, _, _) = try #require(await resume(placement, fixture: fixture))
      #expect(script.target == placement.target)
      #expect(script.command == Self.resumeCommand)
    }
  }

  // MARK: - `+` agent menu

  @Test
  func launchAgentFromNewTabMenuForcesANewTab() async {
    let profile = AgentProfile(kind: .codex, target: .split)
    let worktreeID = WorktreeID()
    let projectID = ProjectID()
    let launched = LockIsolated<AgentLaunchSpec?>(nil)
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0[SettingsWriter.self].readSnapshotSync = {
        Settings(agents: AgentSettings(profiles: [profile]))
      }
      $0.hierarchyClient.launchAgent = { spec in
        launched.withValue { $0 = spec }
        return AgentLaunchOutcome(profile: spec.profile, command: "codex", tabID: nil, paneID: nil)
      }
    }

    await store.send(
      .launchAgentInNewTabTapped(
        profileID: profile.id, inWorktree: worktreeID, inProject: projectID))
    await store.finish()
    #expect(launched.value?.profile.id == profile.id)
    #expect(launched.value?.worktreeID == worktreeID)
    #expect(launched.value?.projectID == projectID)
    // The profile's saved `.split` placement yields to the new-tab button.
    #expect(launched.value?.target == .newTab)
  }

  @Test
  func launchAgentFromNewTabMenuIgnoresRemovedProfile() async {
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0[SettingsWriter.self].readSnapshotSync = { Settings(agents: AgentSettings(profiles: [])) }
    }
    // `launchAgent` stays unimplemented: reaching it would record an issue.
    await store.send(
      .launchAgentInNewTabTapped(
        profileID: UUID(), inWorktree: WorktreeID(), inProject: ProjectID()))
  }

  @Test
  func manageAgentsOpensTheAgentsSettingsPane() async {
    let opened = LockIsolated<SettingsSection?>(nil)
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.settingsWindowPresenter.openAt = { section in opened.withValue { $0 = section } }
    }
    await store.send(.manageAgentsTapped)
    await store.finish()
    #expect(opened.value == .agents)
  }
}
