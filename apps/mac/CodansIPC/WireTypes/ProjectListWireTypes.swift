import CodansCore
import Foundation

extension IPC {
  /// `hierarchy.listProjects` result, read by `codans tree` and the CLI's
  /// id lookups. `handles` and `hosts` are optional so the CLI still reads
  /// responses from an app that predates them.
  public struct ProjectListPayload: Codable, Sendable {
    public let projects: [Project]
    /// Short-handle map printed by `codans tree` in text mode.
    public let handles: TargetHandles?
    /// The Host list. A Server project on the wire carries only its Host id
    /// (catalog v5); this list resolves it. Nil from an older app, whose
    /// Projects carry their host fields inline.
    public let hosts: [HostRecord]?

    public init(projects: [Project], handles: TargetHandles? = nil, hosts: [HostRecord]? = nil) {
      self.projects = projects
      self.handles = handles
      self.hosts = hosts
    }

    private enum CodingKeys: String, CodingKey { case projects, handles, hosts }

    /// Each Server project also carries its resolved `remoteHost`, which
    /// `catalog.json` no longer stores. A CLI that predates Host records
    /// reads only that field to tell a Server project from a local one.
    public func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(projects.map(LegacyHostFields.init), forKey: .projects)
      try container.encodeIfPresent(handles, forKey: .handles)
      try container.encodeIfPresent(hosts, forKey: .hosts)
    }

    /// A Project encoded as usual, plus `remoteHost`.
    private struct LegacyHostFields: Encodable {
      let project: Project

      private enum CodingKeys: String, CodingKey { case remoteHost }

      func encode(to encoder: Encoder) throws {
        try project.encode(to: encoder)
        guard project.hostID != nil, let endpoint = project.remoteHost else { return }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(endpoint, forKey: .remoteHost)
      }
    }

    /// `projects` with each Server project's `remoteHost` filled from
    /// `hosts`, so `Project.kind` / `isRemote` read the same as in the app.
    public var resolvedProjects: [Project] {
      guard let hosts else { return projects }
      var catalog = Catalog(projects: projects, hosts: hosts)
      catalog.resolveHostReferences()
      return catalog.projects
    }
  }

  /// The Host a Project is on: its Host record's id and display name, or
  /// This Mac (no id) for a local Project.
  public struct HostRef: Codable, Equatable, Sendable {
    /// `HostID` as a plain UUID string; nil for This Mac, and for a Server
    /// project reported by an app that predates Host records.
    public let id: String?
    public let name: String

    public init(id: String?, name: String) {
      self.id = id
      self.name = name
    }

    public static let thisMac = HostRef(id: nil, name: HostRecord.thisMacName)

    private enum CodingKeys: String, CodingKey { case id, name }

    /// Writes `"id": null` for This Mac instead of dropping the key, so
    /// `--json` output always has both fields.
    public func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(id, forKey: .id)
      try container.encode(name, forKey: .name)
    }

    public init(project: Project, hosts: [HostRecord]) {
      if let hostID = project.hostID, let record = hosts.first(where: { $0.id == hostID }) {
        self.init(id: hostID.description, name: record.displayName)
      } else if let endpoint = project.remoteHost {
        self.init(id: project.hostID?.description, name: endpoint.displayAuthority)
      } else {
        self = .thisMac
      }
    }
  }
}
