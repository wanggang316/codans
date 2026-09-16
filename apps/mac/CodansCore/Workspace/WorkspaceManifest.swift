import Foundation

/// Contents of `<root>/.codans/workspace.json`: the repositories one agent
/// works across from the workspace root, with where each came from and how
/// it was checked out.
///
/// The manifest is the source of truth for *membership and intent*. Live
/// facts — the branch a child is on, which repository its `.git` belongs to
/// — come from git at reconcile time, never from here, so a hand-edited or
/// stale manifest can mislabel a row but cannot make the app act on a wrong
/// repository.
///
/// Decoding is tolerant: every field has a default and unknown keys are
/// ignored, so a manifest written by a newer build still opens.
public nonisolated struct WorkspaceManifest: Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  /// Display title. Empty means "use the folder name" (see `normalized`).
  public var title: String
  /// Optional task summary shown to agents and in the detail view.
  public var description: String?
  /// Optional links or identifiers for the work item.
  public var taskLinks: [String]
  public var repositories: [Entry]
  public var createdAt: Date?
  public var updatedAt: Date?

  public init(
    schemaVersion: Int = WorkspaceManifest.currentSchemaVersion,
    title: String = "",
    description: String? = nil,
    taskLinks: [String] = [],
    repositories: [Entry] = [],
    createdAt: Date? = nil,
    updatedAt: Date? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.title = title
    self.description = description
    self.taskLinks = taskLinks
    self.repositories = repositories
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  /// How a child checkout was produced from its source repository. Absent
  /// on entries written by hand; the app then treats the folder as an
  /// existing checkout it did not create.
  public enum CheckoutMode: String, Codable, Equatable, Sendable {
    /// `git worktree add -b <branch> <path> [<baseRef>]`
    case newBranch
    /// `git worktree add <path> <branch>`
    case existingBranch
    /// `git worktree add --track -b|-B <branch> <path> <remote>/<branch>`;
    /// `baseRef` records the remote-tracking ref.
    case remoteTrackingRef
  }

  public struct Entry: Equatable, Sendable, Identifiable {
    /// Entries are keyed by folder name — unique within the root by
    /// construction, and also the catalog row's name.
    public var id: String { name }
    /// Display name and, by default, the folder name under the root.
    public var name: String
    /// Short role such as `app`, `backend`, or `docs`. Free text for agents.
    public var role: String?
    /// Folder under the workspace root. Always a single path component —
    /// the manifest never points outside its own root.
    public var path: String
    /// Absolute path of the repository the checkout was created from. Nil
    /// for hand-written entries; the reconcile fills the catalog row's
    /// `sourceGitRoot` from git regardless.
    public var sourceGitRoot: String?
    /// URL the source repository was cloned from when the workspace added
    /// it as a remote; provenance only. Nil for local sources.
    public var remoteURL: String?
    public var checkoutMode: CheckoutMode?
    /// Branch the checkout was created on. Informational — the live branch
    /// is read from git.
    public var branch: String?
    /// Ref the branch was started from, for `newBranch` checkouts.
    public var baseRef: String?

    public init(
      name: String,
      role: String? = nil,
      path: String? = nil,
      sourceGitRoot: String? = nil,
      remoteURL: String? = nil,
      checkoutMode: CheckoutMode? = nil,
      branch: String? = nil,
      baseRef: String? = nil
    ) {
      self.name = name
      self.role = role
      self.path = path ?? name
      self.sourceGitRoot = sourceGitRoot
      self.remoteURL = remoteURL
      self.checkoutMode = checkoutMode
      self.branch = branch
      self.baseRef = baseRef
    }

    /// Absolute path of the child folder under `rootPath`.
    public func resolvedPath(rootPath: String) -> String {
      (rootPath as NSString).appendingPathComponent(path)
    }
  }

  // MARK: - Validation

  public enum ValidationIssue: Equatable, Sendable, CustomStringConvertible {
    /// Empty, absolute, or multi-component path, or `.` / `..`.
    case invalidPath(name: String, path: String)
    case duplicateName(String)
    case duplicatePath(String)

    public var description: String {
      switch self {
      case .invalidPath(let name, let path):
        return
          "repository \"\(name)\" has an invalid path \"\(path)\" — expected a folder name under the workspace root"
      case .duplicateName(let name):
        return "repository name \"\(name)\" appears more than once"
      case .duplicatePath(let path):
        return "repository path \"\(path)\" appears more than once"
      }
    }
  }

  /// Structural problems that make an entry unusable. Run on the
  /// `normalized` form; an unnormalized manifest can report whitespace-only
  /// differences as duplicates.
  public func validate() -> [ValidationIssue] {
    var issues: [ValidationIssue] = []
    var seenNames = Set<String>()
    var seenPaths = Set<String>()
    for entry in repositories {
      if !Self.isValidChildPath(entry.path) {
        issues.append(.invalidPath(name: entry.name, path: entry.path))
      }
      if !seenNames.insert(entry.name).inserted {
        issues.append(.duplicateName(entry.name))
      }
      if !seenPaths.insert(entry.path).inserted {
        issues.append(.duplicatePath(entry.path))
      }
    }
    return issues
  }

  /// A child path is exactly one non-dot path component.
  public static func isValidChildPath(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("/"),
      path != ".", path != ".."
    else { return false }
    return true
  }

  /// Trims every string, fills `title` from the folder name and each
  /// entry's `name` / `path` from the other, and drops entries with neither.
  /// Idempotent. Run after decode and before validate or save.
  public func normalized(rootPath: String) -> WorkspaceManifest {
    var copy = self
    if copy.schemaVersion <= 0 {
      copy.schemaVersion = Self.currentSchemaVersion
    }
    copy.title = copy.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if copy.title.isEmpty {
      let folder = (rootPath as NSString).lastPathComponent
      copy.title = folder.isEmpty ? rootPath : folder
    }
    copy.description = copy.description?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    copy.taskLinks = copy.taskLinks
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    copy.repositories = copy.repositories.compactMap { entry in
      var entry = entry
      entry.name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
      entry.path = entry.path.trimmingCharacters(in: .whitespacesAndNewlines)
      if entry.name.isEmpty { entry.name = entry.path }
      if entry.path.isEmpty { entry.path = entry.name }
      guard !entry.name.isEmpty else { return nil }
      entry.role = entry.role?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      entry.sourceGitRoot = entry.sourceGitRoot?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      entry.remoteURL = entry.remoteURL?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      entry.branch = entry.branch?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      entry.baseRef = entry.baseRef?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      return entry
    }
    return copy
  }
}

// MARK: - Codable (tolerant)

extension WorkspaceManifest: Codable {
  private enum CodingKeys: String, CodingKey {
    case schemaVersion, title, description, taskLinks, repositories, createdAt, updatedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.schemaVersion =
      try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
    self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
    self.description = try container.decodeIfPresent(String.self, forKey: .description)
    self.taskLinks = try container.decodeIfPresent([String].self, forKey: .taskLinks) ?? []
    self.repositories = try container.decodeIfPresent([Entry].self, forKey: .repositories) ?? []
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
    try container.encode(repositories, forKey: .repositories)
    try container.encodeIfPresent(createdAt, forKey: .createdAt)
    try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
  }
}

extension WorkspaceManifest.Entry: Codable {
  private enum CodingKeys: String, CodingKey {
    case name, role, path, sourceGitRoot, remoteURL, checkoutMode, branch, baseRef
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    let path = try container.decodeIfPresent(String.self, forKey: .path)
    self.name = name
    self.path = path ?? name
    self.role = try container.decodeIfPresent(String.self, forKey: .role)
    self.sourceGitRoot = try container.decodeIfPresent(String.self, forKey: .sourceGitRoot)
    self.remoteURL = try container.decodeIfPresent(String.self, forKey: .remoteURL)
    // An unknown mode written by a newer build reads as "not recorded"
    // rather than failing the whole manifest.
    self.checkoutMode = try container.decodeIfPresent(String.self, forKey: .checkoutMode)
      .flatMap(WorkspaceManifest.CheckoutMode.init(rawValue:))
    self.branch = try container.decodeIfPresent(String.self, forKey: .branch)
    self.baseRef = try container.decodeIfPresent(String.self, forKey: .baseRef)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(name, forKey: .name)
    try container.encodeIfPresent(role, forKey: .role)
    try container.encode(path, forKey: .path)
    try container.encodeIfPresent(sourceGitRoot, forKey: .sourceGitRoot)
    try container.encodeIfPresent(remoteURL, forKey: .remoteURL)
    try container.encodeIfPresent(checkoutMode, forKey: .checkoutMode)
    try container.encodeIfPresent(branch, forKey: .branch)
    try container.encodeIfPresent(baseRef, forKey: .baseRef)
  }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
