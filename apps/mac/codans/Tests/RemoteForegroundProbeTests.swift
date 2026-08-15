import CodansCore
import Foundation
import Testing

@testable import Codans

struct RemoteForegroundProbeTests {
  private let paneA = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
  private let paneB = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!

  @Test
  func parseKeepsOnlyForegroundGroupRows() {
    // BSD-style stats: the idle login shell has no `+` once claude owns the
    // foreground group; claude and its same-group child both carry it.
    let output = """
      \(paneA.uuidString) 500 500 Ss -zsh
      \(paneA.uuidString) 612 612 S+ claude
      \(paneA.uuidString) 630 612 S+ node /some/helper.js
      """
    let jobs = RemoteForegroundProbe.parse(output: output)
    let job = jobs[paneA]
    #expect(job?.processGroupID == 612)
    #expect(job?.processes.map(\.processName) == ["claude", "node"])
    #expect(AgentKindPatterns.classify(foregroundJob: job!) == .claudeCode)
  }

  @Test
  func parseIdlePromptIsTheShellForegroundGroup() {
    // At the prompt the shell IS the foreground group (Linux-style stat).
    // The login-shell `-` prefix survives into argv0; the classifier strips it.
    let output = "\(paneA.uuidString) 4211 4211 Ss+ -bash"
    let job = RemoteForegroundProbe.parse(output: output)[paneA]
    #expect(job?.processes.map(\.processName) == ["-bash"])
    #expect(AgentKindPatterns.classify(foregroundJob: job!) == nil)
    #expect(ForegroundJobClassifier.indicatesRunningCommand(job!) == false)
  }

  @Test
  func parseGroupsMultiplePanesIndependently() {
    let output = """
      \(paneA.uuidString) 100 100 S+ claude --continue
      \(paneB.uuidString) 200 200 R+ cargo build --release
      not-a-uuid 300 300 S+ rogue
      \(paneB.uuidString) garbage row here
      """
    let jobs = RemoteForegroundProbe.parse(output: output)
    #expect(jobs.count == 2)
    #expect(jobs[paneA]?.processes.first?.commandLine == "claude --continue")
    #expect(ForegroundJobClassifier.indicatesRunningCommand(jobs[paneB]!))
  }

  @Test
  func scriptIsValidShellAndPrunesDeadTTYs() throws {
    #expect(RemoteForegroundProbe.script.contains("rm -f"))
    #expect(RemoteForegroundProbe.script.contains("ps -t"))
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("codans-probe-\(UUID().uuidString).sh")
    try RemoteForegroundProbe.script.write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sh")
    proc.arguments = ["-n", file.path]
    try proc.run()
    proc.waitUntilExit()
    #expect(proc.terminationStatus == 0)
  }

  @Test
  func recordFragmentIsQuoteSafeAndKeyedByPane() {
    let fragment = RemoteForegroundProbe.recordTTYFragment(paneUUID: paneA.uuidString)
    #expect(fragment.contains("pane-ttys/\(paneA.uuidString)"))
    // The fragment crosses several single-quoting layers in the surface
    // command; an apostrophe would break out of them.
    #expect(!fragment.contains("'"))
    #expect(fragment.hasSuffix("; "))
  }
}
