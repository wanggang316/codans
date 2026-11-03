import Foundation
import Testing

@testable import CodansCore

/// Host list operations on `Catalog` (ADR 0003): the identity check, the
/// in-use check, and how Projects resolve their endpoint from a record.
struct CatalogHostsTests {
  private let box = RemoteHost(alias: "box.example.com", username: "me")

  // MARK: - Codec

  @Test
  func hostRecordRoundTrips() throws {
    let record = HostRecord(address: "10.0.0.5", username: "ops", port: 2222, name: "Lab")
    let decoded = try JSONDecoder().decode(HostRecord.self, from: JSONEncoder().encode(record))
    #expect(decoded == record)
  }

  @Test
  func optionalHostFieldsAreOmitted() throws {
    let record = HostRecord(address: "gpu-box")
    let object = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
    #expect(Set(object.keys) == ["id", "address"])
  }

  @Test
  func catalogDecodeResolvesProjectEndpointsFromHosts() throws {
    let record = HostRecord(address: "box.example.com", username: "me", port: 2200)
    let project = Project(name: "srv", rootPath: "/srv", hostID: record.id)
    let catalog = Catalog(projects: [project], hosts: [record])
    let decoded = try JSONDecoder().decode(Catalog.self, from: JSONEncoder().encode(catalog))
    #expect(decoded.hosts == [record])
    #expect(decoded.projects[0].remoteHost == record.endpoint)
    #expect(decoded.projects[0].isRemote)
    #expect(decoded.projects[0].kind == .server)
  }

  @Test
  func serverProjectWithoutHostIDKeepsLegacyFieldsOnEncode() throws {
    let project = Project(name: "srv", rootPath: "/srv", remoteHost: box)
    let object = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
    #expect(object["remoteHost"] != nil)
    #expect(object["hostID"] == nil)
  }

  @Test
  func displayNameFallsBackToHost() {
    #expect(HostRecord(address: "box").displayName == "box")
    #expect(HostRecord(address: "box", name: "  ").displayName == "box")
    #expect(HostRecord(address: "box", name: "Build").displayName == "Build")
  }

  // MARK: - Add / edit

  @Test
  func addAppendsInOrderOfAddition() throws {
    var catalog = Catalog()
    try catalog.addHost(HostRecord(address: "b"))
    try catalog.addHost(HostRecord(address: "a"))
    #expect(catalog.hosts.map(\.address) == ["b", "a"])
  }

  @Test
  func duplicateHostUsernamePortIsRefused() throws {
    var catalog = Catalog()
    let first = HostRecord(address: "box", username: "me")
    try catalog.addHost(first)
    #expect(throws: HostRecordError.duplicate(existing: first.id)) {
      try catalog.addHost(HostRecord(address: "box", username: "me", port: 22, name: "Other name"))
    }
    // A different username or port is a different Host.
    try catalog.addHost(HostRecord(address: "box", username: "root"))
    try catalog.addHost(HostRecord(address: "box", username: "me", port: 2222))
    #expect(catalog.hosts.count == 3)
  }

  @Test
  func invalidFieldsAreRefused() {
    var catalog = Catalog()
    #expect(throws: HostRecordError.missingAddress) { try catalog.addHost(HostRecord(address: "  ")) }
    #expect(throws: HostRecordError.invalidPort(0)) { try catalog.addHost(HostRecord(address: "a", port: 0)) }
    #expect(throws: HostRecordError.invalidPort(70000)) {
      try catalog.addHost(HostRecord(address: "a", port: 70000))
    }
    #expect(catalog.hosts.isEmpty)
  }

  @Test
  func editToAnotherRecordsIdentityIsRefused() throws {
    var catalog = Catalog()
    let first = HostRecord(address: "a")
    var second = HostRecord(address: "b")
    try catalog.addHost(first)
    try catalog.addHost(second)
    second.address = "a"
    #expect(throws: HostRecordError.duplicate(existing: first.id)) { try catalog.updateHost(second) }
    // Editing a record without changing its identity is allowed.
    var renamed = first
    renamed.name = "Primary"
    try catalog.updateHost(renamed)
    #expect(catalog.hosts[0].displayName == "Primary")
  }

  @Test
  func editAppliesToEveryProjectOnTheHost() throws {
    var catalog = Catalog()
    let id = try catalog.hostID(for: box)
    catalog.projects = [
      Project(name: "a", rootPath: "/a", hostID: id, remoteHost: box),
      Project(name: "b", rootPath: "/b", hostID: id, remoteHost: box),
      Project(name: "local", rootPath: "/local"),
    ]
    var record = try #require(catalog.host(id: id))
    record.address = "box2.example.com"
    record.port = 2200
    try catalog.updateHost(record)
    let moved = RemoteHost(alias: "box2.example.com", username: "me", port: 2200)
    #expect(catalog.projects[0].remoteHost == moved)
    #expect(catalog.projects[1].remoteHost == moved)
    #expect(catalog.projects[2].remoteHost == nil)
  }

  // MARK: - Delete

  @Test
  func deleteOfAHostInUseIsRefused() throws {
    var catalog = Catalog()
    let id = try catalog.hostID(for: box)
    catalog.projects = [
      Project(name: "a", rootPath: "/a", hostID: id), Project(name: "b", rootPath: "/b", hostID: id),
    ]
    #expect(catalog.projectCount(onHost: id) == 2)
    #expect(throws: HostRecordError.inUse(projectCount: 2)) { try catalog.removeHost(id: id) }
    #expect(catalog.hosts.count == 1)

    catalog.projects.removeAll()
    try catalog.removeHost(id: id)
    #expect(catalog.hosts.isEmpty)
  }

  @Test
  func deleteOfAnUnknownHostIsReported() {
    var catalog = Catalog()
    let id = HostID()
    #expect(throws: HostRecordError.notFound(id)) { try catalog.removeHost(id: id) }
  }

  // MARK: - Find or add

  @Test
  func enteredFieldsOfAnExistingHostReuseIt() throws {
    var catalog = Catalog()
    let named = HostRecord(address: "box.example.com", username: "me", name: "Box")
    try catalog.addHost(named)
    #expect(try catalog.hostID(for: RemoteHost(alias: "box.example.com", username: "me", port: 22)) == named.id)
    #expect(try catalog.hostID(for: RemoteHost(alias: " box.example.com ", username: "me")) == named.id)
    #expect(catalog.hosts == [named])

    let other = try catalog.hostID(for: RemoteHost(alias: "box.example.com", username: "root"))
    #expect(other != named.id)
    #expect(catalog.hosts.count == 2)
  }

  // MARK: - Adopt

  @Test
  func adoptAttachesProjectsWithADanglingHostID() {
    var project = Project(name: "srv", rootPath: "/srv", remoteHost: box)
    project.hostID = HostID()
    var catalog = Catalog(projects: [project])
    let changed = catalog.adoptHostReferences()
    #expect(changed)
    #expect(catalog.hosts.map(\.endpoint) == [box])
    #expect(catalog.projects[0].hostID == catalog.hosts[0].id)
    let changedAgain = catalog.adoptHostReferences()
    #expect(!changedAgain)
  }
}
