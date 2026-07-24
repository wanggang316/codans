import CodansCore
import Foundation
import Testing

@testable import Codans

struct SSHCommandTests {
  private let host = RemoteHost(alias: "example.com", username: "alice", port: 2222)

  @Test
  func controlOptionsMultiplexConnections() {
    let options = SSHCommand.controlOptions()
    #expect(options.contains("ControlMaster=auto"))
    #expect(options.contains("ControlPath=~/.ssh/codans-%C"))
    #expect(options.contains("ControlPersist=10m"))
    #expect(options.contains("ServerAliveInterval=5"))
  }

  @Test
  func remoteCommandPrependsCdAndExec() {
    let script = SSHCommand.remoteCommand(
      executable: "/usr/bin/git",
      arguments: ["worktree", "list", "--porcelain"],
      workingDirectory: "/srv/app"
    )
    #expect(script == "cd -- '/srv/app' && exec '/usr/bin/git' 'worktree' 'list' '--porcelain'")
  }

  @Test
  func remoteCommandWithoutWorkingDirectoryOmitsCd() {
    // No cwd → the bare invocation (no cd, no self-exec): the outer login-shell
    // wrapper already execs, and a one-shot command's exit status propagates.
    let script = SSHCommand.remoteCommand(
      executable: "/usr/bin/git", arguments: ["--version"], workingDirectory: nil
    )
    #expect(script == "'/usr/bin/git' '--version'")
  }

  @Test
  func remoteCommandQuotesPathsWithSpaces() {
    let script = SSHCommand.remoteCommand(
      executable: "/usr/bin/git", arguments: ["status"], workingDirectory: "/srv/my app"
    )
    #expect(script.contains("cd -- '/srv/my app'"))
  }

  @Test
  func loginShellWrappedRestoresPath() {
    #expect(SSHCommand.loginShellWrapped("echo hi") == "exec \"$SHELL\" -l -c 'echo hi'")
  }

  @Test
  func invocationBuildsSSHArgv() {
    let (executable, arguments) = SSHCommand.invocation(
      host: host,
      executable: "/usr/bin/git",
      arguments: ["worktree", "list"],
      workingDirectory: "/srv/app",
      extraOptions: SSHCommand.backgroundProbeOptions
    )
    #expect(executable.path == "/usr/bin/ssh")
    #expect(arguments.contains("BatchMode=yes"))
    #expect(arguments.contains("-p"))
    #expect(arguments.contains("2222"))
    // Destination is the user@host token, and it precedes the remote command.
    let destIndex = arguments.firstIndex(of: "alice@example.com")
    #expect(destIndex != nil)
    // The final argument is the single login-shell-wrapped remote command. Its
    // inner single quotes are `'\''`-escaped by the wrapper, so assert on the
    // unambiguous fragments rather than the raw inner quoting.
    let remote = arguments.last ?? ""
    #expect(remote.hasPrefix("exec \"$SHELL\" -l -c "))
    #expect(remote.contains("cd --"))
    #expect(remote.contains("/srv/app"))
    #expect(remote.contains("worktree"))
  }

  @Test
  func invocationOmitsPortWhenAbsent() {
    let (_, arguments) = SSHCommand.invocation(
      host: RemoteHost(alias: "example.com"),
      executable: "/bin/true",
      arguments: [],
      workingDirectory: nil
    )
    #expect(!arguments.contains("-p"))
    #expect(arguments.contains("example.com"))
  }

  @Test
  func commandLineDoubleQuotesForLocalShell() {
    let line = SSHCommand.commandLine(host: host, remoteCommand: "exec \"$SHELL\" -l")
    #expect(line.hasPrefix("/usr/bin/ssh "))
    #expect(line.contains("ConnectTimeout=30"))
    #expect(line.contains("-tt"))
    #expect(line.contains("alice@example.com"))
    // ControlPath option token stays unquoted so ssh expands ~ and %C.
    #expect(line.contains("ControlPath=~/.ssh/codans-%C"))
  }
}
