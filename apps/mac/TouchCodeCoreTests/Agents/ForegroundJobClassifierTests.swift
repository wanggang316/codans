import Foundation
import Testing

@testable import TouchCodeCore

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
