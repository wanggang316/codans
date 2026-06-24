import Foundation
import Testing

@testable import Codans

/// End-to-end test against a real temp git repo + the bundled `wt`
/// script. Exercises the full worktree lifecycle — create via
/// `createWorktreeStream`, list via `lsWorktrees`, safe-remove,
/// force-remove after dirtying the tree, plus the uncommittedChanges
/// error path.
///
/// Uses Swift Testing's `.enabled(if:)` trait so hosts that haven't
/// run `embed-git-wt.sh` (unbundled `wt`) see these tests as
/// *skipped* rather than red failures. The predicate is evaluated at
/// test discovery time — mirrors the pattern in
/// `LiveGitServiceIntegrationTests.swift`.
/// The app build's Tuist pre-script (`verify-git-wt.sh`) keeps the
/// bundled case the default.
@MainActor
struct WorktreeLifecycleIntegrationTests {
  private let fm = FileManager.default

  // `nonisolated` so Swift Testing's `.enabled(if:)` trait (a Sendable
  // context evaluated at test discovery) can read it even though the
  // enclosing struct is @MainActor.
  nonisolated static let wtBundled: Bool = {
    Bundle.main.url(forResource: "wt", withExtension: nil, subdirectory: "git-wt") != nil
  }()

  private func makeTempRepo() throws -> URL {
    let base = fm.temporaryDirectory
      .appending(path: "codans-wt-\(UUID().uuidString)", directoryHint: .isDirectory)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    // git init + initial commit so `wt sw --from HEAD` has something to branch from.
    try runGit(["init", "-q", "-b", "main"], cwd: base)
    try runGit(["config", "user.email", "test@example.com"], cwd: base)
    try runGit(["config", "user.name", "test"], cwd: base)
    try "hello".write(
      to: base.appending(path: "README.md"), atomically: true, encoding: .utf8
    )
    try runGit(["add", "README.md"], cwd: base)
    try runGit(["commit", "-q", "-m", "init"], cwd: base)
    return base
  }

  private func runGit(_ args: [String], cwd: URL) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = args
    p.currentDirectoryURL = cwd
    p.environment = ProcessInfo.processInfo.environment
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    if p.terminationStatus != 0 {
      throw CocoaError(.fileWriteUnknown)
    }
  }

  @Test(.enabled(if: WorktreeLifecycleIntegrationTests.wtBundled))
  func fullLifecycle() async throws {
    let repo = try makeTempRepo()
    defer { try? fm.removeItem(at: repo) }

    let client = GitWorktreeClient.makeLive()

    // Create a worktree via the streaming path.
    let baseDir = repo.appending(path: ".worktrees", directoryHint: .isDirectory)
    try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
    let spec = CreateWorktreeSpec(
      repoRoot: repo,
      baseDirectory: baseDir,
      name: "feature-a",
      baseRef: "HEAD",
      fetchOrigin: false,
      copyIgnored: false,
      copyUntracked: false
    )
    var createdPath: URL?
    for try await event in client.createWorktreeStream(spec) {
      if case .finished(let path) = event { createdPath = path }
    }
    let worktreePath = try #require(createdPath)
    #expect(fm.fileExists(atPath: worktreePath.path(percentEncoded: false)))

    // List — should include main + feature-a, neither bare.
    let entries = try await client.lsWorktrees(repo)
    #expect(entries.count == 2)
    #expect(entries.allSatisfy { !$0.isBare })
    #expect(entries.contains(where: { $0.branch == "feature-a" }))

    // Issue #24 (c): the returned path must be a real entry in
    // `wt ls --json`, not something parsed from stray stdout. The
    // diff-based picker guarantees this invariant; a regression
    // would trigger this #expect.
    #expect(
      entries.contains(where: {
        URL(fileURLWithPath: $0.path).standardizedFileURL == worktreePath
      }))

    // Remove the clean worktree.
    try await client.removeWorktree(repo, worktreePath)
    let afterRemove = try await client.lsWorktrees(repo)
    #expect(afterRemove.count == 1)
  }

  /// `GitWorktreeClient.removeWorktree` uses a relocate-then-prune
  /// strategy: the working directory is moved into a per-process trash
  /// folder before `git worktree prune --expire=now` cleans the metadata,
  /// so git's "modified or untracked files" guard never trips. The Remove
  /// flow is single-step destructive (UI's first confirmation is the only
  /// gate); this test pins that behavior.
  @Test(.enabled(if: WorktreeLifecycleIntegrationTests.wtBundled))
  func removeSucceedsEvenWithUncommittedChanges() async throws {
    let repo = try makeTempRepo()
    defer { try? fm.removeItem(at: repo) }

    let client = GitWorktreeClient.makeLive()
    let baseDir = repo.appending(path: ".worktrees", directoryHint: .isDirectory)
    try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
    let spec = CreateWorktreeSpec(
      repoRoot: repo,
      baseDirectory: baseDir,
      name: "dirty",
      baseRef: "HEAD",
      fetchOrigin: false,
      copyIgnored: false,
      copyUntracked: false
    )
    var createdPath: URL?
    for try await event in client.createWorktreeStream(spec) {
      if case .finished(let path) = event { createdPath = path }
    }
    let worktreePath = try #require(createdPath)

    let dirty = worktreePath.appending(path: "uncommitted.txt")
    try "x".write(to: dirty, atomically: true, encoding: .utf8)
    try runGit(["add", "uncommitted.txt"], cwd: worktreePath)

    try await client.removeWorktree(repo, worktreePath)
    #expect(!fm.fileExists(atPath: worktreePath.path(percentEncoded: false)))
    let after = try await client.lsWorktrees(repo)
    #expect(!after.contains { URL(fileURLWithPath: $0.path).standardizedFileURL == worktreePath })
  }

  /// Exercises issue #24 (a) — cancelling a `createWorktreeStream`
  /// consumer must terminate the spawned `wt` child. The invariant we
  /// test is the direct one master called out: "cancel 后 Process 不
  /// 再活着". We capture a weak reference to the `wt` Process via the
  /// `onCreateWorktreeSpawn` seam on `makeLive`, then cancel the
  /// consuming Task and assert `!process.isRunning` within a short
  /// deadline. No dependency on wt's runtime size, no probing the
  /// filesystem for a partial copy — flake-free.
  @Test(.enabled(if: WorktreeLifecycleIntegrationTests.wtBundled))
  func createStreamCancellationTerminatesWtProcess() async throws {
    let repo = try makeTempRepo()
    defer { try? fm.removeItem(at: repo) }
    let baseDir = repo.appending(path: ".worktrees", directoryHint: .isDirectory)
    try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)

    // Weak box so we don't keep the Process alive beyond natural exit.
    final class WeakProcess: @unchecked Sendable {
      private let lock = NSLock()
      weak var process: Process?
      func capture(_ p: Process) {
        lock.lock()
        process = p
        lock.unlock()
      }
      func isAlive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning ?? false
      }
    }
    let weakBox = WeakProcess()

    let client = GitWorktreeClient.makeLive(
      onCreateWorktreeSpawn: { process in weakBox.capture(process) }
    )

    let spec = CreateWorktreeSpec(
      repoRoot: repo,
      baseDirectory: baseDir,
      name: "cancelled",
      baseRef: "HEAD",
      fetchOrigin: false,
      copyIgnored: false,
      copyUntracked: false
    )

    let consumer = Task<Void, Error> {
      for try await _ in client.createWorktreeStream(spec) {
        // Don't care about events — we just want the stream to start
        // so the Process has been spawned, then we cancel from outside.
      }
    }

    // Wait for wt to actually start (capture() fires immediately
    // before process.run()). 500 ms is generous on this machine;
    // bump if flaky. `weakBox.process` becomes non-nil once onSpawn
    // fires from within `runStream`.
    let spawnDeadline = ContinuousClock.now.advanced(by: .milliseconds(1000))
    while weakBox.process == nil, ContinuousClock.now < spawnDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(weakBox.process != nil, "wt should have spawned")

    consumer.cancel()

    // The real assertion: once cancel propagates through
    // onTermination → processBox.terminateIfRunning(), the wt child
    // exits within SIGTERM's normal window. 2 s is well over the
    // measured time (< 100 ms locally).
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while weakBox.isAlive(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!weakBox.isAlive(), "wt process must be terminated after cancellation")

    // Drain the consumer's failure (CancellationError or similar)
    // so the task leaves cleanly without trip-wiring the Swift
    // Testing harness for unhandled throws.
    _ = try? await consumer.value
  }

  /// Setup-phase sibling of `createStreamCancellationTerminatesWtProcess`:
  /// the cancellation invariant must extend to the setup child too. A
  /// setup script that blocks (`sleep 30`) keeps the run inside the setup
  /// phase; cancelling the consumer must terminate THAT bash child, not
  /// just the already-exited `wt` one — otherwise a cancelled creation
  /// leaks the orphaned setup process.
  ///
  /// `onCreateWorktreeSpawn` fires twice here — once for the `wt sw` child,
  /// once for the setup `bash` child — so we capture the LATEST spawn and
  /// gate on the SECOND fire (`spawnCount >= 2`) to be sure we hold the
  /// setup child, not the wt one, before cancelling.
  @Test(.enabled(if: WorktreeLifecycleIntegrationTests.wtBundled))
  func cancellationTerminatesSetupChild() async throws {
    let repo = try makeTempRepo()
    defer { try? fm.removeItem(at: repo) }
    let baseDir = repo.appending(path: ".worktrees", directoryHint: .isDirectory)
    try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)

    // Weak box that tracks the spawn count (wt child, then setup child) and
    // keeps a weak reference to the LATEST spawned Process. Mirrors the
    // `WeakProcess` helper in `createStreamCancellationTerminatesWtProcess`
    // but adds the count so the test can wait for the SECOND spawn.
    final class WeakSpawnTracker: @unchecked Sendable {
      private let lock = NSLock()
      private weak var latest: Process?
      private var count = 0
      func capture(_ p: Process) {
        lock.lock()
        latest = p
        count += 1
        lock.unlock()
      }
      var spawnCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
      }
      func isLatestAlive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return latest?.isRunning ?? false
      }
    }
    let tracker = WeakSpawnTracker()

    let client = GitWorktreeClient.makeLive(
      onCreateWorktreeSpawn: { process in tracker.capture(process) }
    )

    var spec = CreateWorktreeSpec(
      repoRoot: repo,
      baseDirectory: baseDir,
      name: "setup-cancel",
      baseRef: "HEAD",
      fetchOrigin: false,
      copyIgnored: false,
      copyUntracked: false
    )
    // A blocking setup command keeps the run pinned in the setup phase so the
    // cancel lands while the bash child is alive.
    spec.setupCommand = "sleep 30"

    let consumer = Task<Void, Error> {
      for try await _ in client.createWorktreeStream(spec) {
        // Drain events; we just need the stream to reach the setup phase.
      }
    }

    // Wait for the SECOND spawn (the setup bash child). The wt child spawns
    // first and exits quickly; the setup child is the one we must catch
    // alive. 5 s covers a cold `wt sw` (git worktree add) on this machine.
    let spawnDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    while tracker.spawnCount < 2, ContinuousClock.now < spawnDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(tracker.spawnCount >= 2, "setup bash child should have spawned")
    #expect(tracker.isLatestAlive(), "setup child should be alive before cancel")

    consumer.cancel()

    // The real assertion: cancelling propagates through
    // `continuation.onTermination → processBox.terminateIfRunning()`, which
    // now targets the setup child (the latest `set(_:)`). It must exit
    // within SIGTERM's normal window — well under 2 s for `sleep`.
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while tracker.isLatestAlive(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!tracker.isLatestAlive(), "setup child must be terminated after cancellation")

    _ = try? await consumer.value
  }

  /// Best-effort setup: a setup command that exits non-zero must NOT throw
  /// or roll back the worktree. The stream still reaches `.finished` and the
  /// worktree directory exists on disk. Pins the
  /// "setup failure does not abort creation" contract documented on
  /// `CreateWorktreeSpec.setupCommand`.
  @Test(.enabled(if: WorktreeLifecycleIntegrationTests.wtBundled))
  func setupNonZeroExitStillFinishes() async throws {
    let repo = try makeTempRepo()
    defer { try? fm.removeItem(at: repo) }
    let baseDir = repo.appending(path: ".worktrees", directoryHint: .isDirectory)
    try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)

    let client = GitWorktreeClient.makeLive()
    var spec = CreateWorktreeSpec(
      repoRoot: repo,
      baseDirectory: baseDir,
      name: "setup-fail",
      baseRef: "HEAD",
      fetchOrigin: false,
      copyIgnored: false,
      copyUntracked: false
    )
    spec.setupCommand = "exit 7"

    var createdPath: URL?
    var sawSetupPhase = false
    for try await event in client.createWorktreeStream(spec) {
      switch event {
      case .setupPhaseBegan:
        sawSetupPhase = true
      case .finished(let path):
        createdPath = path
      case .progressLine:
        break
      }
    }
    // The setup phase ran (a non-empty command) and the stream still
    // finished despite the non-zero exit — best-effort, no throw.
    #expect(sawSetupPhase, "a non-empty setup command must emit .setupPhaseBegan")
    let worktreePath = try #require(createdPath, "stream must reach .finished")
    #expect(fm.fileExists(atPath: worktreePath.path(percentEncoded: false)))

    try await client.removeWorktree(repo, worktreePath)
  }

  /// An empty / whitespace-only setup command skips the setup phase
  /// entirely: the stream goes straight from `git worktree add` to
  /// `.finished` and NEVER emits `.setupPhaseBegan`. The trim/skip lives in
  /// the git layer (`createWorktreeStream`), which this exercises against a
  /// real `wt`.
  @Test(.enabled(if: WorktreeLifecycleIntegrationTests.wtBundled))
  func emptySetupCommandSkipsSetupPhase() async throws {
    let repo = try makeTempRepo()
    defer { try? fm.removeItem(at: repo) }
    let baseDir = repo.appending(path: ".worktrees", directoryHint: .isDirectory)
    try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)

    let client = GitWorktreeClient.makeLive()
    var spec = CreateWorktreeSpec(
      repoRoot: repo,
      baseDirectory: baseDir,
      name: "no-setup",
      baseRef: "HEAD",
      fetchOrigin: false,
      copyIgnored: false,
      copyUntracked: false
    )
    // Whitespace-only — must be trimmed to empty and skip the phase.
    spec.setupCommand = "   "

    var createdPath: URL?
    var sawSetupPhase = false
    for try await event in client.createWorktreeStream(spec) {
      switch event {
      case .setupPhaseBegan:
        sawSetupPhase = true
      case .finished(let path):
        createdPath = path
      case .progressLine:
        break
      }
    }
    #expect(!sawSetupPhase, "whitespace-only setup command must skip the setup phase")
    let worktreePath = try #require(createdPath, "stream must reach .finished")
    #expect(fm.fileExists(atPath: worktreePath.path(percentEncoded: false)))

    try await client.removeWorktree(repo, worktreePath)
  }

  /// HAN-57: branches with a `/` create nested directories so the
  /// folder layout mirrors the branch hierarchy (e.g. `feature/abc`
  /// becomes `<base>/feature/abc`, not `<base>/feature-abc`). Exercises
  /// the full create → list → remove path against a real `wt` so the
  /// `mkdir -p $(dirname …)` inside `wt sw` is locked in too.
  @Test(.enabled(if: WorktreeLifecycleIntegrationTests.wtBundled))
  func nestedBranchCreatesNestedFolders() async throws {
    let repo = try makeTempRepo()
    defer { try? fm.removeItem(at: repo) }

    let client = GitWorktreeClient.makeLive()
    let baseDir = repo.appending(path: ".worktrees", directoryHint: .isDirectory)
    try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
    let spec = CreateWorktreeSpec(
      repoRoot: repo,
      baseDirectory: baseDir,
      name: "feature/abc",
      baseRef: "HEAD",
      fetchOrigin: false,
      copyIgnored: false,
      copyUntracked: false
    )

    var createdPath: URL?
    for try await event in client.createWorktreeStream(spec) {
      if case .finished(let path) = event { createdPath = path }
    }
    let worktreePath = try #require(createdPath)

    let expected =
      baseDir
      .appending(path: "feature/abc", directoryHint: .isDirectory)
      .standardizedFileURL
    #expect(worktreePath.standardizedFileURL == expected)
    #expect(fm.fileExists(atPath: worktreePath.path(percentEncoded: false)))
    // Parent must be a real intermediate directory, not the flattened
    // `feature-abc` variant.
    let parent = worktreePath.deletingLastPathComponent()
    #expect(parent.lastPathComponent == "feature")
    #expect(fm.fileExists(atPath: parent.path(percentEncoded: false)))

    try await client.removeWorktree(repo, worktreePath)
    #expect(!fm.fileExists(atPath: worktreePath.path(percentEncoded: false)))
  }
}
