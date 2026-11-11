import CodansCore
import Foundation
import Testing

@testable import Codans

/// The Git Platform CLI lookup and the agent installation check start their
/// probe through the shared login-shell launch, so they resolve with the same
/// shell and `PATH` as the background commands. `$SHELL` in the app's
/// environment does not choose the shell.
struct LoginShellLookupTests {
  typealias ShellCase = LoginShellRunnerIntegrationTests.ShellCase
  typealias Sandbox = LoginShellRunnerIntegrationTests.Sandbox

  /// `$SHELL` as a Dock-launched app can see it: unset, or a shell that is
  /// not the account's.
  enum StaleShell: CaseIterable, Sendable {
    case unset
    case other

    func value(for shell: LoginShell) -> String? {
      switch self {
      case .unset: nil
      case .other: shell.url.lastPathComponent == "bash" ? "/bin/zsh" : "/bin/bash"
      }
    }
  }

  /// A sandbox whose rc prints a banner on stdout and stderr and sets `PATH`
  /// to `$HOME/tools` plus the system directories, so only tools the test
  /// puts there resolve.
  private func sandbox(_ shellCase: ShellCase, tools: [String]) throws -> Sandbox {
    let sandbox = try Sandbox(
      rcName: shellCase.rcName,
      rc: shellCase.rc(
        posix: "echo 'Welcome banner'\necho 'rc warning' >&2\nexport PATH=\"$HOME/tools:/usr/bin:/bin\"\n",
        fish: "echo 'Welcome banner'\necho 'rc warning' >&2\nset -gx PATH $HOME/tools /usr/bin /bin\n"))
    for tool in tools {
      try sandbox.write("#!/bin/sh\nexit 0\n", to: "tools/\(tool)")
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: sandbox.home.appendingPathComponent("tools/\(tool)").path)
    }
    return sandbox
  }

  private func runner(_ shell: LoginShell) -> FoundationCommandRunner {
    FoundationCommandRunner(eofGrace: .milliseconds(200), loginShell: shell)
  }

  private func environment(_ sandbox: Sandbox, shell: String?) -> [String: String] {
    var env = ["HOME": sandbox.home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    env["SHELL"] = shell
    return env
  }

  // MARK: - Git Platform CLI lookup

  @Test(arguments: LoginShellRunnerIntegrationTests.shells, StaleShell.allCases)
  func cliLookupFindsACLIOnlyOnTheLoginShellPath(_ shellCase: ShellCase, stale: StaleShell) async throws {
    let command = "codans-test-cli-\(UUID().uuidString.prefix(8))"
    let sandbox = try sandbox(shellCase, tools: [command])
    let env = environment(sandbox, shell: stale.value(for: shellCase.shell))
    let probe = CLIExecutableResolver.livePathProbe(
      command: command, env: FixedEnvironment(values: env), runner: runner(shellCase.shell), home: sandbox.home)

    let found = await probe()

    #expect(found?.path == sandbox.home.appendingPathComponent("tools/\(command)").path)
  }

  @Test
  func cliLookupStartsWhichThroughTheLoginShell() async {
    let recorder = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data("/opt/tools/gh\n".utf8), stderr: Data(), stdoutOverflow: false)
    ])
    let home = URL(fileURLWithPath: "/tmp/home", isDirectory: true)

    let found = await CLIExecutableResolver.loginShellWhich("gh", runner: recorder, home: home)

    #expect(found?.path == "/opt/tools/gh")
    let calls = await recorder.calls
    #expect(calls.map(\.launch) == [.loginShell])
    #expect(calls.map(\.executable.path) == ["/usr/bin/which"])
    #expect(calls.map(\.arguments) == [["gh"]])
    #expect(calls.first?.env["SHELL"] == nil)
  }

  // MARK: - Agent installation check

  @Test(arguments: LoginShellRunnerIntegrationTests.shells, StaleShell.allCases)
  @MainActor
  func agentCheckFindsAnAgentOnlyOnTheLoginShellPath(_ shellCase: ShellCase, stale: StaleShell) async throws {
    let sandbox = try sandbox(shellCase, tools: [AgentCatalog.descriptor(for: .droid).executable])
    let store = AgentInstallationStore(
      runner: runner(shellCase.shell),
      environment: environment(sandbox, shell: stale.value(for: shellCase.shell)),
      home: sandbox.home)

    await store.rescan()

    #expect(store.hasScanned)
    #expect(store.installed == [.droid])
  }

  @Test
  @MainActor
  func agentCheckStartsThroughTheLoginShell() async {
    let recorder = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data("claude\t/opt/tools/claude\n".utf8), stderr: Data(), stdoutOverflow: false)
    ])
    let store = AgentInstallationStore(
      runner: recorder, environment: ["HOME": "/tmp/home", "SHELL": "/bin/bash"],
      home: URL(fileURLWithPath: "/tmp/home", isDirectory: true))

    await store.rescan()

    #expect(store.installed == [.claudeCode])
    let calls = await recorder.calls
    #expect(calls.map(\.launch) == [.loginShell])
    #expect(calls.map(\.executable.path) == ["/bin/sh"])
  }
}

private struct FixedEnvironment: EnvironmentVariableProvider {
  let values: [String: String]
  func value(for key: String) -> String? { values[key] }
}
