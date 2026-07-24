import CodansCore
import Foundation
import Testing

@testable import Codans

struct RemoteGitServiceTests {
  @Test
  func parsesPorcelainWorktreeList() {
    let output = """
      worktree /srv/app
      HEAD 1111111111111111111111111111111111111111
      branch refs/heads/main

      worktree /srv/app-feature
      HEAD 2222222222222222222222222222222222222222
      branch refs/heads/feature/x

      """
    let entries = RemoteGitService.parseWorktreeList(output)
    #expect(entries.count == 2)
    #expect(entries[0].path == "/srv/app")
    #expect(entries[0].branch == "main")
    #expect(entries[0].head == "1111111111111111111111111111111111111111")
    // `refs/heads/` prefix is stripped; nested branch names survive.
    #expect(entries[1].path == "/srv/app-feature")
    #expect(entries[1].branch == "feature/x")
  }

  @Test
  func detachedWorktreeHasNilBranch() {
    let output = """
      worktree /srv/app
      HEAD 3333333333333333333333333333333333333333
      detached
      """
    let entries = RemoteGitService.parseWorktreeList(output)
    #expect(entries.count == 1)
    #expect(entries[0].branch == nil)
    #expect(entries[0].head == "3333333333333333333333333333333333333333")
  }

  @Test
  func ignoresRecordWithoutHead() {
    // A `worktree` line with no HEAD (never happens in practice, but the
    // parser must not emit a half-built entry) is dropped.
    let output = """
      worktree /srv/incomplete
      """
    #expect(RemoteGitService.parseWorktreeList(output).isEmpty)
  }

  @Test
  func remotePathNormalizationIsStringOnly() {
    // The remote normalizer must NOT resolve against the local filesystem:
    // a remote `/tmp/...` stays `/tmp/...` (the local canonicalPath would map
    // it to `/private/tmp/...`).
    #expect(HierarchyManager.normalizeRemotePath("/tmp/x/") == "/tmp/x")
    #expect(HierarchyManager.normalizeRemotePath("/srv/app") == "/srv/app")
    #expect(HierarchyManager.normalizeRemotePath("/") == "/")
  }

  @Test
  func connectionFailureIsFlaggedByExit255() {
    let sshFailure = RemoteGitError.commandFailed(
      command: "git worktree list", exitCode: 255, stderr: "ssh: connect: refused"
    )
    #expect(sshFailure.isConnectionFailure)
    let gitRefusal = RemoteGitError.commandFailed(
      command: "git worktree add", exitCode: 128, stderr: "fatal: branch exists"
    )
    #expect(!gitRefusal.isConnectionFailure)
  }
}
