import CodansIPC
import ComposableArchitecture
import Testing

@testable import CodansMobile

/// Agents are grouped as needs input / working / idle, driven only by the
/// event stream: a snapshot replaces the table, deltas upsert and remove.
@MainActor
struct AgentsFeatureTests {
  @Test
  func snapshotGroupsAgentsByState() async {
    let store = TestStore(initialState: AgentsFeature.State()) { AgentsFeature() }
    let agents = [
      Fixtures.agent("A", state: "blocked"),
      Fixtures.agent("B", state: "working"),
      Fixtures.agent("C", state: "idle"),
      Fixtures.agent("D", state: "finished"),
      Fixtures.agent("E", state: "someFutureState"),
    ]

    await store.send(.eventReceived(Fixtures.snapshot(agents: agents))) {
      $0.entries = Dictionary(uniqueKeysWithValues: agents.map { ($0.paneID, $0) })
      $0.hasSnapshot = true
    }

    let groups = store.state.groups
    #expect(groups.map(\.kind) == [.needsInput, .working, .idle])
    #expect(groups[0].entries.map(\.paneID) == ["A"])
    #expect(groups[1].entries.map(\.paneID) == ["B"])
    #expect(Set(groups[2].entries.map(\.paneID)) == ["C", "D", "E"])
    #expect(store.state.needsInputCount == 1)
  }

  @Test
  func deltasMoveRowsBetweenGroupsAndDropEmptyOnes() async {
    let store = TestStore(initialState: AgentsFeature.State()) { AgentsFeature() }
    let working = Fixtures.agent("A", state: "working")
    let idle = Fixtures.agent("B", state: "idle")
    await store.send(.eventReceived(Fixtures.snapshot(agents: [working, idle]))) {
      $0.entries = ["A": working, "B": idle]
      $0.hasSnapshot = true
    }

    let blocked = Fixtures.agent("A", state: "blocked", since: "2026-09-25T10:05:00Z")
    let delta = IPC.EventFrame(
      seq: 2, payload: .agentStatesChanged(IPC.AgentStatesDelta(upserted: [blocked], removedPaneIDs: ["B"])))
    await store.send(.eventReceived(delta)) {
      $0.entries = ["A": blocked]
    }
    #expect(store.state.groups.map(\.kind) == [.needsInput])
  }

  @Test
  func needsInputListsTheLongestWaitingFirstAndOthersMostRecentFirst() {
    var state = AgentsFeature.State()
    state.entries = [
      "new-blocked": Fixtures.agent("new-blocked", state: "blocked", since: "2026-09-25T10:09:00Z"),
      "old-blocked": Fixtures.agent("old-blocked", state: "blocked", since: "2026-09-25T10:01:00Z"),
      "old-working": Fixtures.agent("old-working", state: "working", since: "2026-09-25T10:01:00Z"),
      "new-working": Fixtures.agent("new-working", state: "working", since: "2026-09-25T10:09:00Z"),
    ]
    #expect(state.groups[0].entries.map(\.paneID) == ["old-blocked", "new-blocked"])
    #expect(state.groups[1].entries.map(\.paneID) == ["new-working", "old-working"])
  }

  @Test
  func snapshotWithoutAgentsTopicKeepsTheTable() async {
    let entry = Fixtures.agent("A", state: "idle")
    var initial = AgentsFeature.State()
    initial.entries = ["A": entry]
    initial.hasSnapshot = true
    let store = TestStore(initialState: initial) { AgentsFeature() }
    let frame = IPC.EventFrame(seq: 1, payload: .snapshot(IPC.EventsSnapshot(hierarchy: nil, agents: nil)))
    await store.send(.eventReceived(frame))
    await store.send(.reset) {
      $0 = AgentsFeature.State()
    }
  }

  @Test
  func worktreeSummaryReportsTheMostUrgentKindAndItsCount() {
    var state = AgentsFeature.State()
    #expect(state.summary(forWorktree: "W") == nil)

    state.entries = [
      "A": Fixtures.agent("A", state: "working"),
      "B": Fixtures.agent("B", state: "idle"),
    ]
    #expect(state.summary(forWorktree: "W").map { [$0.kind == .working, $0.count == 1] } == [true, true])

    state.entries["C"] = Fixtures.agent("C", state: "blocked")
    state.entries["D"] = Fixtures.agent("D", state: "blocked")
    let summary = state.summary(forWorktree: "W")
    #expect(summary?.kind == .needsInput)
    #expect(summary?.count == 2)
    // Agents elsewhere do not leak into this worktree.
    #expect(state.summary(forWorktree: "other") == nil)
    #expect(state.kind(ofPane: "C") == .needsInput)
    #expect(state.kind(ofPane: "missing") == nil)
  }

  @Test
  func worktreeLookupReturnsItsProject() {
    var browser = BrowserFeature.State()
    #expect(browser.worktree(id: "W") == nil)
    browser.hierarchy = Fixtures.hierarchy
    let found = browser.worktree(id: "W")
    #expect(found?.project.id == "P")
    #expect(found?.worktree.name == "main")
    #expect(browser.worktree(id: "nope") == nil)
    #expect(browser.worktree(id: nil) == nil)
  }
}
