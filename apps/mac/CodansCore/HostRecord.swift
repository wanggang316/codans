import Foundation

/// A machine on which Remote Projects live, kept in the catalog's Host list
/// (`Catalog.hosts`). Remote Projects refer to it by `id`, so a change to the
/// record applies to all of them. Local Projects have no record: they are on
/// This Mac. See ADR 0003.
///
/// The record holds connection info only, never a credential: authentication
/// stays in the user's SSH config and agent.
public nonisolated struct HostRecord: Codable, Equatable, Hashable, Sendable, Identifiable {
  /// Display name for the Host of local Projects.
  public static let thisMacName = "This Mac"

  public var id: HostID
  /// The "Host" field: a domain name, an SSH config alias, or an IP address.
  public var address: String
  public var username: String?
  /// `nil` means the SSH default (22).
  public var port: Int?
  /// Optional display name. `displayName` falls back to `address`.
  public var name: String?
  /// Optional icon of the Host row. `nil` shows `HostIcon.fallback`.
  public var icon: HostIcon?

  public init(
    id: HostID = HostID(),
    address: String,
    username: String? = nil,
    port: Int? = nil,
    name: String? = nil,
    icon: HostIcon? = nil
  ) {
    self.id = id
    self.address = address
    self.username = username
    self.port = port
    self.name = name
    self.icon = icon
  }

  private enum CodingKeys: String, CodingKey {
    case id, address, username, port, name, icon
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(HostID.self, forKey: .id)
    address = try container.decode(String.self, forKey: .address)
    username = try container.decodeIfPresent(String.self, forKey: .username)
    port = try container.decodeIfPresent(Int.self, forKey: .port)
    name = try container.decodeIfPresent(String.self, forKey: .name)
    // An icon this build does not know (a newer build wrote it) is no icon,
    // so the record still loads.
    icon = try container.decodeIfPresent(String.self, forKey: .icon).flatMap(HostIcon.init(rawValue:))
  }

  /// The icon the Host row shows.
  public var displayIcon: HostIcon { icon ?? .fallback }

  /// A record for the connection fields of `endpoint`, without a name.
  public init(id: HostID = HostID(), endpoint: RemoteHost) {
    self.init(id: id, address: endpoint.alias, username: endpoint.username, port: endpoint.port)
  }

  /// `name` when it is not blank, else `address`.
  public var displayName: String {
    let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? address : trimmed
  }

  /// The SSH destination the runtime connects to.
  public var endpoint: RemoteHost {
    RemoteHost(alias: address, username: username, port: port)
  }

  /// The record with trimmed fields and blank optional fields set to `nil`.
  /// Throws for an empty Host field or a port outside 1...65535. Every Host
  /// list change and every Host form use this, so they refuse the same input.
  public func validated() throws(HostRecordError) -> HostRecord {
    var record = self
    record.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !record.address.isEmpty else { throw .missingAddress }
    let username = username?.trimmingCharacters(in: .whitespacesAndNewlines)
    record.username = (username?.isEmpty ?? true) ? nil : username
    let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    record.name = (name?.isEmpty ?? true) ? nil : name
    if let port, !(1...65535).contains(port) {
      throw .invalidPort(port)
    }
    return record
  }

  /// The (Host, Username, Port) triple that must be unique in the Host list.
  /// An empty username equals no username, and no port equals port 22,
  /// because `ssh` reaches the same account in both cases.
  public var identity: Identity { Identity(endpoint) }

  public struct Identity: Hashable, Sendable {
    public let address: String
    public let username: String
    public let port: Int

    public init(_ endpoint: RemoteHost) {
      self.address = endpoint.alias
      self.username = endpoint.username ?? ""
      self.port = endpoint.port ?? 22
    }
  }
}

/// Why a Host list change was refused.
public nonisolated enum HostRecordError: LocalizedError, Equatable, Sendable {
  /// The Host field is empty.
  case missingAddress
  /// The port is outside 1...65535.
  case invalidPort(Int)
  /// Another record has the same (Host, Username, Port).
  case duplicate(existing: HostID)
  /// Projects still refer to the record.
  case inUse(projectCount: Int)
  case notFound(HostID)

  public var errorDescription: String? {
    switch self {
    case .missingAddress:
      return "Enter a host."
    case .invalidPort(let port):
      return "Port \(port) is not valid. Enter a number from 1 to 65535."
    case .duplicate:
      return "A host with the same address, username, and port already exists."
    case .inUse(let count):
      return count == 1
        ? "1 project uses this host. Remove the project first."
        : "\(count) projects use this host. Remove the projects first."
    case .notFound:
      return "The host does not exist."
    }
  }
}
