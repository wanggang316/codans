import Foundation

/// A top-level group of the sidebar (ADR 0002, decision 2): This Mac for
/// local Projects, or a Host record for Server projects.
///
/// Encoded as one string, `this-mac` or the Host's UUID, so the collapsed
/// set in `catalog.json` stays a plain string list.
public nonisolated enum SidebarHost: Hashable, Sendable, Codable {
  case thisMac
  case host(HostID)

  private static let thisMacKey = "this-mac"

  var key: String {
    switch self {
    case .thisMac: Self.thisMacKey
    case .host(let id): id.raw.uuidString
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)
    if raw == Self.thisMacKey {
      self = .thisMac
    } else if let uuid = UUID(uuidString: raw) {
      self = .host(HostID(raw: uuid))
    } else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown sidebar host \(raw)")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(key)
  }
}

/// One Host row of the sidebar and the Projects listed under it.
public nonisolated struct SidebarHostGroup: Equatable, Sendable {
  public let host: SidebarHost
  /// The Host record; `nil` for This Mac.
  public let record: HostRecord?
  public let isExpanded: Bool
  public let projects: [Project]

  /// The name the Host row shows.
  public var displayName: String {
    record?.displayName ?? HostRecord.thisMacName
  }
}

/// What the sidebar needs to group Projects by Host. The catalog gives one
/// only while the Host level shows (`Catalog.sidebarHostLevel`).
public nonisolated struct SidebarHostLevel: Equatable, Sendable {
  public let records: [HostRecord]
  public let collapsed: Set<SidebarHost>
  /// This Mac keeps its row with no Project in it. True while no filter is
  /// on: This Mac is not a Host record, so a catalog with only remote
  /// Projects still shows it (issue #336). A filter hides it like any Host.
  public let keepsThisMac: Bool

  public init(records: [HostRecord], collapsed: Set<SidebarHost>, keepsThisMac: Bool = false) {
    self.records = records
    self.collapsed = collapsed
    self.keepsThisMac = keepsThisMac
  }

  /// `projects` (already filtered and sorted) grouped by Host: This Mac
  /// first, then the Host list order (ADR 0003, decision 6). A Host with no
  /// Project in `projects` has no group, so a filter hides it; This Mac
  /// stays when `keepsThisMac`. Projects keep their order inside a group.
  public func groups(_ projects: [Project]) -> [SidebarHostGroup] {
    var byHost: [SidebarHost: [Project]] = [:]
    for project in projects {
      byHost[Self.host(of: project), default: []].append(project)
    }
    var order: [SidebarHost] = [.thisMac] + records.map { .host($0.id) }
    // A Host id with no record (a catalog that has not run
    // `adoptHostReferences` yet) still lists its Projects, last.
    for project in projects {
      let host = Self.host(of: project)
      if !order.contains(host) { order.append(host) }
    }
    return order.compactMap { host in
      let projects = byHost[host] ?? []
      guard !projects.isEmpty || (host == .thisMac && keepsThisMac) else { return nil }
      let record: HostRecord? =
        switch host {
        case .thisMac: nil
        case .host(let id): records.first { $0.id == id }
        }
      return SidebarHostGroup(
        host: host, record: record, isExpanded: !collapsed.contains(host), projects: projects)
    }
  }

  public static func host(of project: Project) -> SidebarHost {
    project.hostID.map { .host($0) } ?? .thisMac
  }
}
