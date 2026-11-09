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
    /// The Host list. A Remote Project on the wire carries only its Host id
    /// (catalog v5); this list resolves it. Nil from an older app, whose
    /// Projects carry their host fields inline.
    public let hosts: [HostRecord]?

    public init(projects: [Project], handles: TargetHandles? = nil, hosts: [HostRecord]? = nil) {
      self.projects = projects
      self.handles = handles
      self.hosts = hosts
    }

    private enum CodingKeys: String, CodingKey { case projects, handles, hosts }

    /// Each Remote Project also carries its resolved `remoteHost`, which
    /// `catalog.json` no longer stores. A CLI that predates Host records
    /// reads only that field to tell a Remote Project from a local one.
    public func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(projects.map(LegacyHostFields.init), forKey: .projects)
      try container.encodeIfPresent(handles, forKey: .handles)
      try container.encodeIfPresent(hosts, forKey: .hosts)
    }

    /// `projects` with each Remote Project's `remoteHost` filled from
    /// `hosts`, so `Project.kind` / `isRemote` read the same as in the app.
    public var resolvedProjects: [Project] {
      guard let hosts else { return projects }
      var catalog = Catalog(projects: projects, hosts: hosts)
      catalog.resolveHostReferences()
      return catalog.projects
    }
  }

  /// The Host a Project is on: its `HostSelector` string (`"0"` for This
  /// Mac) and its display name.
  public struct HostRef: Codable, Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
      self.id = id
      self.name = name
    }

    public static let thisMac = HostRef(id: HostSelector.thisMacValue, name: HostRecord.thisMacName)

    public init(project: Project, hosts: [HostRecord]) {
      switch HostSelector(project: project) {
      case .thisMac:
        self = .thisMac
      case .host(let hostID):
        let name =
          hosts.first(where: { $0.id == hostID })?.displayName ?? project.remoteHost?.displayAuthority
          ?? hostID.description
        self.init(id: HostSelector.host(hostID).description, name: name)
      }
    }
  }
}

/// A Project encoded as usual, plus `remoteHost` for a Remote Project with a
/// Host id (see `IPC.ProjectListPayload.encode(to:)`).
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
