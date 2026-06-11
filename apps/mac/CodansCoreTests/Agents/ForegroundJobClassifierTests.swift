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
