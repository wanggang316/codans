import CodansIPC
import Foundation
import Testing

@testable import CodansKit

/// `PANE_NOT_LIVE` tells a script that a pane exists but its terminal does
/// not run, which `NOT_FOUND` (a wrong id) does not. Both the code and its
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
  func agentStateEntryCarriesTerminalStateAndDecodesRowsFromOlderApps() throws {
    let entry = IPC.AgentStateEntry(
      paneID: "p", handle: "p1", agent: "claude-code", agentName: "Claude Code", state: "idle",
      since: "2026-10-31T15:32:16Z", sessionID: nil, title: nil, projectID: "a", projectName: "codans",
      worktreeID: "b", worktreeName: "main", tabID: "c", tabTitle: nil, isFocused: false, isLive: true,
      isAttached: false)
    let data = try JSONEncoder().encode(entry)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["isLive"] as? Bool == true)
    #expect(object["isAttached"] as? Bool == false)
    #expect(try JSONDecoder().decode(IPC.AgentStateEntry.self, from: data) == entry)

    var older = object
    older.removeValue(forKey: "isLive")
    older.removeValue(forKey: "isAttached")
    let decoded = try JSONDecoder().decode(
      IPC.AgentStateEntry.self, from: JSONSerialization.data(withJSONObject: older))
    #expect(decoded.isLive == nil)
    #expect(decoded.isAttached == nil)
  }

  // MARK: - output schema

  private static func outputSchemaDefs() throws -> [String: Any] {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("codans-cli/Resources/schema/cli-output.schema.json")
    let schema = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    return try #require(schema["$defs"] as? [String: Any])
  }

  /// `agentStatusEntry` forbids extra properties, so every field the app
  /// encodes must be declared or `--json` output fails validation.
  @Test
  func agentStatusEntrySchemaDeclaresEveryEncodedField() throws {
    let entry = IPC.AgentStateEntry(
      paneID: "p", handle: "p1", agent: "claude-code", agentName: "Claude Code", state: "blocked",
      since: "2026-10-31T15:32:16Z", source: "programStatus", blockedKind: "permission", message: "m",
      sessionID: "s", title: "t", projectID: "a", projectName: "codans", worktreeID: "b",
      worktreeName: "main", tabID: "c", tabTitle: "dev", isFocused: true, isLive: true, isAttached: false)
    let encoded = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
    let def = try #require(try Self.outputSchemaDefs()["agentStatusEntry"] as? [String: Any])
    let declared = try #require(def["properties"] as? [String: Any])
    #expect(Set(encoded.keys).subtracting(declared.keys).isEmpty, "undeclared: \(Set(encoded.keys).subtracting(declared.keys))")
    let required = Set(def["required"] as? [String] ?? [])
    #expect(required.isDisjoint(with: ["isLive", "isAttached"]), "older apps omit them")
  }

  /// The envelope's `error.code` enum lists every code the CLI can emit.
  @Test
  func errorCodeSchemaListsEveryCLIErrorCode() throws {
    let error = try #require(try Self.outputSchemaDefs()["error"] as? [String: Any])
    let properties = try #require(error["properties"] as? [String: Any])
    let code = try #require(properties["code"] as? [String: Any])
    let listed = Set(try #require(code["enum"] as? [String]))
    #expect(listed == Set(CLIErrorCode.allCases.map(\.rawValue)))
  }
}
