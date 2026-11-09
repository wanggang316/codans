import CodansCore
import Foundation
import Testing

@testable import Codans

/// Covers the remote-tracking ref signal end to end: the common-dir
/// resolution for main and linked checkouts, the path filter, and a real
/// `git update-ref` in a child process reaching `events()`. The stream is
/// created with `IgnoreSelf`, so the write must come from another process.
@MainActor
struct RemoteRefsWatcherTests {
  @Test
  func acceptsOnlyRemoteTrackingRefPaths() {
    let common = "/repo/.git"
    #expect(RemoteRefsWatcher.isRemoteRefPath("\(common)/refs/remotes/origin/feat/x"))
    #expect(RemoteRefsWatcher.isRemoteRefPath("\(common)/refs/remotes/origin/main.lock"))
    #expect(RemoteRefsWatcher.isRemoteRefPath("\(common)/packed-refs"))
    #expect(RemoteRefsWatcher.isRemoteRefPath("\(common)/packed-refs.lock"))
    #expect(!RemoteRefsWatcher.isRemoteRefPath("\(common)/index"))
    #expect(!RemoteRefsWatcher.isRemoteRefPath("\(common)/HEAD"))
    #expect(!RemoteRefsWatcher.isRemoteRefPath("\(common)/FETCH_HEAD"))
    #expect(!RemoteRefsWatcher.isRemoteRefPath("\(common)/refs/heads/main"))
    #expect(!RemoteRefsWatcher.isRemoteRefPath("\(common)/logs/HEAD"))
  }

  @Test
  func resolvesTheCommonDirForMainAndLinkedCheckouts() throws {
    let dir = try Self.makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let main = dir.appending(path: "main")
    let linked = dir.appending(path: "linked")
    try Self.git(["init", "-q", main.path])
    try Self.git(["-C", main.path, "commit", "-q", "--allow-empty", "-m", "init"])
    try Self.git(["-C", main.path, "worktree", "add", "-q", "-b", "feature", linked.path])

    let expected = main.appending(path: ".git").resolvingSymlinksInPath()
    let fromMain = try #require(WorktreeHeadResolver.commonDirURL(for: main))
    let fromLinked = try #require(WorktreeHeadResolver.commonDirURL(for: linked))
    #expect(fromMain.resolvingSymlinksInPath() == expected)
    #expect(fromLinked.resolvingSymlinksInPath() == expected)
    #expect(WorktreeHeadResolver.commonDirURL(for: dir) == nil)
  }

  @Test
  func aRemoteRefUpdateFromAnotherProcessYieldsTheUnit() async throws {
    let dir = try Self.makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let repo = dir.appending(path: "repo")
    try Self.git(["init", "-q", repo.path])
    try Self.git(["-C", repo.path, "commit", "-q", "--allow-empty", "-m", "init"])
    let unit = ProjectID()
    let watcher = RemoteRefsWatcher(debounceInterval: .milliseconds(50))
    defer { watcher.stopAll() }
    let events = watcher.events()

    watcher.setRepositories([unit: repo.path])
    let commonDir = RemoteRefsWatcher.realPath(repo.appending(path: ".git"))
    try await Self.waitUntil { watcher.isWatching(unit, path: commonDir) }

    // `git push` records the pushed commit the same way.
    try Self.git(["-C", repo.path, "update-ref", "refs/remotes/origin/main", "HEAD"])
    let received = try await Self.first(of: events, timeout: .seconds(15))
    #expect(received == unit)
  }

  // MARK: - Helpers

  private static func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("rrw-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func git(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.environment = [
      "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
      "GIT_COMMITTER_EMAIL": "t@t", "HOME": NSTemporaryDirectory(),
    ]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
  }

  private static func first(
    of stream: AsyncStream<ProjectID>, timeout: Duration
  ) async throws -> ProjectID? {
    try await withThrowingTaskGroup(of: ProjectID?.self) { group in
      group.addTask {
        for await id in stream { return id }
        return nil
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        return nil
      }
      let result = try await group.next() ?? nil
      group.cancelAll()
      return result
    }
  }

  private static func waitUntil(
    _ condition: @escaping @MainActor () -> Bool,
    timeout: Duration = .seconds(15)
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
      if ContinuousClock.now > deadline {
        Issue.record("condition not met within \(timeout)")
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
  }
}
