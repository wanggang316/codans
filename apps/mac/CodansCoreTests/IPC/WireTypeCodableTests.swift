import Foundation
import Testing

@testable import CodansCore
@testable import CodansIPC

struct WireTypeCodableTests {
  @Test
  func broadcastScopeRoundTripsEveryKind() throws {
    let cases: [IPC.BroadcastScope] = [
      .pane(PaneID()),
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
    let pane = String(bytes: try JSONEncoder().encode(IPC.BroadcastScope.pane(PaneID())), encoding: .utf8) ?? ""
    #expect(pane.contains("\"kind\":\"pane\""))
  }

  @Test
  func tabReadRequestRoundTrip() throws {
    let req = IPC.TabReadRequest(contentID: ContentID(), range: .visible, tail: 5, raw: true)
    let data = try JSONEncoder().encode(req)
    let decoded = try JSONDecoder().decode(IPC.TabReadRequest.self, from: data)
    #expect(decoded == req)
    #expect(String(bytes: data, encoding: .utf8)?.contains("\"contentID\"") == true)
  }

  @Test
  func aliasResolveRoundTrip() throws {
    let req = IPC.AliasResolveRequest(kind: .pane, value: "@agent", contextContentID: ContentID())
    let reqData = try JSONEncoder().encode(req)
    let reqDecoded = try JSONDecoder().decode(IPC.AliasResolveRequest.self, from: reqData)
    #expect(reqDecoded == req)

    let result = IPC.AliasResolveResult(
      kind: .pane,
      id: UUID(),
      matched: .tab,
      disambiguations: [UUID(), UUID()]
    )
    let resData = try JSONEncoder().encode(result)
    let resDecoded = try JSONDecoder().decode(IPC.AliasResolveResult.self, from: resData)
    #expect(resDecoded == result)
  }

  @Test
  func handshakeRoundTrip() throws {
    let req = HelloRequest(clientVersion: "0.2.0", clientBinary: "codans")
    #expect(req.protocolVersion == IPC.protocolVersion)
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

  /// A client that predates the protocol field still decodes, so the
  /// server can answer it with a version mismatch.
  @Test
  func helloWithoutProtocolVersionDecodes() throws {
    let data = Data(#"{"clientVersion":"0.7.0","clientBinary":"codans"}"#.utf8)
    let decoded = try JSONDecoder().decode(HelloRequest.self, from: data)
    #expect(decoded.protocolVersion == nil)
  }
}
