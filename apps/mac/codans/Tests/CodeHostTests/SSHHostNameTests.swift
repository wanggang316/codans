import Foundation
import Testing

@testable import Codans

/// `SSHHostName` asks `ssh -G` which host name an SSH host (or alias) connects to.
struct SSHHostNameTests {
  private static func ok(_ text: String) -> CommandOutcome {
    .exited(code: 0, stdout: Data(text.utf8), stderr: Data(), stdoutOverflow: false)
  }

  @Test
  func readsTheHostNameLineOfSSHG() async {
    let runner = RecordingCommandRunner(outcomes: [Self.ok("user git\nhostname github.com\nport 22\n")])
    let name = await SSHHostName(runner: runner).resolve("github-work")
    #expect(name == "github.com")
    let calls = await runner.calls
    #expect(calls.map(\.executable.path) == ["/usr/bin/ssh"])
    #expect(calls.map(\.arguments) == [["-G", "--", "github-work"]])
    #expect(calls.first?.env["PATH"] != nil)
  }

  @Test(arguments: ["-oProxyCommand=x", "a b", "", "host;rm"])
  func refusesANameThatIsNotAPlainHost(name: String) async {
    let runner = RecordingCommandRunner(outcomes: [])
    #expect(await SSHHostName(runner: runner).resolve(name) == nil)
    #expect(await runner.calls.isEmpty)
  }

  @Test(arguments: [
    CommandOutcome.exited(code: 255, stdout: Data(), stderr: Data("bad".utf8), stdoutOverflow: false),
    .timedOut,
    .spawnFailed(reason: "ENOENT"),
  ])
  func aFailedRunGivesNoName(outcome: CommandOutcome) async {
    #expect(await SSHHostName(runner: RecordingCommandRunner(outcomes: [outcome])).resolve("gl") == nil)
  }
}
