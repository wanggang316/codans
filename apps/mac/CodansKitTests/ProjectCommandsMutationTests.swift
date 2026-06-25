import Foundation
import Testing
import CodansCore
import CodansIPC

@testable import CodansKit

/// Wire-contract tests for the `project commands` mutation leaves (add / edit /
/// rm). The ArgumentParser leaves live in the `codans-cli` executable target
/// (not linkable here), so these pin the `RPCClient` encode/decode path against
/// `project.addScript` / `project.updateScript` / `project.removeScript`, plus
/// the `IPCError` → exit-code mapping (conflict → 3) the rm built-in guard
/// relies on.
@MainActor
struct ProjectCommandsMutationTests {
  private struct ScriptParams: Codable { let projectID: ProjectID; let script: ScriptDefinition }
  private struct ScriptResult: Codable { let script: ScriptDefinition }
  private struct RemoveParams: Codable { let projectID: ProjectID; let scriptID: UUID }
  private struct RemoveResult: Codable { let id: String }

  @Test
  func addEncodesScriptAndDecodesNormalizedEcho() async throws {
    let projectID = ProjectID(raw: UUID())
    let sent = ScriptDefinition(kind: .test, name: "Unit", command: "make test")
    let transport = InMemoryTransport()
    transport.script = { frames in
      let hello = try JSONDecoder().decode(IPC.Request.self, from: frames[0])
      let real = try JSONDecoder().decode(IPC.Request.self, from: frames[1])
      #expect(real.method == .projectAddScript)
      let params = try real.params.decoded(as: ScriptParams.self)
      #expect(params.projectID == projectID)
      #expect(params.script.command == "make test")
      // Server echoes the persisted (normalized) entry under {script:...}.
      let echo: JSONValue = .object([
        "id": .string(sent.id.uuidString), "kind": .string("test"),
        "name": .string("Unit"), "command": .string("make test"),
      ])
      return [
        .success(id: hello.id, result: .object([:])),
        .success(id: real.id, result: .object(["script": echo])),
      ]
    }
    let client = RPCClient(transport: transport, versions: .init(clientVersion: "0.3.0"))
    let result: ScriptResult = try await client.call(
      .projectAddScript, params: ScriptParams(projectID: projectID, script: sent))
    #expect(result.script.id == sent.id)
    #expect(result.script.command == "make test")
  }

  @Test
  func updateEncodesScriptForProjectUpdateScript() async throws {
    let projectID = ProjectID(raw: UUID())
    let edited = ScriptDefinition(kind: .run, name: "New", command: "new")
    let transport = InMemoryTransport()
    transport.script = { frames in
      let hello = try JSONDecoder().decode(IPC.Request.self, from: frames[0])
      let real = try JSONDecoder().decode(IPC.Request.self, from: frames[1])
      #expect(real.method == .projectUpdateScript)
      let params = try real.params.decoded(as: ScriptParams.self)
      #expect(params.script.id == edited.id)
      let echo: JSONValue = .object([
        "id": .string(edited.id.uuidString), "kind": .string("run"),
        "name": .string("New"), "command": .string("new"),
      ])
      return [
        .success(id: hello.id, result: .object([:])),
        .success(id: real.id, result: .object(["script": echo])),
      ]
    }
    let client = RPCClient(transport: transport, versions: .init(clientVersion: "0.3.0"))
    let result: ScriptResult = try await client.call(
      .projectUpdateScript, params: ScriptParams(projectID: projectID, script: edited))
    #expect(result.script.name == "New")
  }

  @Test
  func removeEncodesScriptIDAndDecodesAck() async throws {
    let projectID = ProjectID(raw: UUID())
    let scriptID = UUID()
    let transport = InMemoryTransport()
    transport.script = { frames in
      let hello = try JSONDecoder().decode(IPC.Request.self, from: frames[0])
      let real = try JSONDecoder().decode(IPC.Request.self, from: frames[1])
      #expect(real.method == .projectRemoveScript)
      let params = try real.params.decoded(as: RemoveParams.self)
      #expect(params.scriptID == scriptID)
      return [
        .success(id: hello.id, result: .object([:])),
        .success(id: real.id, result: .object(["id": .string(scriptID.uuidString)])),
      ]
    }
    let client = RPCClient(transport: transport, versions: .init(clientVersion: "0.3.0"))
    let result: RemoveResult = try await client.call(
      .projectRemoveScript, params: RemoveParams(projectID: projectID, scriptID: scriptID))
    #expect(result.id == scriptID.uuidString)
  }

  @Test
  func removeBuiltinRunSurfacesConflictExit3() async throws {
    let transport = InMemoryTransport()
    transport.script = { frames in
      let hello = try JSONDecoder().decode(IPC.Request.self, from: frames[0])
      let real = try JSONDecoder().decode(IPC.Request.self, from: frames[1])
      return [
        .success(id: hello.id, result: .object([:])),
        .error(id: real.id, error: .conflict(reason: "the built-in Run command cannot be removed")),
      ]
    }
    let client = RPCClient(transport: transport, versions: .init(clientVersion: "0.3.0"))
    do {
      let _: RemoveResult = try await client.call(
        .projectRemoveScript,
        params: RemoveParams(
          projectID: ProjectID(raw: UUID()), scriptID: ScriptDefinition.builtinRunID))
      Issue.record("expected RPCError.ipc(.conflict)")
    } catch let error as RPCClient.RPCError {
      guard case .ipc(let ipc) = error, case .conflict = ipc else {
        Issue.record("got \(error)")
        return
      }
      #expect(CLIExitCode.from(ipc) == .conflict)
      #expect(CLIExitCode.conflict.rawValue == 3)
    }
  }
}
