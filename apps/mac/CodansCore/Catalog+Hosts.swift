import Foundation

/// Host list operations. Every change to `hosts` or to a Project's `hostID`
/// goes through here so two invariants hold:
/// - no two records share a (Host, Username, Port) identity;
/// - each Server project's `remoteHost` equals the endpoint of its Host.
extension Catalog {
  public func host(id: HostID) -> HostRecord? {
    hosts.first { $0.id == id }
  }

  /// The record with the same (Host, Username, Port) as `endpoint`, if any.
  public func host(matching endpoint: RemoteHost) -> HostRecord? {
    let identity = HostRecord.Identity(endpoint)
    return hosts.first { $0.identity == identity }
  }

  /// The Host record of `project`; `nil` for a local Project (This Mac).
  public func host(of project: Project) -> HostRecord? {
    project.hostID.flatMap { host(id: $0) }
  }

  /// Number of Projects that refer to the Host.
  public func projectCount(onHost id: HostID) -> Int {
    projects.count(where: { $0.hostID == id })
  }

  /// Append `record` to the Host list. Refuses an empty Host field, a port
  /// outside 1...65535, and a duplicate identity.
  public mutating func addHost(_ record: HostRecord) throws(HostRecordError) {
    let record = try record.validated()
    if let existing = hosts.first(where: { $0.identity == record.identity }) {
      throw .duplicate(existing: existing.id)
    }
    hosts.append(record)
  }

  /// Replace the record with the same id, keeping its place in the list.
  /// Every Project on the Host gets the new endpoint.
  public mutating func updateHost(_ record: HostRecord) throws(HostRecordError) {
    guard let index = hosts.firstIndex(where: { $0.id == record.id }) else {
      throw .notFound(record.id)
    }
    let record = try record.validated()
    if let other = hosts.first(where: { $0.id != record.id && $0.identity == record.identity }) {
      throw .duplicate(existing: other.id)
    }
    hosts[index] = record
    resolveHostReferences()
  }

  /// Remove a record. Refused while a Project refers to it, so every
  /// reference stays valid.
  public mutating func removeHost(id: HostID) throws(HostRecordError) {
    guard let index = hosts.firstIndex(where: { $0.id == id }) else {
      throw .notFound(id)
    }
    let count = projectCount(onHost: id)
    guard count == 0 else { throw .inUse(projectCount: count) }
    hosts.remove(at: index)
    collapsedSidebarHosts.remove(.host(id))
  }

  /// The id of the record for `endpoint`: an existing record with the same
  /// identity, else a new record appended to the list. This is how Connect
  /// to Server and Edit Connection turn entered fields into a Host.
  public mutating func hostID(for endpoint: RemoteHost) throws(HostRecordError) -> HostID {
    let record = try HostRecord(endpoint: endpoint).validated()
    if let existing = hosts.first(where: { $0.identity == record.identity }) {
      return existing.id
    }
    hosts.append(record)
    return record.id
  }

  /// Point the Project at `index` to a Host and resolve its endpoint.
  public mutating func attachProject(at index: Int, toHost id: HostID) {
    projects[index].hostID = id
    projects[index].remoteHost = host(id: id)?.endpoint
  }

  /// Fill each Project's `remoteHost` from its Host record. A Project whose
  /// `hostID` has no record keeps the value it has, so `adoptHostReferences`
  /// can still attach it.
  public mutating func resolveHostReferences() {
    for index in projects.indices {
      guard let id = projects[index].hostID, let record = host(id: id) else { continue }
      projects[index].remoteHost = record.endpoint
    }
  }

  /// Give a Host record to every Server project that has host fields but no
  /// valid `hostID` (a legacy catalog, or a connection restored from the
  /// sidecar). Projects with the same identity share one record; records
  /// are added in Project order. Idempotent. Returns whether anything
  /// changed.
  @discardableResult
  public mutating func adoptHostReferences() -> Bool {
    var changed = false
    for index in projects.indices {
      guard let endpoint = projects[index].remoteHost else { continue }
      if let id = projects[index].hostID, host(id: id) != nil { continue }
      let id: HostID
      if let existing = host(matching: endpoint) {
        id = existing.id
      } else {
        // Legacy fields are kept as they are, even when they would not pass
        // `HostRecord.validated()`: the Project connected with them before.
        let record = HostRecord(endpoint: endpoint)
        hosts.append(record)
        id = record.id
      }
      attachProject(at: index, toHost: id)
      changed = true
    }
    return changed
  }
}
