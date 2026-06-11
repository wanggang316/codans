import Foundation
import Testing

@testable import CodansCore
@testable import CodansIPC

struct WireTypeCodableTests {
  @Test
  func broadcastScopeRoundTripsEveryKind() throws {
    let cases: [IPC.BroadcastScope] = [
      .tab(TabID()),
      .worktree(WorktreeID()),
      .label("agent"),
    ]
    for scope in cases {
      let data = try JSONEncoder().encode(scope)
      let decoded = try JSONDecoder().decode(IPC.BroadcastScope.self, from: data)
      #expect(decoded == scope)
    }
  }

  @Test
  func broadcastScopeWireShape() throws {
    let scope = IPC.BroadcastScope.label("agent")
    let data = try JSONEncoder().encode(scope)
    let json = String(bytes: data, encoding: .utf8) ?? ""
    #expect(json.contains("\"kind\":\"label\""))
    #expect(json.contains("\"target\":\"agent\""))
  }

  @Test
  func paneOpenRequestRoundTrip() throws {
    let req = IPC.PaneOpenRequest(
      tabID: TabID(),
      workingDirectory: "/tmp",
      initialCommand: "echo hi",
      labels: ["agent"],
      activate: true
    )
    let data = try JSONEncoder().encode(req)
    let decoded = try JSONDecoder().decode(IPC.PaneOpenRequest.self, from: data)
    #expect(decoded == req)
  }

  @Test
  func aliasResolveRoundTrip() throws {
    let req = IPC.AliasResolveRequest(kind: .pane, value: "@agent", contextPaneID: PaneID())
    let reqData = try JSONEncoder().encode(req)
    let reqDecoded = try JSONDecoder().decode(IPC.AliasResolveRequest.self, from: reqData)
    #expect(reqDecoded == req)

    let result = IPC.AliasResolveResult(
      kind: .pane,
      id: UUID(),
      disambiguations: [UUID(), UUID()]
    )
    let resData = try JSONEncoder().encode(result)
    let resDecoded = try JSONDecoder().decode(IPC.AliasResolveResult.self, from: resData)
    #expect(resDecoded == result)
  }

  @Test
  func handshakeRoundTrip() throws {
    let req = HelloRequest(clientVersion: "0.2.0", clientBinary: "codans")
    let reqData = try JSONEncoder().encode(req)
    let reqDecoded = try JSONDecoder().decode(HelloRequest.self, from: reqData)
    #expect(reqDecoded == req)

    let res = HelloResponse(
      serverVersion: "0.2.0",
      appBundleVersion: "0.2.0+142",
      protocolMajor: 1,
      protocolMinor: 3,
      deprecatedMethods: ["hierarchy.oldName"]
    )
    let resData = try JSONEncoder().encode(res)
    let resDecoded = try JSONDecoder().decode(HelloResponse.self, from: resData)
    #expect(resDecoded == res)
  }
}
