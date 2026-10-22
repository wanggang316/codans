import CodansCore
import CodansIPC
import Foundation
import Testing

@testable import Codans

/// `agent.listStates` / `agent.wait` over the Agents View's state store.
@MainActor
struct AgentHandlersStateTests {
  private struct Fixture {
    let handlers: AgentHandlers
    let store: AgentStateStore
    let agentContentID: ContentID
    let idleContentID: ContentID
    let catalog: Catalog
  }

  /// Two Panes: the first holds the working agent's Tab ("dev"), the
  /// second the idle agent's Tab ("zsh") beside a plain shell Tab.
  private func makeFixture(focused: ContentID? = nil, waitPollMillis: Int = 10) -> Fixture {
    let agentTab = Tab(name: "dev", content: .terminal(workingDirectory: "/repo"))
    let idleTab = Tab(cachedDisplayTitle: "zsh", content: .terminal(workingDirectory: "/repo"))
    let plainTab = Tab(content: .terminal(workingDirectory: "/repo"))
    let pane = Pane(tabs: [agentTab])
    let pane2 = Pane(tabs: [idleTab, plainTab])
    let worktree = Worktree(
      name: "main", path: "/repo", branch: "main",
      // swiftlint:disable:next force_try
      splitTree: try! SplitTree(leaf: pane.id).inserting(pane2.id, at: pane.id, direction: .right),
      panes: [pane, pane2], focusedPaneID: pane.id)
    let project = Project(name: "repo", rootPath: "/repo", gitRoot: "/repo", worktrees: [worktree])
    let catalog = Catalog(projects: [project])
    let store = AgentStateStore(focusedPane: { focused })
    store.seedRestored([
      (contentID: agentTab.contentID, kind: .claudeCode, state: .working),
      (contentID: idleTab.contentID, kind: .amp, state: .idle),
    ])
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AgentHandlersStateTests-\(UUID().uuidString).json")
    var hierarchy = HierarchyClient.testValue
    hierarchy.snapshot = { catalog }
    let handlers = AgentHandlers(
      settings: SettingsStore(fileURL: url), hierarchy: hierarchy, installation: nil,
      stateStore: { store }, focusedPane: { focused }, waitPollMillis: waitPollMillis)
    return Fixture(
      handlers: handlers, store: store, agentContentID: agentTab.contentID, idleContentID: idleTab.contentID,
      catalog: catalog)
  }

  @Test
  func listStatesReportsEveryBoundPaneInHierarchyOrder() throws {
    let fixture = makeFixture()
    let response = try fixture.handlers.listStates()

    #expect(response.count == 2)
    #expect(
      response.agents.map(\.paneID) == [fixture.agentContentID.description, fixture.idleContentID.description])
    let first = try #require(response.agents.first)
    #expect(first.agent == "claude-code")
    #expect(first.agentName == AgentKind.claudeCode.displayName)
    #expect(first.state == "working")
    #expect(first.handle == "t1")
    #expect(first.projectName == "repo")
    #expect(first.worktreeName == "main")
    #expect(first.tabTitle == "dev")
    #expect(!first.isFocused)
    let second = response.agents[1]
    #expect(second.state == "idle")
    #expect(second.handle == "t2")
    #expect(second.tabTitle == "zsh")
  }

  @Test
  func listStatesMarksTheFocusedPane() throws {
    let fixture = makeFixtureFocusedOnAgentPane()
    let response = try fixture.handlers.listStates()
    #expect(response.agents.first?.isFocused == true)
    #expect(response.agents[1].isFocused == false)
  }

  private func makeFixtureFocusedOnAgentPane() -> Fixture {
    // Build once to learn the Content id, then rebuild with focus on it.
    let base = makeFixture()
    let contentID = base.agentContentID
    let store = base.store
    var hierarchy = HierarchyClient.testValue
    hierarchy.snapshot = { base.catalog }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AgentHandlersStateTests-\(UUID().uuidString).json")
    let handlers = AgentHandlers(
      settings: SettingsStore(fileURL: url), hierarchy: hierarchy, installation: nil,
      stateStore: { store }, focusedPane: { contentID })
    return Fixture(
      handlers: handlers, store: store, agentContentID: contentID, idleContentID: base.idleContentID,
      catalog: base.catalog)
  }

  @Test
  func waitResolvesWhenTheStateArrives() async throws {
    let fixture = makeFixture()
    let contentID = fixture.agentContentID
    let store = fixture.store
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(60))
      store.seedRestored([(contentID: contentID, kind: .claudeCode, state: .idle)])
    }

    let response = try await fixture.handlers.wait(
      IPC.AgentWaitRequest(paneID: contentID, until: .idle, timeoutMillis: 3000))

    #expect(response.satisfied)
    #expect(response.state == "idle")
    #expect(response.previousState == "working")
    #expect(response.agent == "claude-code")
    #expect(response.waitedMs >= 50)
  }

  @Test
  func waitConditionAcceptsTheFormerFinishedName() throws {
    #expect(IPC.AgentWaitCondition(rawValue: "finished") == .done)
    let decoded = try JSONDecoder().decode(
      IPC.AgentWaitCondition.self, from: Data(#""finished""#.utf8))
    #expect(decoded == .done)
    #expect(IPC.AgentWaitCondition(rawValue: "bogus") == nil)
  }

  @Test
  func waitReportsTheDeadlineWithTheLastState() async throws {
    let fixture = makeFixture()

    let response = try await fixture.handlers.wait(
      IPC.AgentWaitRequest(paneID: fixture.agentContentID, until: .done, timeoutMillis: 120))

    #expect(!response.satisfied)
    #expect(response.state == "working")
    #expect(response.waitedMs >= 120)
  }

  @Test
  func waitChangedAndExitFollowTheBinding() async throws {
    let fixture = makeFixture()
    let contentID = fixture.agentContentID
    let store = fixture.store
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(40))
      store.seedRestored([(contentID: contentID, kind: .claudeCode, state: .blocked)])
    }
    let changed = try await fixture.handlers.wait(
      IPC.AgentWaitRequest(paneID: contentID, until: .changed, timeoutMillis: 3000))
    #expect(changed.satisfied)
    #expect(changed.state == "blocked")

    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(40))
      store.onAgentUnbound(contentID)
    }
    let exited = try await fixture.handlers.wait(
      IPC.AgentWaitRequest(paneID: contentID, until: .exit, timeoutMillis: 3000))
    #expect(exited.satisfied)
    #expect(exited.state == nil)
    #expect(exited.agent == "claude-code")
  }

  @Test
  func waitOnAnUnknownPaneIsNotFound() async {
    let fixture = makeFixture()
    do {
      _ = try await fixture.handlers.wait(
        IPC.AgentWaitRequest(paneID: ContentID(), until: .idle, timeoutMillis: 100))
      Issue.record("expected notFound")
    } catch let error as IPCError {
      guard case .notFound(let kind, _) = error else {
        Issue.record("expected notFound, got \(error)")
        return
      }
      #expect(kind == "pane")
    } catch {
      Issue.record("unexpected \(error)")
    }
  }

  @Test
  func withoutAStateStoreBothVerbsAreUnsupported() async {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AgentHandlersStateTests-\(UUID().uuidString).json")
    let handlers = AgentHandlers(
      settings: SettingsStore(fileURL: url), hierarchy: HierarchyClient.testValue, installation: nil)
    #expect(throws: IPCError.self) { try handlers.listStates() }
    await #expect(throws: IPCError.self) {
      try await handlers.wait(IPC.AgentWaitRequest(paneID: ContentID(), until: .idle, timeoutMillis: 10))
    }
  }
}
