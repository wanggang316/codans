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

    // The returned path must be a real entry in
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

  /// A repository without an `origin` remote has nothing to fetch. "Fetch
  /// origin" defaults on, so the create must skip the fetch rather than
  /// fail on `git fetch origin`.
  @Test(.enabled(if: WorktreeLifecycleIntegrationTests.wtBundled))
  func fetchOriginIsSkippedWithoutAnOriginRemote() async throws {
    let repo = try makeTempRepo()
    defer { try? fm.removeItem(at: repo) }

    let client = GitWorktreeClient.makeLive()
    let baseDir = repo.appending(path: ".worktrees", directoryHint: .isDirectory)
    try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
    let spec = CreateWorktreeSpec(
      repoRoot: repo,
      baseDirectory: baseDir,
      name: "no-remote",
      baseRef: "main",
      fetchOrigin: true,
      copyIgnored: false,
      copyUntracked: false
    )
    var createdPath: URL?
    for try await event in client.createWorktreeStream(spec) {
      if case .finished(let path) = event { createdPath = path }
    }
    let worktreePath = try #require(createdPath)
    #expect(fm.fileExists(atPath: worktreePath.path(percentEncoded: false)))
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

  /// Regression: a *locked* worktree must still be removable. git refuses
  /// `worktree remove --force` on a locked entry ("cannot remove a locked
  /// working tree, use -f -f or unlock first") and `prune` silently skips
  /// it, so before the fix an in-app Remove of a worktree locked by a
  /// sibling tool fataled with `GitWorktreeError.worktreeLocked` (surfaced
  /// to the user as "GitWorktreeError error 6"). `removeWorktree` now runs
  /// a best-effort `worktree unlock` up front.
  ///
  /// This variant mirrors the reported state: locked AND the working dir
  /// already gone, which forces the `forceRemoveWorktree` leg — relocate
  /// returns nil for a missing dir, so the forced remove is fatal on refusal.
  @Test(.enabled(if: WorktreeLifecycleIntegrationTests.wtBundled))
  func removeSucceedsWhenLockedAndDirMissing() async throws {
    let repo = try makeTempRepo()
    defer { try? fm.removeItem(at: repo) }

    let client = GitWorktreeClient.makeLive()
    let baseDir = repo.appending(path: ".worktrees", directoryHint: .isDirectory)
    try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
    let spec = CreateWorktreeSpec(
      repoRoot: repo,
      baseDirectory: baseDir,
      name: "locked-gone",
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

    // Lock it (as a sibling tool would), then delete the working dir so
    // the relocate leg is skipped and the forced-remove leg runs.
    try runGit(["worktree", "lock", worktreePath.path(percentEncoded: false)], cwd: repo)
    try fm.removeItem(at: worktreePath)

    try await client.removeWorktree(repo, worktreePath)
    let after = try await client.lsWorktrees(repo)
    #expect(!after.contains { URL(fileURLWithPath: $0.path).standardizedFileURL == worktreePath })
  }

  /// Companion to `removeSucceedsWhenLockedAndDirMissing` for the other
  /// leg: locked but the working dir is still present, so removal goes
  /// through relocate + `prune --expire=now`. `prune` skips *locked*
  /// worktrees, so without the up-front unlock the metadata row would
  /// linger even though the dir was relocated out from under git.
  @Test(.enabled(if: WorktreeLifecycleIntegrationTests.wtBundled))
  func removeSucceedsWhenLockedWithDirPresent() async throws {
    let repo = try makeTempRepo()
    defer { try? fm.removeItem(at: repo) }

    let client = GitWorktreeClient.makeLive()
    let baseDir = repo.appending(path: ".worktrees", directoryHint: .isDirectory)
    try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
    let spec = CreateWorktreeSpec(
      repoRoot: repo,
      baseDirectory: baseDir,
      name: "locked-present",
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

    try runGit(["worktree", "lock", worktreePath.path(percentEncoded: false)], cwd: repo)

    try await client.removeWorktree(repo, worktreePath)
    #expect(!fm.fileExists(atPath: worktreePath.path(percentEncoded: false)))
    let after = try await client.lsWorktrees(repo)
    #expect(!after.contains { URL(fileURLWithPath: $0.path).standardizedFileURL == worktreePath })
  }

  /// Spec for a creation in `repo` named `name`, no fetch, no copies.
  private func spec(_ repo: URL, name: String) throws -> CreateWorktreeSpec {
    let baseDir = repo.appending(path: ".worktrees", directoryHint: .isDirectory)
    try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
    return CreateWorktreeSpec(
      repoRoot: repo, baseDirectory: baseDir, name: name, baseRef: "HEAD",
      fetchOrigin: false, copyIgnored: false, copyUntracked: false)
  }

  /// A `post-checkout` hook that hangs keeps `git worktree add`, and so
  /// `wt sw`, running.
  private func installHangingCheckoutHook(_ repo: URL) throws {
    let hook = repo.appending(path: ".git/hooks/post-checkout")
    try "#!/bin/sh\nsleep 30\n".write(to: hook, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
  }

  /// Cancelling a `createWorktreeStream` consumer stops the `wt` child and
  /// everything it started (here git and its hanging hook).
  @Test(.enabled(if: WorktreeLifecycleIntegrationTests.wtBundled))
  func createStreamCancellationTerminatesWtProcess() async throws {
    let repo = try makeTempRepo()
    defer { try? fm.removeItem(at: repo) }
    try installHangingCheckoutHook(repo)
    let spawns = SpawnRecorder()
    let client = GitWorktreeClient.makeLive(onSpawn: { spawns.record($0) })
    let spec = try spec(repo, name: "cancelled")

    let consumer = Task<Void, Error> {
      for try await _ in client.createWorktreeStream(spec) {}
    }
    try await spawns.waitForSpawns(1)
    let pid = try #require(spawns.all.first, "wt should have spawned")
    consumer.cancel()

    #expect(spawns.allLeadTheirGroup)
    #expect(await processGroupEnds(pid), "wt and its children must stop after cancellation")
    _ = try? await consumer.value
  }

  /// A `wt sw` that hangs ends at the deadline with the timeout error, and
  /// leaves no process behind.
  @Test(.enabled(if: WorktreeLifecycleIntegrationTests.wtBundled))
  func hungWtCreationTimesOut() async throws {
    let repo = try makeTempRepo()
    defer { try? fm.removeItem(at: repo) }
    try installHangingCheckoutHook(repo)
    let spawns = SpawnRecorder()
    var timeouts = GitWorktreeClient.StreamTimeouts()
    timeouts.createWorktree = .seconds(2)
    let client = GitWorktreeClient.makeLive(onSpawn: { spawns.record($0) }, streamTimeouts: timeouts)
    let spec = try spec(repo, name: "hung")

    await #expect {
      for try await _ in client.createWorktreeStream(spec) {}
    } throws: { error in
      guard case .commandFailed(let command, let stderr) = error as? GitWorktreeError else { return false }
      return command.hasPrefix("wt ") && command.contains(" sw ") && stderr == "did not finish in 2 seconds"
    }
    let pid = try #require(spawns.all.first)
    #expect(await processGroupEnds(pid))
  }

  /// Cancelling during the setup phase stops the setup `bash` child, not
  /// only the already-exited `wt` one.
  @Test(.enabled(if: WorktreeLifecycleIntegrationTests.wtBundled))
  func cancellationTerminatesSetupChild() async throws {
    let repo = try makeTempRepo()
    defer { try? fm.removeItem(at: repo) }
    let spawns = SpawnRecorder()
    let client = GitWorktreeClient.makeLive(onSpawn: { spawns.record($0) })
    var spec = try spec(repo, name: "setup-cancel")
    spec.setupCommand = "sleep 30"

    let consumer = Task<Void, Error> {
      for try await _ in client.createWorktreeStream(spec) {}
    }
    // The wt child spawns first; the second spawn is the setup child.
    try await spawns.waitForSpawns(2)
    let setupPID = try #require(spawns.all.dropFirst().first, "setup bash child should have spawned")
    #expect(kill(setupPID, 0) == 0, "setup child should be alive before cancel")
    consumer.cancel()

    #expect(await processGroupEnds(setupPID), "setup child must stop after cancellation")
    _ = try? await consumer.value
  }

  /// A setup script inside a creation that hangs is stopped at its deadline;
  /// setup is best-effort, so the creation still finishes and says why.
  @Test(.enabled(if: WorktreeLifecycleIntegrationTests.wtBundled))
  func hungSetupScriptInCreationTimesOut() async throws {
    let repo = try makeTempRepo()
    defer { try? fm.removeItem(at: repo) }
    let spawns = SpawnRecorder()
    var timeouts = GitWorktreeClient.StreamTimeouts()
    timeouts.setupScript = .seconds(1)
    let client = GitWorktreeClient.makeLive(onSpawn: { spawns.record($0) }, streamTimeouts: timeouts)
    var spec = try spec(repo, name: "setup-hung")
    spec.setupCommand = "sleep 30"

    var lines: [String] = []
    var createdPath: URL?
    for try await event in client.createWorktreeStream(spec) {
      if case .progressLine(let line) = event { lines.append(line) }
      if case .finished(let path) = event { createdPath = path }
    }
    #expect(lines.last == "setup script did not finish in 1 second")
    let worktreePath = try #require(createdPath)
    let setupPID = try #require(spawns.all.last)
    #expect(await processGroupEnds(setupPID))
    try await client.removeWorktree(repo, worktreePath)
  }

  /// `runSetupScript` (the Workspace member path): a hung script ends with
  /// the timeout outcome, and a cancelled caller leaves no process.
  @Test
  func runSetupScriptTimesOutAndStopsOnCancel() async throws {
    let directory = fm.temporaryDirectory
    let spawns = SpawnRecorder()
    var timeouts = GitWorktreeClient.StreamTimeouts()
    timeouts.setupScript = .seconds(1)
    let client = GitWorktreeClient.makeLive(onSpawn: { spawns.record($0) }, streamTimeouts: timeouts)

    let outcome = await client.runSetupScript(directory, "sleep 30") { _ in }
    #expect(outcome == .timedOut(after: .seconds(1)))
    #expect(outcome.failureReason == "setup script did not finish in 1 second")
    let timedOutPID = try #require(spawns.all.first)
    #expect(await processGroupEnds(timedOutPID))

    let longClient = GitWorktreeClient.makeLive(onSpawn: { spawns.record($0) })
    let caller = Task { await longClient.runSetupScript(directory, "sleep 30") { _ in } }
    try await spawns.waitForSpawns(2)
    let cancelledPID = try #require(spawns.all.last)
    caller.cancel()
    #expect(await caller.value == .cancelled)
    #expect(await processGroupEnds(cancelledPID))
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

  // MARK: - deleteBranchIfExists (worktree-removal branch cleanup)

  /// Deleting an existing non-checked-out branch succeeds (`.deleted`).
  @Test(.enabled(if: WorktreeLifecycleIntegrationTests.wtBundled))
  func deleteBranchIfExistsNonCheckedOutSucceeds() async throws {
    let repo = try makeTempRepo()
    defer { try? fm.removeItem(at: repo) }
    let client = GitWorktreeClient.makeLive()

    // Create a branch (local, not checked out anywhere).
    try runGit(["branch", "to-delete"], cwd: repo)

    let outcome = await client.deleteBranchIfExists(repo, "to-delete")
    #expect(outcome == .deleted)

    // Confirm the branch is gone.
    let names = try await client.localBranchNames(repo)
    #expect(!names.contains("to-delete"))
  }

  /// `localBranchNames` preserves the ref's ORIGINAL casing (it no longer
  /// case-folds). This is what lets `CreateWorktreeFeature` recover the exact
  /// existing ref (`danglingRealName`) so a Recreate/Reuse of a mixed-case
  /// branch targets and reproduces the SAME-cased ref instead of a
  /// differently-cased duplicate. Asserts the mixed-case name comes back
  /// verbatim, not lowercased.
  @Test(.enabled(if: WorktreeLifecycleIntegrationTests.wtBundled))
  func localBranchNamesPreservesOriginalCasing() async throws {
    let repo = try makeTempRepo()
    defer { try? fm.removeItem(at: repo) }
    let client = GitWorktreeClient.makeLive()

    try runGit(["branch", "Feature-Login"], cwd: repo)

    let names = try await client.localBranchNames(repo)
    #expect(names.contains("Feature-Login"))  // original casing preserved
    #expect(!names.contains("feature-login"))  // NOT case-folded
  }

  /// Deleting a branch that is currently checked out in a worktree is
  /// refused by git even with `-D`. The outcome is `.kept`, not a throw.
  @Test(.enabled(if: WorktreeLifecycleIntegrationTests.wtBundled))
  func deleteBranchIfExistsCheckedOutYieldsKept() async throws {
    let repo = try makeTempRepo()
    defer { try? fm.removeItem(at: repo) }
    let client = GitWorktreeClient.makeLive()

    // Add a worktree on a new branch so that branch is checked out.
    let baseDir = repo.appending(path: ".worktrees", directoryHint: .isDirectory)
    try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
    let spec = CreateWorktreeSpec(
      repoRoot: repo,
      baseDirectory: baseDir,
      name: "checked-out-branch",
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
    defer { try? fm.removeItem(at: worktreePath) }

    // "checked-out-branch" is now checked out in the worktree; git -D refuses.
    let outcome = await client.deleteBranchIfExists(repo, "checked-out-branch")
    guard case .kept = outcome else {
      #expect(Bool(false), "expected .kept, got \(outcome)")
      return
    }
  }

  // MARK: - Nested branch folders

  /// Branches with a `/` create nested directories so the
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

  /// A remote's HEAD is not a branch. `%(refname:short)` reports
  /// `refs/remotes/origin/HEAD` as plain `origin`, which the pickers would
  /// otherwise offer as a branch named after the remote.
  @Test
  func branchRefsListsBranchesWithoutTheRemoteHead() async throws {
    let repo = try makeTempRepo()
    defer { try? fm.removeItem(at: repo) }
    try runGit(["branch", "feat/x"], cwd: repo)
    try runGit(["update-ref", "refs/remotes/origin/main", "HEAD"], cwd: repo)
    try runGit(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], cwd: repo)

    let refs = try await GitWorktreeClient.makeLive().branchRefs(repo)
    #expect(refs.sorted() == ["feat/x", "main", "origin/main"])
  }
}
