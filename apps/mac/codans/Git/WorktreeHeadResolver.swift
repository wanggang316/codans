import Foundation

/// Resolves the on-disk path of the `HEAD` file for a worktree, handling
/// both layouts git uses:
///
/// - **Main checkout:** `<worktree>/.git` is a directory and `HEAD` lives
///   at `<worktree>/.git/HEAD`.
/// - **Linked worktree:** `<worktree>/.git` is a file containing one line
///   `gitdir: <relative-or-absolute-path>` that points at
///   `<repo>/.git/worktrees/<name>/`, where `HEAD` lives.
///
/// Returns `nil` when the worktree path is not a git repo (no `.git` at
/// all) or the gitdir file is malformed. Callers treat `nil` as "no
/// watchable HEAD" and skip the worktree silently.
enum WorktreeHeadResolver {
  static func headURL(for worktreeURL: URL, fileManager: FileManager = .default) -> URL? {
    gitDirURL(for: worktreeURL, fileManager: fileManager)?.appending(path: "HEAD")
  }

  /// The repository's common git directory — where shared refs such as
  /// `refs/remotes/` and `packed-refs` live. Equal to the worktree's own
  /// git dir for a main checkout; for a linked worktree, its git dir names
  /// the common dir in a `commondir` file (usually `../..`).
  static func commonDirURL(for worktreeURL: URL, fileManager: FileManager = .default) -> URL? {
    guard let gitDir = gitDirURL(for: worktreeURL, fileManager: fileManager) else { return nil }
    let pointer = gitDir.appending(path: "commondir")
    guard let contents = try? String(contentsOf: pointer, encoding: .utf8) else {
      return gitDir
    }
    let pathPart = contents.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !pathPart.isEmpty else { return gitDir }
    if pathPart.hasPrefix("/") { return URL(fileURLWithPath: pathPart).standardizedFileURL }
    return gitDir.appending(path: pathPart).standardizedFileURL
  }

  /// The worktree's own git dir: `<worktree>/.git` for a main checkout, the
  /// `gitdir:` target for a linked worktree.
  static func gitDirURL(for worktreeURL: URL, fileManager: FileManager = .default) -> URL? {
    let gitURL = worktreeURL.appending(path: ".git")
    var isDirectory: ObjCBool = false
    guard
      fileManager.fileExists(
        atPath: gitURL.path(percentEncoded: false),
        isDirectory: &isDirectory
      )
    else { return nil }
    if isDirectory.boolValue {
      return gitURL
    }
    // `.git` is a file — parse the `gitdir:` pointer.
    guard let contents = try? String(contentsOf: gitURL, encoding: .utf8) else {
      return nil
    }
    guard let line = contents.split(whereSeparator: \.isNewline).first else {
      return nil
    }
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = "gitdir:"
    guard trimmed.hasPrefix(prefix) else { return nil }
    let pathPart = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !pathPart.isEmpty else { return nil }
    return URL(fileURLWithPath: String(pathPart), relativeTo: worktreeURL)
      .standardizedFileURL
  }
}
