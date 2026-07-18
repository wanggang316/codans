import Foundation
import Testing
import CodansCore
import CodansIPC

@testable import CodansKit

/// Contract tests for `codans project commands list`. The ArgumentParser leaf
/// lives in the `codans-cli` executable target (not linkable here), so these
/// exercise the wire contract the command is built on: the `RPCClient` encode/
/// decode path against `project.listScripts`, and the `IPCError` → exit-code
/// mapping the command's error surface relies on (2/4/10/11).
@MainActor
struct ProjectCommandsListTests {
  /// Mirror of the CLI's inline `Params` for `project.listScripts`. Kept in
  /// sync structurally with `ProjectCommandsList.run`.
  private struct ListScriptsParams: Codable { let projectID: ProjectID }
  /// Mirror of the CLI's `ProjectCommandsListPayload`.
  private struct ListScriptsResult: Codable { let scripts: [ScriptDefinition] }

  // MARK: - Encode the right params

  @Test
  func listEncodesProjectIDParamsForProjectListScripts() async throws {
    let projectID = ProjectID(raw: UUID())
    let transport = InMemoryTransport()
    transport.script = { frames in
      #expect(frames.count == 2)
      let hello = try JSONDecoder().decode(IPC.Request.self, from: frames[0])
      #expect(hello.method == .systemHello)
      let real = try JSONDecoder().decode(IPC.Request.self, from: frames[1])
      // The leaf calls `.projectListScripts` with `{ projectID }`.
      #expect(real.method == .projectListScripts)
      let params = try real.params.decoded(as: ListScriptsParams.self)
      #expect(params.projectID == projectID)
      return [
        .success(id: hello.id, result: .object([:])),
        .success(id: real.id, result: .object(["scripts": .array([])])),
      ]
    }

    let client = RPCClient(transport: transport, versions: .init(clientVersion: "0.3.0"))
    let result: ListScriptsResult = try await client.call(
      .projectListScripts,
      params: ListScriptsParams(projectID: projectID)
    )
    #expect(result.scripts.isEmpty)
  }

  // MARK: - Decode the {scripts:[...]} result, order preserved

  @Test
  func listDecodesScriptsResultPreservingOrder() async throws {
    let runID = UUID()
    let lintID = UUID()
    let transport = InMemoryTransport()
    transport.script = { frames in
      let hello = try JSONDecoder().decode(IPC.Request.self, from: frames[0])
      let real = try JSONDecoder().decode(IPC.Request.self, from: frames[1])
      // Server payload uses ScriptDefinition's native omit-when-default shape:
      // an unnamed Run (no `name`/`command`) followed by a named Lint.
      let scripts: JSONValue = .array([
        .object(["id": .string(runID.uuidString), "kind": .string("run")]),
        .object([
          "id": .string(lintID.uuidString),
          "kind": .string("lint"),
          "name": .string("CI Lint"),
          "command": .string("swiftlint"),
        ]),
      ])
      return [
        .success(id: hello.id, result: .object([:])),
        .success(id: real.id, result: .object(["scripts": scripts])),
      ]
    }

    let client = RPCClient(transport: transport, versions: .init(clientVersion: "0.3.0"))
    let result: ListScriptsResult = try await client.call(
      .projectListScripts,
      params: ListScriptsParams(projectID: ProjectID(raw: UUID()))
    )
    #expect(result.scripts.map(\.id) == [runID, lintID])
    #expect(result.scripts[0].kind == .run)
    #expect(result.scripts[0].name.isEmpty)  // unnamed → empty (DTO renders null)
    #expect(result.scripts[1].name == "CI Lint")
    #expect(result.scripts[1].command == "swiftlint")
  }

  // MARK: - Unknown project → notFound surfaces (CLI maps to exit 2)

  @Test
  func unknownProjectSurfacesAsNotFoundIPCError() async throws {
    let transport = InMemoryTransport()
    transport.script = { frames in
      let hello = try JSONDecoder().decode(IPC.Request.self, from: frames[0])
      let real = try JSONDecoder().decode(IPC.Request.self, from: frames[1])
      return [
        .success(id: hello.id, result: .object([:])),
        .error(id: real.id, error: .notFound(kind: "project", id: "nope")),
      ]
    }

    let client = RPCClient(transport: transport, versions: .init(clientVersion: "0.3.0"))
    do {
      let _: ListScriptsResult = try await client.call(
        .projectListScripts,
        params: ListScriptsParams(projectID: ProjectID(raw: UUID()))
      )
      Issue.record("expected RPCError.ipc(.notFound)")
    } catch let error as RPCClient.RPCError {
      guard case .ipc(let ipc) = error, case .notFound = ipc else {
        Issue.record("got \(error)")
        return
      }
      // The exit-code mapping the command relies on.
      #expect(CLIExitCode.from(ipc) == .notFound)
    }
  }

  // MARK: - Timeout surfaces (CLI maps to exit 11)

  @Test
  func noResponseTimesOut() async throws {
    let transport = InMemoryTransport()
    transport.script = { _ in [] }  // server stays silent

    let client = RPCClient(transport: transport, versions: .init(clientVersion: "0.3.0"))
    do {
      let _: ListScriptsResult = try await client.call(
        .projectListScripts,
        params: ListScriptsParams(projectID: ProjectID(raw: UUID())),
        timeout: .milliseconds(150)
      )
      Issue.record("expected RPCError.timeout")
    } catch let error as RPCClient.RPCError {
      guard case .timeout = error else {
        Issue.record("got \(error)")
        return
      }
    }
  }

  // MARK: - Error → exit-code vocabulary the command's selector path uses

  @Test
  func selectorErrorCodesMapToExpectedExits() {
    // Unknown id → 2, bare-name (server `unsupported`) → 4. noSocket (10) and
    // requestTimeout (11) are not IPCError-derived — they're raised by the
    // transport / timeout paths — so they are pinned by their raw values.
    #expect(CLIExitCode.from(.notFound(kind: "project", id: "x")) == .notFound)
    #expect(CLIExitCode.notFound.rawValue == 2)
    #expect(CLIExitCode.from(.unsupported(reason: "bare name")) == .unsupported)
    #expect(CLIExitCode.unsupported.rawValue == 4)
    #expect(CLIExitCode.noSocket.rawValue == 10)
    #expect(CLIExitCode.requestTimeout.rawValue == 11)
  }
}
