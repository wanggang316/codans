import CodansIPC
import CodansRemote
import Foundation

@testable import CodansMobile

enum Fixtures {
  static let deviceID = UUID(uuidString: "7C1E0000-0000-0000-0000-000000000001")!
  static let pairedAt = Date(timeIntervalSince1970: 1_000_000)

  static let payload = PairingPayload(
    serviceName: "Studio (codans-dev)",
    deviceID: deviceID,
    pskIdentity: deviceID.uuidString,
    psk: Data(repeating: 7, count: PairingPayload.keyLength),
    channel: "codans-dev"
  )

  static var pairingCode: String {
    // swiftlint:disable:next force_try
    try! payload.encodedString()
  }

  static let gateway = PairedGateway(payload: payload, pairedAt: pairedAt)

  static let info = RemoteSessionInfo(serverVersion: "0.7.4", permission: .interactive)

  static func agent(
    _ paneID: String,
    state: String,
    since: String = "2026-09-25T10:00:00Z",
    title: String? = nil
  ) -> IPC.AgentStateEntry {
    IPC.AgentStateEntry(
      paneID: paneID,
      handle: nil,
      agent: "claude",
      agentName: "Claude Code",
      state: state,
      since: since,
      sessionID: nil,
      title: title,
      projectID: "P",
      projectName: "codans",
      worktreeID: "W",
      worktreeName: "main",
      tabID: "T",
      tabTitle: nil,
      isFocused: false
    )
  }

  static func snapshot(seq: Int = 1, agents: [IPC.AgentStateEntry]) -> IPC.EventFrame {
    IPC.EventFrame(
      seq: seq,
      payload: .snapshot(IPC.EventsSnapshot(hierarchy: hierarchy, agents: agents))
    )
  }

  static let hierarchy = IPC.HierarchySummary(
    projects: [
      IPC.ProjectSummary(
        id: "P",
        name: "codans",
        isRemote: false,
        selectedWorktreeID: "W",
        worktrees: [
          IPC.WorktreeSummary(
            id: "W",
            name: "main",
            branch: "main",
            isPinned: false,
            selectedTabID: "T",
            tabs: [
              IPC.TabSummary(
                id: "T",
                handle: "t1",
                title: "shell",
                focusedPaneID: "A",
                panes: [
                  IPC.PaneSummary(id: "A", handle: "p1", title: "claude", agent: "claude", labels: [])
                ]
              )
            ]
          )
        ]
      )
    ],
    selectedProjectID: "P"
  )
}
