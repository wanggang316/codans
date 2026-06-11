import Foundation
import Testing
import CodansCore

@testable import Codans

/// Exercises `LiveGitService` against a scratch repo on disk. Gated behind
/// `TC_RUN_GIT_INTEGRATION_TESTS=1` so CI can opt in on machines where `git` is available.
///
/// Uses Swift Testing's `.enabled(if:)` trait so unenabled runs skip cleanly rather than
/// showing as failures. The predicate is evaluated at test discovery time.
struct LiveGitServiceIntegrationTests {
  static let integrationEnabled: Bool = {
    ProcessInfo.processInfo.environment["TC_RUN_GIT_INTEGRATION_TESTS"] == "1"
  }()

  @Test(.enabled(if: LiveGitServiceIntegrationTests.integrationEnabled))
  func logRoundTripOnScratchRepo() async throws {
    let (repoURL, _) = try await Self.makeScratchRepo(commits: 2)

    let service = LiveGitService()
    let page = try await service.log(at: repoURL, page: .init(offset: 0, limit: 10))
    #expect(page.commits.count == 2)
    #expect(page.commits[0].subject == "second")
    #expect(page.commits[1].subject == "initial")
    #expect(!page.hasMore)
  }

  @Test(.enabled(if: LiveGitServiceIntegrationTests.integrationEnabled))
  func workingTreeDiffPicksUpUncommittedChange() async throws {
    let (repoURL, _) = try await Self.makeScratchRepo(commits: 1)
    try "uncommitted\n".write(
      to: repoURL.appendingPathComponent("README.md"),
      atomically: true,
      encoding: .utf8
    )

    let service = LiveGitService()
    let diff = try await service.workingTreeDiff(at: repoURL)
    #expect(!diff.files.isEmpty)
    #expect(diff.files.contains(where: { $0.id == "README.md" }))
  }

  @Test(.enabled(if: LiveGitServiceIntegrationTests.integrationEnabled))
  func statusPicksUpUntrackedFile() async throws {
    let (repoURL, _) = try await Self.makeScratchRepo(commits: 1)
    try "scratch\n".write(
      to: repoURL.appendingPathComponent("new-file.txt"),
      atomically: true,
      encoding: .utf8
    )

    let service = LiveGitService()
    let status = try await service.status(at: repoURL)
    #expect(status.entries.contains(where: { $0.path == "new-file.txt" }))
  }

  @Test(.enabled(if: LiveGitServiceIntegrationTests.integrationEnabled))
  func commitDiffRejectsInvalidSha() async throws {
    let (repoURL, _) = try await Self.makeScratchRepo(commits: 1)
    let service = LiveGitService()
    await #expect(throws: GitError.invalidInput("not a git SHA: 'notahex'")) {
      try await service.commitDiff(at: repoURL, sha: "notahex")
    }
  }

  @Test(.enabled(if: LiveGitServiceIntegrationTests.integrationEnabled))
  func notARepositorySurfacesNotARepo() async throws {
    let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("codans-not-a-repo-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let service = LiveGitService()
    await #expect(throws: GitError.notARepo) {
      try await service.log(at: tempURL, page: .init(offset: 0, limit: 10))
    }
  }

  // MARK: - Scratch-repo helpers

  /// Creates a temp repo with `commits` linear commits, returning the repo URL and the list
  /// of commit SHAs (newest first).
  private static func makeScratchRepo(commits: Int) async throws -> (URL, [String]) {
    let repoURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("codans-git-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)

    try await run(["git", "init", "-q"], cwd: repoURL)
    try await run(["git", "config", "user.email", "test@example.com"], cwd: repoURL)
    try await run(["git", "config", "user.name", "Test"], cwd: repoURL)
    try await run(["git", "config", "commit.gpgsign", "false"], cwd: repoURL)

    let messages =
      commits == 1
      ? ["initial"]
      : (0..<commits).map { idx in
        idx == 0 ? "initial" : (idx == 1 ? "second" : "change-\(idx)")
      }

    var shas: [String] = []
    for (idx, message) in messages.enumerated() {
      let file = repoURL.appendingPathComponent("README.md")
      try "content \(idx)\n".write(to: file, atomically: true, encoding: .utf8)
      try await run(["git", "add", "-A"], cwd: repoURL)
      try await run(["git", "commit", "-q", "-m", message], cwd: repoURL)
      let sha = try await captureStdout(["git", "rev-parse", "HEAD"], cwd: repoURL)
      shas.append(sha.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return (repoURL, shas.reversed())
  }

  private static func run(_ argv: [String], cwd: URL) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = argv
    process.currentDirectoryURL = cwd
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      process.terminationHandler = { _ in cont.resume() }
    }
  }

  private static func captureStdout(_ argv: [String], cwd: URL) async throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = argv
    process.currentDirectoryURL = cwd
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      process.terminationHandler = { _ in cont.resume() }
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
  }
}
