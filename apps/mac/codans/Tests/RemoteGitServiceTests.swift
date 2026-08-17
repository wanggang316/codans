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
  func lastNonEmptyLineSkipsLoginBanners() {
    // A login shell may print banners before the probe's own output; the
    // result is the final non-empty line, trimmed.
    let output = "Welcome to the server!\nmotd line\n\n/srv/app\n"
    #expect(RemoteGitService.lastNonEmptyLine(of: output) == "/srv/app")
    #expect(RemoteGitService.lastNonEmptyLine(of: "\n \n") == "")
  }

  @Test
  func resolvePathScriptExpandsTildeAndCanonicalizes() throws {
    // The script runs under POSIX sh on the host; local /bin/sh matches that
    // contract, so exercise it for real: a symlinked directory resolves to
    // its physical path, and a missing directory exits non-zero.
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("codans-rp-\(UUID().uuidString)")
    let real = base.appendingPathComponent("real")
    let link = base.appendingPathComponent("link")
    try fm.createDirectory(at: real, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: link, withDestinationURL: real)
    defer { try? fm.removeItem(at: base) }

    func run(_ argument: String) -> (status: Int32, stdout: String) {
      let proc = Process()
      proc.executableURL = URL(fileURLWithPath: "/bin/sh")
      proc.arguments = ["-c", RemoteGitService.resolvePathScript, "sh", argument]
      let out = Pipe()
      proc.standardOutput = out
      proc.standardError = Pipe()
      try? proc.run()
      proc.waitUntilExit()
      let data = out.fileHandleForReading.readDataToEndOfFile()
      return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    let resolved = run(link.path)
    #expect(resolved.status == 0)
    let resolvedPath = RemoteGitService.lastNonEmptyLine(of: resolved.stdout)
    // `pwd -P` resolves the symlink: the link and the real dir must resolve
    // to the SAME physical path (compare script-vs-script — Foundation's
    // `resolvingSymlinksInPath` strips `/private` and can't be the oracle).
    let direct = run(real.path)
    #expect(resolvedPath == RemoteGitService.lastNonEmptyLine(of: direct.stdout))
    #expect(resolvedPath.hasSuffix("/real"))
    #expect(!resolvedPath.contains("link"))

    let missing = run(base.appendingPathComponent("nope").path)
    #expect(missing.status != 0)
  }

  @Test
  func addWorktreeCarriesBaseRefInRemoteCommand() async throws {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data(), stderr: Data(), stdoutOverflow: false)
    ])
    let service = RemoteGitService(
      host: RemoteHost(alias: "example.com"), runner: runner
    )
    try await service.addWorktree(
      gitRoot: "/srv/app", branch: "feat-x", path: "/srv/feat-x", baseRef: "origin/main"
    )
    let remote = await runner.calls[0].arguments.last ?? ""
    #expect(remote.contains("worktree"))
    #expect(remote.contains("add"))
    #expect(remote.contains("-b"))
    #expect(remote.contains("feat-x"))
    #expect(remote.contains("origin/main"))
  }

  @Test
  func deleteBranchMapsRefusalToKept() async {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(
        code: 1,
        stdout: Data(),
        stderr: Data("error: cannot delete branch 'main' used by worktree at '/srv/app'".utf8),
        stdoutOverflow: false
      )
    ])
    let service = RemoteGitService(
      host: RemoteHost(alias: "example.com"), runner: runner
    )
    let outcome = await service.deleteBranchIfExists(gitRoot: "/srv/app", branch: "main")
    guard case .kept = outcome else {
      Issue.record("expected .kept, got \(outcome)")
      return
    }
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
