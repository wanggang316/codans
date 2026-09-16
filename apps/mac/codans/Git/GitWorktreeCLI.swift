import ComposableArchitecture
import Foundation

nonisolated struct GitWorktreeEntry: Equatable, Sendable {
  let path: String
  let branch: String?
  let head: String
}

/// What a candidate source path is, git-wise. See
/// `GitWorktreeCLI.inspectRepository(at:)`.
nonisolated struct RepositoryProbe: Equatable, Sendable {
  /// Repository root: the folder holding `.git` for a normal repository,
  /// the directory itself for a bare one. Not canonicalized.
  let root: String
  let isBare: Bool
}

enum GitCLIError: Error, Equatable, Sendable {
  case exitCode(Int32, stderr: String)
  case executableNotFound
  case invalidUTF8
}

actor GitWorktreeCLI {
  private let gitExecutable: URL

  init(gitExecutable: URL = URL(fileURLWithPath: "/usr/bin/git")) {
    self.gitExecutable = gitExecutable
  }

  func listWorktrees(repoPath: String) throws -> [GitWorktreeEntry] {
    let output = try run(arguments: ["worktree", "list", "--porcelain"], cwd: repoPath)
    return parseWorktreeList(output)
  }

  func createWorktree(repoPath: String, branch: String, path: String) throws {
    _ = try run(
      arguments: ["worktree", "add", "-b", branch, path],
      cwd: repoPath
    )
  }

  func removeWorktree(repoPath: String, path: String, force: Bool) throws {
    var args = ["worktree", "remove"]
    if force { args.append("--force") }
    args.append(path)
    _ = try run(arguments: args, cwd: repoPath)
  }

  func listBranches(repoPath: String) throws -> [String] {
    let output = try run(
      arguments: ["for-each-ref", "--format=%(refname:short)", "refs/heads"],
      cwd: repoPath
    )
    return output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
  }

  func discoverGitRoot(candidatePath: String) throws -> String? {
    do {
      let output = try run(arguments: ["rev-parse", "--show-toplevel"], cwd: candidatePath)
      let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    } catch GitCLIError.exitCode {
      return nil
    }
  }

  /// Short name of the branch checked out at `path`; nil on a detached HEAD
  /// or when `path` is not inside a repository (both are non-zero exits).
  func currentBranch(path: String) throws -> String? {
    do {
      let output = try run(arguments: ["symbolic-ref", "--short", "HEAD"], cwd: path)
      let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    } catch GitCLIError.exitCode {
      return nil
    }
  }

  /// Root of the repository the checkout at `path` belongs to — for a linked
  /// worktree that is the *source* repository, not the checkout itself, which
  /// is what `--show-toplevel` would report. Read from the common git dir:
  /// `<source>/.git` for a normal repository, the directory itself for a bare
  /// one. Nil when `path` is not inside a repository.
  func repositoryRoot(forCheckoutAt path: String) throws -> String? {
    do {
      let output = try run(
        arguments: ["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd: path)
      let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      let url = URL(fileURLWithPath: trimmed, isDirectory: true)
      return url.lastPathComponent == ".git"
        ? url.deletingLastPathComponent().path(percentEncoded: false)
        : url.path(percentEncoded: false)
    } catch GitCLIError.exitCode {
      return nil
    }
  }

  /// Classifies `path` as a repository source: its root — the checkout's own
  /// root for a normal repository, the *source* repository for a linked
  /// worktree, the directory itself for a bare repository — and whether it
  /// is bare. Nil when `path` is not inside any repository.
  /// `discoverGitRoot` cannot answer this for a bare repository, whose
  /// `--show-toplevel` has no working tree to report.
  func inspectRepository(at path: String) throws -> RepositoryProbe? {
    guard let root = try repositoryRoot(forCheckoutAt: path) else { return nil }
    do {
      let output = try run(arguments: ["rev-parse", "--is-bare-repository"], cwd: path)
      let isBare = output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
      return RepositoryProbe(root: root, isBare: isBare)
    } catch GitCLIError.exitCode {
      return nil
    }
  }

  /// Clones `remoteURL` into `destinationPath`. The destination's parent
  /// directory is created if missing (git itself won't make intermediate
  /// parents) and used as the working directory; git creates the final
  /// leaf. Throws `GitCLIError.exitCode` carrying git's stderr on failure
  /// (bad URL, auth, existing non-empty dir) so callers can surface the
  /// reason verbatim.
  func clone(remoteURL: String, destinationPath: String) throws {
    let destination = URL(fileURLWithPath: destinationPath)
    let parent = destination.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    _ = try run(
      arguments: ["clone", remoteURL, destinationPath],
      cwd: parent.path
    )
  }

  // MARK: - Private

  private func run(arguments: [String], cwd: String) throws -> String {
    let process = Process()
    process.executableURL = gitExecutable
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
      try process.run()
    } catch {
      throw GitCLIError.executableNotFound
    }

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard let stdout = String(data: stdoutData, encoding: .utf8),
      let stderr = String(data: stderrData, encoding: .utf8)
    else {
      throw GitCLIError.invalidUTF8
    }

    if process.terminationStatus != 0 {
      throw GitCLIError.exitCode(process.terminationStatus, stderr: stderr)
    }
    return stdout
  }

  private func parseWorktreeList(_ output: String) -> [GitWorktreeEntry] {
    var entries: [GitWorktreeEntry] = []
    var currentPath: String?
    var currentHead: String?
    var currentBranch: String?

    for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty {
        if let path = currentPath, let head = currentHead {
          entries.append(GitWorktreeEntry(path: path, branch: currentBranch, head: head))
        }
        currentPath = nil
        currentHead = nil
        currentBranch = nil
        continue
      }

      if trimmed.hasPrefix("worktree ") {
        currentPath = String(trimmed.dropFirst("worktree ".count))
      } else if trimmed.hasPrefix("HEAD ") {
        currentHead = String(trimmed.dropFirst("HEAD ".count))
      } else if trimmed.hasPrefix("branch ") {
        let ref = String(trimmed.dropFirst("branch ".count))
        currentBranch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
      } else if trimmed == "detached" {
        currentBranch = nil
      }
    }
    if let path = currentPath, let head = currentHead {
      entries.append(GitWorktreeEntry(path: path, branch: currentBranch, head: head))
    }
    return entries
  }
}

// MARK: - Dependency injection

extension GitWorktreeCLI: DependencyKey {
  /// Single shared actor instance; `GitWorktreeCLI` wraps the system `git`
  /// binary with no per-instance state (the actor just serializes subprocess
  /// invocations). Used today by `HierarchySidebarFeature`'s Add Project
  /// flow for add-time gitRoot classification — reconcile-time worktree
  /// enumeration is owned by `HierarchyClient.reconcileDiscoveredWorktrees`
  /// and does not go through this dependency.
  static let liveValue = GitWorktreeCLI()

  /// Tests that touch `discoverGitRoot` typically do so against a real
  /// temp-dir `git init` fixture, so the "test" CLI is the same live actor
  /// — subprocess calls are deterministic and quick enough. Tests that need
  /// to avoid `/usr/bin/git` altogether can override the dependency at the
  /// `TestStore` scope.
  static let testValue = GitWorktreeCLI()
}

extension DependencyValues {
  var gitWorktreeCLI: GitWorktreeCLI {
    get { self[GitWorktreeCLI.self] }
    set { self[GitWorktreeCLI.self] = newValue }
  }
}
