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
  /// git ran past its deadline, or the calling task was cancelled; the
  /// runner stopped it and what it started.
  case timedOut
}

actor GitWorktreeCLI {
  /// Local commands answer at once; a hung one must not block its caller.
  static let defaultTimeout: Duration = .seconds(60)
  /// A clone transfers the whole repository and may wait on a credential
  /// helper; bounded so a hung rc or network cannot wait forever.
  static let cloneTimeout: Duration = .seconds(30 * 60)
  static let maxOutputBytes = 4 * 1024 * 1024

  private let gitExecutable: URL
  private let runner: any CommandRunner
  private let parentEnvironment: [String: String]
  /// Per destination, a task that ends when the last clone started there has
  /// finished, cleanup included. See `clone(remoteURL:destinationPath:)`.
  private var cloneTails: [String: Task<Void, Never>] = [:]

  init(
    gitExecutable: URL = URL(fileURLWithPath: "/usr/bin/git"),
    runner: any CommandRunner = FoundationCommandRunner(),
    parentEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.gitExecutable = gitExecutable
    self.runner = runner
    self.parentEnvironment = parentEnvironment
  }

  func listWorktrees(repoPath: String) async throws -> [GitWorktreeEntry] {
    let output = try await run(arguments: ["worktree", "list", "--porcelain"], cwd: repoPath)
    return parseWorktreeList(output)
  }

  func createWorktree(repoPath: String, branch: String, path: String) async throws {
    _ = try await run(
      arguments: ["worktree", "add", "-b", branch, path],
      cwd: repoPath
    )
  }

  func removeWorktree(repoPath: String, path: String, force: Bool) async throws {
    var args = ["worktree", "remove"]
    if force { args.append("--force") }
    args.append(path)
    _ = try await run(arguments: args, cwd: repoPath)
  }

  func listBranches(repoPath: String) async throws -> [String] {
    let output = try await run(
      arguments: ["for-each-ref", "--format=%(refname:short)", "refs/heads"],
      cwd: repoPath
    )
    return output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
  }

  func discoverGitRoot(candidatePath: String) async throws -> String? {
    do {
      let output = try await run(arguments: ["rev-parse", "--show-toplevel"], cwd: candidatePath)
      let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    } catch GitCLIError.exitCode {
      return nil
    }
  }

  /// Short name of the branch checked out at `path`; nil on a detached HEAD
  /// or when `path` is not inside a repository (both are non-zero exits).
  func currentBranch(path: String) async throws -> String? {
    do {
      let output = try await run(arguments: ["symbolic-ref", "--short", "HEAD"], cwd: path)
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
  func repositoryRoot(forCheckoutAt path: String) async throws -> String? {
    do {
      let output = try await run(
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
  func inspectRepository(at path: String) async throws -> RepositoryProbe? {
    guard let root = try await repositoryRoot(forCheckoutAt: path) else { return nil }
    do {
      let output = try await run(arguments: ["rev-parse", "--is-bare-repository"], cwd: path)
      let isBare = output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
      return RepositoryProbe(root: root, isBare: isBare)
    } catch GitCLIError.exitCode {
      return nil
    }
  }

  /// Fetch URL of `remote` in the repository at `repoPath`; nil when the
  /// remote is not configured or `repoPath` is not a repository.
  func remoteURL(repoPath: String, remote: String = "origin") async throws -> String? {
    do {
      let output = try await run(arguments: ["remote", "get-url", remote], cwd: repoPath)
      let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
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
  ///
  /// On failure, timeout, or cancellation the destination is removed when
  /// this clone created it: git cleans up on SIGTERM, but a git killed after
  /// the grace period leaves its partial checkout behind. A destination that
  /// existed before stays.
  ///
  /// Ownership comes from creating the destination, not from checking for
  /// it: `mkdir` fails when the path exists, so no other process can create
  /// it between the check and the clone. git clones into the empty
  /// directory as it would into a missing one.
  ///
  /// Clones into one destination run one after another: a retry started
  /// while a cancelled clone is still stopping waits for its cleanup, so that
  /// cleanup cannot remove the retry's checkout.
  func clone(remoteURL: String, destinationPath: String) async throws {
    let destination = URL(fileURLWithPath: destinationPath)
    let key = destination.standardizedFileURL.path
    let previous = cloneTails[key]
    let (finished, finish) = AsyncStream<Never>.makeStream()
    let tail = Task {
      await previous?.value
      for await _ in finished {}
    }
    cloneTails[key] = tail
    defer {
      finish.finish()
      if cloneTails[key] == tail { cloneTails[key] = nil }
    }
    await previous?.value
    // Cancelled while waiting: stop before touching the destination.
    if Task.isCancelled { throw GitCLIError.timedOut }

    let parent = destination.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    // Any failure (the path exists, no permission) leaves it unowned; git
    // then reports the reason.
    let createdDestination = mkdir(destinationPath, 0o777) == 0
    do {
      _ = try await run(
        arguments: ["clone", remoteURL, destinationPath],
        cwd: parent.path,
        timeout: Self.cloneTimeout
      )
    } catch {
      if createdDestination {
        try? FileManager.default.removeItem(at: destination)
      }
      throw error
    }
  }

  /// Returns when every clone started into `destinationPath` has finished,
  /// cleanup included.
  func waitForClones(at destinationPath: String) async {
    let key = URL(fileURLWithPath: destinationPath).standardizedFileURL.path
    await cloneTails[key]?.value
  }

  // MARK: - Private

  /// Runs git through the shared `CommandRunner`, started as `GitLaunch`
  /// chooses: `clone` through the user's login shell, so a credential helper
  /// given by bare name resolves as it does in a terminal; local commands
  /// directly, retried once in the login shell when they report a missing
  /// command. The environment is `GitProcessEnv.inheriting`. A timeout or a
  /// cancelled caller stops git and what it started.
  private func run(
    arguments: [String], cwd: String, timeout: Duration = GitWorktreeCLI.defaultTimeout
  ) async throws -> String {
    let outcome = await runner.run(
      executable: gitExecutable,
      arguments: arguments,
      env: GitProcessEnv.inheriting(from: parentEnvironment),
      cwd: URL(fileURLWithPath: cwd, isDirectory: true),
      timeout: timeout,
      maxOutputBytes: Self.maxOutputBytes,
      launch: GitLaunch.mode(for: arguments)
    )
    switch outcome {
    case .exited(let code, let stdoutData, let stderrData, _):
      guard let stdout = String(data: stdoutData, encoding: .utf8),
        let stderr = String(data: stderrData, encoding: .utf8)
      else {
        throw GitCLIError.invalidUTF8
      }
      guard code == 0 else { throw GitCLIError.exitCode(code, stderr: stderr) }
      return stdout
    case .timedOut:
      throw GitCLIError.timedOut
    case .spawnFailed:
      throw GitCLIError.executableNotFound
    }
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
  /// binary with no per-instance state (the shared runner bounds concurrent
  /// subprocesses). Used today by `HierarchySidebarFeature`'s Add Project
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
