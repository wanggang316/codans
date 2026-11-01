import CodansIPC
import Foundation
import Testing

@testable import CodansKit

/// `PANE_NOT_LIVE` tells a script that a pane exists but has no attached
/// terminal, which `NOT_FOUND` (a wrong id) does not. Both the code and its
/// exit code are part of the CLI contract.
struct PaneNotLiveErrorTests {
  @Test
  func paneNotLiveIsADomainCodeThatExitsConflict() {
    let error = IPCError.paneNotLive("E8B7E3D6-6123-4F8E-B0FA-8BFCF709B4FC")
    guard case .domain(let code, let message, let hint) = error else {
      Issue.record("expected a domain error, got \(error)")
      return
    }
    #expect(code == "PANE_NOT_LIVE")
    #expect(message.contains("E8B7E3D6-6123-4F8E-B0FA-8BFCF709B4FC"))
    #expect(hint?.contains("codans pane focus") == true)
    #expect(CLIErrorCode(domainCode: code) == .paneNotLive)
    #expect(CLIErrorCode.paneNotLive.domainExitCode == .conflict)
    #expect(CLIExitCode.from(error) == .conflict)
  }

  @Test
  func agentStateEntryCarriesIsLiveAndDecodesRowsFromOlderApps() throws {
    let entry = IPC.AgentStateEntry(
      paneID: "p", handle: "p1", agent: "claude-code", agentName: "Claude Code", state: "idle",
      since: "2026-10-31T15:32:16Z", sessionID: nil, title: nil, projectID: "a", projectName: "codans",
      worktreeID: "b", worktreeName: "main", tabID: "c", tabTitle: nil, isFocused: false, isLive: false,)
    let data = try JSONEncoder().encode(entry)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["isLive"] as? Bool == false)
    #expect(try JSONDecoder().decode(IPC.AgentStateEntry.self, from: data) == entry)

    var older = object
    older.removeValue(forKey: "isLive")
    let decoded = try JSONDecoder().decode(
      IPC.AgentStateEntry.self, from: JSONSerialization.data(withJSONObject: older),)
    #expect(decoded.isLive == nil)
  }
}
