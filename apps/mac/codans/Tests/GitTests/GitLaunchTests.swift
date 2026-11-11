import Foundation
import Testing

@testable import Codans

/// The launch-mode table of `docs/design-docs/environment.md`, per git route.
struct GitLaunchTests {
  @Test(arguments: [
    ["clone", "--progress", "--", "http://h/r.git", "/tmp/r"],
    ["-C", "/repo", "fetch", "origin"],
    ["fetch", "origin"],
    ["-C", "/repo", "push", "origin", "--delete", "b"],
    ["pull", "--ff-only"],
    ["ls-remote", "--symref", "--", "http://h/r.git", "HEAD", "refs/heads/*"],
    ["-c", "credential.helper=x", "fetch"],
    ["-C", "/repo", "remote", "show", "origin"],
    ["remote", "update"],
    ["remote", "-v", "prune", "origin"],
  ])
  func commandsThatReachARemoteUseTheLoginShell(arguments: [String]) {
    #expect(GitLaunch.mode(for: arguments) == .loginShell)
  }

  @Test(arguments: [
    ["status", "--porcelain=v1", "-z"],
    ["diff", "--numstat"],
    ["log", "--format=%H"],
    ["rev-parse", "--is-inside-work-tree"],
    ["show-ref", "--verify", "refs/heads/main"],
    ["-C", "/repo", "branch", "-D", "b"],
    ["worktree", "list", "--porcelain"],
    ["-C", "/repo", "worktree", "add", "-b", "b", "/tmp/w", "origin/main"],
    ["-C", "/repo", "remote", "get-url", "origin"],
    ["remote", "show", "-n", "origin"],
    ["-C", "/repo", "for-each-ref", "--format=%(refname)", "refs/heads"],
    ["--version"],
    // A path or ref named like a remote command is not the subcommand.
    ["-C", "/fetch", "status"],
  ])
  func localCommandsRunDirectWithTheRetry(arguments: [String]) {
    #expect(GitLaunch.mode(for: arguments) == .directThenLoginShell)
  }

  @Test
  func bundledWtRunsDirectWithTheRetry() {
    let wt = URL(fileURLWithPath: "/Applications/Codans.app/Contents/Resources/git-wt/wt")
    #expect(GitWorktreeShell.launch(executable: wt, arguments: ["sw", "b"]) == .directThenLoginShell)
    #expect(GitWorktreeShell.launch(executable: GitWorktreeShell.gitURL, arguments: ["fetch"]) == .loginShell)
  }

  @Test
  func attemptsPerLaunchMode() {
    #expect(CommandLaunch.direct.attemptsViaLoginShell == [false])
    #expect(CommandLaunch.loginShell.attemptsViaLoginShell == [true])
    #expect(CommandLaunch.directThenLoginShell.attemptsViaLoginShell == [false, true])
  }

  @Test
  func missingCommandIsReportedByStatusOrStderr() {
    #expect(LoginShellLaunch.reportsMissingCommand(exitCode: 127, stderr: ""))
    #expect(
      LoginShellLaunch.reportsMissingCommand(
        exitCode: 128,
        stderr: "glab auth git-credential get: glab: command not found\nfatal: could not read Username"))
    #expect(!LoginShellLaunch.reportsMissingCommand(exitCode: 0, stderr: "x: command not found"))
    #expect(!LoginShellLaunch.reportsMissingCommand(exitCode: 1, stderr: "fatal: not a git repository"))
  }
}

/// Call-site audit through `LiveGitService`: status and diff refreshes start
/// direct (no rc cost); only a remote command would use the login shell.
struct LiveGitServiceLaunchTests {
  @Test
  func statusAndDiffRefreshesStartDirect() async {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data("true\n".utf8), stderr: Data(), stdoutOverflow: false)
    ])
    let service = LiveGitService(runner: runner, resolveRemoteHost: { _ in nil })
    let repo = URL(fileURLWithPath: "/tmp")
    _ = try? await service.status(at: repo)
    _ = try? await service.diffNumstat(at: repo)
    let calls = await runner.calls
    #expect(!calls.isEmpty)
    #expect(calls.allSatisfy { $0.launch == .directThenLoginShell })
  }
}
