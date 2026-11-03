import CodansCore
import CodansIPC
import Foundation
import Testing

@testable import CodansKit

/// The Host each Project shows in `codans tree`, `codans project list`, and
/// `codans project show` (ADR 0003), asserted on the renderables the
/// commands emit.
struct HierarchyRenderablesHostTests {
  private static let box = HostRecord(address: "box.example.com", username: "me", name: "Build box")

  /// Projects as `codans tree` and `project list` get them: decoded from
  /// the app's list payload and resolved against its Host list.
  private static func listedProjects() throws -> (projects: [Project], hosts: [HostRecord]) {
    let local = Project(name: "app", rootPath: "/src/app", gitRoot: "/src/app")
    let server = Project(name: "srv", rootPath: "/srv/app", hostID: box.id, remoteHost: box.endpoint)
    let sent = IPC.ProjectListPayload(projects: [local, server], hosts: [box])
    let payload = try JSONDecoder().decode(IPC.ProjectListPayload.self, from: JSONEncoder().encode(sent))
    return (payload.resolvedProjects, payload.hosts ?? [])
  }

  private func emit<T: Encodable & CustomStringConvertible>(
    _ value: T, command: String, mode: RenderMode
  ) throws -> String {
    try Renderer.$context.withValue(RenderContext(command: command)) {
      var out = ""
      try Renderer.emit(value, mode: mode) { out = $0 }
      return out
    }
  }

  private func data(_ json: String) throws -> [String: Any] {
    let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    return try #require(object["data"] as? [String: Any])
  }

  @Test
  func treeTextShowsHostOfEachProject() throws {
    let (projects, hosts) = try Self.listedProjects()
    let text = try emit(
      HierarchyTreeRenderable(projects: projects, handles: nil, hosts: hosts), command: "tree", mode: .text(useColor: false))
    let lines = text.split(separator: "\n").map(String.init)

    #expect(lines.contains("  host: This Mac"))
    #expect(lines.contains("  host: Build box  \(Self.box.id)"))
    #expect(lines.contains { $0.hasPrefix("srv  ") && $0.hasSuffix("[server]") })
  }

  @Test
  func treeJSONCarriesHostIDAndName() throws {
    let (projects, hosts) = try Self.listedProjects()
    let json = try emit(
      HierarchyTreeRenderable(projects: projects, handles: nil, hosts: hosts), command: "tree", mode: .json)
    let rows = try #require(try data(json)["projects"] as? [[String: Any]])

    let localHost = try #require(rows[0]["host"] as? [String: Any])
    #expect(localHost["id"] is NSNull)
    #expect(localHost["name"] as? String == "This Mac")
    let serverHost = try #require(rows[1]["host"] as? [String: Any])
    #expect(serverHost["id"] as? String == Self.box.id.description)
    #expect(serverHost["name"] as? String == "Build box")
    #expect(rows[1]["kind"] as? String == "server")
  }

  @Test
  func projectListJSONReportsServerKind() throws {
    let (projects, _) = try Self.listedProjects()
    let json = try emit(ProjectListRenderable(projects: projects), command: "project.list", mode: .json)
    let rows = try #require(try data(json)["projects"] as? [[String: Any]])
    #expect(rows.map { $0["kind"] as? String } == ["git_repo", "server"])
  }

  @Test
  func projectShowTextShowsTheHost() throws {
    func describe(host: IPC.HostRef?, remoteHost: String?) -> IPC.ProjectDescription {
      IPC.ProjectDescription(
        id: UUID().uuidString, name: "srv", canonicalName: "srv", rootPath: "/srv", gitRoot: nil,
        remoteHost: remoteHost, host: host, isSelected: false, selectedWorktreeID: nil, worktreeCount: 1,
        archivedWorktreeCount: 0, tagIDs: [])
    }
    func hostLine(_ d: IPC.ProjectDescription) throws -> String? {
      let text = try emit(KeyValueRenderable(d, lines: ProjectShowLines.lines), command: "project.show", mode: .text(useColor: false))
      return text.split(separator: "\n").map(String.init).first { $0.hasPrefix("host:") }
    }

    let server = describe(
      host: IPC.HostRef(id: Self.box.id.description, name: "Build box"), remoteHost: "box.example.com")
    #expect(try hostLine(server)?.hasSuffix(" Build box  \(Self.box.id)") == true)
    #expect(try hostLine(describe(host: .thisMac, remoteHost: nil))?.hasSuffix(" This Mac") == true)
    // An app that predates Host records sends only the address.
    #expect(try hostLine(describe(host: nil, remoteHost: "box.example.com"))?.hasSuffix(" box.example.com") == true)

    let json = try emit(KeyValueRenderable(server, lines: ProjectShowLines.lines), command: "project.show", mode: .json)
    let host = try #require(try data(json)["host"] as? [String: Any])
    #expect(host["name"] as? String == "Build box")
  }
}
