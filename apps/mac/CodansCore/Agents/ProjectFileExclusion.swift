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
  /// excludes everything in it. `nil` excludes every file under `root`:
  /// codans could not list the files, so it does not guess.
  public let paths: Set<String>?

  public init(root: URL, paths: Set<String>?) {
    self.root = root.standardizedFileURL
    self.paths = paths
  }

  /// `true` when the new worktree will not have `url`. A file outside
  /// `root` is never excluded.
  public func excludes(_ url: URL) -> Bool {
    var base = root.path(percentEncoded: false)
    if !base.hasSuffix("/") { base += "/" }
    let path = url.standardizedFileURL.path(percentEncoded: false)
    guard path.hasPrefix(base) else { return false }
    guard let paths else { return true }
    let relative = Substring(path.dropFirst(base.count))
    if paths.contains(String(relative)) { return true }
    // A listed directory covers the files below it.
    var index = relative.startIndex
    while let slash = relative[index...].firstIndex(of: "/") {
      let next = relative.index(after: slash)
      if paths.contains(String(relative[..<next])) { return true }
      index = next
    }
    return false
  }
}
