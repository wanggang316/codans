import CodansCore
import Foundation

/// A view of the project files a new worktree will have, for skill
/// completion before the worktree exists (ADR 0010). `wt` creates the
/// worktree from the tracked files of a ref and copies the ignored
/// (`--copy-ignored`) and the untracked (`--copy-untracked`) files of the
/// main checkout only when asked. The view holds the same files under the
/// paths skill completion reads (`SkillLocationResolver.projectFilePaths`):
/// the tracked ones from the ref, the copied ones from the main checkout.
/// A symlink in the view whose target is elsewhere in the repository gets
/// that target too, by the same rules.
nonisolated enum NewWorktreeFiles {
  /// Symlink targets are followed this many rounds; a deeper chain stays
  /// dangling, so its skill is not offered.
  private static let maxSymlinkRounds = 8

  /// A new directory with the view, or `nil` when git fails (then no
  /// project file can be trusted). `paths` outside the repository are
  /// left out. The caller removes the directory.
  static func makeView(
    repoRoot: URL, ref: String, copyIgnored: Bool, copyUntracked: Bool, paths: [String],
  ) async -> URL? {
    let view = FileManager.default.temporaryDirectory
      .appending(path: "codans-new-worktree-\(UUID().uuidString)", directoryHint: .isDirectory)
    do {
      try FileManager.default.createDirectory(at: view, withIntermediateDirectories: true)
    } catch {
      return nil
    }
    let source = Source(
      repoRoot: repoRoot, ref: ref, copyIgnored: copyIgnored, copyUntracked: copyUntracked, )
    // git refuses a path outside the repository, and the new worktree's
    // place relative to such a path is unknown anyway.
    var pending = paths.compactMap(SkillLocationResolver.pathInside)
    var done = Set<String>()
    for _ in 0...maxSymlinkRounds {
      pending = pending.filter { done.insert($0).inserted }
      guard !pending.isEmpty else { break }
      guard await source.materialize(pending, into: view) else {
        try? FileManager.default.removeItem(at: view)
        return nil
      }
      pending = danglingTargets(in: view)
    }
    return view
  }

  private struct Source {
    let repoRoot: URL
    let ref: String
    let copyIgnored: Bool
    let copyUntracked: Bool

    /// Puts what the new worktree has under `paths` into `view`.
    func materialize(_ paths: [String], into view: URL) async -> Bool {
      guard let tracked = await git(["ls-tree", "-r", "-z", "--name-only", ref, "--"] + paths) else {
        return false
      }
      let files = NewWorktreeFiles.parse(tracked)
      if !files.isEmpty {
        // Check the files out of the ref through a private index, as
        // `git worktree add` does. `git archive` would apply the
        // `export-ignore` and `export-subst` attributes.
        let index = view.deletingLastPathComponent()
          .appending(path: "\(view.lastPathComponent).index", directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: index) }
        let indexEnvironment = "GIT_INDEX_FILE=\(index.path(percentEncoded: false))"
        guard await git(["read-tree", ref], environment: indexEnvironment) != nil,
          await git(
            ["checkout-index", "-f", "--prefix=\(view.path(percentEncoded: false))/", "--"] + files.sorted(),
            environment: indexEnvironment) != nil
        else { return false }
      }
      if copyIgnored {
        guard await copy(["--ignored"], paths, into: view) else { return false }
      }
      if copyUntracked {
        guard await copy([], paths, into: view) else { return false }
      }
      return true
    }

    /// Copies the main checkout's untracked files under `paths`, or its
    /// ignored ones with `--ignored`. These are the `git ls-files` lists
    /// `wt` copies; a symlink is copied as a symlink. Like `wt` without
    /// `--force`, a copy never replaces a path the view already has: a file
    /// the ref tracks stays the ref's.
    private func copy(_ extra: [String], _ paths: [String], into view: URL) async -> Bool {
      guard
        let output = await git(
          ["ls-files", "--others"] + extra + ["--exclude-standard", "-z", "--"] + paths)
      else { return false }
      let fileManager = FileManager.default
      for file in NewWorktreeFiles.parse(output) {
        let target = view.appending(path: file, directoryHint: .notDirectory)
        let targetPath = target.path(percentEncoded: false)
        guard (try? fileManager.destinationOfSymbolicLink(atPath: targetPath)) == nil,
          !fileManager.fileExists(atPath: targetPath)
        else { continue }
        do {
          try fileManager.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
          try fileManager.copyItem(at: repoRoot.appending(path: file, directoryHint: .notDirectory), to: target)
        } catch {
          return false
        }
      }
      return true
    }

    /// Paths are literal, not patterns: a file name may hold `*` or `[`.
    /// `environment` is one `NAME=value` for git alone.
    private func git(_ arguments: [String], environment: String? = nil) async -> Data? {
      let git = ["--literal-pathspecs", "-C", repoRoot.path(percentEncoded: false)] + arguments
      guard let environment else { return await run(GitWorktreeShell.gitURL, git) }
      return await run(
        URL(fileURLWithPath: "/usr/bin/env"), [environment, GitWorktreeShell.gitURL.path(percentEncoded: false)] + git)
    }

    private func run(_ executable: URL, _ arguments: [String]) async -> Data? {
      let outcome = await GitWorktreeShell.run(executable: executable, arguments: arguments, cwd: repoRoot)
      guard case .exited(0, let stdout, _, false) = outcome else { return nil }
      return stdout
    }
  }

  /// Targets, relative to `view`, of the relative symlinks in `view` that
  /// point to a missing path inside it. A target outside the view is left
  /// alone: from the new worktree it points outside the repository.
  static func danglingTargets(in view: URL) -> [String] {
    let fileManager = FileManager.default
    let base =
      view.path(percentEncoded: false).hasSuffix("/")
      ? view.path(percentEncoded: false) : view.path(percentEncoded: false) + "/"
    guard let enumerator = fileManager.enumerator(atPath: base) else { return [] }
    var targets: [String] = []
    while let relative = enumerator.nextObject() as? String {
      guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: base + relative),
        !destination.hasPrefix("/"),
        let target = SkillLocationResolver.pathInside(
          (relative.split(separator: "/").dropLast() + [Substring(destination)]).joined(separator: "/"))
      else { continue }
      if !fileManager.fileExists(atPath: base + target) { targets.append(target) }
    }
    return targets
  }

  static func parse(_ output: Data) -> Set<String> {
    Set(
      GitWorktreeShell.decodeUTF8(output).split(separator: "\0").map(String.init)
        .filter { !$0.hasPrefix(".git/") })
  }
}
