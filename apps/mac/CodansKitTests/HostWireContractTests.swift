import CodansCore
import CodansIPC
import Foundation
import Testing

@testable import CodansKit

/// Wire contract for the Host of each Project (ADR 0003), as `codans tree`
/// and `codans project show` read it. The command leaves live in the
/// `codans-cli` executable target (not linkable here), so these drive the
/// shared wire types and the `RPCClient` decode path.
@MainActor
struct HostWireContractTests {
  private static let box = HostRecord(address: "box.example.com", username: "me", name: "Build box")

  private static func catalogProjects() -> [Project] {
    [
      Project(name: "local", rootPath: "/src/local"),
      Project(name: "srv", rootPath: "/srv/app", hostID: box.id, remoteHost: box.endpoint),
    ]
  }

  private func listProjects(responding payload: JSONValue) async throws -> IPC.ProjectListPayload {
    let transport = InMemoryTransport()
    transport.script = { frames in
      let hello = try JSONDecoder().decode(IPC.Request.self, from: frames[0])
      let real = try JSONDecoder().decode(IPC.Request.self, from: frames[1])
      #expect(real.method == .hierarchyListProjects)
      return [.success(id: hello.id, result: .object([:])), .success(id: real.id, result: payload)]
    }
    let client = RPCClient(transport: transport, versions: .init(clientVersion: "0.7.0"))
    struct Empty: Codable {}
    return try await client.call(.hierarchyListProjects, params: Empty())
  }

  @Test
  func listResolvesEachProjectsHostFromTheHostList() async throws {
    let sent = IPC.ProjectListPayload(projects: Self.catalogProjects(), hosts: [Self.box])
    let payload = try await listProjects(responding: try JSONValue.encoded(sent))

    // On the wire a Server project carries only its Host id.
    #expect(payload.projects[1].remoteHost == nil)
    let projects = payload.resolvedProjects
    #expect(projects[1].remoteHost == Self.box.endpoint)
    #expect(projects[1].kind == .server)

    let hosts = try #require(payload.hosts)
    #expect(IPC.HostRef(project: projects[0], hosts: hosts) == .thisMac)
    #expect(
      IPC.HostRef(project: projects[1], hosts: hosts)
        == IPC.HostRef(id: Self.box.id.description, name: "Build box"))
  }

  @Test
  func listFromAnAppWithoutHostRecordsStillReadsTheHost() async throws {
    // An older app sends host fields inline and no `hosts` key.
    let legacy: JSONValue = try JSONValue.encoded([
      "projects": [Project(name: "srv", rootPath: "/srv/app", remoteHost: RemoteHost(alias: "box", port: 2200))]
    ])
    let payload = try await listProjects(responding: legacy)

    #expect(payload.hosts == nil)
    let project = try #require(payload.resolvedProjects.first)
    #expect(project.kind == .server)
    #expect(IPC.HostRef(project: project, hosts: []) == IPC.HostRef(id: nil, name: "box:2200"))
  }

  @Test
  func hostRefAlwaysWritesItsID() throws {
    let object = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(IPC.HostRef.thisMac)) as? [String: Any])
    #expect(object["name"] as? String == "This Mac")
    #expect(object.keys.contains("id"))
    #expect(object["id"] is NSNull)
  }

  @Test
  func projectDescriptionHostIsOptionalOnTheWire() throws {
    let described = IPC.ProjectDescription(
      id: UUID().uuidString, name: "srv", canonicalName: "srv", rootPath: "/srv", gitRoot: nil,
      remoteHost: "box.example.com", host: IPC.HostRef(id: Self.box.id.description, name: "Build box"),
      isSelected: false, selectedWorktreeID: nil, worktreeCount: 1, archivedWorktreeCount: 0, tagIDs: [])
    let decoded = try JSONDecoder().decode(IPC.ProjectDescription.self, from: JSONEncoder().encode(described))
    #expect(decoded == described)

    // An older app sends no `host`.
    var object = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(described)) as? [String: Any])
    object.removeValue(forKey: "host")
    let older = try JSONDecoder().decode(
      IPC.ProjectDescription.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(older.host == nil)
    #expect(older.remoteHost == "box.example.com")
  }

  @Test
  func outputSchemaDescribesTheHostOfEachProject() throws {
    let schemaURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("codans-cli/Resources/schema/cli-output.schema.json")
    let schema = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: schemaURL)) as? [String: Any])
    let defs = try #require(schema["$defs"] as? [String: Any])
    let hostRef = try #require(defs["hostRef"] as? [String: Any])
    #expect(hostRef["required"] as? [String] == ["id", "name"])
    let treeProject = try #require(defs["treeProject"] as? [String: Any])
    #expect((treeProject["required"] as? [String])?.contains("host") == true)
    let projectShow = try #require(defs["projectShow"] as? [String: Any])
    #expect((projectShow["properties"] as? [String: Any])?["host"] != nil)
  }
}
