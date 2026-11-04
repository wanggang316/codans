import CodansCore
import CodansIPC
import Foundation
import Testing

@testable import CodansKit

/// `--host` (ADR 0006): its parse at the CLI edge, and how it reaches
/// `hierarchy.resolveAlias`.
@MainActor
struct HostArgumentTests {
  @Test
  func acceptsZeroAndAHostID() throws {
    let id = UUID()
    #expect(try HostArgument.parse(nil) == nil)
    #expect(try HostArgument.parse("0") == .thisMac)
    #expect(try HostArgument.parse(id.uuidString) == .host(HostID(raw: id)))
    #expect(try HostArgument.parse(id.uuidString.lowercased()) == .host(HostID(raw: id)))
  }

  @Test
  func rejectsEmptyAndOtherValues() {
    for value in ["", "mini", "00", "this-mac", " 0"] {
      #expect(throws: CLIArgumentError.self) { try HostArgument.parse(value) }
    }
  }

  @Test
  func selectorStringIsWhatOutputsCarry() {
    let id = HostID()
    #expect(IPC.HostSelector.thisMac.description == "0")
    #expect(IPC.HostSelector.host(id).description == id.raw.uuidString)
    #expect(IPC.HostSelector(project: Project(name: "a", rootPath: "/a")) == .thisMac)
    #expect(IPC.HostSelector(project: Project(name: "a", rootPath: "/a", hostID: id)) == .host(id))
  }

  @Test
  func projectUUIDWithHostGoesToTheServer() async throws {
    let projectID = UUID()
    let hostID = HostID()
    let (client, sent) = Self.client(answering: projectID)

    let resolved = try await AliasResolver.resolve(
      projectID.uuidString, kind: .project, host: .host(hostID), env: [:], client: client)

    #expect(resolved == projectID)
    let request = try #require(sent.value)
    #expect(request.value == projectID.uuidString)
    #expect(request.hostID == hostID.raw.uuidString)
  }

  @Test
  func currentProjectWithHostSkipsTheEnvironment() async throws {
    let projectID = UUID()
    let (client, sent) = Self.client(answering: projectID)

    let resolved = try await AliasResolver.resolve(
      "current", kind: .project, host: .thisMac, env: ["CODANS_PROJECT_ID": UUID().uuidString], client: client)

    #expect(resolved == projectID)
    #expect(sent.value?.hostID == "0")
  }

  @Test
  func hostIsNotSentForOtherKinds() async throws {
    let tabID = UUID()
    let resolved = try await AliasResolver.resolve(
      tabID.uuidString, kind: .tab, host: .thisMac, env: [:], client: Self.unreachableClient())
    #expect(resolved == tabID)
  }

  // MARK: - Helpers

  final class Sent: @unchecked Sendable {
    var value: IPC.AliasResolveRequest?
  }

  private static func client(answering id: UUID) -> (RPCClient, Sent) {
    let sent = Sent()
    let transport = InMemoryTransport()
    transport.script = { frames in
      let hello = try JSONDecoder().decode(IPC.Request.self, from: frames[0])
      let real = try JSONDecoder().decode(IPC.Request.self, from: frames[1])
      sent.value = try real.params.decoded(as: IPC.AliasResolveRequest.self)
      return [
        .success(id: hello.id, result: .object([:])),
        .success(id: real.id, result: try JSONValue.encoded(IPC.AliasResolveResult(kind: .project, id: id))),
      ]
    }
    return (RPCClient(transport: transport, versions: .init(clientVersion: "0.9.0")), sent)
  }

  struct ShouldNotDial: Error {}

  private static func unreachableClient() throws -> RPCClient { throw ShouldNotDial() }
}
