import CodansCore
import Foundation
import Testing

@testable import Codans

/// Coverage for the Server-project git transport seam: `LiveGitService`
/// routes an invocation over SSH when the path resolver returns a host, and
/// `HierarchyManager.remoteHost(forPath:)` is that resolver's live backing.
struct RemoteGitRoutingTests {
  private static let host = RemoteHost(alias: "example.com", username: "alice", port: 2222)

  @Test
  func remotePathRoutesInvocationOverSSH() async throws {
    let runner = RecordingCommandRunner(outcomes: [
      // ensureIsRepo → rev-parse --is-inside-work-tree
      .exited(code: 0, stdout: Data("true\n".utf8), stderr: Data(), stdoutOverflow: false),
      // localDiffStats → diff HEAD --shortstat
      .exited(
        code: 0,
        stdout: Data(" 3 files changed, 17 insertions(+), 4 deletions(-)\n".utf8),
        stderr: Data(),
        stdoutOverflow: false
      ),
    ])
    let service = LiveGitService(
      runner: runner,
      resolveRemoteHost: { url in url.path == "/srv/app" ? Self.host : nil }
    )

    let stats = try await service.localDiffStats(at: URL(fileURLWithPath: "/srv/app"))
    #expect(stats == LocalDiffStats(additions: 17, deletions: 4))

    let calls = await runner.calls
    #expect(calls.count == 2)
    for call in calls {
      // Both the repo probe and the diff ride /usr/bin/ssh to the host…
      #expect(call.executable.path == "/usr/bin/ssh")
      #expect(call.arguments.contains("alice@example.com"))
      #expect(call.arguments.contains("2222"))
      // …with a *local* cwd — the remote `cd` owns the directory, and the
      // remote path must never be used as a local working directory.
      #expect(call.cwd.path != "/srv/app")
      // Fail fast instead of hanging on an auth prompt.
      #expect(call.arguments.contains("BatchMode=yes"))
    }
    // The remote command runs bare `git` under the login shell (PATH-resolved,
    // so a Homebrew-only git still works), cd'd into the remote repo.
    let probe = calls[0].arguments.last ?? ""
    #expect(probe.contains("git"))
    #expect(probe.contains("rev-parse"))
    #expect(probe.contains("/srv/app"))
    let diff = calls[1].arguments.last ?? ""
    #expect(diff.contains("--shortstat"))
  }

  @Test
  func localPathKeepsLocalInvocation() async throws {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data("true\n".utf8), stderr: Data(), stdoutOverflow: false),
      .exited(code: 0, stdout: Data(), stderr: Data(), stdoutOverflow: false),
    ])
    let service = LiveGitService(
      runner: runner,
      resolveRemoteHost: { _ in nil }
    )
    _ = try await service.localDiffStats(at: URL(fileURLWithPath: "/tmp"))
    let calls = await runner.calls
    #expect(calls.allSatisfy { $0.executable.path == "/usr/bin/git" })
    #expect(calls.allSatisfy { $0.cwd.path == "/tmp" })
  }

  @Test
  @MainActor
  func managerResolvesRemoteHostForServerProjectPathsOnly() {
    let tempURL = FileManager.default.temporaryDirectory
      .appending(component: UUID().uuidString + ".json")
    let manager = HierarchyManager(
      catalog: .default,
      store: CatalogStore(fileURL: tempURL),
      runtime: FakeHierarchyRuntime()
    )
    _ = manager.addProject(name: "local", rootPath: "/srv/app", gitRoot: "/srv/app")
    let serverID = manager.addServerProject(
      name: "server", remoteHost: Self.host, rootPath: "/data/app", gitRoot: "/data/app"
    )
    _ = manager.reconcileDiscoveredWorktrees(
      projectID: serverID,
      entries: [(path: "/data/app-feature", branch: "feature")],
      normalizePath: HierarchyManager.normalizeRemotePath
    )

    // Server rootPath / gitRoot / discovered worktree paths resolve (trailing
    // slash tolerated); a local project's identical-shape path does not.
    #expect(manager.remoteHost(forPath: "/data/app") == Self.host)
    #expect(manager.remoteHost(forPath: "/data/app/") == Self.host)
    #expect(manager.remoteHost(forPath: "/data/app-feature") == Self.host)
    #expect(manager.remoteHost(forPath: "/srv/app") == nil)
    #expect(manager.remoteHost(forPath: "/elsewhere") == nil)
  }
}
