import Foundation
import Testing

@testable import CodansIPC

struct EventsWireTypesTests {
  private static let agent = IPC.AgentStateEntry(
    paneID: "p-1",
    handle: "p1",
    agent: "claude",
    agentName: "Claude Code",
    state: "blocked",
    since: "2026-09-25T00:00:00Z",
    sessionID: nil,
    title: "fix tests",
    projectID: "proj-1",
    projectName: "codans",
    worktreeID: "wt-1",
    worktreeName: "main",
    tabID: "tab-1",
    tabTitle: nil,
    isFocused: false
  )

  private static let hierarchy = IPC.HierarchySummary(
    projects: [
      IPC.ProjectSummary(
        id: "proj-1",
        name: "codans",
        isRemote: false,
        selectedWorktreeID: "wt-1",
        worktrees: [
          IPC.WorktreeSummary(
            id: "wt-1",
            name: "main",
            branch: "main",
            isPinned: true,
            selectedTabID: "tab-1",
            tabs: [
              IPC.TabSummary(
                id: "tab-1",
                handle: "t1",
                title: "agents",
                focusedPaneID: "p-1",
                panes: [
                  IPC.PaneSummary(id: "p-1", handle: "p1", title: "fix tests", agent: "claude", labels: ["agent"])
                ]
              )
            ]
          )
        ]
      )
    ],
    selectedProjectID: "proj-1"
  )

  private func roundTrip(_ frame: IPC.EventFrame) throws -> IPC.EventFrame {
    try JSONDecoder().decode(IPC.EventFrame.self, from: JSONEncoder().encode(frame))
  }

  private func object(_ frame: IPC.EventFrame) throws -> [String: Any] {
    try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(frame)) as? [String: Any])
  }

  @Test
  func everyKnownKindRoundTrips() throws {
    let frames: [IPC.EventFrame] = [
      IPC.EventFrame(
        seq: 0, payload: .snapshot(IPC.EventsSnapshot(hierarchy: Self.hierarchy, agents: [Self.agent]))),
      IPC.EventFrame(seq: 1, payload: .snapshot(IPC.EventsSnapshot(hierarchy: nil, agents: [Self.agent]))),
      IPC.EventFrame(seq: 2, payload: .hierarchyChanged(Self.hierarchy)),
      IPC.EventFrame(
        seq: 3,
        payload: .agentStatesChanged(IPC.AgentStatesDelta(upserted: [Self.agent], removedPaneIDs: ["p-9"]))),
      IPC.EventFrame(seq: 4, payload: .heartbeat),
    ]
    for frame in frames {
      #expect(try roundTrip(frame) == frame)
    }
  }

  @Test
  func frameIsFlatAndDiscriminatedByKind() throws {
    let json = try object(
      IPC.EventFrame(
        seq: 7,
        payload: .agentStatesChanged(IPC.AgentStatesDelta(upserted: [], removedPaneIDs: ["p-2"]))))
    #expect(json["seq"] as? Int == 7)
    #expect(json["kind"] as? String == "agentStatesChanged")
    #expect(json["removedPaneIDs"] as? [String] == ["p-2"])
    #expect(json["payload"] == nil)
  }

  @Test
  func snapshotOmitsUnsubscribedSections() throws {
    let json = try object(
      IPC.EventFrame(seq: 0, payload: .snapshot(IPC.EventsSnapshot(hierarchy: nil, agents: []))))
    #expect(json["kind"] as? String == "snapshot")
    #expect(json["hierarchy"] == nil)
    #expect(json["agents"] != nil)
  }

  @Test
  func unknownKindDecodesInsteadOfFailing() throws {
    let data = Data(#"{"seq": 9, "kind": "paneOutput", "text": "hi"}"#.utf8)
    let frame = try JSONDecoder().decode(IPC.EventFrame.self, from: data)
    #expect(frame == IPC.EventFrame(seq: 9, payload: .unknown(kind: "paneOutput")))
  }

  @Test
  func knownKindWithMissingPayloadFails() {
    let data = Data(#"{"seq": 1, "kind": "hierarchyChanged"}"#.utf8)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(IPC.EventFrame.self, from: data)
    }
  }

  @Test
  func subscribeRequestResolvesTopics() throws {
    #expect(IPC.EventsSubscribeRequest().resolvedTopics == [.hierarchy, .agents])
    #expect(IPC.EventsSubscribeRequest(topics: [.agents]).resolvedTopics == [.agents])
    let decoded = try JSONDecoder().decode(IPC.EventsSubscribeRequest.self, from: Data("{}".utf8))
    #expect(decoded.topics == nil)
  }

  @Test
  func subscribeRequestRejectsUnknownTopic() {
    let data = Data(#"{"topics": ["agents", "weather"]}"#.utf8)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(IPC.EventsSubscribeRequest.self, from: data)
    }
  }

  // MARK: - Phase 2 summary fields

  private static let splitLayout = IPC.SplitLayoutNode.split(
    direction: .horizontal, ratio: 0.4,
    left: .leaf(paneID: "p-1"),
    right: .split(direction: .vertical, ratio: 0.5, left: .leaf(paneID: "p-2"), right: .leaf(paneID: "p-3")))

  @Test
  func phaseTwoFieldsRoundTrip() throws {
    let tab = IPC.TabSummary(
      id: "tab-1", handle: "t1", title: "dev", focusedPaneID: "p-2",
      panes: [
        IPC.PaneSummary(
          id: "p-1", handle: "p1", title: nil, agent: nil, labels: [], cwd: "/repo", isLive: true),
        IPC.PaneSummary(
          id: "p-2", handle: "p2", title: nil, agent: nil, labels: [], cwd: nil, isLive: false),
      ],
      layout: Self.splitLayout, zoomedPaneID: "p-2")
    let summary = IPC.HierarchySummary(
      projects: [
        IPC.ProjectSummary(
          id: "proj-1", name: "codans", isRemote: false, selectedWorktreeID: "wt-1",
          worktrees: [
            IPC.WorktreeSummary(
              id: "wt-1", name: "main", branch: "main", isPinned: false, selectedTabID: "tab-1", tabs: [tab])
          ])
      ],
      selectedProjectID: "proj-1", activePaneID: "p-2")
    let frame = IPC.EventFrame(seq: 0, payload: .hierarchyChanged(summary))
    #expect(try roundTrip(frame) == frame)
  }

  @Test
  func layoutUsesLeafAndSplitObjects() throws {
    let data = try JSONEncoder().encode(Self.splitLayout)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let split = try #require(json["split"] as? [String: Any])
    #expect(split["direction"] as? String == "horizontal")
    #expect(split["ratio"] as? Double == 0.4)
    #expect((split["left"] as? [String: Any])?["leaf"] as? String == "p-1")
    #expect(Self.splitLayout.paneIDs == ["p-1", "p-2", "p-3"])
  }

  @Test
  func summaryWithoutPhaseTwoFieldsStillDecodes() throws {
    let data = Data(
      #"""
      {"projects": [{"id": "proj-1", "name": "codans", "isRemote": false, "worktrees": [
        {"id": "wt-1", "name": "main", "isPinned": false, "tabs": [
          {"id": "tab-1", "panes": [{"id": "p-1", "labels": []}]}
        ]}
      ]}]}
      """#.utf8)
    let summary = try JSONDecoder().decode(IPC.HierarchySummary.self, from: data)
    #expect(summary.activePaneID == nil)
    let tab = try #require(summary.projects.first?.worktrees.first?.tabs.first)
    #expect(tab.layout == nil)
    #expect(tab.zoomedPaneID == nil)
    #expect(tab.panes.first?.cwd == nil)
    #expect(tab.panes.first?.isLive == nil)
  }

  @Test
  func unknownLayoutShapeDropsOnlyTheLayout() throws {
    let data = Data(
      #"""
      {"id": "tab-1", "focusedPaneID": "p-1", "panes": [{"id": "p-1", "labels": []}],
       "layout": {"grid": {"rows": 2}}, "zoomedPaneID": "p-1"}
      """#.utf8)
    let tab = try JSONDecoder().decode(IPC.TabSummary.self, from: data)
    #expect(tab.layout == nil)
    #expect(tab.zoomedPaneID == "p-1")
    #expect(tab.panes.count == 1)

    let newerDirection = Data(
      #"""
      {"id": "tab-1", "panes": [], "layout": {"split": {"direction": "diagonal", "ratio": 0.5,
        "left": {"leaf": "a"}, "right": {"leaf": "b"}}}}
      """#.utf8)
    #expect(try JSONDecoder().decode(IPC.TabSummary.self, from: newerDirection).layout == nil)
  }

  @Test
  func nilPhaseTwoFieldsAreOmittedOnTheWire() throws {
    let pane = IPC.PaneSummary(id: "p-1", handle: nil, title: nil, agent: nil, labels: [])
    let json = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(pane)) as? [String: Any])
    #expect(json["cwd"] == nil)
    #expect(json["isLive"] == nil)
  }
}
