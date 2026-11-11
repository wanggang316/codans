import Darwin
import Foundation

/// The file reads skill completion makes: the Skill Location walk, the
/// plugin registries, the Pi trust store, and the `SKILL.md` scan. Local
/// projects read this Mac (`LocalSkillFileSystem`); remote projects read
/// the host through a `SkillFileSnapshot` filled over SSH. Paths are
/// absolute paths on the file system the agent runs on.
public nonisolated protocol SkillFileSystem: Sendable {
  /// The bytes of the regular file at `path`, or `nil` when it is missing,
  /// is not a file, or cannot be read. Follows symlinks.
  func contents(atPath path: String) -> Data?
  /// `true` when something is at `path` (file or directory). Follows
  /// symlinks, so a dangling symlink is `false`.
  func fileExists(atPath path: String) -> Bool
  /// The names in the directory at `path`, hidden names included, or `nil`
  /// when it is not a readable directory.
  func contentsOfDirectory(atPath path: String) -> [String]?
  /// The physical path of the directory at `path`, or `nil` when it does
  /// not exist.
  func realPath(_ path: String) -> String?
}

extension SkillFileSystem {
  func contents(of url: URL) -> Data? {
    contents(atPath: url.path(percentEncoded: false))
  }

  func fileExists(at url: URL) -> Bool {
    fileExists(atPath: url.path(percentEncoded: false))
  }

  /// `true` when `directory` holds a `.git` folder or a worktree's `.git`
  /// file.
  func hasGitEntry(_ directory: URL) -> Bool {
    fileExists(at: directory.appending(path: ".git", directoryHint: .notDirectory))
  }
}

/// Reads this Mac.
public nonisolated struct LocalSkillFileSystem: SkillFileSystem {
  public init() {}

  public func contents(atPath path: String) -> Data? {
    FileManager.default.contents(atPath: path)
  }

  public func fileExists(atPath path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
  }

  public func contentsOfDirectory(atPath path: String) -> [String]? {
    try? FileManager.default.contentsOfDirectory(atPath: path)
  }

  public func realPath(_ path: String) -> String? {
    guard let resolved = Darwin.realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }
}
