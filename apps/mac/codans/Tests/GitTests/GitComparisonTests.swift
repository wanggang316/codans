import CodansCore
import Foundation
import Testing

@testable import Codans

@Suite(.serialized)
struct GitComparisonTests {
  private func git(_ args: [String], at url: URL) async throws {
    let outcome = await FoundationCommandRunner().run(
      executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: args,
      env: GitProcessEnv.build(), cwd: url, timeout: .seconds(10), maxOutputBytes: 1024 * 1024)
    guard case .exited(0, _, _, false) = outcome else {
      throw GitError.unparsable(context: "Fixture command failed: \(args): \(outcome)")
    }
  }

  private func repository() async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("codans-comparison-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try await git(["init", "-b", "main"], at: url)
    try await git(["config", "user.email", "test@example.com"], at: url)
    try await git(["config", "user.name", "Test"], at: url)
    return url
  }

  private func write(_ text: String, _ path: String, at url: URL) throws {
    try Data(text.utf8).write(to: url.appendingPathComponent(path))
  }

  @Test func scopesFreezeIndexAndPreserveSpecialPaths() async throws {
    let url = try await repository()
    defer { try? FileManager.default.removeItem(at: url) }
    let name = "a\tspace\n'$.txt"
    try write("base\n", name, at: url)
    try await git(["add", "."], at: url)
    try await git(["commit", "-m", "initial"], at: url)
    try write("staged\n", name, at: url)
    try await git(["add", "."], at: url)
    try write("working\n", name, at: url)
    try write("untracked\n", "new.txt", at: url)
    let service = LiveGitService()
    let staged = try await service.comparison(at: url, scope: .staged, base: nil)
    let unstaged = try await service.comparison(at: url, scope: .unstaged, base: nil)
    let all = try await service.comparison(at: url, scope: .all, base: nil)
    #expect(staged.files.count == 1)
    #expect(unstaged.files.count == 2)
    #expect(all.files.count == 2)
    try await git(["add", "."], at: url)
    let stagedText = try await service.comparisonContent(at: url, snapshot: staged, file: #require(staged.files.first))
    #expect(stagedText.oldText == "base\n")
    #expect(stagedText.newText == "staged\n")
    let unstagedText = try await service.comparisonContent(
      at: url, snapshot: unstaged, file: #require(unstaged.files.first { $0.path == name }))
    #expect(unstagedText.oldText == "staged\n")
    #expect(unstagedText.newText == "working\n")
  }

  @Test func outgoingExcludesTargetOnlyChangesAndUncommittedWork() async throws {
    let url = try await repository()
    defer { try? FileManager.default.removeItem(at: url) }
    try write("base\n", "file.txt", at: url)
    try await git(["add", "."], at: url)
    try await git(["commit", "-m", "base"], at: url)
    try await git(["checkout", "-b", "feature"], at: url)
    try write("feature\n", "file.txt", at: url)
    try await git(["commit", "-am", "feature"], at: url)
    try await git(["checkout", "main"], at: url)
    try write("target\n", "target.txt", at: url)
    try await git(["add", "."], at: url)
    try await git(["commit", "-m", "target"], at: url)
    try await git(["checkout", "feature"], at: url)
    try write("dirty\n", "file.txt", at: url)
    let service = LiveGitService()
    let snapshot = try await service.comparison(at: url, scope: .outgoing, base: "main")
    #expect(snapshot.files.map(\.path) == ["file.txt"])
    let content = try await service.comparisonContent(at: url, snapshot: snapshot, file: #require(snapshot.files.first))
    #expect(content.oldText == "base\n")
    #expect(content.newText == "feature\n")
  }

  @Test func unbornBinaryAndLimit() async throws {
    let url = try await repository()
    defer { try? FileManager.default.removeItem(at: url) }
    try write("first\n", "first.txt", at: url)
    try await git(["add", "."], at: url)
    let service = LiveGitService()
    let staged = try await service.comparison(at: url, scope: .staged, base: nil)
    #expect(staged.files.map(\.path) == ["first.txt"])
    try Data([0, 1, 2]).write(to: url.appendingPathComponent("binary"))
    try Data(repeating: 65, count: LiveGitService.comparisonContentLimit + 1).write(
      to: url.appendingPathComponent("large"))
    let all = try await service.comparison(at: url, scope: .all, base: nil)
    for path in ["binary", "large"] {
      let content = try await service.comparisonContent(
        at: url, snapshot: all, file: #require(all.files.first { $0.path == path }))
      #expect(content.notice != nil)
    }
  }
  @Test func renameDeletionAndModeOnly() async throws {
    let url = try await repository()
    defer { try? FileManager.default.removeItem(at: url) }
    try write("same text\n", "old.txt", at: url)
    try write("delete me\n", "deleted.txt", at: url)
    try write("script\n", "script.sh", at: url)
    try await git(["add", "."], at: url)
    try await git(["commit", "-m", "base"], at: url)
    try await git(["mv", "old.txt", "new name.txt"], at: url)
    try await git(["rm", "deleted.txt"], at: url)
    try await git(["update-index", "--chmod=+x", "script.sh"], at: url)
    let service = LiveGitService()
    let snapshot = try await service.comparison(at: url, scope: .staged, base: nil)
    let renamed = try #require(snapshot.files.first { $0.status == "R" })
    #expect(renamed.oldPath == "old.txt")
    #expect(renamed.path == "new name.txt")
    let deleted = try #require(snapshot.files.first { $0.status == "D" })
    let deletedContent = try await service.comparisonContent(at: url, snapshot: snapshot, file: deleted)
    #expect(deletedContent.oldText == "delete me\n")
    #expect(deletedContent.newText.isEmpty)
    let mode = try #require(snapshot.files.first { $0.path == "script.sh" })
    let modeContent = try await service.comparisonContent(at: url, snapshot: snapshot, file: mode)
    #expect(modeContent.notice?.contains("Metadata") == true)
  }

  @Test func conflictAndSymlinkAreNotRendered() async throws {
    let url = try await repository()
    defer { try? FileManager.default.removeItem(at: url) }
    try write("base\n", "file", at: url)
    try await git(["add", "."], at: url)
    try await git(["commit", "-m", "base"], at: url)
    try await git(["checkout", "-b", "feature"], at: url)
    try write("feature\n", "file", at: url)
    try await git(["commit", "-am", "feature"], at: url)
    try await git(["checkout", "main"], at: url)
    try write("main\n", "file", at: url)
    try await git(["commit", "-am", "main"], at: url)
    try? await git(["merge", "feature"], at: url)
    let service = LiveGitService()
    let snapshot = try await service.comparison(at: url, scope: .unstaged, base: nil)
    let file = try #require(snapshot.files.first { $0.path == "file" })
    #expect(file.status == "U")
    let content = try await service.comparisonContent(at: url, snapshot: snapshot, file: file)
    #expect(content.notice?.contains("Unmerged") == true)
    let all = try await service.comparison(at: url, scope: .all, base: nil)
    #expect(all.files.first { $0.path == "file" }?.status == "U")
    try FileManager.default.createSymbolicLink(
      atPath: url.appendingPathComponent("link").path, withDestinationPath: "/etc/hosts")
    let links = try await service.comparison(at: url, scope: .all, base: nil)
    let link = try #require(links.files.first { $0.path == "link" })
    let linkContent = try await service.comparisonContent(at: url, snapshot: links, file: link)
    #expect(linkContent.notice?.contains("symlink") == true)
    #expect(linkContent.newText.isEmpty)
  }

  @Test func missingBaseDetachedHeadAndNonRepository() async throws {
    let url = try await repository()
    defer { try? FileManager.default.removeItem(at: url) }
    try write("base\n", "file", at: url)
    try await git(["add", "."], at: url)
    try await git(["commit", "-m", "base"], at: url)
    try await git(["branch", "-m", "trunk"], at: url)
    let service = LiveGitService()
    await #expect(throws: GitError.invalidInput("Choose a target branch for Outgoing")) {
      try await service.comparison(at: url, scope: .outgoing, base: nil)
    }
    try await git(["checkout", "--detach"], at: url)
    let detached = try await service.comparison(at: url, scope: .outgoing, base: "trunk")
    #expect(detached.files.isEmpty)
    // An unrelated directory, not a child of the repository (Git discovers parents).
    let unrelated = FileManager.default.temporaryDirectory.appendingPathComponent("codans-not-repo-\(UUID())")
    try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: unrelated) }
    await #expect(throws: GitError.notARepo) {
      try await service.comparison(at: unrelated, scope: .all, base: nil)
    }
  }

  @Test func remoteWorkingContentUsesSSHTransportAndBounds() async throws {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data("remote\n".utf8), stderr: Data(), stdoutOverflow: false)
    ])
    let service = LiveGitService(runner: runner, resolveRemoteHost: { _ in RemoteHost(alias: "fixture.example") })
    let file = GitComparisonFile(path: "space ' $(echo unsafe).txt", status: "A")
    let snapshot = GitComparisonSnapshot(scope: .all, baseLabel: "HEAD", files: [file], repositoryPath: "/srv/app")
    let content = try await service.comparisonContent(
      at: URL(fileURLWithPath: "/srv/app"), snapshot: snapshot, file: file)
    #expect(content.newText == "remote\n")
    let calls = await runner.calls
    #expect(calls.count == 1)
    let call = try #require(calls.first)
    #expect(call.executable.path == "/usr/bin/ssh")
    #expect(call.arguments.contains("fixture.example"))
    #expect(call.arguments.contains("BatchMode=yes"))
    #expect(call.cwd.path != "/srv/app")
    #expect(call.maxOutputBytes == LiveGitService.comparisonContentLimit)
  }

}
