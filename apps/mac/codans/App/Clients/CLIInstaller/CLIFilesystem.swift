import Foundation

/// A narrow wrapper over the subset of `FileManager` operations `CLIInstallerClient`
/// needs. Injectable so tests can substitute an in-memory fake.
///
/// Scoped to the CLI installer domain today; promote out of `CLIInstaller/` if a
/// second feature adopts it. Previously lived in the (now-deleted) Skill subsystem
/// as `SkillFileSystem` — renamed and relocated when PR #15 decoupled Skill from
/// the engineering tree so nothing in the code path keeps a "skill" prefix.
public protocol CLIFilesystem: Sendable {
  func fileExists(atPath path: String) -> Bool
  func isDirectory(atPath path: String) -> Bool
  func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws
  func copyItem(at src: URL, to dst: URL) throws
  func removeItem(at url: URL) throws
  func createSymbolicLink(at url: URL, withDestinationURL dst: URL) throws
  func destinationOfSymbolicLink(atPath path: String) throws -> String
  func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any]
  func contents(atPath path: String) -> Data?
  func subpathsOfDirectory(at url: URL) throws -> [String]
  func writeData(_ data: Data, to url: URL) throws
}

/// Live `FileManager.default`-backed implementation.
public nonisolated struct RealCLIFilesystem: CLIFilesystem {
  public init() {}

  public func fileExists(atPath path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
  }

  public func isDirectory(atPath path: String) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
  }

  public func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: withIntermediateDirectories
    )
  }

  public func copyItem(at src: URL, to dst: URL) throws {
    try FileManager.default.copyItem(at: src, to: dst)
  }

  public func removeItem(at url: URL) throws {
    try FileManager.default.removeItem(at: url)
  }

  public func createSymbolicLink(at url: URL, withDestinationURL dst: URL) throws {
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: dst)
  }

  public func destinationOfSymbolicLink(atPath path: String) throws -> String {
    try FileManager.default.destinationOfSymbolicLink(atPath: path)
  }

  public func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
    try FileManager.default.attributesOfItem(atPath: path)
  }

  public func contents(atPath path: String) -> Data? {
    FileManager.default.contents(atPath: path)
  }

  public func subpathsOfDirectory(at url: URL) throws -> [String] {
    try FileManager.default.subpathsOfDirectory(atPath: url.path).sorted()
  }

  public func writeData(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
  }
}
