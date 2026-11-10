import Foundation
import Testing

@testable import Codans

struct GitWorktreeCLITests {
  @Test
  func discoverGitRootReturnsNilForNonRepo() async throws {
    let cli = GitWorktreeCLI()
    let root = try await cli.discoverGitRoot(candidatePath: NSTemporaryDirectory())
    #expect(root == nil)
  }

  @Test
  func listWorktreesOnFreshRepoReturnsOneEntry() async throws {
    let repoPath = try makeTempRepo()
    defer { try? FileManager.default.removeItem(atPath: repoPath) }

    let cli = GitWorktreeCLI()
    let entries = try await cli.listWorktrees(repoPath: repoPath)
    #expect(entries.count == 1)
    #expect(entries[0].path == repoPath)
  }

  @Test
  func createAndRemoveWorktree() async throws {
    let repoPath = try makeTempRepo()
    defer { try? FileManager.default.removeItem(atPath: repoPath) }

    let worktreePath = repoPath + "-wt"
    defer { try? FileManager.default.removeItem(atPath: worktreePath) }

    let cli = GitWorktreeCLI()
    try await cli.createWorktree(repoPath: repoPath, branch: "feature", path: worktreePath)

    let entries = try await cli.listWorktrees(repoPath: repoPath)
    #expect(entries.count == 2)
    #expect(entries.contains(where: { $0.path == worktreePath && $0.branch == "feature" }))

    try await cli.removeWorktree(repoPath: repoPath, path: worktreePath, force: true)
    let afterRemove = try await cli.listWorktrees(repoPath: repoPath)
    #expect(afterRemove.count == 1)
  }

  @Test
  func listBranchesReturnsDefaultBranch() async throws {
    let repoPath = try makeTempRepo()
    defer { try? FileManager.default.removeItem(atPath: repoPath) }

    let cli = GitWorktreeCLI()
    let branches = try await cli.listBranches(repoPath: repoPath)
    #expect(!branches.isEmpty)
  }

  // MARK: - Helpers

  private func makeTempRepo() throws -> String {
    let raw = NSTemporaryDirectory() + "git-test-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
    let temp = realpath(raw, nil).map { String(cString: $0) } ?? raw

    try runSync("/usr/bin/git", ["init", "-b", "main", temp])
    try runSync("/usr/bin/git", ["-C", temp, "config", "user.email", "test@example.com"])
    try runSync("/usr/bin/git", ["-C", temp, "config", "user.name", "Test"])

    let readme = temp + "/README.md"
    try "hello".write(toFile: readme, atomically: true, encoding: .utf8)

    try runSync("/usr/bin/git", ["-C", temp, "add", "README.md"])
    try runSync("/usr/bin/git", ["-C", temp, "commit", "-m", "initial"])

    return temp
  }

  /// Parent keys that would redirect git; `GitWorktreeCLI` must not pass them on.
  private static let hostileParent: [String: String] = [
    "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "GIT_DIR": "/nonexistent/.git", "GIT_WORK_TREE": "/nonexistent", "GIT_CONFIG_GLOBAL": "/nonexistent/config",
    "GIT_TERMINAL_PROMPT": "1", "LC_ALL": "fr_FR.UTF-8",
  ]

  @Test
  func cloneUsesTheLoginShellTheCloneTimeoutAndTheGitEnvironment() async throws {
    let runner = RecordingCommandRunner()
    let cli = GitWorktreeCLI(runner: runner, parentEnvironment: Self.hostileParent)
    let destination = NSTemporaryDirectory() + "codans-clone-\(UUID().uuidString)/repo"
    try await cli.clone(remoteURL: "http://example.invalid/r.git", destinationPath: destination)
    _ = try await cli.listBranches(repoPath: NSTemporaryDirectory())

    let calls = await runner.calls
    #expect(calls.map(\.launch) == [.loginShell, .directThenLoginShell])
    #expect(calls.map(\.timeout) == [GitWorktreeCLI.cloneTimeout, GitWorktreeCLI.defaultTimeout])
    for call in calls {
      #expect(call.env.keys.filter { $0.hasPrefix("GIT_") } == ["GIT_TERMINAL_PROMPT"])
      #expect(call.env["GIT_TERMINAL_PROMPT"] == "0")
      #expect(call.env["LC_ALL"] == "C.UTF-8")
    }
  }

  @Test
  func timeoutIsReportedAsTimedOut() async {
    let cli = GitWorktreeCLI(runner: RecordingCommandRunner(outcomes: [.timedOut]))
    await #expect(throws: GitCLIError.timedOut) {
      try await cli.clone(remoteURL: "http://example.invalid/r.git", destinationPath: NSTemporaryDirectory() + "x/r")
    }
  }

  /// A parent `GIT_DIR` would point every command at a missing repository.
  @Test
  func parentGitKeysDoNotReachRealGit() async throws {
    let repoPath = try makeTempRepo()
    defer { try? FileManager.default.removeItem(atPath: repoPath) }
    let cli = GitWorktreeCLI(parentEnvironment: Self.hostileParent)
    let root = try await cli.discoverGitRoot(candidatePath: repoPath)
    let resolved = root.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    #expect(resolved == URL(fileURLWithPath: repoPath).resolvingSymlinksInPath().path)
  }

  /// A clone that hangs (here an `ext::` remote that sleeps) stops when the
  /// caller's task is cancelled, and leaves no child process.
  @Test
  func cancellingAHungCloneStopsIt() async throws {
    let home = NSTemporaryDirectory() + "codans-clone-home-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    try "[protocol \"ext\"]\n\tallow = always\n".write(
      toFile: home + "/.gitconfig", atomically: true, encoding: .utf8)
    let seconds = "4\(Int.random(in: 10_000...99_999)).5"
    let cli = GitWorktreeCLI(parentEnvironment: ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
    let task = Task {
      try await cli.clone(remoteURL: "ext::sh -c sleep% \(seconds)", destinationPath: home + "/dest")
    }
    for _ in 0..<200 where pgrep("sleep \(seconds)").isEmpty {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(!pgrep("sleep \(seconds)").isEmpty)
    let clock = ContinuousClock()
    let start = clock.now
    task.cancel()
    await #expect(throws: GitCLIError.timedOut) { try await task.value }
    #expect(clock.now - start < .seconds(10))
    #expect(pgrep("sleep \(seconds)").isEmpty)
  }

  private func pgrep(_ pattern: String) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-fl", pattern]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    process.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  }

  private func runSync(_ executable: String, _ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = args
    p.standardOutput = Pipe()
    p.standardError = Pipe()
    try p.run()
    p.waitUntilExit()
    if p.terminationStatus != 0 {
      throw GitCLIError.exitCode(p.terminationStatus, stderr: "")
    }
  }
}
