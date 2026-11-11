import Darwin
import Foundation
import Testing

@testable import Codans

/// Runs real login shells against a temporary `HOME`, through the same
/// `FoundationCommandRunner` the app uses for git, `wt`, `gh`, and `glab`.
struct LoginShellRunnerIntegrationTests {
  struct ShellCase: CustomTestStringConvertible, Sendable {
    let shell: LoginShell
    /// Relative to `HOME`.
    let rcName: String
    /// The file `-l` reads, relative to `HOME`.
    let profileName: String
    var testDescription: String { shell.url.lastPathComponent }

    var isFish: Bool {
      if case .fish = shell { return true }
      return false
    }

    /// rc text in this shell's syntax.
    func rc(posix: String, fish: String) -> String { isFish ? fish : posix }
  }

  /// zsh and bash ship with macOS. fish runs when it is installed, or when
  /// `CODANS_TEST_FISH` names a binary (pass `TEST_RUNNER_CODANS_TEST_FISH` to
  /// `xcodebuild test`).
  static let shells: [ShellCase] = {
    var cases = [
      ShellCase(shell: .zsh(URL(fileURLWithPath: "/bin/zsh")), rcName: ".zshrc", profileName: ".zprofile"),
      ShellCase(shell: .bash(URL(fileURLWithPath: "/bin/bash")), rcName: ".bashrc", profileName: ".bash_profile"),
    ]
    let fishCandidates =
      [ProcessInfo.processInfo.environment["CODANS_TEST_FISH"]].compactMap(\.self)
      + ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
    if let fish = fishCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
      cases.append(
        ShellCase(
          shell: .fish(URL(fileURLWithPath: fish)), rcName: ".config/fish/config.fish",
          profileName: ".config/fish/conf.d/profile.fish"))
    }
    return cases
  }()

  /// A temporary `HOME` whose rc file is `rc`, plus a scratch directory.
  struct Sandbox {
    let home: URL
    let work: URL

    init(rcName: String, rc: String) throws {
      let root = URL(fileURLWithPath: Self.realPath(NSTemporaryDirectory()), isDirectory: true)
        .appendingPathComponent("codans-login-shell-\(UUID().uuidString)", isDirectory: true)
      home = root.appendingPathComponent("home", isDirectory: true)
      work = root.appendingPathComponent("work dir", isDirectory: true)
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
      try write(rc, to: rcName)
    }

    /// Writes `text` to `name` under `HOME`, creating its directories.
    func write(_ text: String, to name: String) throws {
      let file = home.appendingPathComponent(name)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try text.write(to: file, atomically: true, encoding: .utf8)
    }

    static func realPath(_ path: String) -> String {
      guard let resolved = realpath(path, nil) else { return path }
      defer { free(resolved) }
      return String(cString: resolved)
    }

    /// What a launchd-started app passes: a reduced PATH.
    var gitEnv: [String: String] {
      GitProcessEnv.build(from: ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
    }
  }

  private func runner(_ shell: LoginShell) -> FoundationCommandRunner {
    FoundationCommandRunner(eofGrace: .milliseconds(200), loginShell: shell)
  }

  private func text(_ data: Data) -> String { String(data: data, encoding: .utf8) ?? "" }

  /// PIDs whose full command line contains `pattern`.
  private func processes(matching pattern: String) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-fl", pattern]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    process.waitUntilExit()
    return text(pipe.fileHandleForReading.readDataToEndOfFile())
  }

  private func uniqueSleepSeconds() -> String { "3\(Int.random(in: 10_000...99_999)).5" }

  @Test(arguments: shells)
  func gitRunsAHelperThatOnlyTheRcPutsOnPath(_ shellCase: ShellCase) async throws {
    let sandbox = try Sandbox(
      rcName: shellCase.rcName,
      rc: shellCase.rc(posix: "export PATH=\"$HOME/tools:$PATH\"\n", fish: "set -gx PATH $HOME/tools $PATH\n"))
    let tools = sandbox.home.appendingPathComponent("tools", isDirectory: true)
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
    let helper = tools.appendingPathComponent("codans-test-helper")
    try "#!/bin/sh\necho helper-ran\n".write(to: helper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
    let arguments = ["-c", "alias.probe=!codans-test-helper", "probe"]

    let wrapped = await runner(shellCase.shell).run(
      executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments, env: sandbox.gitEnv,
      cwd: sandbox.work, timeout: .seconds(30), maxOutputBytes: 1 << 16, launch: .loginShell)
    guard case .exited(0, let stdout, _, _) = wrapped else {
      Issue.record("expected exit 0, got \(wrapped)")
      return
    }
    #expect(text(stdout) == "helper-ran\n")

    // Control: started directly, git does not find the helper.
    let direct = await FoundationCommandRunner().run(
      executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments, env: sandbox.gitEnv,
      cwd: sandbox.work, timeout: .seconds(30), maxOutputBytes: 1 << 16)
    guard case .exited(let code, _, _, _) = direct else {
      Issue.record("expected .exited, got \(direct)")
      return
    }
    #expect(code != 0)
  }

  /// A sandbox whose rc puts `$HOME/tools` (holding `codans-test-helper`)
  /// on `PATH` and appends a line to `$HOME/rc-ran` each time it runs.
  private func helperSandbox(_ shellCase: ShellCase) throws -> Sandbox {
    let sandbox = try Sandbox(
      rcName: shellCase.rcName,
      rc: shellCase.rc(
        posix: "echo ran >> \"$HOME/rc-ran\"\nexport PATH=\"$HOME/tools:$PATH\"\n",
        fish: "echo ran >> $HOME/rc-ran\nset -gx PATH $HOME/tools $PATH\n"))
    try sandbox.write("#!/bin/sh\necho helper-ran\n", to: "tools/codans-test-helper")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: sandbox.home.appendingPathComponent("tools/codans-test-helper").path)
    return sandbox
  }

  private func rcRuns(_ sandbox: Sandbox) -> Int {
    let marker = sandbox.home.appendingPathComponent("rc-ran")
    return ((try? String(contentsOf: marker, encoding: .utf8)) ?? "").split(separator: "\n").count
  }

  @Test(arguments: shells)
  func localStatusAndDiffStartNoLoginShell(_ shellCase: ShellCase) async throws {
    let sandbox = try helperSandbox(shellCase)
    let git = URL(fileURLWithPath: "/usr/bin/git")
    let runner = runner(shellCase.shell)
    for arguments in [["init", "-q"], ["status", "--porcelain=v1", "-z"], ["diff", "--numstat"]] {
      let outcome = await runner.run(
        executable: git, arguments: arguments, env: sandbox.gitEnv, cwd: sandbox.work,
        timeout: .seconds(30), maxOutputBytes: 1 << 16, launch: GitLaunch.mode(for: arguments))
      guard case .exited(0, _, _, _) = outcome else {
        Issue.record("git \(arguments) failed: \(outcome)")
        return
      }
    }
    #expect(rcRuns(sandbox) == 0)
  }

  @Test(arguments: shells)
  func directRunRetriesOnceInTheLoginShellWhenAToolIsMissing(_ shellCase: ShellCase) async throws {
    let sandbox = try helperSandbox(shellCase)
    // With an argument, git runs the alias through `sh`, as it runs
    // `!glab auth git-credential`; a missing program is then sh's 127.
    let arguments = ["-c", "alias.probe=!codans-test-helper --probe", "probe"]
    #expect(GitLaunch.mode(for: arguments) == .directThenLoginShell)
    let outcome = await runner(shellCase.shell).run(
      executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments, env: sandbox.gitEnv,
      cwd: sandbox.work, timeout: .seconds(30), maxOutputBytes: 1 << 16, launch: .directThenLoginShell)
    guard case .exited(0, let stdout, _, _) = outcome else {
      Issue.record("expected exit 0, got \(outcome)")
      return
    }
    #expect(text(stdout) == "helper-ran\n")
    #expect(rcRuns(sandbox) == 1)
  }

  /// The bundled `wt` is a script that calls other tools; one that exists
  /// only on the login `PATH` makes the direct run exit 127.
  @Test(arguments: shells)
  func streamedScriptRetriesOnceInTheLoginShellWhenAToolIsMissing(_ shellCase: ShellCase) async throws {
    let sandbox = try helperSandbox(shellCase)
    try sandbox.write("#!/bin/sh\necho start\ncodans-test-helper\n", to: "bin/fake-wt")
    let script = sandbox.home.appendingPathComponent("bin/fake-wt")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let lines = LockedLines()
    let result = await runner(shellCase.shell).runStream(
      executable: script, arguments: [], env: sandbox.gitEnv, cwd: sandbox.work, timeout: .seconds(30),
      launch: GitWorktreeShell.launch(executable: script, arguments: []), onLine: { lines.append($0) })
    guard case .exited(0, let lastStdoutLine, _) = result else {
      Issue.record("expected exit 0, got \(result)")
      return
    }
    #expect(lastStdoutLine == "helper-ran")
    // Both attempts stream: the direct one stops at the missing tool.
    #expect(lines.all.filter { $0 == "start" }.count == 2)
    #expect(rcRuns(sandbox) == 1)
  }

  @Test(arguments: shells)
  func rcOutputDoesNotReachCapturedOutput(_ shellCase: ShellCase) async throws {
    let sandbox = try Sandbox(rcName: shellCase.rcName, rc: "echo BANNER\necho BANNER-ERR >&2\n")
    // The profile `-l` reads runs before the script, outside its rc redirect.
    try sandbox.write("echo PROFILE-BANNER\necho PROFILE-BANNER-ERR >&2\n", to: shellCase.profileName)
    let outcome = await runner(shellCase.shell).run(
      executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["hello"], env: sandbox.gitEnv,
      cwd: sandbox.work, timeout: .seconds(30), maxOutputBytes: 1 << 16, launch: .loginShell)
    guard case .exited(0, let stdout, let stderr, _) = outcome else {
      Issue.record("expected exit 0, got \(outcome)")
      return
    }
    #expect(text(stdout) == "hello\n")
    #expect(text(stderr) == "")
  }

  @Test(arguments: shells)
  func rcCannotSeeOrChangeTheCommandOrItsDirectory(_ shellCase: ShellCase) async throws {
    let sandbox = try Sandbox(
      rcName: shellCase.rcName,
      rc: shellCase.rc(
        posix: "printf '%s' \"$*\" > \"$HOME/seen-args\"\nset -- /bin/echo hijacked\ncd /\n",
        fish: "printf '%s' \"$argv\" > $HOME/seen-args\nset -g argv /bin/echo hijacked\ncd /\n"))
    let outcome = await runner(shellCase.shell).run(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "/bin/pwd -P; printf '[%s]' \"$@\"", "sh", "a b", "it's", "$HOME", "\"q\""],
      env: sandbox.gitEnv, cwd: sandbox.work, timeout: .seconds(30), maxOutputBytes: 1 << 16, launch: .loginShell)
    guard case .exited(0, let stdout, _, _) = outcome else {
      Issue.record("expected exit 0, got \(outcome)")
      return
    }
    #expect(text(stdout) == "\(sandbox.work.path)\n[a b][it's][$HOME][\"q\"]")
    let seen = try String(contentsOf: sandbox.home.appendingPathComponent("seen-args"), encoding: .utf8)
    #expect(seen == "")
  }

  @Test(arguments: shells)
  func missingWorkingDirectoryExitsWith125(_ shellCase: ShellCase) async throws {
    let sandbox = try Sandbox(rcName: shellCase.rcName, rc: "")
    let outcome = await runner(shellCase.shell).run(
      executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], env: sandbox.gitEnv,
      cwd: sandbox.work.appendingPathComponent("gone", isDirectory: true),
      timeout: .seconds(30), maxOutputBytes: 1 << 16, launch: .loginShell)
    guard case .exited(let code, _, _, _) = outcome else {
      Issue.record("expected .exited, got \(outcome)")
      return
    }
    #expect(code == LoginShellLaunch.directoryFailureStatus)
  }

  @Test(arguments: shells)
  func strippedGitKeysExportedByTheRcDoNotReachGit(_ shellCase: ShellCase) async throws {
    let sandbox = try Sandbox(
      rcName: shellCase.rcName,
      rc: """
        export GIT_DIR=/nonexistent/.git
        export GIT_CONFIG_GLOBAL=/nonexistent/config
        export GIT_TERMINAL_PROMPT=1
        export LC_ALL=fr_FR.UTF-8
        export SECRET_TOKEN=leaked

        """)
    let git = URL(fileURLWithPath: "/usr/bin/git")
    let initOutcome = await FoundationCommandRunner().run(
      executable: git, arguments: ["init", "-q"], env: sandbox.gitEnv, cwd: sandbox.work,
      timeout: .seconds(30), maxOutputBytes: 1 << 16)
    #expect(initOutcome == .exited(code: 0, stdout: Data(), stderr: Data(), stdoutOverflow: false))

    let gitDir = await runner(shellCase.shell).run(
      executable: git, arguments: ["rev-parse", "--absolute-git-dir"], env: sandbox.gitEnv,
      cwd: sandbox.work, timeout: .seconds(30), maxOutputBytes: 1 << 16, launch: .loginShell)
    guard case .exited(0, let stdout, _, _) = gitDir else {
      Issue.record("expected exit 0, got \(gitDir)")
      return
    }
    #expect(text(stdout) == "\(sandbox.work.path)/.git\n")

    var env = sandbox.gitEnv
    env["GIT_TERMINAL_PROMPT"] = "0"
    let printed = await runner(shellCase.shell).run(
      executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [], env: env,
      cwd: sandbox.work, timeout: .seconds(30), maxOutputBytes: 1 << 16, launch: .loginShell)
    guard case .exited(0, let envOut, _, _) = printed else {
      Issue.record("expected exit 0, got \(printed)")
      return
    }
    let keys = Set(text(envOut).split(separator: "\n").compactMap { $0.split(separator: "=").first.map(String.init) })
    #expect(keys == ["HOME", "PATH", "LC_ALL", "GIT_TERMINAL_PROMPT"])
    #expect(text(envOut).contains("LC_ALL=C.UTF-8\n"))
    #expect(text(envOut).contains("GIT_TERMINAL_PROMPT=0\n"))
  }

  @Test(arguments: shells)
  func timeoutLeavesNoChildProcess(_ shellCase: ShellCase) async throws {
    let commandSleep = uniqueSleepSeconds()
    let rcSleep = uniqueSleepSeconds()
    // The command itself hangs.
    let sandbox = try Sandbox(rcName: shellCase.rcName, rc: "")
    let outcome = await runner(shellCase.shell).run(
      executable: URL(fileURLWithPath: "/bin/sleep"), arguments: [commandSleep], env: sandbox.gitEnv,
      cwd: sandbox.work, timeout: .milliseconds(500), maxOutputBytes: 1 << 16, launch: .loginShell)
    #expect(outcome == .timedOut)
    #expect(processes(matching: "sleep \(commandSleep)") == "")

    // The rc hangs before the command starts.
    let hangingRc = try Sandbox(rcName: shellCase.rcName, rc: "/bin/sleep \(rcSleep)\n")
    let rcOutcome = await runner(shellCase.shell).run(
      executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], env: hangingRc.gitEnv,
      cwd: hangingRc.work, timeout: .milliseconds(500), maxOutputBytes: 1 << 16, launch: .loginShell)
    #expect(rcOutcome == .timedOut)
    #expect(processes(matching: "sleep \(rcSleep)") == "")
  }

  @Test(arguments: shells)
  func cancelLeavesNoChildProcess(_ shellCase: ShellCase) async throws {
    let seconds = uniqueSleepSeconds()
    let sandbox = try Sandbox(rcName: shellCase.rcName, rc: "")
    let runner = runner(shellCase.shell)
    let env = sandbox.gitEnv
    let work = sandbox.work
    let task = Task {
      await runner.run(
        executable: URL(fileURLWithPath: "/bin/sleep"), arguments: [seconds], env: env,
        cwd: work, timeout: .seconds(60), maxOutputBytes: 1 << 16, launch: .loginShell)
    }
    // Wait until the command runs, so the cancel hits the real process.
    for _ in 0..<100 where processes(matching: "sleep \(seconds)").isEmpty {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(!processes(matching: "sleep \(seconds)").isEmpty)
    task.cancel()
    _ = await task.value
    #expect(processes(matching: "sleep \(seconds)") == "")
  }
}
