import Foundation

/// Files of a repository that a new worktree will not have. Skill
/// completion for a worktree that does not exist yet reads the main
/// checkout instead, so it skips these files (design doc: Agent Skill
/// Completion → New Worktree Files).
///
/// The worktree gets the tracked files, plus the ignored and the untracked
/// files that its copy options copy. The others are listed here.
public nonisolated struct ProjectFileExclusion: Equatable, Sendable {
  /// The main checkout the paths are relative to.
  public let root: URL
  /// Paths relative to `root`. A path that ends with `/` is a directory and
  /// excludes everything in it. A path without `/` excludes what is under it
  /// too: git lists a symlink to a directory as a file, and the new worktree
  /// does not have the files reached through it. `nil` excludes every file
  /// under `root`: codans could not list the files, so it does not guess.
  public let paths: Set<String>?

  public init(root: URL, paths: Set<String>?) {
    self.root = root.standardizedFileURL
    self.paths = paths
  }

  /// `true` when the new worktree will not have `url`. A file outside
  /// `root` is never excluded.
  ///
  /// The new worktree has a tracked symlink, but not always its target. So
  /// the path is resolved one component at a time, as the system does, and
  /// every path inside `root` it passes through is checked (ADR 0010). A
  /// relative symlink that leaves `root` excludes the file: from the new
  /// worktree, which is in another directory, it points somewhere else. So
  /// does a symlink loop.
  public func excludes(_ url: URL) -> Bool {
    // Not `standardizedFileURL`: it can resolve symlinks, which would skip
    // the checks below. The walk handles `.` and `..` itself.
    guard let (base, relative) = split(url.absoluteURL.path(percentEncoded: false)) else {
      return false
    }
    guard let paths else { return true }
    var resolved: [Substring] = []
    var pending = relative.split(separator: "/")[...]
    var hops = 0
    while let component = pending.popFirst() {
      switch component {
      case ".":
        continue
      case "..":
        // Only real directories are in `resolved`, so `..` is their parent.
        guard resolved.popLast() != nil else { return true }
        continue
      default:
        resolved.append(component)
      }
      let path = resolved.joined(separator: "/")
      // A listed file or directory, or a listed symlink, covers what is
      // reached through it.
      if paths.contains(path) || paths.contains(path + "/") { return true }
      guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: base + path)
      else { continue }
      hops += 1
      guard hops <= Self.maxSymlinkHops else { return true }
      resolved.removeLast()
      if destination.hasPrefix("/") {
        guard let (_, inside) = split(destination) else { return false }
        resolved = []
        pending = inside.split(separator: "/") + pending
      } else {
        pending = destination.split(separator: "/") + pending
      }
    }
    return false
  }

  private static let maxSymlinkHops = 32

  /// `root` as given, as Foundation resolves it, and as the system
  /// resolves it, each with a trailing `/`. A path or a symlink target can
  /// name the root any of these ways: Foundation drops a leading `/private`
  /// that `realpath` keeps.
  private var bases: [String] {
    let given = root.path(percentEncoded: false)
    let real = realpath(given, nil).map { pointer in
      defer { free(pointer) }
      return String(cString: pointer)
    }
    return Set([given, root.resolvingSymlinksInPath().path(percentEncoded: false), real].compactMap { $0 })
      .map { $0.hasSuffix("/") ? $0 : $0 + "/" }
      .sorted { $0.count > $1.count }
  }

  /// The base `path` is under and the path relative to it, or `nil` when
  /// `path` is outside `root`.
  private func split(_ path: String) -> (base: String, relative: Substring)? {
    for base in bases where path.hasPrefix(base) {
      return (base, Substring(path.dropFirst(base.count)))
    }
    return nil
  }
}
