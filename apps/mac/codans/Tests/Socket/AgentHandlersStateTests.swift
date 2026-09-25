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
    let pane: Pane
    let idlePane: Pane
    let catalog: Catalog
  }

  private func makeFixture(focused: PaneID? = nil, waitPollMillis: Int = 10) -> Fixture {
    let pane = Pane(workingDirectory: "/repo")
    let idlePane = Pane(workingDirectory: "/repo")
    let plain = Pane(workingDirectory: "/repo")
    let tab = Tab(name: "dev", splitTree: SplitTree(leaf: pane.id), panes: [pane])
    let tab2 = Tab(
      cachedDisplayTitle: "zsh",
      // swiftlint:disable:next force_try
      splitTree: try! SplitTree(leaf: idlePane.id).inserting(
        plain.id, at: idlePane.id, direction: .right),
      panes: [idlePane, plain])
    let worktree = Worktree(name: "main", path: "/repo", branch: "main", tabs: [tab, tab2])
    let project = Project(name: "repo", rootPath: "/repo", gitRoot: "/repo", worktrees: [worktree])
    let catalog = Catalog(projects: [project])
    let store = AgentStateStore(focusedPane: { focused })
    store.seedRestored([
      (paneID: pane.id, kind: .claudeCode, state: .working),
      (paneID: idlePane.id, kind: .amp, state: .idle),
    ])
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AgentHandlersStateTests-\(UUID().uuidString).json")
    var hierarchy = HierarchyClient.testValue
    hierarchy.snapshot = { catalog }
    let handlers = AgentHandlers(
      settings: SettingsStore(fileURL: url), hierarchy: hierarchy, installation: nil,
      stateStore: { store }, focusedPane: { focused }, waitPollMillis: waitPollMillis)
    return Fixture(
      handlers: handlers, store: store, pane: pane, idlePane: idlePane, catalog: catalog)
  }

  @Test
  func errorStateIsExposedAndWaitable() async throws {
    let fixture = makeFixture()
    fixture.store.onTerminalEvent(
      .paneViewportChanged(fixture.pane.id, text: "API Error: 503 unavailable"))
    #expect(try fixture.handlers.listStates().agents.first?.state == "error")
    let response = try await fixture.handlers.wait(
      .init(paneID: fixture.pane.id, until: .error, timeoutMillis: 100))
    #expect(response.satisfied)
    #expect(response.state == "error")
  }

  @Test
  func listStatesReportsEveryBoundPaneInHierarchyOrder() throws {
    let fixture = makeFixture()
    let response = try fixture.handlers.listStates()

    #expect(response.count == 2)
    #expect(
      response.agents.map(\.paneID) == [
        fixture.pane.id.description, fixture.idlePane.id.description,
      ])
    let first = try #require(response.agents.first)
    #expect(first.agent == "claude-code")
    #expect(first.agentName == AgentKind.claudeCode.displayName)
    #expect(first.state == "working")
    #expect(first.handle == "p1")
    #expect(first.projectName == "repo")
    #expect(first.worktreeName == "main")
    #expect(first.tabTitle == "dev")
    #expect(!first.isFocused)
    let second = response.agents[1]
    #expect(second.state == "idle")
    #expect(second.handle == "p2")
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
    // Build once to learn the pane id, then rebuild with focus on it.
    let base = makeFixture()
    let pane = base.pane
    let store = base.store
    var hierarchy = HierarchyClient.testValue
    hierarchy.snapshot = { base.catalog }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AgentHandlersStateTests-\(UUID().uuidString).json")
    let handlers = AgentHandlers(
      settings: SettingsStore(fileURL: url), hierarchy: hierarchy, installation: nil,
      stateStore: { store }, focusedPane: { pane.id })
    return Fixture(
      handlers: handlers, store: store, pane: pane, idlePane: base.idlePane, catalog: base.catalog)
  }

  @Test
  func waitResolvesWhenTheStateArrives() async throws {
    let fixture = makeFixture()
    let pane = fixture.pane
    let store = fixture.store
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(60))
      store.seedRestored([(paneID: pane.id, kind: .claudeCode, state: .idle)])
    }

    let response = try await fixture.handlers.wait(
      IPC.AgentWaitRequest(paneID: pane.id, until: .idle, timeoutMillis: 3000))

    #expect(response.satisfied)
    #expect(response.state == "idle")
    #expect(response.previousState == "working")
    #expect(response.agent == "claude-code")
    #expect(response.waitedMs >= 50)
  }

  @Test
  func waitReportsTheDeadlineWithTheLastState() async throws {
    let fixture = makeFixture()

    let response = try await fixture.handlers.wait(
      IPC.AgentWaitRequest(paneID: fixture.pane.id, until: .finished, timeoutMillis: 120))

    #expect(!response.satisfied)
    #expect(response.state == "working")
    #expect(response.waitedMs >= 120)
  }

  @Test
  func waitChangedAndExitFollowTheBinding() async throws {
    let fixture = makeFixture()
    let pane = fixture.pane
    let store = fixture.store
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(40))
      store.seedRestored([(paneID: pane.id, kind: .claudeCode, state: .blocked)])
    }
    let changed = try await fixture.handlers.wait(
      IPC.AgentWaitRequest(paneID: pane.id, until: .changed, timeoutMillis: 3000))
    #expect(changed.satisfied)
    #expect(changed.state == "blocked")

    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(40))
      store.onAgentUnbound(pane.id)
    }
    let exited = try await fixture.handlers.wait(
      IPC.AgentWaitRequest(paneID: pane.id, until: .exit, timeoutMillis: 3000))
    #expect(exited.satisfied)
    #expect(exited.state == nil)
    #expect(exited.agent == "claude-code")
  }

  @Test
  func waitOnAnUnknownPaneIsNotFound() async {
    let fixture = makeFixture()
    do {
      _ = try await fixture.handlers.wait(
        IPC.AgentWaitRequest(paneID: PaneID(), until: .idle, timeoutMillis: 100))
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
      settings: SettingsStore(fileURL: url), hierarchy: HierarchyClient.testValue, installation: nil
    )
    #expect(throws: IPCError.self) { try handlers.listStates() }
    await #expect(throws: IPCError.self) {
      try await handlers.wait(
        IPC.AgentWaitRequest(paneID: PaneID(), until: .idle, timeoutMillis: 10))
    }
  }
}
