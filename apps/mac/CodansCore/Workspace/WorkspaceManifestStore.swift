import Foundation

/// Reads and writes `<root>/.codans/workspace.json`.
///
/// Pure filesystem work, no subprocesses, so callers may use it off the main
/// actor. `hasManifest` is a single `stat` and is the only call the catalog
/// load path makes — it decides whether a project is a workspace without
/// decoding anything.
public nonisolated enum WorkspaceManifestStore {
  public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
    case missing(path: String)
    case malformed(path: String, reason: String)
    case invalid(path: String, issues: [WorkspaceManifest.ValidationIssue])

    public var description: String {
      switch self {
      case .missing(let path):
        return "workspace manifest not found at \(path)"
      case .malformed(let path, let reason):
        return "workspace manifest at \(path) could not be read: \(reason)"
      case .invalid(let path, let issues):
        return "workspace manifest at \(path) is invalid: "
          + issues.map(\.description).joined(separator: "; ")
      }
    }
  }

  public static func hasManifest(rootPath: String) -> Bool {
    FileManager.default.fileExists(
      atPath: WorkspaceLayout.manifestURL(rootPath: rootPath).path(percentEncoded: false))
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
