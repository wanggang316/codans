import Foundation

/// Keeps `<root>/<default>/<name>` symbolic links in step with the source
/// projects of a group manifest, so a group-level agent can reach every
/// source main checkout from the `default` directory.
///
/// Only symbolic links are ever created, replaced, or removed. Any other
/// entry in the directory is left alone and reported, because it may be
/// user data.
public nonisolated enum WorkspaceDefaultLinks {
  public struct Report: Equatable, Sendable {
    public var created: [String] = []
    public var replaced: [String] = []
    public var removed: [String] = []
    /// Entries that are not symbolic links where a link should be, or that
    /// could not be changed, with the reason.
    public var notes: [Note] = []

    public init() {}
  }

  public enum Note: Equatable, Sendable {
    /// A non-link entry occupies a project's link name. Left untouched.
    case notALink(path: String)
    case failed(path: String, reason: String)
  }

  public enum Failure: Error, Equatable, Sendable {
    case noDefaultGroup
    /// The `default` directory is missing and could not be created, or is
    /// not a real directory.
    case defaultDirectoryUnusable(path: String, reason: String)
  }

  @discardableResult
  public static func sync(
    rootPath: String,
    manifest: WorkspaceGroupsManifest,
    fileManager: FileManager = .default
  ) throws -> Report {
    guard let group = manifest.defaultGroup else { throw Failure.noDefaultGroup }
    let directory = URL(fileURLWithPath: rootPath, isDirectory: true)
      .appendingPathComponent(group.path, isDirectory: true)
    try ensureDirectory(directory, fileManager: fileManager)

    var report = Report()
    let wanted = Dictionary(manifest.projects.map { ($0.name, $0.sourceGitRoot) }) { first, _ in first }
    for source in manifest.projects where wanted[source.name] == source.sourceGitRoot {
      let link = directory.appendingPathComponent(source.name)
      syncLink(at: link.path, to: source.sourceGitRoot, report: &report, fileManager: fileManager)
    }

    let entries = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
    for name in entries.sorted() where wanted[name] == nil {
      let path = directory.appendingPathComponent(name).path
      guard destination(ofLinkAt: path, fileManager: fileManager) != nil else { continue }
      do {
        try fileManager.removeItem(atPath: path)
        report.removed.append(path)
      } catch {
        report.notes.append(.failed(path: path, reason: error.localizedDescription))
      }
    }
    return report
  }

  private static func syncLink(
    at path: String,
    to target: String,
    report: inout Report,
    fileManager: FileManager
  ) {
    let exists = (try? fileManager.attributesOfItem(atPath: path)) != nil
    do {
      if !exists {
        try fileManager.createSymbolicLink(atPath: path, withDestinationPath: target)
        report.created.append(path)
        return
      }
      guard let current = destination(ofLinkAt: path, fileManager: fileManager) else {
        report.notes.append(.notALink(path: path))
        return
      }
      guard current != target else { return }
      try fileManager.removeItem(atPath: path)
      try fileManager.createSymbolicLink(atPath: path, withDestinationPath: target)
      report.replaced.append(path)
    } catch {
      report.notes.append(.failed(path: path, reason: error.localizedDescription))
    }
  }

  /// Target of the symbolic link at `path`; `nil` when the entry is not a
  /// symbolic link.
  private static func destination(ofLinkAt path: String, fileManager: FileManager) -> String? {
    guard let attributes = try? fileManager.attributesOfItem(atPath: path),
      attributes[.type] as? FileAttributeType == .typeSymbolicLink
    else { return nil }
    return try? fileManager.destinationOfSymbolicLink(atPath: path)
  }

  private static func ensureDirectory(_ url: URL, fileManager: FileManager) throws {
    let path = url.path
    if let attributes = try? fileManager.attributesOfItem(atPath: path) {
      guard attributes[.type] as? FileAttributeType == .typeDirectory else {
        throw Failure.defaultDirectoryUnusable(path: path, reason: "not a directory")
      }
      return
    }
    do {
      try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
      throw Failure.defaultDirectoryUnusable(path: path, reason: error.localizedDescription)
    }
  }
}
