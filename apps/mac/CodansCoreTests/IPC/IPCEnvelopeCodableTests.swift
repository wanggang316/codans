import Foundation
import Testing

@testable import CodansIPC

struct IPCEnvelopeCodableTests {
  @Test
  func unaryRequestRoundTrip() throws {
    let req = IPC.Request(
      id: "abc123",
      method: .systemPing,
      params: .object([:])
    )
    let data = try JSONEncoder().encode(req)
    let decoded = try JSONDecoder().decode(IPC.Request.self, from: data)
    #expect(decoded == req)
  }

  @Test
  func responseWithResultRoundTrip() throws {
    let res = IPC.Response(
      id: "abc123",
      result: .object(["pong": .bool(true)])
    )
    let data = try JSONEncoder().encode(res)
    let decoded = try JSONDecoder().decode(IPC.Response.self, from: data)
    #expect(decoded == res)
  }

  @Test
  func responseWithErrorRoundTrip() throws {
    let res = IPC.Response(
      id: "abc123",
      error: .notFound(kind: "pane", id: "xxx")
    )
    let data = try JSONEncoder().encode(res)
    let decoded = try JSONDecoder().decode(IPC.Response.self, from: data)
    #expect(decoded == res)
  }

  @Test
  func streamingTerminalFrameRoundTrip() throws {
    let res = IPC.Response(id: "stream-1", stream: false, result: nil, error: nil)
    let data = try JSONEncoder().encode(res)
    let decoded = try JSONDecoder().decode(IPC.Response.self, from: data)
    #expect(decoded == res)
  }

  @Test
  func methodStringIsStable() throws {
    // Catch accidental renames that would break the wire.
    #expect(IPC.Method.systemHello.rawValue == "system.hello")
    #expect(IPC.Method.terminalBroadcastInput.rawValue == "terminal.broadcastInput")
    #expect(IPC.Method.hierarchyResolveAlias.rawValue == "hierarchy.resolveAlias")
  }

  @Test
  func methodEnumOmitsSkillNamespace() throws {
    // DEC-5: skill.* is deferred to exec-plan 0004.
    for method in IPC.Method.allCases {
      #expect(!method.rawValue.hasPrefix("skill."), "Unexpected skill method: \(method.rawValue)")
    }
  }
}
