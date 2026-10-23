import CryptoKit
import Foundation

/// The two kinds of Workspace group. A Workspace has exactly one `default`
/// group (references to the source main checkouts) and any number of
/// `named` groups (checkouts the group owns).
public nonisolated enum WorkspaceGroupKind: String, Codable, Equatable, Sendable {
  case `default`
  case named
}

/// Where a catalog row sits inside a Workspace. Present on Workspace rows
/// only.
public nonisolated struct WorkspaceSlot: Codable, Equatable, Hashable, Sendable {
  public enum Role: String, Codable, Equatable, Hashable, Sendable {
    /// The row for the group directory. One per group.
    case groupTerminal
    /// A `default` member. Its path is the source main checkout, which the
    /// Workspace does not own.
    case reference
    /// A checkout the group owns.
    case member
  }

  public var groupID: WorkspaceGroupID
  public var role: Role

  public init(groupID: WorkspaceGroupID, role: Role) {
    self.groupID = groupID
    self.role = role
  }
}

/// A destructive group delete that has started and still has unresolved
/// items. Persisted so a restart shows "Deletion incomplete" and Retry.
public nonisolated struct GroupDeletionState: Codable, Equatable, Sendable {
  public var deleteBranches: Bool
  public var startedAt: Date

  public init(deleteBranches: Bool, startedAt: Date) {
    self.deleteBranches = deleteBranches
    self.startedAt = startedAt
  }
}

/// Catalog copy of one manifest group plus its sidebar state. The manifest
/// is the source of truth for membership; this record lets the sidebar
/// render synchronously at launch.
public nonisolated struct WorkspaceGroupRecord: Equatable, Sendable, Identifiable {
  public var id: WorkspaceGroupID
  public var name: String
  public var kind: WorkspaceGroupKind
  public var isExpanded: Bool
  public var deletion: GroupDeletionState?

  public init(
    id: WorkspaceGroupID,
    name: String,
    kind: WorkspaceGroupKind,
    isExpanded: Bool = false,
    deletion: GroupDeletionState? = nil
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.isExpanded = isExpanded
    self.deletion = deletion
  }
}

extension WorkspaceGroupRecord: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, name, kind, isExpanded, deletion
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(WorkspaceGroupID.self, forKey: .id)
    self.name = try container.decode(String.self, forKey: .name)
    self.kind = try container.decode(WorkspaceGroupKind.self, forKey: .kind)
    self.isExpanded = try container.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? false
    self.deletion = try container.decodeIfPresent(GroupDeletionState.self, forKey: .deletion)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(kind, forKey: .kind)
    if isExpanded {
      try container.encode(true, forKey: .isExpanded)
    }
    try container.encodeIfPresent(deletion, forKey: .deletion)
  }
}

extension WorkspaceGroupID {
  /// Stable ID for a group that migration or a second app instance must
  /// compute identically: the first 16 bytes of SHA-256 over the key and
  /// the Workspace root.
  public static func derived(rootPath: String, key: String) -> WorkspaceGroupID {
    WorkspaceGroupID(raw: derivedUUID("codans.workspace-group|\(key)|\(rootPath)"))
  }
}

extension WorkspaceMemberID {
  /// Stable ID for a migrated member, derived from the Workspace root and
  /// the member path relative to it.
  public static func derived(rootPath: String, path: String) -> WorkspaceMemberID {
    WorkspaceMemberID(raw: derivedUUID("codans.workspace-member|\(path)|\(rootPath)"))
  }
}

private nonisolated func derivedUUID(_ seed: String) -> UUID {
  let bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
  return UUID(
    uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}
