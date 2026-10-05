import Foundation
import Testing

@testable import CodansCore

struct ForegroundJobClassifierTests {
  @Test
  func shellAtPromptIsNotRunning() {
    #expect(!ForegroundJobClassifier.indicatesRunningCommand(Self.job("zsh")))
    #expect(!ForegroundJobClassifier.indicatesRunningCommand(Self.job("bash")))
    #expect(!ForegroundJobClassifier.indicatesRunningCommand(Self.job("fish")))
    #expect(!ForegroundJobClassifier.indicatesRunningCommand(Self.job("/bin/zsh")))
  }

  @Test
  func loginShellArgv0IsNotRunning() {
    // Interactive login shells set argv0 to "-zsh" / "-bash".
    #expect(!ForegroundJobClassifier.indicatesRunningCommand(Self.job("-zsh")))
    #expect(ForegroundJobClassifier.isShell("-bash"))
    #expect(ForegroundJobClassifier.isShell("zsh"))
    #expect(!ForegroundJobClassifier.isShell("make"))
  }

  @Test
  func plainCommandIsRunning() {
    #expect(ForegroundJobClassifier.indicatesRunningCommand(Self.job("make")))
    #expect(ForegroundJobClassifier.indicatesRunningCommand(Self.job("pytest")))
    #expect(
      ForegroundJobClassifier.indicatesRunningCommand(
        Self.job("/usr/bin/node", commandLine: "node dev.js")))
  }

  @Test
  func recognizedAgentDefersToAgentState() {
    // Agents stay foreground for their whole session; their activity is
    // render-derived, so the foreground-job source must not report them busy.
    #expect(!ForegroundJobClassifier.indicatesRunningCommand(Self.job("claude")))
    #expect(!ForegroundJobClassifier.indicatesRunningCommand(Self.job("codex")))
  }

  @Test
  func emptyJobIsIdle() {
    #expect(
      !ForegroundJobClassifier.indicatesRunningCommand(
        ForegroundJob(processGroupID: 0, processes: [])))
  }

  @Test
  func pipelineOfNonShellsIsRunning() {
    let job = ForegroundJob(
      processGroupID: 200,
      processes: [Self.process("cat", pid: 200), Self.process("grep", pid: 201)]
    )
    #expect(ForegroundJobClassifier.indicatesRunningCommand(job))
  }

  // MARK: - indicatesBusyCommand

  @Test
  func interactiveSSHLoginIsRunningButNotBusy() {
    for line in [
      "ssh macmini", "/usr/bin/ssh -p 2222 user@host", "ssh -p2222 host", "ssh -i key -J jump host",
      "ssh host -v", "ssh -t host htop", "ssh -tt host tmux attach", "ssh -N -L 8080:localhost:80 host",
    ] {
      let job = Self.job("ssh", commandLine: line)
      #expect(ForegroundJobClassifier.indicatesRunningCommand(job), "\(line)")
      #expect(!ForegroundJobClassifier.indicatesBusyCommand(job), "\(line)")
    }
  }

  @Test
  func sshOptionValuesWithSpacesUseTheRealArgv() {
    // What the shell-integration `ssh` wrapper actually execs.
    let argv = [
      "ssh", "-o", "SetEnv COLORTERM=truecolor", "-o", "SendEnv TERM_PROGRAM TERM_PROGRAM_VERSION",
      "-o", "BatchMode=yes", "nanops-do",
    ]
    let process = ForegroundProcess(
      pid: 600, parentPID: 1, processGroupID: 600, argv0: "ssh",
      commandLine: argv.joined(separator: " "), arguments: argv)
    #expect(!ForegroundJobClassifier.indicatesBusyCommand(ForegroundJob(processGroupID: 600, processes: [process])))

    var withCommand = process
    withCommand.arguments = argv + ["uptime"]
    #expect(ForegroundJobClassifier.indicatesBusyCommand(ForegroundJob(processGroupID: 600, processes: [withCommand])))
  }

  @Test
  func sshRunningARemoteCommandIsBusy() {
    for line in [
      "ssh host make build", "ssh -p 22 host ls -la", "ssh host -- uptime", "ssh -o BatchMode=yes host true",
    ] {
      #expect(ForegroundJobClassifier.indicatesBusyCommand(Self.job("ssh", commandLine: line)), "\(line)")
    }
  }

  @Test
  func moshAndEtSessionsAreNotBusy() {
    #expect(!ForegroundJobClassifier.indicatesBusyCommand(Self.job("mosh-client", commandLine: "mosh-client -# host")))
    #expect(!ForegroundJobClassifier.indicatesBusyCommand(Self.job("et", commandLine: "et host")))
  }

  @Test
  func sshHelpersInItsGroupStillCountAsTheSession() {
    // ProxyCommand / ProxyJump helpers run in ssh's process group as its children.
    let job = ForegroundJob(
      processGroupID: 400,
      processes: [
        ForegroundProcess(pid: 400, parentPID: 1, processGroupID: 400, argv0: "ssh", commandLine: "ssh prod"),
        ForegroundProcess(
          pid: 401, parentPID: 400, processGroupID: 400, argv0: "ssh", commandLine: "ssh -W prod:22 bastion"),
        ForegroundProcess(pid: 402, parentPID: 400, processGroupID: 400, argv0: "nc", commandLine: "nc prod 22"),
      ])
    #expect(!ForegroundJobClassifier.indicatesBusyCommand(job))
  }

  @Test
  func sshInsideAPipelineIsBusy() {
    let job = ForegroundJob(
      processGroupID: 500,
      processes: [
        ForegroundProcess(pid: 500, parentPID: 1, processGroupID: 500, argv0: "ssh", commandLine: "ssh host"),
        ForegroundProcess(pid: 501, parentPID: 1, processGroupID: 500, argv0: "tee", commandLine: "tee log"),
      ])
    #expect(ForegroundJobClassifier.indicatesBusyCommand(job))
  }

  @Test
  func plainCommandsStayBusy() {
    #expect(ForegroundJobClassifier.indicatesBusyCommand(Self.job("make")))
    #expect(!ForegroundJobClassifier.indicatesBusyCommand(Self.job("zsh")))
    #expect(!ForegroundJobClassifier.indicatesBusyCommand(Self.job("claude")))
  }

  // MARK: - indicatesGitCommand

  @Test
  func gitAndGhAreGitCommands() {
    #expect(ForegroundJobClassifier.indicatesGitCommand(Self.job("git")))
    #expect(ForegroundJobClassifier.indicatesGitCommand(Self.job("gh")))
    #expect(
      ForegroundJobClassifier.indicatesGitCommand(
        Self.job("/usr/bin/git", commandLine: "git push")))
  }

  @Test
  func shellAndPlainCommandsAreNotGitCommands() {
    #expect(!ForegroundJobClassifier.indicatesGitCommand(Self.job("zsh")))
    #expect(!ForegroundJobClassifier.indicatesGitCommand(Self.job("-zsh")))
    #expect(!ForegroundJobClassifier.indicatesGitCommand(Self.job("make")))
    // VCS TUIs are long-running, not discrete prompt commands — excluded so
    // a refresh isn't kicked on every keystroke inside them.
    #expect(!ForegroundJobClassifier.indicatesGitCommand(Self.job("lazygit")))
  }

  @Test
  func agentRunningGitIsNotAGitCommand() {
    // An agent's own git subprocess is render-derived activity, not a prompt
    // command — defer to agent state, matching `indicatesRunningCommand`.
    let job = ForegroundJob(
      processGroupID: 300,
      processes: [Self.process("claude", pid: 300), Self.process("git", pid: 301)]
    )
    #expect(!ForegroundJobClassifier.indicatesGitCommand(job))
  }

  @Test
  func gitPushPipelineIsAGitCommand() {
    // `git push` spawns `git-remote-https`; the top-level `git` is still in
    // the group, so the job is recognised.
    let job = ForegroundJob(
      processGroupID: 300,
      processes: [
        Self.process("git", pid: 300, commandLine: "git push"),
        Self.process("git-remote-https", pid: 301),
      ]
    )
    #expect(ForegroundJobClassifier.indicatesGitCommand(job))
  }

  @Test
  func emptyJobIsNotAGitCommand() {
    #expect(
      !ForegroundJobClassifier.indicatesGitCommand(
        ForegroundJob(processGroupID: 0, processes: [])))
  }

  // MARK: - Helpers

  private static func job(_ argv0: String, commandLine: String? = nil) -> ForegroundJob {
    ForegroundJob(
      processGroupID: 123, processes: [process(argv0, pid: 123, commandLine: commandLine)])
  }

  private static func process(
    _ argv0: String, pid: Int32, commandLine: String? = nil
  ) -> ForegroundProcess {
    ForegroundProcess(
      pid: pid, parentPID: 1, processGroupID: 123, argv0: argv0,
      commandLine: commandLine ?? argv0)
  }
}
