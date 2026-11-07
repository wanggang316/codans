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

    let projects = payload.resolvedProjects
    #expect(projects[1].remoteHost == Self.box.endpoint)
    #expect(projects[1].kind == .remote)

    let hosts = try #require(payload.hosts)
    #expect(IPC.HostRef(project: projects[0], hosts: hosts) == .thisMac)
    #expect(
      IPC.HostRef(project: projects[1], hosts: hosts)
        == IPC.HostRef(id: Self.box.id.description, name: "Build box"))
  }

  /// The `Project` shape of a CLI that predates Host records: it tells a
  /// Remote Project by `remoteHost` alone.
  private struct OldCLIProject: Decodable {
    let id: ProjectID
    let remoteHost: RemoteHost?
  }

  private struct OldCLIPayload: Decodable {
    let projects: [OldCLIProject]
  }

  @Test
  func listStillTellsAnOlderCLIWhichProjectsAreRemoteProjects() throws {
    let sent = IPC.ProjectListPayload(projects: Self.catalogProjects(), hosts: [Self.box])
    let data = try JSONEncoder().encode(sent)

    let old = try JSONDecoder().decode(OldCLIPayload.self, from: data)
    #expect(old.projects.map(\.remoteHost) == [nil, Self.box.endpoint])

    // `catalog.json` itself keeps only the Host id.
    let stored = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.catalogProjects()[1])) as? [String: Any])
    #expect(stored["remoteHost"] == nil)
    #expect(stored["hostID"] != nil)
  }

  @Test
  func editedHostWinsOverTheWireCopyOfTheFields() throws {
    // The list is resolved from `hosts`, so the record is the source of truth.
    var moved = Self.box
    moved.port = 2200
    let sent = IPC.ProjectListPayload(projects: Self.catalogProjects(), hosts: [moved])
    let payload = try JSONDecoder().decode(IPC.ProjectListPayload.self, from: JSONEncoder().encode(sent))
    #expect(payload.resolvedProjects[1].remoteHost == moved.endpoint)
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
    #expect(project.kind == .remote)
  }

  @Test
  func thisMacHostRefIDIsZero() throws {
    let object = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(IPC.HostRef.thisMac)) as? [String: Any])
    #expect(object["name"] as? String == "This Mac")
    #expect(object["id"] as? String == "0")
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
    let hostID = try #require(defs["hostID"] as? [String: Any])
    let pattern = try Regex(try #require(hostID["pattern"] as? String))
    #expect(try pattern.wholeMatch(in: "0") != nil)
    #expect(try pattern.wholeMatch(in: Self.box.id.description) != nil)
    #expect(try pattern.wholeMatch(in: "") == nil)
    for def in ["projectAdd", "projectListItem"] {
      let object = try #require(defs[def] as? [String: Any])
      #expect((object["required"] as? [String])?.contains("host") == true, "\(def) requires host")
    }
    let treeProject = try #require(defs["treeProject"] as? [String: Any])
    #expect((treeProject["required"] as? [String])?.contains("host") == true)
    let projectShow = try #require(defs["projectShow"] as? [String: Any])
    #expect((projectShow["properties"] as? [String: Any])?["host"] != nil)
  }
}
