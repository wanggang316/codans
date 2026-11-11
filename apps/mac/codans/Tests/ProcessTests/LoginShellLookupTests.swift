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
      command: command, launchEnvironment: { env }, env: FixedEnvironment(values: env),
      runner: runner(shellCase.shell), home: sandbox.home)

    let found = await probe()

    #expect(found?.path == sandbox.home.appendingPathComponent("tools/\(command)").path)
  }

  /// The app's `PATH` has another copy of the CLI; the login shell's `PATH`
  /// decides which one runs, so the lookup returns that one.
  @Test(arguments: LoginShellRunnerIntegrationTests.shells)
  func cliLookupPrefersTheLoginShellPathOverTheAppPath(_ shellCase: ShellCase) async throws {
    let command = "codans-test-cli-\(UUID().uuidString.prefix(8))"
    let sandbox = try sandbox(shellCase, tools: [command])
    try sandbox.write("#!/bin/sh\nexit 0\n", to: "app-path/\(command)")
    let appPath = sandbox.home.appendingPathComponent("app-path", isDirectory: true)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: appPath.appendingPathComponent(command).path)
    var env = environment(sandbox, shell: nil)
    env["PATH"] = appPath.path + ":/usr/bin:/bin"
    let launchEnv = env
    let probe = CLIExecutableResolver.livePathProbe(
      command: command, launchEnvironment: { launchEnv }, env: FixedEnvironment(values: env),
      runner: runner(shellCase.shell), home: sandbox.home)

    let found = await probe()

    #expect(found?.path == sandbox.home.appendingPathComponent("tools/\(command)").path)
  }

  @Test
  func cliLookupStartsWhichThroughTheLoginShellWithTheCLIEnvironment() async {
    let recorder = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data("/opt/tools/gh\n".utf8), stderr: Data(), stdoutOverflow: false)
    ])
    let launchEnv = ["HOME": "/tmp/home", "XDG_CONFIG_HOME": "/tmp/xdg", "PATH": "/usr/bin:/bin"]
    let probe = CLIExecutableResolver.livePathProbe(
      command: "gh", launchEnvironment: { launchEnv }, env: FixedEnvironment(values: [:]),
      runner: recorder, home: URL(fileURLWithPath: "/tmp/home", isDirectory: true))

    let found = await probe()

    #expect(found?.path == "/opt/tools/gh")
    let calls = await recorder.calls
    #expect(calls.map(\.launch) == [.loginShell])
    #expect(calls.map(\.executable.path) == ["/usr/bin/which"])
    #expect(calls.map(\.arguments) == [["gh"]])
    #expect(calls.map(\.env) == [launchEnv])
  }

  @Test
  func cliLookupFallsBackToTheAppPathWhenTheLoginShellCannotAnswer() async throws {
    let command = "codans-test-cli-\(UUID().uuidString.prefix(8))"
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("codans-lookup-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let cli = dir.appendingPathComponent(command)
    try "#!/bin/sh\nexit 0\n".write(to: cli, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
    let recorder = RecordingCommandRunner(outcomes: [
      .exited(code: 1, stdout: Data(), stderr: Data(), stdoutOverflow: false)
    ])
    let probe = CLIExecutableResolver.livePathProbe(
      command: command, launchEnvironment: { [:] }, env: FixedEnvironment(values: ["PATH": dir.path]),
      runner: recorder, home: URL(fileURLWithPath: "/tmp/home", isDirectory: true))

    let found = await probe()

    #expect(found?.path == cli.path)
    #expect(await recorder.calls.count == 1)
  }

  // MARK: - Agent installation check

  @MainActor
  private func agentStore(_ shellCase: ShellCase, sandbox: Sandbox, shell: String?) -> AgentInstallationStore {
    let loginShell = shellCase.shell
    return AgentInstallationStore(
      runner: runner(shellCase.shell), environment: environment(sandbox, shell: shell),
      home: sandbox.home, loginShell: { loginShell })
  }

  @Test(arguments: LoginShellRunnerIntegrationTests.shells, StaleShell.allCases)
  @MainActor
  func agentCheckFindsAnAgentOnlyOnTheLoginShellPath(_ shellCase: ShellCase, stale: StaleShell) async throws {
    let sandbox = try sandbox(shellCase, tools: [AgentCatalog.descriptor(for: .droid).executable])
    let store = agentStore(shellCase, sandbox: sandbox, shell: stale.value(for: shellCase.shell))

    await store.rescan()

    #expect(store.hasScanned)
    #expect(store.installed == [.droid])
  }

  /// A pane runs the agent command in an interactive shell, so an alias the
  /// rc defines launches the agent; the check sees it too.
  @Test(arguments: LoginShellRunnerIntegrationTests.shells.filter { !$0.isFish })
  @MainActor
  func agentCheckSeesAnAgentAliasFromTheRc(_ shellCase: ShellCase) async throws {
    let sandbox = try sandbox(shellCase, tools: [])
    let rc = sandbox.home.appendingPathComponent(shellCase.rcName)
    let text = try String(contentsOf: rc, encoding: .utf8)
    try sandbox.write(text + "alias droid='echo droid-alias'\n", to: shellCase.rcName)
    let store = agentStore(shellCase, sandbox: sandbox, shell: "/bin/sh")

    await store.rescan()

    #expect(store.installed == [.droid])
  }

  @Test
  @MainActor
  func agentCheckRunsTheAccountShellThroughTheLoginShellLaunch() async {
    let recorder = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data("claude\t/opt/tools/claude\n".utf8), stderr: Data(), stdoutOverflow: false)
    ])
    let store = AgentInstallationStore(
      runner: recorder, environment: ["HOME": "/tmp/home", "SHELL": "/bin/bash"],
      home: URL(fileURLWithPath: "/tmp/home", isDirectory: true),
      loginShell: { .zsh(URL(fileURLWithPath: "/bin/zsh")) })

    await store.rescan()

    #expect(store.installed == [.claudeCode])
    let calls = await recorder.calls
    #expect(calls.map(\.launch) == [.loginShell])
    #expect(calls.map(\.executable.path) == ["/bin/zsh"])
    #expect(calls.first?.arguments.prefix(2) == ["-i", "-c"])
  }
}

private struct FixedEnvironment: EnvironmentVariableProvider {
  let values: [String: String]
  func value(for key: String) -> String? { values[key] }
}
