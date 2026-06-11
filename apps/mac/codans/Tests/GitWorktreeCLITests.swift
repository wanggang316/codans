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
