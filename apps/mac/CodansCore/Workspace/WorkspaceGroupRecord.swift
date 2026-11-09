import Foundation

/// The two kinds of Workspace group. A Workspace has exactly one `default`
/// group (references to the source main checkouts) and any number of
/// `named` groups (checkouts the group owns).
public nonisolated enum WorkspaceGroupKind: String, Codable, Equatable, Sendable {
  case `default`
  case named
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
