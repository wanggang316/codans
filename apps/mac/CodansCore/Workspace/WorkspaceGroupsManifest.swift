import Foundation

/// Contents of `<root>/.codans/workspace-groups.json` (schema 2): the source
/// projects of a Workspace and its groups.
///
/// `projects` defines the members of `default` and of future named groups.
/// Each named group keeps its own `members`; `default` has none, because its
/// references derive from `projects`.
///
/// Decoding is strict on structure (required keys and known enum values)
/// and tolerant only on optional fields. `validate()` checks the rules that
/// span entries, such as unique paths.
public nonisolated struct WorkspaceGroupsManifest: Equatable, Sendable {
  public static let currentSchemaVersion = 2

  public var schemaVersion: Int
  public var title: String
  public var description: String?
  public var taskLinks: [String]
  public var projects: [Source]
  public var groups: [Group]
  public var createdAt: Date?
  public var updatedAt: Date?

  public init(
    schemaVersion: Int = WorkspaceGroupsManifest.currentSchemaVersion,
    title: String,
    description: String? = nil,
    taskLinks: [String] = [],
    projects: [Source] = [],
    groups: [Group] = [],
    createdAt: Date? = nil,
    updatedAt: Date? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.title = title
    self.description = description
    self.taskLinks = taskLinks
    self.projects = projects
    self.groups = groups
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  /// A source project: a main checkout the Workspace references.
  public struct Source: Codable, Equatable, Sendable {
    /// Link name inside the `default` directory. One path component.
    public var name: String
    /// Absolute path of the source main checkout.
    public var sourceGitRoot: String
    /// URL the Workspace cloned the source from; provenance only.
    public var remoteURL: String?

    public init(name: String, sourceGitRoot: String, remoteURL: String? = nil) {
      self.name = name
      self.sourceGitRoot = sourceGitRoot
      self.remoteURL = remoteURL
    }
  }

  /// How a group came to exist. Absent for groups the app created.
  public enum Origin: String, Codable, Equatable, Sendable {
    /// Built from a version 1 manifest; its path is the Workspace root.
    case migrated
  }

  public struct Group: Equatable, Sendable, Identifiable {
    public var id: WorkspaceGroupID
    public var name: String
    public var kind: WorkspaceGroupKind
    /// Group directory relative to the root.
    public var path: String
    public var origin: Origin?
    /// Creation-time branch. A record, not identity: members keep their own
    /// live branch.
    public var branch: String?
    public var createdAt: Date?
    public var members: [Member]
    public var deletion: GroupDeletionState?

    public init(
      id: WorkspaceGroupID,
      name: String,
      kind: WorkspaceGroupKind,
      path: String,
      origin: Origin? = nil,
      branch: String? = nil,
      createdAt: Date? = nil,
      members: [Member] = [],
      deletion: GroupDeletionState? = nil
    ) {
      self.id = id
      self.name = name
      self.kind = kind
      self.path = path
      self.origin = origin
      self.branch = branch
      self.createdAt = createdAt
      self.members = members
      self.deletion = deletion
    }
  }

  /// A checkout a named group owns.
  public struct Member: Equatable, Sendable, Identifiable {
    public var id: WorkspaceMemberID
    public var name: String
    /// Checkout directory relative to the root.
    public var path: String
    /// Repository the checkout belongs to. `nil` only for a migrated entry
    /// that never recorded it; the reconcile reads it from git.
    public var sourceGitRoot: String?
    /// Free-text role for agents, carried over from version 1.
    public var role: String?
    public var checkoutMode: WorkspaceManifest.CheckoutMode?
    public var branch: String?
    public var baseRef: String?
    /// `true` when the group created `branch`. Only then may a group delete
    /// offer to delete the branch. `nil` means unknown (migrated).
    public var createdBranch: Bool?

    public init(
      id: WorkspaceMemberID,
      name: String,
      path: String,
      sourceGitRoot: String? = nil,
      role: String? = nil,
      checkoutMode: WorkspaceManifest.CheckoutMode? = nil,
      branch: String? = nil,
      baseRef: String? = nil,
      createdBranch: Bool? = nil
    ) {
      self.id = id
      self.name = name
      self.path = path
      self.sourceGitRoot = sourceGitRoot
      self.role = role
      self.checkoutMode = checkoutMode
      self.branch = branch
      self.baseRef = baseRef
      self.createdBranch = createdBranch
    }
  }

  /// The single `default` group, when present.
  public var defaultGroup: Group? {
    groups.first { $0.kind == .default }
  }
}

// MARK: - Validation

extension WorkspaceGroupsManifest {
  public enum ValidationIssue: Equatable, Sendable, CustomStringConvertible {
    case missingDefaultGroup
    case multipleDefaultGroups
    case reservedGroupName(String)
    case duplicateGroupName(String)
    case duplicateGroupID(WorkspaceGroupID)
    case defaultGroupHasMembers
    /// Not relative, not normalized, escapes the root, or `.` where only a
    /// migrated group may use it.
    case invalidPath(String)
    /// Two group or member paths are equal, or one is inside another in a
    /// way the layout does not allow.
    case overlappingPaths(String, String)
    case invalidSourceName(String)
    case duplicateSourceName(String)
    case duplicateSource(String)
    case relativeSourcePath(String)

    public var description: String {
      switch self {
      case .missingDefaultGroup: return "no \"default\" group"
      case .multipleDefaultGroups: return "more than one \"default\" group"
      case .reservedGroupName(let name): return "group name \"\(name)\" is reserved"
      case .duplicateGroupName(let name): return "group name \"\(name)\" appears more than once"
      case .duplicateGroupID(let id): return "group id \(id) appears more than once"
      case .defaultGroupHasMembers: return "the \"default\" group must not list members"
      case .invalidPath(let path): return "path \"\(path)\" is not a valid path under the workspace root"
      case .overlappingPaths(let lhs, let rhs): return "paths \"\(lhs)\" and \"\(rhs)\" overlap"
      case .invalidSourceName(let name): return "project name \"\(name)\" is not a valid folder name"
      case .duplicateSourceName(let name): return "project name \"\(name)\" appears more than once"
      case .duplicateSource(let path): return "project \"\(path)\" appears more than once"
      case .relativeSourcePath(let path): return "project path \"\(path)\" is not absolute"
      }
    }
  }

  public func validate() -> [ValidationIssue] {
    var issues: [ValidationIssue] = []
    issues += validateGroups()
    issues += validateSources()
    issues += validatePaths()
    return issues
  }

  private func validateGroups() -> [ValidationIssue] {
    var issues: [ValidationIssue] = []
    let defaults = groups.filter { $0.kind == .default }
    if defaults.isEmpty { issues.append(.missingDefaultGroup) }
    if defaults.count > 1 { issues.append(.multipleDefaultGroups) }
    if defaults.contains(where: { !$0.members.isEmpty }) { issues.append(.defaultGroupHasMembers) }
    var names = Set<String>()
    var ids = Set<WorkspaceGroupID>()
    for group in groups {
      if group.kind == .named, group.name == WorkspaceLayout.defaultGroupName {
        issues.append(.reservedGroupName(group.name))
      }
      if !names.insert(group.name).inserted { issues.append(.duplicateGroupName(group.name)) }
      if !ids.insert(group.id).inserted { issues.append(.duplicateGroupID(group.id)) }
    }
    return issues
  }

  private func validateSources() -> [ValidationIssue] {
    var issues: [ValidationIssue] = []
    var names = Set<String>()
    var roots = Set<String>()
    for source in projects {
      if !WorkspaceManifest.isValidChildPath(source.name) { issues.append(.invalidSourceName(source.name)) }
      if !names.insert(source.name).inserted { issues.append(.duplicateSourceName(source.name)) }
      if !source.sourceGitRoot.hasPrefix("/") { issues.append(.relativeSourcePath(source.sourceGitRoot)) }
      if !roots.insert(source.sourceGitRoot).inserted { issues.append(.duplicateSource(source.sourceGitRoot)) }
    }
    return issues
  }

  /// Every group directory and member path must be a normalized relative
  /// path. `.` is the root and is allowed only for a migrated group. No two
  /// paths may be equal, and a path may sit inside another only when it is
  /// a member inside its own group's directory.
  private func validatePaths() -> [ValidationIssue] {
    var issues: [ValidationIssue] = []
    struct Entry {
      let components: [String]
      let path: String
      /// Index of the group that owns this entry.
      let group: Int
      let isGroupDirectory: Bool
    }
    var entries: [Entry] = []
    for (index, group) in groups.enumerated() {
      if group.path == WorkspaceLayout.migratedGroupPath {
        if group.origin != .migrated || group.kind != .named { issues.append(.invalidPath(group.path)) }
      } else if let components = Self.normalizedComponents(group.path) {
        entries.append(Entry(components: components, path: group.path, group: index, isGroupDirectory: true))
      } else {
        issues.append(.invalidPath(group.path))
      }
      for member in group.members {
        guard let components = Self.normalizedComponents(member.path) else {
          issues.append(.invalidPath(member.path))
          continue
        }
        entries.append(Entry(components: components, path: member.path, group: index, isGroupDirectory: false))
      }
    }
    for lhsIndex in entries.indices {
      for rhsIndex in entries.indices where rhsIndex > lhsIndex {
        let lhs = entries[lhsIndex]
        let rhs = entries[rhsIndex]
        let (outer, inner) = lhs.components.count <= rhs.components.count ? (lhs, rhs) : (rhs, lhs)
        guard inner.components.starts(with: outer.components) else { continue }
        let allowed =
          outer.components.count < inner.components.count && outer.isGroupDirectory
          && !inner.isGroupDirectory && outer.group == inner.group
        if !allowed { issues.append(.overlappingPaths(lhs.path, rhs.path)) }
      }
    }
    return issues
  }

  /// Components of a relative, lexically normalized path; `nil` when the
  /// path is empty, absolute, has a trailing or doubled `/`, or contains
  /// `.` or `..`.
  static func normalizedComponents(_ path: String) -> [String]? {
    guard !path.isEmpty, !path.hasPrefix("/") else { return nil }
    let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    for component in components where component.isEmpty || component == "." || component == ".." {
      return nil
    }
    return components
  }
}

// MARK: - Codable

extension WorkspaceGroupsManifest: Codable {
  /// Thrown before anything else is decoded when the file declares a schema
  /// this build does not know.
  public enum DecodingIssue: Error, Equatable, Sendable {
    case newerSchema(Int)
    case unsupportedSchema(Int)
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, title, description, taskLinks, projects, groups, createdAt, updatedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    if schemaVersion > Self.currentSchemaVersion { throw DecodingIssue.newerSchema(schemaVersion) }
    if schemaVersion < Self.currentSchemaVersion { throw DecodingIssue.unsupportedSchema(schemaVersion) }
    self.schemaVersion = schemaVersion
    self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
    self.description = try container.decodeIfPresent(String.self, forKey: .description)
    self.taskLinks = try container.decodeIfPresent([String].self, forKey: .taskLinks) ?? []
    self.projects = try container.decode([Source].self, forKey: .projects)
    self.groups = try container.decode([Group].self, forKey: .groups)
    self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
    self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(title, forKey: .title)
    try container.encodeIfPresent(description, forKey: .description)
    if !taskLinks.isEmpty {
      try container.encode(taskLinks, forKey: .taskLinks)
    }
    try container.encode(projects, forKey: .projects)
    try container.encode(groups, forKey: .groups)
    try container.encodeIfPresent(createdAt, forKey: .createdAt)
    try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
  }
}

// IDs are plain UUID strings here, unlike the catalog: agents read this file.
extension WorkspaceGroupsManifest.Group: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, name, kind, path, origin, branch, createdAt, members, deletion
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = WorkspaceGroupID(raw: try container.decode(UUID.self, forKey: .id))
    self.name = try container.decode(String.self, forKey: .name)
    self.kind = try container.decode(WorkspaceGroupKind.self, forKey: .kind)
    self.path = try container.decode(String.self, forKey: .path)
    // An origin written by a newer build reads as "not recorded".
    self.origin = try container.decodeIfPresent(String.self, forKey: .origin)
      .flatMap(WorkspaceGroupsManifest.Origin.init(rawValue:))
    self.branch = try container.decodeIfPresent(String.self, forKey: .branch)
    self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
    self.members = try container.decodeIfPresent([WorkspaceGroupsManifest.Member].self, forKey: .members) ?? []
    self.deletion = try container.decodeIfPresent(GroupDeletionState.self, forKey: .deletion)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id.raw, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(kind, forKey: .kind)
    try container.encode(path, forKey: .path)
    try container.encodeIfPresent(origin, forKey: .origin)
    try container.encodeIfPresent(branch, forKey: .branch)
    try container.encodeIfPresent(createdAt, forKey: .createdAt)
    if kind == .named {
      try container.encode(members, forKey: .members)
    }
    try container.encodeIfPresent(deletion, forKey: .deletion)
  }
}

extension WorkspaceGroupsManifest.Member: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, name, path, sourceGitRoot, role, checkoutMode, branch, baseRef, createdBranch
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = WorkspaceMemberID(raw: try container.decode(UUID.self, forKey: .id))
    self.name = try container.decode(String.self, forKey: .name)
    self.path = try container.decode(String.self, forKey: .path)
    self.sourceGitRoot = try container.decodeIfPresent(String.self, forKey: .sourceGitRoot)
    self.role = try container.decodeIfPresent(String.self, forKey: .role)
    self.checkoutMode = try container.decodeIfPresent(String.self, forKey: .checkoutMode)
      .flatMap(WorkspaceManifest.CheckoutMode.init(rawValue:))
    self.branch = try container.decodeIfPresent(String.self, forKey: .branch)
    self.baseRef = try container.decodeIfPresent(String.self, forKey: .baseRef)
    self.createdBranch = try container.decodeIfPresent(Bool.self, forKey: .createdBranch)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id.raw, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(path, forKey: .path)
    try container.encodeIfPresent(sourceGitRoot, forKey: .sourceGitRoot)
    try container.encodeIfPresent(role, forKey: .role)
    try container.encodeIfPresent(checkoutMode, forKey: .checkoutMode)
    try container.encodeIfPresent(branch, forKey: .branch)
    try container.encodeIfPresent(baseRef, forKey: .baseRef)
    try container.encodeIfPresent(createdBranch, forKey: .createdBranch)
  }
}
