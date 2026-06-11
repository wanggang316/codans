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
    let gitURL = worktreeURL.appending(path: ".git")
    var isDirectory: ObjCBool = false
    guard
      fileManager.fileExists(
        atPath: gitURL.path(percentEncoded: false),
        isDirectory: &isDirectory
      )
    else { return nil }
    if isDirectory.boolValue {
      return gitURL.appending(path: "HEAD")
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
    let gitdirURL = URL(fileURLWithPath: String(pathPart), relativeTo: worktreeURL)
      .standardizedFileURL
    return gitdirURL.appending(path: "HEAD")
  }
}
