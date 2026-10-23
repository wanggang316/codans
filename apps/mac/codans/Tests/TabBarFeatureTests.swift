import ComposableArchitecture
import Foundation
import Testing
import CodansCore

@testable import Codans

@MainActor
struct TabBarFeatureTests {
  /// One Project / Worktree with the given Panes, selected all the way
  /// down so reducers that read `snapshot()` resolve the Worktree path.
  private static func catalog(
    projectID: ProjectID, worktreeID: WorktreeID, path: String = "/tmp/repo",
    splitTree: SplitTree<PaneID>, panes: [Pane], focusedPaneID: PaneID?
  ) -> Catalog {
    let worktree = Worktree(
      id: worktreeID, name: "main", path: path, branch: "main",
      splitTree: splitTree, panes: panes, focusedPaneID: focusedPaneID
    )
    let project = Project(
      id: projectID, name: "p", rootPath: path,
      worktrees: [worktree], selectedWorktreeID: worktreeID
    )
    return Catalog(projects: [project])
  }

  private static func address(
    projectID: ProjectID, worktreeID: WorktreeID, paneID: PaneID, contentID: ContentID = ContentID()
  ) -> TabAddress {
    TabAddress(
      projectID: projectID, worktreeID: worktreeID, paneID: paneID,
      tabID: TabID(), contentID: contentID)
  }

  @Test
  func newTabButtonOpensATabInTheWorktreeDirectory() async {
    let worktreeID = WorktreeID()
    let projectID = ProjectID()
    let paneID = PaneID()
    let createdContent = ContentID()
    let received = LockIsolated<(PaneID?, WorktreeID, ProjectID, String?, String?)?>(nil)
    let ensured = LockIsolated<ContentID?>(nil)
    let focused = LockIsolated<ContentID?>(nil)

    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = {
        Self.catalog(
          projectID: projectID, worktreeID: worktreeID,
          splitTree: SplitTree(), panes: [], focusedPaneID: nil)
      }
      $0.hierarchyClient.newTab = { pane, w, p, content, name, _, _ in
        received.withValue { $0 = (pane, w, p, content.terminal?.workingDirectory, name) }
        return Self.address(
          projectID: p, worktreeID: w, paneID: pane ?? PaneID(), contentID: createdContent)
      }
      $0.hierarchyClient.ensureSurface = { id in ensured.withValue { $0 = id } }
      $0.hierarchyClient.focusSurfaceView = { id in focused.withValue { $0 = id } }
    }

    await store.send(
      .newTabButtonTapped(inPane: paneID, inWorktree: worktreeID, inProject: projectID))
    await store.finish()
    let captured = received.value
    #expect(captured?.0 == paneID)
    #expect(captured?.1 == worktreeID)
    #expect(captured?.2 == projectID)
    #expect(captured?.3 == "/tmp/repo")
    #expect(captured?.4 == nil)
    #expect(ensured.value == createdContent)
    #expect(focused.value == createdContent)
  }

  @Test
  func newTabButtonIsANoOpForAnUnknownWorktree() async {
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { Catalog() }
    }
    // `newTab` stays unimplemented: reaching it would record an issue.
    await store.send(
      .newTabButtonTapped(inPane: nil, inWorktree: WorktreeID(), inProject: ProjectID()))
  }

  @Test
  func tabButtonCallsSelectTab() async {
    let tabID = TabID()
    let received = LockIsolated<TabID?>(nil)

    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.selectTab = { id in
        received.withValue { $0 = id }
      }
    }

    await store.send(.tabButtonTapped(tabID))
    #expect(received.value == tabID)
  }

  @Test
  func closeButtonCallsCloseTab() async {
    let tabID = TabID()
    let received = LockIsolated<TabID?>(nil)

    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.closeTab = { id in
        received.withValue { $0 = id }
      }
    }

    await store.send(.closeButtonTapped(tabID))
    #expect(received.value == tabID)
  }

  @Test
  func stripTapFocusesThePaneAndItsSelectedTab() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let tabs = (0..<2).map { _ in Tab(content: .terminal(workingDirectory: "/tmp")) }
    let other = Pane(tabs: [Tab(content: .terminal(workingDirectory: "/tmp"))])
    let pane = Pane(tabs: tabs, selectedTabID: tabs[1].id)
    let catalog = Self.catalog(
      projectID: projectID, worktreeID: worktreeID,
      splitTree: (try? SplitTree(leaf: other.id).inserting(pane.id, at: other.id, direction: .right))
        ?? SplitTree(leaf: other.id),
      panes: [other, pane], focusedPaneID: other.id)
    let focusedPane = LockIsolated<PaneID?>(nil)
    let focusedSurface = LockIsolated<ContentID?>(nil)

    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.focusPane = { id in focusedPane.withValue { $0 = id } }
      $0.hierarchyClient.focusSurfaceView = { id in focusedSurface.withValue { $0 = id } }
    }

    await store.send(.stripTapped(pane.id))
    #expect(focusedPane.value == pane.id)
    #expect(focusedSurface.value == tabs[1].contentID)
  }

  // MARK: - Tab-bar uplift (M2-T2.10)

  @Test
  func renameSubmittedCallsRenameTab() async {
    let tabID = TabID()
    let received = LockIsolated<(TabID, String?)?>(nil)
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.renameTab = { id, name in
        received.withValue { $0 = (id, name) }
      }
    }
    await store.send(.renameSubmitted(tabID, name: "new-title"))
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
      $0.hierarchyClient.closeOtherTabs = { keep in
        received.withValue { $0 = keep }
      }
    }
    await store.send(.contextMenuCloseOthers(tabID))
    #expect(received.value == tabID)
  }

  @Test
  func contextMenuCloseToRightCallsClient() async {
    let tabID = TabID()
    let received = LockIsolated<TabID?>(nil)
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.closeTabsToRight = { pivot in
        received.withValue { $0 = pivot }
      }
    }
    await store.send(.contextMenuCloseToRight(tabID))
    #expect(received.value == tabID)
  }

  @Test
  func contextMenuCloseAllCallsClient() async {
    let paneID = PaneID()
    let received = LockIsolated<PaneID?>(nil)
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.closeAllTabs = { pane in
        received.withValue { $0 = pane }
      }
    }
    await store.send(.contextMenuCloseAll(inPane: paneID))
    #expect(received.value == paneID)
  }

  @Test
  func dragReorderEndedCallsReorderTabs() async {
    let ids = [TabID(), TabID(), TabID()]
    let paneID = PaneID()
    let received = LockIsolated<(PaneID, [TabID])?>(nil)
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.reorderTabs = { pane, ordered in
        received.withValue { $0 = (pane, ordered) }
      }
    }
    await store.send(.dragReorderEnded(orderedIDs: ids, inPane: paneID))
    #expect(received.value?.0 == paneID)
    #expect(received.value?.1 == ids)
  }

  @Test
  func middleClickedCallsCloseTab() async {
    let tabID = TabID()
    let received = LockIsolated<TabID?>(nil)
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.closeTab = { id in
        received.withValue { $0 = id }
      }
    }
    await store.send(.middleClicked(tabID))
    #expect(received.value == tabID)
  }

  @Test
  func trailingSplitRequestedAnchorsOnTheGivenPane() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let paneID = PaneID()
    let tab = Tab(content: .terminal(workingDirectory: "/tmp/repo"))
    let pane = Pane(id: paneID, tabs: [tab])
    let catalog = Self.catalog(
      projectID: projectID, worktreeID: worktreeID,
      splitTree: SplitTree(leaf: paneID), panes: [pane], focusedPaneID: paneID)

    let received = LockIsolated<(PaneID, SplitTree<PaneID>.NewDirection, String?)?>(nil)
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.splitPane = { pid, dir, content, _, _ in
        received.withValue { $0 = (pid, dir, content.terminal?.workingDirectory) }
        return Self.address(projectID: projectID, worktreeID: worktreeID, paneID: PaneID())
      }
      $0.hierarchyClient.ensureSurface = { _ in }
      $0.hierarchyClient.focusSurfaceView = { _ in }
    }

    await store.send(
      .trailingSplitRequested(
        direction: .right, fromPane: paneID,
        inWorktree: worktreeID, inProject: projectID
      ))
    await store.finish()
    #expect(received.value?.0 == paneID)
    #expect(received.value?.1 == .right)
    #expect(received.value?.2 == "/tmp/repo")
  }

  @Test
  func trailingSplitRequestedAnchorsOnTheFocusedPaneByDefault() async throws {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let firstPaneID = PaneID()
    let focusedPaneID = PaneID()

    // Two-Pane Worktree: leaves().first is `firstPaneID`, but focus rests
    // on `focusedPaneID`. The chord path (no explicit Pane) must anchor on
    // the focused Pane and start in its selected session's directory.
    let firstPane = Pane(id: firstPaneID, tabs: [Tab(content: .terminal(workingDirectory: "/tmp/a"))])
    let focusedPane = Pane(
      id: focusedPaneID, tabs: [Tab(content: .terminal(workingDirectory: "/tmp/b"))])
    let splitTree = try SplitTree(leaf: firstPaneID)
      .inserting(focusedPaneID, at: firstPaneID, direction: .right)
    let catalog = Self.catalog(
      projectID: projectID, worktreeID: worktreeID,
      splitTree: splitTree, panes: [firstPane, focusedPane], focusedPaneID: focusedPaneID)

    let received = LockIsolated<(PaneID, String?)?>(nil)
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.focusedContent = { wid in
        guard wid == worktreeID, let tab = focusedPane.selectedTab else { return nil }
        return TabAddress(
          projectID: projectID, worktreeID: worktreeID, paneID: focusedPaneID,
          tabID: tab.id, contentID: tab.contentID)
      }
      $0.hierarchyClient.splitPane = { pid, _, content, _, _ in
        received.withValue { $0 = (pid, content.terminal?.workingDirectory) }
        return Self.address(projectID: projectID, worktreeID: worktreeID, paneID: PaneID())
      }
      $0.hierarchyClient.ensureSurface = { _ in }
      $0.hierarchyClient.focusSurfaceView = { _ in }
    }

    await store.send(
      .trailingSplitRequested(
        direction: .down, fromPane: nil,
        inWorktree: worktreeID, inProject: projectID
      ))
    await store.finish()
    #expect(received.value?.0 == focusedPaneID)
    #expect(received.value?.1 == "/tmp/b")
  }

  @Test
  func trailingSplitRequestedNoOpWhenTheWorktreeHasNoPane() async {
    // Empty catalog — no Worktree / Pane to anchor off.
    let catalog = Catalog()
    let splitCalled = LockIsolated<Bool>(false)
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.focusedContent = { _ in nil }
      $0.hierarchyClient.splitPane = { _, _, _, _, _ in
        splitCalled.withValue { $0 = true }
        return Self.address(projectID: ProjectID(), worktreeID: WorktreeID(), paneID: PaneID())
      }
    }
    await store.send(
      .trailingSplitRequested(
        direction: .right, fromPane: nil,
        inWorktree: WorktreeID(), inProject: ProjectID()
      ))
    #expect(!splitCalled.value)
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
        return AgentLaunchOutcome(
          profile: spec.profile, command: "codex", tabID: nil, paneID: nil, contentID: nil)
      }
    }

    await store.send(
      .launchAgentInNewTabTapped(
        profileID: profile.id, inPane: nil, inWorktree: worktreeID, inProject: projectID))
    await store.finish()
    #expect(launched.value?.profile.id == profile.id)
    #expect(launched.value?.worktreeID == worktreeID)
    #expect(launched.value?.projectID == projectID)
    // The profile's saved `.split` placement yields to the new-tab button.
    #expect(launched.value?.target == .newTab)
  }

  @Test
  func launchAgentFromNewTabMenuFocusesTheStripsPaneFirst() async {
    let profile = AgentProfile(kind: .codex, target: .newTab)
    let paneID = PaneID()
    let focused = LockIsolated<PaneID?>(nil)
    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0[SettingsWriter.self].readSnapshotSync = {
        Settings(agents: AgentSettings(profiles: [profile]))
      }
      $0.hierarchyClient.focusPane = { pane in focused.withValue { $0 = pane } }
      $0.hierarchyClient.launchAgent = { spec in
        AgentLaunchOutcome(
          profile: spec.profile, command: "codex", tabID: nil, paneID: nil, contentID: nil)
      }
    }

    await store.send(
      .launchAgentInNewTabTapped(
        profileID: profile.id, inPane: paneID, inWorktree: WorktreeID(), inProject: ProjectID()))
    await store.finish()
    #expect(focused.value == paneID)
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
        profileID: UUID(), inPane: nil, inWorktree: WorktreeID(), inProject: ProjectID()))
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
