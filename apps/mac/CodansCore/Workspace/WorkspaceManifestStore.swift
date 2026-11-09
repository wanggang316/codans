import Foundation

/// Reads and writes the Workspace manifests: `<root>/.codans/workspace.json`
/// (version 1, read only for migration) and
/// `<root>/.codans/workspace-groups.json` (schema 2).
///
/// Pure filesystem work, no subprocesses, so callers may use it off the main
/// actor. `hasManifest` is at most two `stat`s and is the only call the
/// catalog load path makes — it decides whether a project is a workspace
/// without decoding anything.
public nonisolated enum WorkspaceManifestStore {
  public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
    case missing(path: String)
    case malformed(path: String, reason: String)
    case invalid(path: String, issues: [WorkspaceManifest.ValidationIssue])
    case invalidGroups(path: String, issues: [WorkspaceGroupsManifest.ValidationIssue])
    /// The group manifest declares a schema newer than this build reads.
    case newerSchema(path: String, version: Int)

    public var description: String {
      switch self {
      case .missing(let path):
        return "workspace manifest not found at \(path)"
      case .malformed(let path, let reason):
        return "workspace manifest at \(path) could not be read: \(reason)"
      case .invalid(let path, let issues):
        return "workspace manifest at \(path) is invalid: "
          + issues.map(\.description).joined(separator: "; ")
      case .invalidGroups(let path, let issues):
        return "workspace manifest at \(path) is invalid: "
          + issues.map(\.description).joined(separator: "; ")
      case .newerSchema(let path, let version):
        return "workspace manifest at \(path) uses schema \(version); created by a newer Codans"
      }
    }
  }

  /// True when either manifest exists, so marker repair and add-folder
  /// detection see migrated and unmigrated Workspaces alike.
  public static func hasManifest(rootPath: String) -> Bool {
    let fileManager = FileManager.default
    return fileManager.fileExists(
      atPath: WorkspaceLayout.groupsManifestURL(rootPath: rootPath).path(percentEncoded: false))
      || fileManager.fileExists(
        atPath: WorkspaceLayout.manifestURL(rootPath: rootPath).path(percentEncoded: false))
  }

  /// Loads the group manifest; when only version 1 exists, migrates it and
  /// writes the group manifest. Version 1 is never modified, and never used
  /// as a fallback when the group manifest exists but cannot be used.
  public static func loadOrMigrate(
    rootPath: String,
    pathExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
  ) throws -> WorkspaceGroupsManifest {
    let groupsURL = WorkspaceLayout.groupsManifestURL(rootPath: rootPath)
    if FileManager.default.fileExists(atPath: groupsURL.path(percentEncoded: false)) {
      return try loadGroups(rootPath: rootPath)
    }
    let legacy = try load(rootPath: rootPath)
    let migrated = WorkspaceManifestMigration.migrate(legacy, rootPath: rootPath, pathExists: pathExists)
    let issues = migrated.validate()
    guard issues.isEmpty else {
      throw Failure.invalidGroups(path: groupsURL.path(percentEncoded: false), issues: issues)
    }
    try AtomicFileStore.write(migrated, to: groupsURL, encoder: encoder)
    return migrated
  }

  /// Decodes and validates the group manifest under `rootPath`.
  public static func loadGroups(rootPath: String) throws -> WorkspaceGroupsManifest {
    let url = WorkspaceLayout.groupsManifestURL(rootPath: rootPath)
    let path = url.path(percentEncoded: false)
    let decoded: WorkspaceGroupsManifest?
    do {
      decoded = try AtomicFileStore.read(WorkspaceGroupsManifest.self, at: url, decoder: decoder)
    } catch WorkspaceGroupsManifest.DecodingIssue.newerSchema(let version) {
      throw Failure.newerSchema(path: path, version: version)
    } catch {
      throw Failure.malformed(path: path, reason: String(describing: error))
    }
    guard let decoded else {
      throw Failure.missing(path: path)
    }
    let issues = decoded.validate()
    guard issues.isEmpty else {
      throw Failure.invalidGroups(path: path, issues: issues)
    }
    return decoded
  }

  /// Validates and writes the group manifest atomically, stamping
  /// `updatedAt` (and `createdAt` on first write).
  @discardableResult
  public static func saveGroups(
    _ manifest: WorkspaceGroupsManifest,
    rootPath: String,
    now: Date = Date()
  ) throws -> WorkspaceGroupsManifest {
    let url = WorkspaceLayout.groupsManifestURL(rootPath: rootPath)
    let issues = manifest.validate()
    guard issues.isEmpty else {
      throw Failure.invalidGroups(path: url.path(percentEncoded: false), issues: issues)
    }
    var stamped = manifest
    if stamped.createdAt == nil {
      stamped.createdAt = now
    }
    stamped.updatedAt = now
    try AtomicFileStore.write(stamped, to: url, encoder: encoder)
    return stamped
  }

  /// Decodes, normalizes, and validates the manifest under `rootPath`.
  public static func load(rootPath: String) throws -> WorkspaceManifest {
    let url = WorkspaceLayout.manifestURL(rootPath: rootPath)
    let path = url.path(percentEncoded: false)
    let decoded: WorkspaceManifest?
    do {
      decoded = try AtomicFileStore.read(WorkspaceManifest.self, at: url, decoder: decoder)
    } catch {
      throw Failure.malformed(path: path, reason: String(describing: error))
    }
    guard let decoded else {
      throw Failure.missing(path: path)
    }
    let manifest = decoded.normalized(rootPath: rootPath)
    let issues = manifest.validate()
    guard issues.isEmpty else {
      throw Failure.invalid(path: path, issues: issues)
    }
    return manifest
  }

  /// Writes the normalized manifest atomically, stamping `updatedAt` (and
  /// `createdAt` on first write). Creates `.codans/` when missing.
  @discardableResult
  public static func save(
    _ manifest: WorkspaceManifest,
    rootPath: String,
    now: Date = Date()
  ) throws -> WorkspaceManifest {
    var stamped = manifest.normalized(rootPath: rootPath)
    if stamped.createdAt == nil {
      stamped.createdAt = now
    }
    stamped.updatedAt = now
    try AtomicFileStore.write(
      stamped, to: WorkspaceLayout.manifestURL(rootPath: rootPath), encoder: encoder)
    return stamped
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder.touchCodeDefault
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder.touchCodeDefault
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
